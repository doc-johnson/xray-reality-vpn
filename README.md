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
| `--force` | Remove existing install and redeploy without confirmation. Preserves traffic stats (`totals.json`, `history.json`) and `access.log`. Generates new Reality keys — clients need to re-fetch their subscription. | — |

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

## Firewall

- **firewalld**: ports open — SSH, 443, 8443, 80 (only with domain)
- **iptables**: port 8080 is blocked via `DOCKER-USER` chain, accessible only through VPN
- **SSH hardening**: `MaxAuthTries 3`, `PasswordAuthentication no`

## Cron jobs

| Schedule | Script | Description |
|---|---|---|
| `* * * * *` | `collect-stats.sh` | Collect traffic statistics |
| `0 3 * * *` | — | Rotate `access.log` |
| `0 3 1 */2 *` | — | Renew TLS certificate (domain mode only) |

## Docker

Docker is installed automatically if not present on the server.

Three containers run in a single bridge network `xray-net`:

| Container | Role |
|---|---|
| `xray` | Xray VPN server |
| `xray-nginx` | Nginx — subscriptions + monitoring dashboard |
| `xray-api` | REST API (Flask / Gunicorn) |

## Security

- The API container mounts the Docker socket to restart Xray. If the API is compromised, the attacker gets root on the host. Port 8080 is firewalled and only reachable through the VPN tunnel.

## License

MIT
