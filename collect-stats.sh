#!/bin/bash
WORK_DIR="$HOME/xray"
STATS_FILE="$WORK_DIR/monitoring/stats.json"
TOTALS_FILE="$WORK_DIR/monitoring/totals.json"
HISTORY_FILE="$WORK_DIR/monitoring/history.json"
IP_COUNTS_FILE="$WORK_DIR/monitoring/ip_counts.json"
IP_LOG_FILE="$WORK_DIR/monitoring/ip_log.json"
ACCESS_LOG="$WORK_DIR/config/access.log"
USERS_FILE="$WORK_DIR/config/.user_uuids"
MAX_HISTORY=1440
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
TS_HIST=$(date '+%Y-%m-%d %H:%M')

# Read known users
declare -a KNOWN_USERS=()
if [[ -f "$USERS_FILE" ]]; then
    while IFS=: read -r user uuid; do
        KNOWN_USERS+=("$user")
    done < "$USERS_FILE"
fi
[[ ${#KNOWN_USERS[@]} -eq 0 ]] && exit 0

# Read persistent totals
declare -A TOTAL_UP TOTAL_DN LAST_SEEN
for user in "${KNOWN_USERS[@]}"; do
    TOTAL_UP[$user]=0
    TOTAL_DN[$user]=0
    LAST_SEEN[$user]=""
done
if [[ -f "$TOTALS_FILE" && -s "$TOTALS_FILE" ]]; then
    for user in "${KNOWN_USERS[@]}"; do
        TOTAL_UP[$user]=$(jq -r ".\"${user}\".up // 0" "$TOTALS_FILE" 2>/dev/null || echo 0)
        TOTAL_DN[$user]=$(jq -r ".\"${user}\".dn // 0" "$TOTALS_FILE" 2>/dev/null || echo 0)
        LAST_SEEN[$user]=$(jq -r ".\"${user}\".last_seen // \"\"" "$TOTALS_FILE" 2>/dev/null || echo "")
    done
fi

# Query Xray stats API (JSON) and reset counters
RAW=$(docker exec xray xray api statsquery -s 127.0.0.1:10085 -reset 2>/dev/null || echo '{"stat":[]}')

# Parse deltas from JSON
declare -A DELTA_UP DELTA_DN
for user in "${KNOWN_USERS[@]}"; do
    DELTA_UP[$user]=$(echo "$RAW" | jq -r "[.stat[] | select(.name == \"user>>>$user>>>traffic>>>uplink\") | .value // 0] | add // 0" 2>/dev/null || echo 0)
    DELTA_DN[$user]=$(echo "$RAW" | jq -r "[.stat[] | select(.name == \"user>>>$user>>>traffic>>>downlink\") | .value // 0] | add // 0" 2>/dev/null || echo 0)

    TOTAL_UP[$user]=$(( ${TOTAL_UP[$user]} + ${DELTA_UP[$user]} ))
    TOTAL_DN[$user]=$(( ${TOTAL_DN[$user]} + ${DELTA_DN[$user]} ))

    # Update last_seen if user has traffic in this cycle
    if (( ${DELTA_UP[$user]} + ${DELTA_DN[$user]} > 0 )); then
        LAST_SEEN[$user]="$TIMESTAMP"
    fi
done

# Save persistent totals
{
    echo "{"
    first=true
    for user in "${KNOWN_USERS[@]}"; do
        $first || echo ","
        first=false
        printf '  "%s": {"up": %d, "dn": %d, "last_seen": "%s"}' "$user" "${TOTAL_UP[$user]}" "${TOTAL_DN[$user]}" "${LAST_SEEN[$user]}"
    done
    echo ""
    echo "}"
} > "$TOTALS_FILE"

# === IP tracking from access.log ===
declare -A IPS_NOW
for user in "${KNOWN_USERS[@]}"; do
    IPS_NOW[$user]=0
done

if [[ -f "$ACCESS_LOG" && -s "$ACCESS_LOG" ]]; then
    # Boundary: 2 minutes ago in Xray log format (YYYY/MM/DD HH:MM:SS)
    TWO_MIN_AGO=$(date -d '2 minutes ago' '+%Y/%m/%d %H:%M:%S' 2>/dev/null \
        || date -v-2M '+%Y/%m/%d %H:%M:%S' 2>/dev/null || "")

    # Parse recent IPs per user (last 2 minutes)
    if [[ -n "$TWO_MIN_AGO" ]]; then
        for user in "${KNOWN_USERS[@]}"; do
            IPS_NOW[$user]=$(awk -v boundary="$TWO_MIN_AGO" -v email="$user" '
                {
                    ts = $1 " " $2
                    if (ts >= boundary && $0 ~ "email: " email) {
                        split($4, a, ":")
                        ip = (a[1] == "tcp" || a[1] == "udp") ? a[2] : a[1]
                        if (ip ~ /^[0-9]+\./) ips[ip] = 1
                    }
                }
                END { print length(ips) }
            ' "$ACCESS_LOG")
        done
    fi

    # Update ip_log.json: all IPs from access.log with last_seen
    IP_LOG_TMP="$WORK_DIR/monitoring/.ip_log.tmp"
    IP_PAIRS_TMP="$WORK_DIR/monitoring/.ip_pairs.tmp"

    if [[ -f "$IP_LOG_FILE" && -s "$IP_LOG_FILE" ]]; then
        cp "$IP_LOG_FILE" "$IP_LOG_TMP"
    else
        echo '{}' > "$IP_LOG_TMP"
    fi

    # Build list of known users for awk filtering
    KNOWN_LIST=$(printf '%s\n' "${KNOWN_USERS[@]}" | paste -sd'|' -)

    # Extract unique user:ip pairs from access.log with latest timestamp per pair
    awk -v known="$KNOWN_LIST" '
        BEGIN { split(known, ku, "|"); for (k in ku) users[ku[k]] = 1 }
        /email: / {
            split($4, a, ":");
            ip = (a[1] == "tcp" || a[1] == "udp") ? a[2] : a[1];
            if (ip !~ /^[0-9]+\./) next;
            for (i=1; i<=NF; i++) {
                if ($i == "email:") { user = $(i+1); break }
            }
            # Convert log timestamp YYYY/MM/DD HH:MM:SS to YYYY-MM-DD HH:MM:SS
            ts = $1 " " substr($2, 1, 8);
            gsub(/\//, "-", ts);
            if (user in users && ip) {
                key = user "\t" ip;
                latest[key] = ts
            }
        }
        END { for (key in latest) print key "\t" latest[key] }
    ' "$ACCESS_LOG" > "$IP_PAIRS_TMP"

    # Batch-update ip_log.json with all extracted pairs and real timestamps
    if [[ -s "$IP_PAIRS_TMP" ]]; then
        # Convert pairs file to JSON array: [{"u":"user","ip":"1.2.3.4","ts":"..."}, ...]
        PAIRS_JSON=$(awk -F'\t' '{printf "%s{\"u\":\"%s\",\"ip\":\"%s\",\"ts\":\"%s\"}", (NR>1?",":""), $1, $2, $3}' "$IP_PAIRS_TMP")
        PAIRS_JSON="[${PAIRS_JSON}]"
        # Merge with existing ip_log, keeping the most recent timestamp
        jq --argjson pairs "$PAIRS_JSON" '
            reduce $pairs[] as $p (.;
                .[$p.u] = ((.[$p.u] // {}) |
                    if (.[$p.ip] // "") < $p.ts then .[$p.ip] = $p.ts else . end
                )
            )
        ' "$IP_LOG_TMP" > "${IP_LOG_TMP}.2" 2>/dev/null \
            && mv "${IP_LOG_TMP}.2" "$IP_LOG_TMP"
    fi
    rm -f "$IP_PAIRS_TMP"

    # Remove entries older than 30 days from ip_log.json
    THIRTY_DAYS_AGO=$(date -d '30 days ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
        || date -v-30d '+%Y-%m-%d %H:%M:%S' 2>/dev/null || "")
    if [[ -n "$THIRTY_DAYS_AGO" ]]; then
        jq --arg cutoff "$THIRTY_DAYS_AGO" '
            to_entries | map(
                .value = (.value | to_entries | map(select(.value >= $cutoff)) | from_entries)
            ) | map(select(.value | length > 0)) | from_entries
        ' "$IP_LOG_TMP" > "${IP_LOG_TMP}.2" 2>/dev/null \
            && mv "${IP_LOG_TMP}.2" "$IP_LOG_TMP"
    fi
    mv "$IP_LOG_TMP" "$IP_LOG_FILE"
fi

# Update ip_counts.json (rolling 24h window)
IP_COUNTS_ENTRY=$(
    echo "{"
    first=true
    for user in "${KNOWN_USERS[@]}"; do
        $first || echo ","
        first=false
        printf '"%s": %d' "$user" "${IPS_NOW[$user]}"
    done
    echo "}"
)
IP_COUNTS_ENTRY=$(echo "$IP_COUNTS_ENTRY" | jq -c .)

if [[ -f "$IP_COUNTS_FILE" && -s "$IP_COUNTS_FILE" ]]; then
    jq -c ". + [{\"ts\": \"$TS_HIST\", \"users\": $IP_COUNTS_ENTRY}] | .[-${MAX_HISTORY}:]" \
        "$IP_COUNTS_FILE" > "${IP_COUNTS_FILE}.tmp" 2>/dev/null \
        && mv "${IP_COUNTS_FILE}.tmp" "$IP_COUNTS_FILE" \
        || echo "[{\"ts\": \"$TS_HIST\", \"users\": $IP_COUNTS_ENTRY}]" > "$IP_COUNTS_FILE"
else
    echo "[{\"ts\": \"$TS_HIST\", \"users\": $IP_COUNTS_ENTRY}]" > "$IP_COUNTS_FILE"
fi

# Compute max IPs per user over 24h
declare -A IPS_MAX
for user in "${KNOWN_USERS[@]}"; do
    IPS_MAX[$user]=$(jq -r "[.[].users.\"$user\" // 0] | max // 0" "$IP_COUNTS_FILE" 2>/dev/null || echo 0)
done

# Build stats.json for dashboard
{
    echo "{"
    echo "  \"updated\": \"$TIMESTAMP\","
    echo "  \"users\": {"
    first=true
    for user in "${KNOWN_USERS[@]}"; do
        $first || echo ","
        first=false
        local_ls="${LAST_SEEN[$user]}"
        printf '    "%s": {"uplink": %d, "downlink": %d, "last_seen": "%s", "ips_now": %d, "ips_max_24h": %d}' \
            "$user" "${TOTAL_UP[$user]}" "${TOTAL_DN[$user]}" "${local_ls:-—}" "${IPS_NOW[$user]}" "${IPS_MAX[$user]}"
    done
    echo ""
    echo "  }"
    echo "}"
} > "$STATS_FILE"

# Build history entry (deltas for graphing)
{
    echo "{"
    first=true
    for user in "${KNOWN_USERS[@]}"; do
        $first || echo ","
        first=false
        printf '  "%s": {"up": %d, "dn": %d}' "$user" "${DELTA_UP[$user]}" "${DELTA_DN[$user]}"
    done
    echo ""
    echo "}"
} > "$WORK_DIR/monitoring/.hist_entry.tmp"

ENTRY=$(jq -c . "$WORK_DIR/monitoring/.hist_entry.tmp")

# Append to history, trim to MAX_HISTORY
if [[ -f "$HISTORY_FILE" && -s "$HISTORY_FILE" ]]; then
    jq -c ". + [{\"ts\": \"$TS_HIST\", \"users\": $ENTRY}] | .[-${MAX_HISTORY}:]" \
        "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" 2>/dev/null \
        && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE" \
        || echo "[{\"ts\": \"$TS_HIST\", \"users\": $ENTRY}]" > "$HISTORY_FILE"
else
    echo "[{\"ts\": \"$TS_HIST\", \"users\": $ENTRY}]" > "$HISTORY_FILE"
fi

rm -f "$WORK_DIR/monitoring/.hist_entry.tmp"
