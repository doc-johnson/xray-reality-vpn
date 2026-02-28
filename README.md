# Xray Reality VPN

One-command deploy for Xray VLESS+Reality with multi-user support, subscription links, monitoring dashboard and user management API.

## Demo

![Dashboard](demo.gif)

## What's inside

| File | Description |
|---|---|
| `init.sh` | Full server setup: installs Xray, nginx, TLS, configures subscriptions and monitoring |
| `sync-users.sh` | Pulls user list from server back to local `.env` |
| `collect-stats.sh` | Traffic stats collector (runs via cron every minute) |
| `index.html` | Monitoring dashboard (online status, traffic charts, IP tracking) |
| `api/` | User management REST API (Python/Flask, runs in Docker) |
| `.env` | Secrets: users, tokens, SSH port |
| `.env.example` | Template for `.env` |

## Quick start

1. Copy `.env.example` to `.env` and fill in your values:
   ```bash
   cp .env.example .env
   ```
2. Run the deploy:
   ```bash
   ./init.sh --ip <server-ip> --domain <domain>    # with TLS
   ./init.sh --ip <server-ip>                      # no domain (HTTP)
   ```

## Usage

### Initial deploy
```bash
./init.sh --ip <server-ip> [--domain <domain>] [--user <ssh-user>] [--force]
```

### Sync users
If users were added/removed via the web panel, pull changes to local `.env`:
```bash
./sync-users.sh --ip <server-ip> [--user <ssh-user>]
```

### Redeploy
```bash
./init.sh --ip <server-ip> [--domain <domain>] --force
```

| Flag | Description | Default |
|---|---|---|
| `--ip` | Server IP address | required |
| `--domain` | Server domain (enables TLS for subscriptions) | optional |
| `--user` | SSH user | `root` |
| `--force` | Remove existing install and redeploy without confirmation | — |

> **Note on `--force`:** preserves traffic stats (`totals.json`, `history.json`) and `access.log`. Generates new Reality keys — clients need to re-fetch their subscription.

### No-domain mode

When `--domain` is omitted:
- No certbot, no certificates
- Nginx serves subscriptions over plain HTTP on port 8443
- Subscription URLs: `http://<ip>:8443/sub/<token>`
- Port 80 stays closed
- No certbot renew in cron

`SSH_PORT` in `.env` — the port SSH will be changed to on the server. The script connects on default port 22, then changes it to the specified one.

## Subscriptions

Each user gets a personal subscription URL:
- With domain: `https://<domain>:8443/sub/<token>`
- Without domain: `http://<ip>:8443/sub/<token>`

Tokens are generated automatically (32-character hex). Copy the URL and add it to any compatible client: v2rayN, v2rayNG, Shadowrocket, Hiddify, etc.

## API

Base URL: `http://<server-ip>:8080/api/` (accessible only through VPN).

Authorization: `X-API-Key` header with the key from `.env`.

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/users` | List all users |
| `POST` | `/api/users` | Create a new user |
| `DELETE` | `/api/users/<name>` | Delete a user |
| `POST` | `/api/users/<name>/disable` | Disable a user |
| `POST` | `/api/users/<name>/enable` | Enable a user |
| `POST` | `/api/users/<name>/reset` | Reset traffic statistics |

## Monitoring dashboard

Access: `http://<server-ip>:8080` — only through VPN.

The dashboard shows:
- User table: online status, traffic usage, IP addresses
- Traffic charts: 1h / 6h / 24h
- Activity timeline
- IP address table

If the API key is configured, the dashboard also provides a user management panel (create, delete, enable/disable users).

## Requirements

**Local machine:**
- macOS or Linux
- `ssh` access to the server (key-based or password)
- `jq` for `sync-users.sh` (`brew install jq`)
- `curl`

**Server:**
- Ubuntu 20.04+
- 1 vCPU, 1 GB RAM
- Open ports: 443 (Xray), 8443 (subscriptions)
- Port 8080 (monitoring) is blocked externally, accessible only through VPN

## Cron jobs

`init.sh` automatically installs the following cron jobs on the server via `crontab`:

- **Every minute** — run `collect-stats.sh` to collect traffic statistics from Xray access log and update `totals.json` / `history.json`
- **Daily at 03:00** — truncate `access.log` to prevent disk overflow (resets to 0 bytes)
- **1st of every 2 months at 03:00** — renew TLS certificate via certbot (domain mode only; stops nginx during renewal)

## Docker

Docker is installed automatically if not present on the server.

Three containers run in a single bridge network `xray-net`:

| Container | Role |
|---|---|
| `xray` | Xray VPN server |
| `xray-nginx` | Nginx — subscriptions + monitoring dashboard |
| `xray-api` | REST API (Flask / Gunicorn) |

## Security

The server is hardened automatically during deploy:

- **Firewall**: ports 443, 8443, SSH open via firewalld; port 80 open only with domain. Port 8080 blocked externally via iptables `DOCKER-USER` chain (persisted with systemd), accessible only through VPN
- **SSH**: key-only authentication, `MaxAuthTries 3`, custom port, PAM and X11 disabled
- **API key**: 32-char hex generated with `openssl rand`, passed via `X-API-Key` header
- **Subscription tokens**: generated with `secrets.token_hex()` (cryptographically secure)
- **Nginx**: TLS 1.2/1.3 only (domain mode), all paths except `/sub/` return 404, volumes mounted read-only
- **Secrets**: `.env` file has `600` permissions; API key regenerated on each deploy
- **Input validation**: usernames checked for length and allowed characters
- **Docker socket**: mounted in API container to restart Xray. If the API is compromised, the attacker gets root on the host

## TODO

- [ ] Store API key as hash, compare with `hmac.compare_digest()` to prevent timing attacks
- [ ] Add rate limiting to API (`flask-limiter`) to protect against key brute-force
- [ ] Remove Docker socket mount — use Xray gRPC API for hot-reload user management instead of container restart
- [ ] Add authentication for subscription URLs (basic auth or TTL links)

## License

MIT
