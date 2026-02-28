# Xray Reality VPN

One-command deploy for Xray VLESS+Reality with multi-user support, subscription links, monitoring dashboard and user management API.

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

### No-domain mode

When `--domain` is omitted:
- No certbot, no certificates
- Nginx serves subscriptions over plain HTTP on port 8443
- Subscription URLs: `http://<ip>:8443/sub/<token>`
- Port 80 stays closed
- No certbot renew in cron

`SSH_PORT` is set in `.env` (defaults to `22`).

## Requirements

**Local machine:**
- macOS or Linux
- `ssh` access to the server (key-based or password)
- `jq` for `sync-users.sh` (`brew install jq`)
- `curl`

**Server:**
- Ubuntu 20.04+
- Open ports: 443 (Xray), 8443 (subscriptions)
- Port 8080 (monitoring) is blocked externally, accessible only through VPN

## Security

- The API container mounts the Docker socket to restart Xray. If the API is compromised, the attacker gets root on the host. Port 8080 is firewalled and only reachable through the VPN tunnel.

## License

MIT
