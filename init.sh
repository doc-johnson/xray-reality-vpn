#!/bin/bash
# ============================================================
# Xray Reality VPN — Multi-user with subscriptions & monitoring
# Usage: ./init.sh --ip <server-ip> [--domain <domain>] [--user <user>] [--force]
# Example: ./init.sh --ip 1.2.3.4 --domain example.com
# Without domain: ./init.sh --ip 1.2.3.4  (subscriptions via HTTP)
# ============================================================

# --- Configuration ---
DESTINATION="www.microsoft.com:443"
XRAY_VERSION="26.2.6"
STATS_PORT=8080
SUB_PORT=8443

# --- Load secrets from .env ---
SCRIPT_DIR_CFG="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR_CFG/.env"
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
else
    echo "ERROR: .env not found at $ENV_FILE"
    echo "Copy .env.example to .env and fill in your values."
    exit 1
fi
USERS=($USERS)
SSH_PORT="${SSH_PORT:-22}"
[[ -z "$SSH_PORT" ]] && SSH_PORT=22
TZ="${TZ:-UTC}"

# --- Helpers ---
get_token() { eval echo "\${TOKEN_${1}}"; }

has_any_token() {
    for user in "${USERS[@]}"; do
        [[ -n "$(get_token "$user")" ]] && return 0
    done
    return 1
}

generate_tokens() {
    local env_path="$1"
    for user in "${USERS[@]}"; do
        local token
        token=$(openssl rand -hex 16)
        eval "TOKEN_${user}=\"$token\""
        perl -i -pe "s/^TOKEN_${user}=.*/TOKEN_${user}=\"${token}\"/" "$env_path"
    done
}

sub_base_url() {
    if [[ -n "$DOMAIN" ]]; then
        echo "https://$DOMAIN:$SUB_PORT"
    else
        echo "http://$SERVER_ADDRESS:$SUB_PORT"
    fi
}

# --- Argument parsing ---
SERVER_ADDRESS=""
DOMAIN=""
SSH_USER="root"
DEPLOY_MODE=false
FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)     [[ $# -ge 2 ]] || { echo "Error: $1 requires a value"; exit 1; }; SERVER_ADDRESS="$2"; shift ;;
        --domain) [[ $# -ge 2 ]] || { echo "Error: $1 requires a value"; exit 1; }; DOMAIN="$2"; shift ;;
        --user)   [[ $# -ge 2 ]] || { echo "Error: $1 requires a value"; exit 1; }; SSH_USER="$2"; shift ;;
        --deploy) DEPLOY_MODE=true ;;
        --force)  FORCE=true ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done
[[ -z "$SERVER_ADDRESS" ]] && { echo "Usage: $0 --ip <server-ip> [--domain <domain>] [--user <user>] [--force]"; exit 1; }

# ================================================================
#                        LOCAL MODE
# ================================================================
if [[ "$DEPLOY_MODE" == "false" ]]; then
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    echo "=== Xray Reality VPN Deployment ==="
    echo "Server: $SERVER_ADDRESS"
    echo ""

    if has_any_token; then
        echo "Existing subscription URLs:"
        for user in "${USERS[@]}"; do
            echo "  $user: $(sub_base_url)/sub/$(get_token "$user")"
        done
        echo ""
        read -rp "Generate NEW subscription URLs? (y/N): " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            generate_tokens "$ENV_FILE"
            echo "New tokens generated and saved."
        fi
    else
        echo "No existing tokens — generating new ones..."
        generate_tokens "$ENV_FILE"
        echo "Tokens generated and saved."
    fi

    echo ""
    echo "Subscription URLs:"
    for user in "${USERS[@]}"; do
        echo "  $user: $(sub_base_url)/sub/$(get_token "$user")"
    done
    echo ""

    # Determine SSH port
    echo "Connecting to server..."
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p "$SSH_PORT" ${SSH_USER}@"$SERVER_ADDRESS" true 2>/dev/null; then
        REMOTE_SSH_PORT=$SSH_PORT
    else
        REMOTE_SSH_PORT=22
    fi
    echo "SSH port: $REMOTE_SSH_PORT"

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    scp -P "$REMOTE_SSH_PORT" -o StrictHostKeyChecking=accept-new "$SCRIPT_PATH" ${SSH_USER}@"$SERVER_ADDRESS":/tmp/deploy-xray.sh
    scp -P "$REMOTE_SSH_PORT" -o StrictHostKeyChecking=accept-new "$ENV_FILE" ${SSH_USER}@"$SERVER_ADDRESS":/tmp/.env
    scp -P "$REMOTE_SSH_PORT" -o StrictHostKeyChecking=accept-new "$SCRIPT_DIR/collect-stats.sh" ${SSH_USER}@"$SERVER_ADDRESS":/tmp/collect-stats.sh
    scp -P "$REMOTE_SSH_PORT" -o StrictHostKeyChecking=accept-new "$SCRIPT_DIR/index.html" ${SSH_USER}@"$SERVER_ADDRESS":/tmp/monitor-index.html
    scp -rP "$REMOTE_SSH_PORT" -o StrictHostKeyChecking=accept-new "$SCRIPT_DIR/api" ${SSH_USER}@"$SERVER_ADDRESS":/tmp/deploy-api
    DEPLOY_CMD="chmod +x /tmp/deploy-xray.sh && bash /tmp/deploy-xray.sh --ip $SERVER_ADDRESS --deploy --force"
    [[ -n "$DOMAIN" ]] && DEPLOY_CMD="chmod +x /tmp/deploy-xray.sh && bash /tmp/deploy-xray.sh --ip $SERVER_ADDRESS --domain $DOMAIN --deploy --force"
    ssh -p "$REMOTE_SSH_PORT" -o StrictHostKeyChecking=accept-new ${SSH_USER}@"$SERVER_ADDRESS" "$DEPLOY_CMD"

    echo ""
    echo "=== Deployment Complete ==="
    echo ""
    echo "Subscription URLs (share with users):"
    for user in "${USERS[@]}"; do
        echo "  $user: $(sub_base_url)/sub/$(get_token "$user")"
    done
    echo ""
    echo "Monitoring (only via VPN): http://$SERVER_ADDRESS:$STATS_PORT"
    echo "SSH: ssh -p $SSH_PORT $SSH_USER@$SERVER_ADDRESS"
    exit 0
fi

# ================================================================
#                       DEPLOY MODE (on server)
# ================================================================
set -euo pipefail

WORK_DIR="$HOME/xray"

# --- Install dependencies ---
install_dependencies() {
    echo ">>> Installing dependencies..."
    apt-get update -y
    local packages="ca-certificates curl gnupg jq cron"
    [[ -n "$DOMAIN" ]] && packages="$packages certbot"
    apt-get install -y $packages

    # Docker
    if ! command -v docker &>/dev/null; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            | tee /etc/apt/sources.list.d/docker.list >/dev/null
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    fi
    systemctl enable docker
    systemctl start docker

    # Docker Compose plugin (if missing)
    if ! docker compose version &>/dev/null; then
        echo ">>> Installing Docker Compose plugin..."
        mkdir -p /usr/local/lib/docker/cli-plugins
        curl -SL "https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-$(uname -m)" \
            -o /usr/local/lib/docker/cli-plugins/docker-compose
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    fi

    # Firewall
    apt-get install -y firewalld
    systemctl enable firewalld
    systemctl start firewalld
    sleep 2
    firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
    firewall-cmd --permanent --add-port=443/tcp
    [[ -n "$DOMAIN" ]] && firewall-cmd --permanent --add-port=80/tcp
    firewall-cmd --permanent --add-port=${SUB_PORT}/tcp
    # Port $STATS_PORT intentionally NOT opened — monitoring only via VPN
    firewall-cmd --permanent --zone=public --add-masquerade
    firewall-cmd --permanent --zone=trusted --add-interface=docker0
    firewall-cmd --reload

    # SSH hardening
    cat > /etc/ssh/sshd_config <<SSHEOF
Include /etc/ssh/sshd_config.d/*.conf
Port $SSH_PORT
MaxAuthTries 3
MaxSessions 10
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PrintMotd no
X11Forwarding no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
SSHEOF
    systemctl enable ssh
    systemctl restart sshd
}

# --- TLS certificate ---
obtain_certificate() {
    if [[ -z "$DOMAIN" ]]; then
        echo ">>> No domain specified, skipping TLS certificate."
        return
    fi
    echo ">>> Obtaining TLS certificate for $DOMAIN..."
    if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
        echo "  Certificate already exists, skipping."
    else
        certbot certonly --standalone --non-interactive --agree-tos \
            --register-unsafely-without-email -d "$DOMAIN"
    fi
}

# --- Reality keys ---
generate_reality_keys() {
    echo ">>> Generating Reality keys..."
    REALITY_KEYS=$(docker run --rm teddysun/xray:$XRAY_VERSION xray x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$REALITY_KEYS" | awk '/PrivateKey:/ {print $NF}')
    PUBLIC_KEY=$(echo "$REALITY_KEYS"  | awk '/Password:/   {print $NF}')
    SHORT_ID=$(openssl rand -hex 8)
    echo "  Public key: ${PUBLIC_KEY:0:12}..."
    echo "  Short ID:   $SHORT_ID"
}

# --- Xray config with stats ---
generate_xray_config() {
    echo ">>> Generating Xray config..."
    mkdir -p config

    # Build clients JSON
    CLIENTS_JSON=""
    > config/.user_uuids
    for user in "${USERS[@]}"; do
        UUID=$(cat /proc/sys/kernel/random/uuid)
        echo "${user}:${UUID}" >> config/.user_uuids
        [[ -n "$CLIENTS_JSON" ]] && CLIENTS_JSON+=","
        CLIENTS_JSON+="
            {
                \"id\": \"$UUID\",
                \"flow\": \"xtls-rprx-vision\",
                \"email\": \"$user\",
                \"level\": 0
            }"
    done

    cat > config/config.json <<XEOF
{
    "log": {
        "loglevel": "warning",
        "access": "/etc/xray/access.log"
    },
    "dns": {
        "servers": [
            "https+local://1.1.1.1/dns-query",
            "https+local://8.8.8.8/dns-query"
        ],
        "queryStrategy": "UseIPv4"
    },
    "stats": {},
    "api": {
        "tag": "api",
        "services": ["StatsService"]
    },
    "policy": {
        "levels": {
            "0": {
                "statsUserUplink": true,
                "statsUserDownlink": true
            }
        },
        "system": {
            "statsInboundUplink": true,
            "statsInboundDownlink": true
        }
    },
    "inbounds": [
        {
            "tag": "api-in",
            "listen": "127.0.0.1",
            "port": 10085,
            "protocol": "dokodemo-door",
            "settings": {
                "address": "127.0.0.1"
            }
        },
        {
            "tag": "vless-in",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [$CLIENTS_JSON],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$DESTINATION",
                    "serverNames": ["${DESTINATION%:*}"],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": ["$SHORT_ID"],
                    "fingerprint": "chrome"
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        }
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {
                "inboundTag": ["api-in"],
                "outboundTag": "api",
                "type": "field"
            }
        ]
    },
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}
XEOF
    echo "  Config saved: config/config.json"
}

# --- Subscription files ---
create_subscriptions() {
    echo ">>> Creating subscription files..."
    mkdir -p subscriptions

    while IFS=: read -r user uuid; do
        local token
        token=$(get_token "$user")
        [[ -z "$token" ]] && { echo "  WARNING: no token for $user, skipping"; continue; }

        VLESS_LINK="vless://${uuid}@${SERVER_ADDRESS}:443?security=reality&encryption=none&flow=xtls-rprx-vision&pbk=${PUBLIC_KEY}&fp=chrome&sni=${DESTINATION%:*}&sid=${SHORT_ID}&type=tcp#${user}"
        echo -n "$VLESS_LINK" | base64 -w 0 > "subscriptions/${token}"
        echo "  $user -> /sub/$token"
    done < config/.user_uuids
}

# --- Nginx config ---
create_nginx_config() {
    echo ">>> Creating nginx config..."
    mkdir -p nginx/conf.d

    if [[ -n "$DOMAIN" ]]; then
        cat > nginx/conf.d/default.conf <<NGEOF
server {
    listen 8443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location /sub/ {
        alias /usr/share/nginx/subscriptions/;
        default_type text/plain;
        charset utf-8;
    }

    location / {
        return 404;
    }
}
NGEOF
    else
        cat > nginx/conf.d/default.conf <<NGEOF
server {
    listen 8443;
    server_name _;

    location /sub/ {
        alias /usr/share/nginx/subscriptions/;
        default_type text/plain;
        charset utf-8;
    }

    location / {
        return 404;
    }
}
NGEOF
    fi

    cat >> nginx/conf.d/default.conf <<NGEOF

server {
    listen 8080;
    server_name _;

    root /usr/share/nginx/monitoring;
    index index.html;

    location /api/ {
        proxy_pass http://xray-api:5000/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 30s;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGEOF
}

# --- Monitoring dashboard + stats collector ---
create_monitoring() {
    echo ">>> Creating monitoring dashboard..."
    mkdir -p monitoring

    # Initial empty stats (don't overwrite if restoring)
    [[ -f monitoring/stats.json ]] || echo '{"updated":"never","users":{}}' > monitoring/stats.json
    [[ -f monitoring/totals.json ]] || echo '{}' > monitoring/totals.json
    [[ -f monitoring/history.json ]] || echo '[]' > monitoring/history.json

    # Copy dashboard and collector from staging area
    [[ -f /tmp/monitor-index.html ]] && cp /tmp/monitor-index.html monitoring/index.html
    [[ -f /tmp/collect-stats.sh ]] && cp /tmp/collect-stats.sh collect-stats.sh && chmod +x collect-stats.sh
    echo "  Dashboard: monitoring/index.html"
    echo "  Stats collector: collect-stats.sh"

    # Copy API files
    if [[ -d /tmp/deploy-api ]]; then
        mkdir -p api
        cp /tmp/deploy-api/* api/
        echo "  API: api/"
    fi
}

# --- Docker compose ---
create_docker_compose() {
    echo ">>> Creating docker-compose.yml..."

    local nginx_volumes="      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./subscriptions:/usr/share/nginx/subscriptions:ro
      - ./monitoring:/usr/share/nginx/monitoring:ro"
    [[ -n "$DOMAIN" ]] && nginx_volumes="$nginx_volumes
      - /etc/letsencrypt:/etc/letsencrypt:ro"

    cat > docker-compose.yml <<DCEOF
services:
  xray:
    image: teddysun/xray:\${XRAY_VERSION:-$XRAY_VERSION}
    container_name: xray
    environment:
      - TZ=${TZ}
    restart: unless-stopped
    volumes:
      - ./config:/etc/xray
    ports:
      - "443:443"
    networks:
      - xray-net
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  nginx:
    image: nginx:alpine
    container_name: xray-nginx
    environment:
      - TZ=${TZ}
    restart: unless-stopped
    volumes:
${nginx_volumes}
    ports:
      - "${SUB_PORT}:8443"
      - "${STATS_PORT}:8080"
    networks:
      - xray-net
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  api:
    build: ./api
    container_name: xray-api
    restart: unless-stopped
    environment:
      - DOMAIN=${DOMAIN}
      - SERVER_ADDRESS=${SERVER_ADDRESS}
      - SUB_PORT=${SUB_PORT}
      - API_KEY=\${API_KEY}
      - REALITY_PUBLIC_KEY=\${REALITY_PUBLIC_KEY:-}
    volumes:
      - ./config:/data/config
      - ./subscriptions:/data/subscriptions
      - ./monitoring:/data/monitoring
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - xray-net
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  xray-net:
    driver: bridge
DCEOF
}

# --- Cron for stats ---
setup_stats_cron() {
    echo ">>> Setting up stats cron (every 1 minute)..."
    # Stats every minute + access.log rotation daily (truncate if >50MB)
    local cron_entries="* * * * * $WORK_DIR/collect-stats.sh >/dev/null 2>&1
0 3 * * * /usr/bin/truncate -s 0 $WORK_DIR/config/access.log 2>/dev/null"
    if [[ -n "$DOMAIN" ]]; then
        cron_entries="$cron_entries
0 3 1 */2 * certbot renew --standalone --pre-hook \"docker stop xray-nginx\" --post-hook \"docker start xray-nginx\" >/dev/null 2>&1"
    fi
    echo "$cron_entries" | crontab -
    systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
    systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true

    # Block external access to monitoring port (Docker bypasses firewalld)
    local iface
    iface=$(ip route | grep default | awk '{print $5}' | head -1)
    iptables -D DOCKER-USER -i "$iface" -p tcp --dport ${STATS_PORT} -j DROP 2>/dev/null || true
    iptables -I DOCKER-USER -i "$iface" -p tcp --dport ${STATS_PORT} -j DROP

    # Persist iptables rule across reboots
    cat > /etc/systemd/system/block-monitoring-port.service <<IPTEOF
[Unit]
Description=Block external access to monitoring port ${STATS_PORT}
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/iptables -I DOCKER-USER -i $iface -p tcp --dport ${STATS_PORT} -j DROP
ExecStop=/sbin/iptables -D DOCKER-USER -i $iface -p tcp --dport ${STATS_PORT} -j DROP

[Install]
WantedBy=multi-user.target
IPTEOF
    systemctl daemon-reload
    systemctl enable block-monitoring-port.service
    echo "  Cron: every 1 minute"
    echo "  Port ${STATS_PORT} blocked from external access"
}

# --- Main deploy ---
main_deploy() {
    install_dependencies
    obtain_certificate
    generate_reality_keys
    generate_xray_config
    create_subscriptions
    create_nginx_config
    create_monitoring
    create_docker_compose
    setup_stats_cron

    # Create .env for docker-compose
    echo ">>> Creating .env..."
    cat > .env <<ENVEOF
DOMAIN=$DOMAIN
SERVER_ADDRESS=$SERVER_ADDRESS
API_KEY=$(openssl rand -hex 16)
REALITY_PUBLIC_KEY=$PUBLIC_KEY
XRAY_VERSION=$XRAY_VERSION
ENVEOF
    echo "  Admin API Key: $(grep '^API_KEY=' .env | cut -d= -f2)"

    echo ""
    echo ">>> Starting containers..."
    docker rm -f xray xray-nginx 2>/dev/null || true
    docker compose up -d
    sleep 3

    # Add Docker custom bridge to firewalld trusted zone (for outbound internet)
    local net_id bridge
    net_id=$(docker network inspect xray_xray-net -f '{{.Id}}' 2>/dev/null | cut -c1-12)
    bridge="br-${net_id}"
    # Fallback: find any br- interface
    ip link show "$bridge" &>/dev/null || bridge=$(ip link show | grep -oP 'br-[a-f0-9]+' | head -1)
    if [[ -n "$bridge" ]]; then
        firewall-cmd --permanent --zone=trusted --add-interface="$bridge" 2>/dev/null || true
        firewall-cmd --reload
        echo "  Docker bridge $bridge added to trusted zone"
    fi

    docker compose ps
    echo ""
    docker compose logs xray | tail -10

    # Run stats collector once
    bash collect-stats.sh 2>/dev/null || true

    echo ""
    echo "=== READY ==="
    echo "  VLESS Reality:    port 443"
    if [[ -n "$DOMAIN" ]]; then
        echo "  Subscriptions:    https://$DOMAIN:$SUB_PORT"
        echo "  Domain:           $DOMAIN"
    else
        echo "  Subscriptions:    http://$SERVER_ADDRESS:$SUB_PORT"
        echo "  Domain:           (none — HTTP mode)"
    fi
    echo "  Monitoring (VPN): port $STATS_PORT"
    echo "  SSH:              port $SSH_PORT"
    echo "  Public Key:       $PUBLIC_KEY"
    echo "  Short ID:         $SHORT_ID"
    echo "  Admin API Key:    $(grep '^API_KEY=' .env | cut -d= -f2)"
}

# --- Entry point ---
if [[ -d "$WORK_DIR" ]]; then
    echo "Directory $WORK_DIR already exists."
    if [[ "$FORCE" != "true" ]]; then
        read -rp "Remove and redeploy? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 1; }
    fi
    # Save access log if exists
    [[ -f "$WORK_DIR/config/access.log" ]] && cp "$WORK_DIR/config/access.log" /tmp/xray-access.log.bak
    [[ -f "$WORK_DIR/monitoring/totals.json" ]] && cp "$WORK_DIR/monitoring/totals.json" /tmp/xray-totals.json.bak
    [[ -f "$WORK_DIR/monitoring/history.json" ]] && cp "$WORK_DIR/monitoring/history.json" /tmp/xray-history.json.bak
    rm -rf "$WORK_DIR"
fi

mkdir -p "$WORK_DIR" && cd "$WORK_DIR" || exit 1

# Restore preserved data
[[ -f /tmp/xray-access.log.bak ]] && { mkdir -p config; mv /tmp/xray-access.log.bak config/access.log; }
[[ -f /tmp/xray-totals.json.bak ]] && { mkdir -p monitoring; mv /tmp/xray-totals.json.bak monitoring/totals.json; }
[[ -f /tmp/xray-history.json.bak ]] && { mkdir -p monitoring; mv /tmp/xray-history.json.bak monitoring/history.json; }

main_deploy
