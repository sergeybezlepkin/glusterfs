#!/usr/bin/env bash
set -uo pipefail

# ==========================================================
# Cron: */5 * * * * /path/to/health_check.sh
# ==========================================================

if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

VOL_NAME="${1:-gv0}"
ALERT_LOG="./gluster-healthcheck.log"
HOSTNAME=$(hostname)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

ISSUES=0
WARNINGS=()
ERRORS=()

log_message() {
    local severity="$1" message="$2"
    echo "[$TIMESTAMP] [$severity] $message" | tee -a "$ALERT_LOG"
}

log_issue() {
    local severity="$1" message="$2"
    log_message "$severity" "$message"
    if [[ "$severity" == "WARNING" ]]; then
        WARNINGS+=("$message")
    else
        ERRORS+=("$message")
    fi
    ISSUES=$((ISSUES + 1))
}


safe_count() {
    local cmd="$1"
    local result
    result=$(eval "$cmd" 2>/dev/null | head -n1 | tr -cd '0-9')
    if [[ -z "$result" ]]; then
        echo "0"
    else
        echo "$result"
    fi
}

# ==========================================================
# CHECK: glusterd service
# ==========================================================
if ! systemctl is-active --quiet glusterd; then
    log_issue "CRITICAL" "glusterd is NOT running on $HOSTNAME"
    exit 1
fi

# ==========================================================
# CHECK: Peer status
# ==========================================================
TOTAL_PEERS=$(safe_count "gluster peer status | grep -c 'Hostname:'")
CONNECTED=$(safe_count "gluster peer status | grep -c 'State: Peer in Cluster (Connected)'")
DISCONNECTED=$(safe_count "gluster peer status | grep -c 'State: Peer in Cluster (Disconnected)'")

if [[ "$DISCONNECTED" -gt 0 ]]; then
    log_issue "CRITICAL" "$DISCONNECTED peer(s) DISCONNECTED (Total: $TOTAL_PEERS, Connected: $CONNECTED)"
fi

# ==========================================================
# CHECK: Volume status
# ==========================================================
VOL_STATUS=$(gluster volume info "$VOL_NAME" 2>/dev/null | awk '/^Status:/{print $2; exit}')
if [[ -z "$VOL_STATUS" ]]; then
    log_issue "CRITICAL" "Volume '$VOL_NAME' not found or gluster command failed"
elif [[ "$VOL_STATUS" != "Started" ]]; then
    log_issue "CRITICAL" "Volume $VOL_NAME status=$VOL_STATUS (expected: Started)"
fi

# ==========================================================
# CHECK: Brick status
# ==========================================================
TOTAL_BRICKS=$(safe_count "gluster volume status $VOL_NAME | grep -c '^Brick'")
OFFLINE=$(gluster volume status "$VOL_NAME" 2>/dev/null | awk '$NF=="N"{printf "%s ",$2}' | sed 's/ $//')

if [[ -n "$OFFLINE" ]]; then
    log_issue "CRITICAL" "Offline bricks: $OFFLINE"
fi

# ==========================================================
# CHECK: Heal / Failed (Split-Brain)
# ==========================================================
HEAL_ENTRIES=$(safe_count "gluster volume heal $VOL_NAME info | awk '/Number of entries/{sum+=\$NF} END{print sum+0}'")
HEAL_FAILED=$(safe_count "gluster volume heal $VOL_NAME info heal-failed | awk '/Number of entries/{sum+=\$NF} END{print sum+0}'")

if [[ "$HEAL_ENTRIES" -gt 0 ]]; then
    log_issue "WARNING" "$HEAL_ENTRIES entries pending self-heal"
    gluster volume heal "$VOL_NAME" full >/dev/null 2>&1
fi
[[ "$HEAL_FAILED" -gt 0 ]] && log_issue "ERROR" "Heal failed: $HEAL_FAILED entries"

# ==========================================================
# CHECK: Mount & Disk usage (Readiness Check + Exact Errors)
# ==========================================================
DISK_USAGE=""
DISK_AVAIL="N/A"
MOUNT_PATH="/mnt/$VOL_NAME"
BRICK_PATH="/data/gluster/brick"

is_mount_alive() {
    local path="$1"
    mountpoint -q "$path" 2>/dev/null || return 1
    timeout 3 stat "$path" >/dev/null 2>&1 || return 1
    df "$path" >/dev/null 2>&1 || return 1
    return 0
}

if is_mount_alive "$MOUNT_PATH"; then
    DISK_USAGE=$(df "$MOUNT_PATH" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    DISK_AVAIL=$(df -h "$MOUNT_PATH" 2>/dev/null | awk 'NR==2{print $4}')

    if [[ "$DISK_USAGE" =~ ^[0-9]+$ ]]; then
        [[ "$DISK_USAGE" -ge 90 ]] && log_issue "CRITICAL" "Disk ${DISK_USAGE}% full (avail: $DISK_AVAIL)"
        [[ "$DISK_USAGE" -ge 80 && "$DISK_USAGE" -lt 90 ]] && log_issue "WARNING" "Disk ${DISK_USAGE}% full (avail: $DISK_AVAIL)"
    fi
else
    if [[ -d "$MOUNT_PATH" ]]; then
        log_issue "CRITICAL" "Mount point $MOUNT_PATH is NOT accessible"
        log_message "INFO" "Attempting recovery..."

        if [[ -d "$BRICK_PATH" ]]; then
            BRICK_OWNER=$(stat -c '%U:%G' "$BRICK_PATH" 2>/dev/null)
            if [[ "$BRICK_OWNER" != "gluster:gluster" && "$BRICK_OWNER" != "glusterfs:glusterfs" ]]; then
                log_message "INFO" "Fixing brick permissions: $BRICK_OWNER -> gluster:gluster"
                chown -R gluster:gluster "$BRICK_PATH" 2>/dev/null || true
                systemctl restart glusterfsd 2>/dev/null || true
            fi
        fi

        umount -l "$MOUNT_PATH" 2>/dev/null
        sleep 2

        VOL_STATE=$(gluster volume info "$VOL_NAME" 2>/dev/null | awk '/^Status:/{print $2}')
        if [[ "$VOL_STATE" != "Started" ]]; then
            log_message "INFO" "Volume $VOL_NAME is $VOL_STATE. Starting..."
            gluster volume start "$VOL_NAME" 2>&1 | tee -a "$ALERT_LOG"
        fi

        log_message "INFO" "Waiting for glusterfsd to initialize..."
        timeout 10 bash -c 'until pgrep -x glusterfsd >/dev/null || ss -tlnp | grep -q glusterfsd; do sleep 1; done' 2>/dev/null
        sleep 2

        if timeout 5 rm -rf "$MOUNT_PATH" 2>/dev/null; then
            mkdir -p "$MOUNT_PATH"
            
            MOUNT_CMD="mount -t glusterfs localhost:/$VOL_NAME $MOUNT_PATH"
            log_message "INFO" "Executing: $MOUNT_CMD"
            
            MOUNT_OUTPUT=$($MOUNT_CMD 2>&1)
            MOUNT_RC=$?
            
            if [[ $MOUNT_RC -eq 0 ]]; then
                log_message "OK" "Recovery successful: localhost:/$VOL_NAME remounted"
                DISK_USAGE=$(df "$MOUNT_PATH" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
                DISK_AVAIL=$(df -h "$MOUNT_PATH" 2>/dev/null | awk 'NR==2{print $4}')
            else
                log_message "ERROR" "Mount failed (RC=$MOUNT_RC): $MOUNT_OUTPUT"
            fi
        else
            log_message "CRITICAL" "Kernel VFS hang detected. Manual 'umount -f' or reboot required."
        fi
    else
        log_issue "WARNING" "Volume not mounted at $MOUNT_PATH (directory missing)"
    fi
fi

# ==========================================================
# CHECK: TLS Certificate Expiry (15d WARNING, 5d CRITICAL)
# ==========================================================
CERT_FILE="/etc/ssl/glusterfs.pem"
if [[ -f "$CERT_FILE" ]]; then
    EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
    if [[ -n "$EXPIRY_DATE" ]]; then
        EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null)
        NOW_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

        if [[ "$DAYS_LEFT" -le 0 ]]; then
            log_issue "CRITICAL" "TLS certificate EXPIRED on $EXPIRY_DATE. Cluster traffic may be blocked."
        elif [[ "$DAYS_LEFT" -le 5 ]]; then
            log_issue "CRITICAL" "TLS certificate expires in $DAYS_LEFT days. IMMEDIATE renewal required!"
        elif [[ "$DAYS_LEFT" -le 15 ]]; then
            log_issue "WARNING" "TLS certificate expires in $DAYS_LEFT days. Schedule renewal."
        else
            log_message "INFO" "TLS certificate valid for $DAYS_LEFT days (expires: $EXPIRY_DATE)."
        fi
    else
        log_message "WARNING" "Could not parse TLS certificate expiry date."
    fi
else
    log_issue "CRITICAL" "TLS certificate missing at $CERT_FILE."
fi

# ==========================================================
# CHECK: Time Synchronization (NTP/Chrony)
# ==========================================================
NTP_STATUS=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)
if [[ "$NTP_STATUS" != "yes" ]]; then
    log_issue "CRITICAL" "System time is NOT synchronized (NTP=off). High risk of split-brain & metadata corruption!"
else
    log_message "INFO" "System time synchronized via NTP."
    if command -v chronyc &>/dev/null; then
        OFFSET=$(chronyc tracking 2>/dev/null | awk '/^System time/{gsub(/s/,"",$4); print $4}')
        if [[ -n "$OFFSET" ]]; then
            IS_HIGH=$(awk -v off="$OFFSET" 'BEGIN{print (off>1 || off<-1) ? 1 : 0}')
            if [[ "$IS_HIGH" == "1" ]]; then
                log_issue "WARNING" "NTP offset is ${OFFSET}s. GlusterFS requires < 1s offset for consistency."
            fi
        fi
    fi
fi

# ==========================================================
# CHECK: Split-Brain Detection & Auto-Resolution
# ==========================================================
SPLIT_BRAIN=$(safe_count "gluster volume heal $VOL_NAME info split-brain | awk '/Number of entries/{sum+=\$NF} END{print sum+0}'")
if [[ "$SPLIT_BRAIN" -gt 0 ]]; then
    log_issue "CRITICAL" "SPLIT-BRAIN detected: $SPLIT_BRAIN file(s) in conflict"
    log_message "INFO" "Attempting auto-resolution (policy: latest-mtime)..."
    RESOLVE_OUTPUT=$(gluster volume heal "$VOL_NAME" split-brain latest-mtime 2>&1)
    if [[ $? -eq 0 ]]; then
        log_message "OK" "Split-brain resolved successfully using latest-mtime policy."
    else
        log_message "ERROR" "Auto-resolution failed. Manual intervention required."
        log_message "INFO" "Debug: gluster volume heal $VOL_NAME info split-brain"
        log_message "INFO" "Output: $RESOLVE_OUTPUT"
    fi
else
    log_message "INFO" "No split-brain entries detected."
fi

# ==========================================================
# SUMMARY
# ==========================================================
if [[ "$ISSUES" -eq 0 ]]; then
    log_message "OK" "All checks passed"
    log_message "INFO" "Peers: $CONNECTED/$TOTAL_PEERS | Bricks: $TOTAL_BRICKS online | Disk: ${DISK_USAGE:-N/A}% | Heal: $HEAL_ENTRIES"
    exit 0
else
    log_message "ALERT" "$ISSUES issue(s): ${#ERRORS[@]} critical/error, ${#WARNINGS[@]} warnings"
    exit 1
fi
