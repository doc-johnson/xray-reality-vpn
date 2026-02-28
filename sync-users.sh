#!/bin/bash
# ============================================================
# Sync users from server to local .env
# Usage: ./sync-users.sh --ip <server-ip> [--domain <domain>] [--user <user>]
# ============================================================

set -euo pipefail

# --- Arguments ---
SERVER_ADDRESS=""
DOMAIN=""
SSH_USER="root"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)     [[ $# -ge 2 ]] || { echo "Error: $1 requires a value"; exit 1; }; SERVER_ADDRESS="$2"; shift ;;
        --domain) [[ $# -ge 2 ]] || { echo "Error: $1 requires a value"; exit 1; }; DOMAIN="$2"; shift ;;
        --user)   [[ $# -ge 2 ]] || { echo "Error: $1 requires a value"; exit 1; }; SSH_USER="$2"; shift ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [[ -z "$SERVER_ADDRESS" ]]; then
    echo "Usage: $0 --ip <server-ip> [--domain <domain>] [--user <user>]"
    echo "Example: $0 --ip 1.2.3.4"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found at $ENV_FILE"
    exit 1
fi

# Load SSH_PORT from .env
source "$ENV_FILE"
SSH_PORT="${SSH_PORT:-22}"
[[ -z "$SSH_PORT" ]] && SSH_PORT=22

# --- Determine SSH port (configured → 22 fallback) ---
echo "Checking SSH on port $SSH_PORT..."
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p "$SSH_PORT" ${SSH_USER}@"$SERVER_ADDRESS" true 2>/dev/null; then
    REMOTE_SSH_PORT=$SSH_PORT
else
    echo "Port $SSH_PORT unavailable, trying 22..."
    REMOTE_SSH_PORT=22
fi
echo "SSH port: $REMOTE_SSH_PORT"

# --- Get API_KEY from server ---
echo "Fetching API_KEY from server..."
REMOTE_HOME=$(ssh -p "$REMOTE_SSH_PORT" -o StrictHostKeyChecking=accept-new ${SSH_USER}@"$SERVER_ADDRESS" 'echo $HOME')
API_KEY=$(ssh -p "$REMOTE_SSH_PORT" -o StrictHostKeyChecking=accept-new ${SSH_USER}@"$SERVER_ADDRESS" \
    "grep '^API_KEY=' ${REMOTE_HOME}/xray/.env | cut -d= -f2")

if [[ -z "$API_KEY" ]]; then
    echo "ERROR: Could not retrieve API_KEY from server"
    exit 1
fi
echo "API_KEY: ${API_KEY:0:8}..."

# --- Open SSH tunnel ---
LOCAL_PORT=$((RANDOM % 10000 + 20000))
echo "Opening SSH tunnel (localhost:$LOCAL_PORT → server:8080)..."
ssh -p "$REMOTE_SSH_PORT" -o StrictHostKeyChecking=accept-new -f -N \
    -L "$LOCAL_PORT:localhost:8080" ${SSH_USER}@"$SERVER_ADDRESS"

# ssh -f forks into background, find PID by listening port
sleep 1
TUNNEL_PID=$(lsof -ti "tcp:$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null || true)

cleanup() {
    if [[ -n "${TUNNEL_PID:-}" ]]; then
        kill "$TUNNEL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Fetch users from API ---
echo "Fetching users from API..."
RESPONSE=$(curl -sf -H "X-API-Key: $API_KEY" "http://localhost:$LOCAL_PORT/api/users" 2>&1) || {
    echo "ERROR: Failed to fetch users from API"
    echo "Response: $RESPONSE"
    exit 1
}

# Validate JSON
if ! echo "$RESPONSE" | jq empty 2>/dev/null; then
    echo "ERROR: Invalid JSON response"
    echo "$RESPONSE"
    exit 1
fi

USER_COUNT=$(echo "$RESPONSE" | jq '.users | length')
echo "Users received: $USER_COUNT"

# --- Parse server users into temp file (name<tab>token per line) ---
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"; cleanup' EXIT

echo "$RESPONSE" | jq -r '.users[] | .username + "\t" + (.subscription_url | split("/") | last)' \
    | sed 's/[^a-zA-Z0-9_	]/_/g' > "$TMPFILE"

echo ""
echo "Server users:"
while IFS=$'\t' read -r name token; do
    echo "  $name → ${token:0:12}..."
done < "$TMPFILE"

# --- Read current .env state ---
# Parse USERS from .env (space-separated string)
LOCAL_USERS=($USERS)

# Parse tokens into temp file
TMPLOCAL=$(mktemp)
trap 'rm -f "$TMPFILE" "$TMPLOCAL"; cleanup' EXIT
sed -n '/^# ===== TOKENS START =====/,/^# ===== TOKENS END =====/{
    /^TOKEN_/p
}' "$ENV_FILE" | sed 's/TOKEN_//; s/="/ /; s/"$//' > "$TMPLOCAL"

# --- Compute diff ---
ADDED=""
REMOVED=""
UPDATED=""
UNCHANGED=""
ADDED_COUNT=0
REMOVED_COUNT=0
UPDATED_COUNT=0
UNCHANGED_COUNT=0

# Check server users against local
while IFS=$'\t' read -r srv_name srv_token; do
    local_token=$(awk -v u="$srv_name" '$1 == u {print $2}' "$TMPLOCAL")
    if [[ -z "$local_token" ]]; then
        ADDED="${ADDED}    + $srv_name"$'\n'
        ADDED_COUNT=$((ADDED_COUNT + 1))
    elif [[ "$local_token" != "$srv_token" ]]; then
        UPDATED="${UPDATED}    ~ $srv_name"$'\n'
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
    else
        UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
    fi
done < "$TMPFILE"

# Check local users missing on server
for local_user in "${LOCAL_USERS[@]}"; do
    if ! awk -v u="$local_user" 'BEGIN{f=0} $1==u{f=1} END{exit !f}' "$TMPFILE"; then
        REMOVED="${REMOVED}    - $local_user"$'\n'
        REMOVED_COUNT=$((REMOVED_COUNT + 1))
    fi
done

# --- Apply changes ---
if [[ $ADDED_COUNT -eq 0 && $REMOVED_COUNT -eq 0 && $UPDATED_COUNT -eq 0 ]]; then
    echo ""
    echo "No changes needed — .env is in sync with server."
    exit 0
fi

echo ""
echo "Applying changes to .env..."

# Build new USERS string (space-separated)
NEW_USERS_STR=""
while IFS=$'\t' read -r name token; do
    NEW_USERS_STR="${NEW_USERS_STR}$name "
done < "$TMPFILE"
NEW_USERS_STR="${NEW_USERS_STR% }"

# Build new TOKENS block content into a temp file
TMPTOKENS=$(mktemp)
trap 'rm -f "$TMPFILE" "$TMPLOCAL" "$TMPTOKENS"; cleanup' EXIT
while IFS=$'\t' read -r name token; do
    echo "TOKEN_${name}=\"${token}\"" >> "$TMPTOKENS"
done < "$TMPFILE"

# Update USERS= line and TOKENS block in one pass
TMPENV=$(mktemp)
sed "s/^USERS=.*/USERS=\"$NEW_USERS_STR\"/" "$ENV_FILE" > "$TMPENV"
mv "$TMPENV" "$ENV_FILE"

# Update TOKENS block using awk (read tokens from file)
TMPENV=$(mktemp)
awk -v tokfile="$TMPTOKENS" '
    /^# ===== TOKENS START =====/ {
        print
        while ((getline line < tokfile) > 0) print line
        close(tokfile)
        skip=1; next
    }
    /^# ===== TOKENS END =====/ { skip=0; print; next }
    !skip { print }
' "$ENV_FILE" > "$TMPENV"
mv "$TMPENV" "$ENV_FILE"

# --- Summary ---
echo ""
echo "========== SUMMARY =========="
if [[ $ADDED_COUNT -gt 0 ]]; then
    echo "  ADDED ($ADDED_COUNT):"
    echo -n "$ADDED"
fi
if [[ $REMOVED_COUNT -gt 0 ]]; then
    echo "  REMOVED ($REMOVED_COUNT):"
    echo -n "$REMOVED"
fi
if [[ $UPDATED_COUNT -gt 0 ]]; then
    echo "  UPDATED tokens ($UPDATED_COUNT):"
    echo -n "$UPDATED"
fi
if [[ $UNCHANGED_COUNT -gt 0 ]]; then
    echo "  Unchanged: $UNCHANGED_COUNT users"
fi
echo ""
echo ".env updated successfully."
