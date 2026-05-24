#!/usr/bin/env bash
set -uo pipefail

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
    [[ "$severity" == "WARNING" ]] && WARNINGS+=("$message") || ERRORS+=("$message")
    ISSUES=$((ISSUES + 1))
}

# Безопасное извлечение числа (всегда возвращает одно целое число)
safe_count() {
    local val
    val=$(eval "$1" 2>/dev/null | head -1 | tr -cd '0-9')
    echo "${val:-0}"
}

# ==========================================================
# CHECK 1: glusterd
# ==========================================================
if ! systemctl is-active --quiet glusterd; then
    log_issue "CRITICAL" "glusterd is NOT running on $HOSTNAME"
    exit 1
fi

# ==========================================================
# CHECK 2: Peers
# ==========================================================
TOTAL_PEERS=$(safe_count "gluster peer status | grep -c 'Hostname:'")
CONNECTED=$(safe_count "gluster peer status | grep -c 'State: Peer in Cluster (Connected)'")
DISCONNECTED=$(safe_count "gluster peer status | grep -c 'State: Peer in Cluster (Disconnected)'")

if [[ "$DISCONNECTED" -gt 0 ]]; then
    log_issue "CRITICAL" "$DISCONNECTED peer(s) DISCONNECTED (Total: $TOTAL_PEERS, Connected: $CONNECTED)"
fi

# ==========================================================
# CHECK 3: Volume status
# ==========================================================
VOL_STATUS=$(gluster volume info "$VOL_NAME" 2>/dev/null | awk '/^Status:/{print $2; exit}')
if [[ -z "$VOL_STATUS" ]]; then
    log_issue "CRITICAL" "Volume '$VOL_NAME' not found or gluster command failed"
elif [[ "$VOL_STATUS" != "Started" ]]; then
    log_issue "CRITICAL" "Volume $VOL_NAME status=$VOL_STATUS (expected: Started)"
fi

# ==========================================================
# CHECK 4: Bricks
# ==========================================================
TOTAL_BRICKS=$(safe_count "gluster volume status $VOL_NAME | grep -c '^Brick'")
OFFLINE=$(gluster volume status "$VOL_NAME" 2>/dev/null | awk '$NF=="N"{printf "%s ",$2}' | sed 's/ $//')

if [[ -n "$OFFLINE" ]]; then
    log_issue "CRITICAL" "Offline bricks: $OFFLINE"
fi

# ==========================================================
# CHECK 5-7: Heal / Split-brain / Failed
# ==========================================================
HEAL_ENTRIES=$(safe_count "gluster volume heal $VOL_NAME info | awk '/Number of entries/{sum+=\$NF} END{print sum}'")
SPLIT_BRAIN=$(safe_count "gluster volume heal $VOL_NAME info split-brain | awk '/Number of entries/{sum+=\$NF} END{print sum}'")
HEAL_FAILED=$(safe_count "gluster volume heal $VOL_NAME info heal-failed | awk '/Number of entries/{sum+=\$NF} END{print sum}'")

if [[ "$HEAL_ENTRIES" -gt 0 ]]; then
    log_issue "WARNING" "$HEAL_ENTRIES entries pending self-heal"
    gluster volume heal "$VOL_NAME" full >/dev/null 2>&1
fi
[[ "$SPLIT_BRAIN" -gt 0 ]] && log_issue "CRITICAL" "SPLIT-BRAIN: $SPLIT_BRAIN entries (manual fix required)"
[[ "$HEAL_FAILED" -gt 0 ]] && log_issue "ERROR" "Heal failed: $HEAL_FAILED entries"

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
    log_message "INFO" "Peers: $CONNECTED/$TOTAL_PEERS | Bricks: $TOTAL_BRICKS online | Disk: ${DISK_USAGE:-N/A}% | Heal: $HEAL_ENTRIES"
    exit 0
else
    log_message "ALERT" "$ISSUES issue(s): ${#ERRORS[@]} critical/error, ${#WARNINGS[@]} warnings"
    exit 1
fi
