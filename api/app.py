import base64
import fcntl
import json
import os
import uuid
import secrets
import threading
from contextlib import contextmanager
from functools import wraps
from pathlib import Path

import docker
from flask import Flask, jsonify, request

app = Flask(__name__)

# --- Paths ---
CONFIG_DIR = Path("/data/config")
SUB_DIR = Path("/data/subscriptions")
MON_DIR = Path("/data/monitoring")
CONFIG_FILE = CONFIG_DIR / "config.json"
UUIDS_FILE = CONFIG_DIR / ".user_uuids"
DISABLED_FILE = CONFIG_DIR / ".disabled_users"

# --- Env ---
API_KEY = os.environ.get("API_KEY", "")
DOMAIN = os.environ.get("DOMAIN", "")
SERVER_ADDRESS = os.environ.get("SERVER_ADDRESS", "")
SUB_PORT = os.environ.get("SUB_PORT", "8443")

# --- Reality params (read once at startup from existing config) ---
REALITY = {}


def load_reality_params():
    """Extract Reality parameters from existing xray config."""
    global REALITY
    try:
        cfg = json.loads(CONFIG_FILE.read_text())
        for inbound in cfg.get("inbounds", []):
            rs = inbound.get("streamSettings", {}).get("realitySettings")
            if rs:
                REALITY = {
                    "dest": rs.get("dest", ""),
                    "serverNames": rs.get("serverNames", []),
                    "publicKey": "",  # filled from xray x25519 — not in config
                    "shortIds": rs.get("shortIds", []),
                }
                break
    except Exception as e:
        app.logger.warning(f"Could not load reality params: {e}")


# --- File lock for concurrent access ---
LOCK_FILE = CONFIG_DIR / ".api.lock"


@contextmanager
def file_lock():
    """Process-safe file lock (works across gunicorn workers)."""
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        fd.close()


# --- Helpers ---

def require_api_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        key = request.headers.get("X-API-Key", "")
        if not API_KEY or key != API_KEY:
            return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated


def read_uuids():
    """Return dict {username: uuid}."""
    result = {}
    if UUIDS_FILE.exists():
        for line in UUIDS_FILE.read_text().strip().splitlines():
            if ":" in line:
                name, uid = line.split(":", 1)
                result[name.strip()] = uid.strip()
    return result


def write_uuids(uuids):
    """Write dict {username: uuid} to file."""
    lines = [f"{name}:{uid}" for name, uid in uuids.items()]
    UUIDS_FILE.write_text("\n".join(lines) + "\n" if lines else "")


def read_disabled():
    """Return set of disabled usernames."""
    if DISABLED_FILE.exists():
        return set(DISABLED_FILE.read_text().strip().splitlines())
    return set()


def write_disabled(disabled):
    """Write set of disabled usernames."""
    DISABLED_FILE.write_text("\n".join(sorted(disabled)) + "\n" if disabled else "")


def read_config():
    return json.loads(CONFIG_FILE.read_text())


def write_config(cfg):
    CONFIG_FILE.write_text(json.dumps(cfg, indent=4) + "\n")


def read_totals():
    totals_file = MON_DIR / "totals.json"
    if totals_file.exists():
        try:
            return json.loads(totals_file.read_text())
        except Exception:
            pass
    return {}


def write_totals(totals):
    totals_file = MON_DIR / "totals.json"
    totals_file.write_text(json.dumps(totals, indent=2) + "\n")


def find_subscription_token(username):
    """Find subscription token for user by checking subscription files."""
    uuids = read_uuids()
    user_uuid = uuids.get(username)
    if not user_uuid:
        return None
    for f in SUB_DIR.iterdir():
        if f.is_file() and not f.name.startswith("."):
            try:
                content = base64.b64decode(f.read_text().strip()).decode()
                if user_uuid in content:
                    return f.name
            except Exception:
                continue
    return None


def get_subscription_url(username):
    token = find_subscription_token(username)
    if token:
        if DOMAIN:
            return f"https://{DOMAIN}:{SUB_PORT}/sub/{token}"
        return f"http://{SERVER_ADDRESS}:{SUB_PORT}/sub/{token}"
    return None


def build_vless_link(username, user_uuid):
    """Build VLESS subscription link."""
    cfg = read_config()
    for inbound in cfg.get("inbounds", []):
        rs = inbound.get("streamSettings", {}).get("realitySettings")
        if rs:
            sni = rs["serverNames"][0] if rs.get("serverNames") else ""
            sid = rs["shortIds"][0] if rs.get("shortIds") else ""
            # publicKey must come from env or stored separately
            pbk = os.environ.get("REALITY_PUBLIC_KEY", REALITY.get("publicKey", ""))
            return (
                f"vless://{user_uuid}@{SERVER_ADDRESS}:443"
                f"?security=reality&encryption=none&flow=xtls-rprx-vision"
                f"&pbk={pbk}&fp=chrome&sni={sni}&sid={sid}&type=tcp"
                f"#{username}"
            )
    return None


def create_subscription_file(username, user_uuid):
    """Create subscription file with VLESS link."""
    vless = build_vless_link(username, user_uuid)
    if not vless:
        return None
    token = secrets.token_hex(16)
    sub_path = SUB_DIR / token
    sub_path.write_text(base64.b64encode(vless.encode()).decode())
    return token


def rebuild_xray_config(uuids, disabled):
    """Rebuild xray config.json with active users only."""
    cfg = read_config()
    active_uuids = {name: uid for name, uid in uuids.items() if name not in disabled}

    clients = []
    for name, uid in active_uuids.items():
        clients.append({
            "id": uid,
            "flow": "xtls-rprx-vision",
            "email": name,
            "level": 0,
        })

    for inbound in cfg.get("inbounds", []):
        if inbound.get("protocol") == "vless":
            inbound["settings"]["clients"] = clients
            break

    write_config(cfg)


def restart_xray():
    """Restart xray container in background thread so API responds immediately."""
    def _restart():
        try:
            client = docker.from_env()
            container = client.containers.get("xray")
            container.restart(timeout=5)
        except Exception as e:
            app.logger.error(f"Failed to restart xray: {e}")
    threading.Thread(target=_restart, daemon=True).start()


# --- API Endpoints ---

@app.route("/api/users", methods=["GET"])
@require_api_key
def list_users():
    uuids = read_uuids()
    disabled = read_disabled()
    totals = read_totals()

    # Read stats.json for IP data
    stats = {}
    stats_file = MON_DIR / "stats.json"
    if stats_file.exists():
        try:
            stats = json.loads(stats_file.read_text()).get("users", {})
        except Exception:
            pass

    users = []
    for name in uuids:
        status = "disabled" if name in disabled else "active"
        sub_url = get_subscription_url(name)
        user_totals = totals.get(name, {})
        user_stats = stats.get(name, {})
        users.append({
            "username": name,
            "status": status,
            "subscription_url": sub_url,
            "traffic": {
                "uplink": user_totals.get("up", 0),
                "downlink": user_totals.get("dn", 0),
            },
            "ips_now": user_stats.get("ips_now", 0),
            "ips_max_24h": user_stats.get("ips_max_24h", 0),
        })

    return jsonify({"users": users})


@app.route("/api/users", methods=["POST"])
@require_api_key
def create_user():
    data = request.get_json(silent=True) or {}
    username = data.get("username", "").strip()

    if not username:
        return jsonify({"error": "Username is required"}), 400
    if len(username) > 32:
        return jsonify({"error": "Username too long (max 32 chars)"}), 400
    if not username.replace("_", "").replace("-", "").isalnum():
        return jsonify({"error": "Username must be alphanumeric (with _ or -)"}), 400

    with file_lock():
        uuids = read_uuids()
        if username in uuids:
            return jsonify({"error": f"User '{username}' already exists"}), 409

        user_uuid = str(uuid.uuid4())
        uuids[username] = user_uuid
        write_uuids(uuids)

        token = create_subscription_file(username, user_uuid)
        disabled = read_disabled()
        rebuild_xray_config(uuids, disabled)

    restart_xray()

    if token:
        sub_url = f"https://{DOMAIN}:{SUB_PORT}/sub/{token}" if DOMAIN else f"http://{SERVER_ADDRESS}:{SUB_PORT}/sub/{token}"
    else:
        sub_url = None
    return jsonify({
        "username": username,
        "uuid": user_uuid,
        "subscription_url": sub_url,
        "status": "active",
    }), 201


@app.route("/api/users/<name>", methods=["DELETE"])
@require_api_key
def delete_user(name):
    with file_lock():
        uuids = read_uuids()
        if name not in uuids:
            return jsonify({"error": f"User '{name}' not found"}), 404

        # Remove subscription file
        token = find_subscription_token(name)
        if token:
            sub_path = SUB_DIR / token
            if sub_path.exists():
                sub_path.unlink()

        # Remove from uuids
        del uuids[name]
        write_uuids(uuids)

        # Remove from disabled
        disabled = read_disabled()
        disabled.discard(name)
        write_disabled(disabled)

        # Remove from totals
        totals = read_totals()
        totals.pop(name, None)
        write_totals(totals)

        # Remove from stats.json
        stats_file = MON_DIR / "stats.json"
        if stats_file.exists():
            try:
                stats = json.loads(stats_file.read_text())
                stats.get("users", {}).pop(name, None)
                stats_file.write_text(json.dumps(stats, indent=2) + "\n")
            except Exception:
                pass

        # Remove from history.json
        history_file = MON_DIR / "history.json"
        if history_file.exists():
            try:
                history = json.loads(history_file.read_text())
                for entry in history:
                    entry.get("users", {}).pop(name, None)
                history_file.write_text(json.dumps(history) + "\n")
            except Exception:
                pass

        # Rebuild config and restart
        rebuild_xray_config(uuids, disabled)

    restart_xray()

    return jsonify({"message": f"User '{name}' deleted"})


@app.route("/api/users/<name>/disable", methods=["POST"])
@require_api_key
def disable_user(name):
    with file_lock():
        uuids = read_uuids()
        if name not in uuids:
            return jsonify({"error": f"User '{name}' not found"}), 404

        disabled = read_disabled()
        if name in disabled:
            return jsonify({"message": f"User '{name}' is already disabled"})

        disabled.add(name)
        write_disabled(disabled)
        rebuild_xray_config(uuids, disabled)

    restart_xray()

    return jsonify({"message": f"User '{name}' disabled"})


@app.route("/api/users/<name>/enable", methods=["POST"])
@require_api_key
def enable_user(name):
    with file_lock():
        uuids = read_uuids()
        if name not in uuids:
            return jsonify({"error": f"User '{name}' not found"}), 404

        disabled = read_disabled()
        if name not in disabled:
            return jsonify({"message": f"User '{name}' is already enabled"})

        disabled.discard(name)
        write_disabled(disabled)
        rebuild_xray_config(uuids, disabled)

    restart_xray()

    return jsonify({"message": f"User '{name}' enabled"})


@app.route("/api/users/<name>/reset", methods=["POST"])
@require_api_key
def reset_traffic(name):
    with file_lock():
        uuids = read_uuids()
        if name not in uuids:
            return jsonify({"error": f"User '{name}' not found"}), 404

        totals = read_totals()
        totals[name] = {"up": 0, "dn": 0, "last_seen": ""}
        write_totals(totals)

    return jsonify({"message": f"Traffic reset for '{name}'"})


# --- Startup ---
with app.app_context():
    load_reality_params()
