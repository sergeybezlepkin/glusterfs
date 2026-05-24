#!/usr/bin/env bash
# ==========================================================
# GlusterFS Health Check Script (Zabbix-friendly)
# Run: ./gluster-healthcheck.sh gv0
# Cron: */5 * * * * /usr/local/bin/gluster-healthcheck.sh gv0
# ==========================================================

set -uo pipefail

VOL_NAME="${1:-gv0}"
ALERT_LOG="./gluster-healthcheck.log"
HOSTNAME=$(hostname)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

ISSUES=0
WARNINGS=()
ERRORS=()

log_message() {
    local severity="$1"
    local message="$2"
    echo "[$TIMESTAMP] [$severity] $message" | tee -a "$ALERT_LOG"
}

log_issue() {
    local severity="$1"
    local message="$2"
    log_message "$severity" "$message"
    if [[ "$severity" == "WARNING" ]]; then
        WARNINGS+=("$message")
    else
        ERRORS+=("$message")
    fi
    ((ISSUES++)) || true
}

# ==========================================================
# CHECK 1: glusterd service status
# ==========================================================
if ! systemctl is-active --quiet glusterd; then
    log_issue "CRITICAL" "glusterd service is NOT running on $HOSTNAME"
    exit 1
fi

# ==========================================================
# CHECK 2: Peer status
# ==========================================================
TOTAL_PEERS=$(gluster peer status 2>/dev/null | grep -c "Hostname:" || echo "0")
CONNECTED_PEERS=$(gluster peer status 2>/dev/null | grep -c "State: Peer in Cluster (Connected)" || echo "0")
DISCONNECTED_PEERS=$(gluster peer status 2>/dev/null | grep -c "State: Peer in Cluster (Disconnected)" || echo "0")

if [[ "${DISCONNECTED_PEERS:-0}" -gt 0 ]]; then
    log_issue "CRITICAL" "$DISCONNECTED_PEERS peer(s) DISCONNECTED (Total: $TOTAL_PEERS, Connected: $CONNECTED_PEERS)"
fi

# ==========================================================
# CHECK 3: Volume status (FIXED: reliable parsing)
# ==========================================================
VOL_STATUS=$(gluster volume info "$VOL_NAME" 2>/dev/null | awk '/^Status:/ {print $2}')
if [[ -z "$VOL_STATUS" ]]; then
    log_issue "CRITICAL" "Cannot determine status of volume $VOL_NAME (volume may not exist)"
elif [[ "$VOL_STATUS" != "Started" ]]; then
    log_issue "CRITICAL" "Volume $VOL_NAME is $VOL_STATUS (expected: Started)"
fi

# ==========================================================
# CHECK 4: Brick status
# ==========================================================
TOTAL_BRICKS=$(gluster volume status "$VOL_NAME" 2>/dev/null | grep -c "Brick" || echo "0")
OFFLINE_BRICKS=$(gluster volume status "$VOL_NAME" 2>/dev/null | awk '$NF=="N" {print $2}' || true)

if [[ -n "$OFFLINE_BRICKS" ]]; then
    log_issue "CRITICAL" "Offline bricks in $VOL_NAME: $OFFLINE_BRICKS"
fi

# ==========================================================
# CHECK 5: Self-heal entries
# ==========================================================
HEAL_ENTRIES=$(gluster volume heal "$VOL_NAME" info 2>/dev/null | grep "Number of entries" | awk '{sum+=$NF} END {print sum+0}')
HEAL_ENTRIES="${HEAL_ENTRIES:-0}"

if [[ "$HEAL_ENTRIES" -gt 0 ]]; then
    log_issue "WARNING" "Volume $VOL_NAME has $HEAL_ENTRIES entries pending self-heal"
    log_message "INFO" "Triggering automatic heal..."
    gluster volume heal "$VOL_NAME" full >/dev/null 2>&1
    log_message "INFO" "Heal command sent. Check: gluster volume heal $VOL_NAME info"
fi

# ==========================================================
# CHECK 6: Split-brain
# ==========================================================
SPLIT_BRAIN=$(gluster volume heal "$VOL_NAME" info split-brain 2>/dev/null | grep "Number of entries in split-brain" | awk '{sum+=$NF} END {print sum+0}')
SPLIT_BRAIN="${SPLIT_BRAIN:-0}"

if [[ "$SPLIT_BRAIN" -gt 0 ]]; then
    log_issue "CRITICAL" "SPLIT-BRAIN detected! $SPLIT_BRAIN entries require manual intervention"
    log_message "CRITICAL" "Run: gluster volume heal $VOL_NAME info split-brain"
fi

# ==========================================================
# CHECK 7: Heal failed
# ==========================================================
HEAL_FAILED=$(gluster volume heal "$VOL_NAME" info heal-failed 2>/dev/null | grep "Number of entries" | awk '{sum+=$NF} END {print sum+0}')
HEAL_FAILED="${HEAL_FAILED:-0}"

if [[ "$HEAL_FAILED" -gt 0 ]]; then
    log_issue "ERROR" "Heal failed for $HEAL_FAILED entries in $VOL_NAME"
fi

# ==========================================================
# CHECK 8: Mount & Disk usage (robust FUSE check)
# ==========================================================
DISK_USAGE=""
DISK_AVAIL="N/A"
MOUNT_PATH="/mnt/$VOL_NAME"

is_mount_alive() {
    local path="$1"
    # 1. Check if it's a mount point at all
    mountpoint -q "$path" 2>/dev/null || return 1
    
    # 2. Check if stat works (detects hung FUSE)
    timeout 3 stat "$path" >/dev/null 2>&1 || return 1
    
    # 3. Check if df returns valid data (confirms FS is responsive)
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
    # Directory exists but mount is dead/hung vs not mounted at all
    if [[ -d "$MOUNT_PATH" ]]; then
        log_issue "CRITICAL" "Mount point $MOUNT_PATH exists but is NOT accessible (hung FUSE or stale mount)"
        log_message "INFO" "Fix: umount -l $MOUNT_PATH && mount -t glusterfs localhost:/$VOL_NAME $MOUNT_PATH"
    else
        log_issue "WARNING" "Volume not mounted at $MOUNT_PATH (directory does not exist)"
    fi
fi

# ==========================================================
# SUMMARY
# ==========================================================
if [[ "$ISSUES" -eq 0 ]]; then
    log_message "OK" "All checks passed"
    log_message "INFO" "Peers: ${CONNECTED_PEERS:-0}/${TOTAL_PEERS:-0} connected | Bricks: ${TOTAL_BRICKS:-0} online | Disk: ${DISK_USAGE:-N/A}% used | Heal pending: $HEAL_ENTRIES"
    exit 0
else
    log_message "ALERT" "Found $ISSUES issue(s): ${#ERRORS[@]} critical/error, ${#WARNINGS[@]} warnings"
    exit 1
fi
