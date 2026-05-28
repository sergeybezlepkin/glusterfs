#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

echo "=== SSH ACCESS SETUP ==="
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

if [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
    echo "Generating SSH key (RSA 4096)..."
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa" -q
    echo "Key created: $HOME/.ssh/id_rsa"
else
    echo "SSH key already exists. Skipping generation."
fi

[[ ! -f "$HOME/.ssh/config" ]] && touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"

read -p "How many REMOTE nodes to add? (Total will be: N + 1 local): " node_count
[[ "$node_count" =~ ^[1-9][0-9]*$ ]] || { echo "Enter a number >= 1"; exit 1; }

for (( i=1; i<=node_count; i++ )); do
    echo "--- Node $i ---"
    while true; do
        read -p "IPv4 address: " ip
        [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
        echo "Invalid IPv4 format."
    done
    while true; do
        read -p "Username: " user
        [[ "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] && break
        echo "Username must start with a letter."
    done
    while true; do
        read -p "Short alias (e.g., node$i): " alias
        [[ "$alias" =~ ^[a-zA-Z0-9-]+$ ]] && break
        echo "Alias: only letters, numbers, and '-'."
    done

    echo "Copying key to $user@$ip..."
    if ssh-copy-id -i "$HOME/.ssh/id_rsa.pub" -o "StrictHostKeyChecking=no" "$user@$ip"; then
        echo "Key successfully copied."
    else
        echo "Copy error. Check access and password."
        exit 1
    fi

    if ! grep -q "^Host $alias$" "$HOME/.ssh/config" 2>/dev/null; then
        cat >> "$HOME/.ssh/config" <<SSHCONF
Host $alias
    HostName $ip
    User $user
    Port 22
SSHCONF
        echo "Alias '$alias' added to ~/.ssh/config"
    else
        echo "Alias '$alias' already exists."
    fi
    echo "----------------------------------------"
done

echo "Reading configured nodes from ~/.ssh/config..."
declare -a ALIASES=() IPS=() USERS=()
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^Host[[:space:]]+([^[:space:]]+) ]]; then
        ALIASES+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ ^[[:space:]]+HostName[[:space:]]+([^[:space:]]+) ]]; then
        IPS+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ ^[[:space:]]+User[[:space:]]+([^[:space:]]+) ]]; then
        USERS+=("${BASH_REMATCH[1]}")
    fi
done < "$HOME/.ssh/config"

[[ ${#IPS[@]} -eq 0 ]] && { echo "No nodes found."; exit 1; }

LOCAL_IP=$(hostname -I | awk '{print $1}')
NODES=("$LOCAL_IP" "${IPS[@]}")
echo "Final list of cluster nodes: ${NODES[*]}"

echo "Checking SSH access..."
for i in "${!ALIASES[@]}"; do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${USERS[$i]}@${ALIASES[$i]}" true; then
        echo "No access to ${ALIASES[$i]}"
        exit 1
    fi
done
echo "SSH is available on all nodes."

# ==========================================================
# 1. SYNCHRONIZE /etc/hosts
# ==========================================================
echo ""
echo "============================================================"
echo "[1/5] SYNC /etc/hosts"
echo "============================================================"

declare -a NODE_IPS=("$LOCAL_IP" "${IPS[@]}")
declare -a NODE_NAMES=("$(hostname)")
for i in "${!ALIASES[@]}"; do
    NODE_NAMES+=("$(ssh "${USERS[$i]}@${ALIASES[$i]}" hostname 2>/dev/null || echo "node-${IPS[$i]}")")
done

HOSTS_BLOCK=$(mktemp)
{
    echo "# GLUSTERFS_CLUSTER_START"
    for idx in "${!NODE_IPS[@]}"; do
        printf "%-16s %s\n" "${NODE_IPS[$idx]}" "${NODE_NAMES[$idx]}"
    done
    echo "# GLUSTERFS_CLUSTER_END"
} > "$HOSTS_BLOCK"

for i in "${!ALIASES[@]}"; do
    echo ""
    echo ">>> Node: ${ALIASES[$i]} (${IPS[$i]})"
    echo "    [1/2] Uploading the hosts_block file to a remote node..."
    ssh "${USERS[$i]}@${ALIASES[$i]}" "cat > /tmp/gluster_hosts_block" < "$HOSTS_BLOCK"
    ssh "${USERS[$i]}@${ALIASES[$i]}" "cat > /tmp/sync_hosts.sh" <<'SYNC_EOF'
if grep -q "# GLUSTERFS_CLUSTER_START" /etc/hosts; then
    grep -v "# GLUSTERFS_CLUSTER_START\|# GLUSTERFS_CLUSTER_END" /etc/hosts | \
        grep -v "192\.168\.72\." > /tmp/hosts_clean
    mv /tmp/hosts_clean /etc/hosts
fi
cat /tmp/gluster_hosts_block >> /etc/hosts
rm -f /tmp/gluster_hosts_block
SYNC_EOF
    echo "    [2/2] Applying changes to /etc/hosts (requires sudo password)..."
    ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo bash /tmp/sync_hosts.sh && rm -f /tmp/sync_hosts.sh"
    echo "    Done."
done

echo ""
echo "Updating local /etc/hosts..."
if grep -q "# GLUSTERFS_CLUSTER_START" /etc/hosts; then
    echo "    Removing old cluster entries..."
    grep -v "# GLUSTERFS_CLUSTER_START\|# GLUSTERFS_CLUSTER_END" /etc/hosts | \
        grep -v "192\.168\.72\." > /tmp/hosts_clean
    mv /tmp/hosts_clean /etc/hosts
fi
echo "    Adding new entries..."
cat "$HOSTS_BLOCK" >> /etc/hosts
rm -f "$HOSTS_BLOCK"
echo "/etc/hosts successfully synchronized."

# ==========================================================
# 2. DEFINE GLUSTERFS SYSTEM USER
# ==========================================================
echo ""
echo "============================================================"
echo "[2/5] DEFINING THE GLUSTERFS SYSTEM USER"
echo "============================================================"

if id gluster >/dev/null 2>&1; then
    GLUSTER_USER="gluster"
elif id glusterfs >/dev/null 2>&1; then
    GLUSTER_USER="glusterfs"
else
    echo "ERROR: gluster/glusterfs user not found."
    exit 1
fi

echo "System user identified: $GLUSTER_USER"

# ==========================================================
# 3. COLLECT AND DISTRIBUTE TLS CERTIFICATES
# ==========================================================
echo ""
echo "============================================================"
echo "[3/5] COLLECTION AND DISTRIBUTION OF TLS CERTIFICATES"
echo "============================================================"

CA_DIR="/etc/ssl/glusterfs/ca"
CA_FILE="/etc/ssl/glusterfs.ca"

echo "Preparing local directory $CA_DIR..."
mkdir -p "$CA_DIR"
cp /etc/ssl/glusterfs.pem "$CA_DIR/$(hostname).pem"

# 4-step method without pipe to prevent SSH hanging
for i in "${!ALIASES[@]}"; do
    echo ""
    echo ">>> Node: ${ALIASES[$i]} (${IPS[$i]})"
    
    echo "    [1/4] Creating a temporary script to copy the certificate..."
    ssh "${USERS[$i]}@${ALIASES[$i]}" "cat > /tmp/get_cert.sh" <<'GET_CERT'
sudo cp /etc/ssl/glusterfs.pem /tmp/user_cert.pem
sudo chown $USER:$USER /tmp/user_cert.pem
sudo chmod 644 /tmp/user_cert.pem
GET_CERT
    
    echo "    [2/4] Script execution (requires sudo password)..."
    ssh -t "${USERS[$i]}@${ALIASES[$i]}" "bash /tmp/get_cert.sh"
    
    echo "    [3/4] Certificate download via scp..."
    scp -q "${USERS[$i]}@${ALIASES[$i]}:/tmp/user_cert.pem" "$CA_DIR/${ALIASES[$i]}.pem"
    
    echo "    [4/4] Clearing temporary files..."
    ssh "${USERS[$i]}@${ALIASES[$i]}" "rm -f /tmp/user_cert.pem /tmp/get_cert.sh"
    echo "    Certificate saved: $CA_DIR/${ALIASES[$i]}.pem"
done

echo ""
echo "Creating a common CA file $CA_FILE (concatenating all certificates)..."
cat "$CA_DIR"/*.pem > "$CA_FILE"

if [[ -f "$CA_FILE" ]]; then
    chmod 644 "$CA_FILE"
    echo "CA file created ($(wc -l < "$CA_FILE") lines)."
else
    echo "ERROR: CA file not created."
    exit 1
fi

for i in "${!ALIASES[@]}"; do
    echo ""
    echo ">>> Node: ${ALIASES[$i]} (${IPS[$i]})"
    
    echo "    [1/3] Uploading CA file and certificates to /tmp on remote node..."
    scp -q "$CA_FILE" "${USERS[$i]}@${ALIASES[$i]}:/tmp/gluster_ca_file.pem"
    
    tar -czf /tmp/gluster_ca_bundle.tar.gz -C "$CA_DIR" . 2>/dev/null
    scp -q /tmp/gluster_ca_bundle.tar.gz "${USERS[$i]}@${ALIASES[$i]}:/tmp/gluster_ca_bundle.tar.gz"
    rm -f /tmp/gluster_ca_bundle.tar.gz
    
    ssh "${USERS[$i]}@${ALIASES[$i]}" "cat > /tmp/apply_tls.sh" <<'APPLY_TLS'
CA_DIR="/etc/ssl/glusterfs/ca"
CA_FILE="/etc/ssl/glusterfs.ca"
mkdir -p "$CA_DIR"
tar -xzf /tmp/gluster_ca_bundle.tar.gz -C "$CA_DIR"
rm -f /tmp/gluster_ca_bundle.tar.gz
cp /tmp/gluster_ca_file.pem "$CA_FILE"
chmod 644 "$CA_FILE"
rm -f /tmp/gluster_ca_file.pem
systemctl restart glusterd
APPLY_TLS
    
    echo "    [2/3] Applying TLS on remote node (requires sudo password)..."
    ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo bash /tmp/apply_tls.sh && rm -f /tmp/apply_tls.sh"
    echo "    [3/3] TLS applied, glusterd restarted."
done

echo ""
echo "Restarting local glusterd..."
sudo systemctl restart glusterd
echo "TLS bundle successfully distributed."

# ==========================================================
# 4. PEER PROBE AND CONNECTIVITY WAIT (uses hostnames)
# ==========================================================
echo ""
echo "============================================================"
echo "[4/5] ADDING NODES TO THE CLUSTER (PEER PROBE)"
echo "============================================================"

for i in "${!ALIASES[@]}"; do
    REMOTE_HOSTNAME="${NODE_NAMES[$((i+1))]}"
    echo "Probe: $REMOTE_HOSTNAME (${IPS[$i]})"
    gluster peer probe "$REMOTE_HOSTNAME" 2>/dev/null || true
done

echo ""
echo "Waiting for the 'Connected' state..."
CONNECTED=0
for attempt in {1..20}; do
    CONNECTED=$(gluster peer status | grep -c "State: Peer in Cluster (Connected)" || true)
    echo "  Attempt $attempt/20: connected $CONNECTED out of ${#IPS[@]}"
    if [[ "$CONNECTED" -eq "${#IPS[@]}" ]]; then break; fi
    sleep 3
done

if [[ "$CONNECTED" -ne "${#IPS[@]}" ]]; then
    echo "WARNING: Not all nodes are connected. Checking status:"
    gluster peer status
else
    echo "All nodes are in the Connected state."
fi

# ==========================================================
# 5. VOLUME CREATION AND MOUNTING
# ==========================================================
echo ""
echo "============================================================"
echo "[5/5] CREATING A VOLUME AND MOUNTING"
echo "============================================================"

VOL_NAME="${VOL_NAME:-gv0}"
BRICK_PATH="${BRICK_PATH:-/data/gluster/brick}"

if gluster volume info "$VOL_NAME" &>/dev/null; then
    echo "Volume '$VOL_NAME' already exists. Removing metadata..."
    gluster volume stop "$VOL_NAME" force 2>/dev/null || true
    gluster volume delete "$VOL_NAME" 2>/dev/null || true
    echo "Old volume removed."
else
    echo "The volume '$VOL_NAME' does not exist. Creating a new one."
fi

echo ""
echo "Creating brick directories ($BRICK_PATH) with the owner $GLUSTER_USER..."
for i in "${!ALIASES[@]}"; do
    echo ""
    echo ">>> Node: ${ALIASES[$i]} (${IPS[$i]})"
    
    REMOTE_BRICK_EXISTS=$(ssh "${USERS[$i]}@${ALIASES[$i]}" "test -d $BRICK_PATH && echo yes || echo no")
    if [[ "$REMOTE_BRICK_EXISTS" == "yes" ]]; then
        echo "    [Operation] Directory $BRICK_PATH already exists. Skipping creation."
    else
        echo "    [Operation] Creating the $BRICK_PATH directory and assigning the owner to $GLUSTER_USER"
        echo "    >>> Enter the sudo password for the node: ${ALIASES[$i]} (${IPS[$i]})"
        ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo mkdir -p $BRICK_PATH && sudo chown -R $GLUSTER_USER:$GLUSTER_USER $BRICK_PATH" || {
            echo "    WARNING: Failed to create directory."
        }
    fi
    echo "    Done."
done

echo ""
echo "Creating local brick directory..."
if [[ -d "$BRICK_PATH" ]]; then
    echo "    Local directory $BRICK_PATH already exists. Skipping."
else
    sudo mkdir -p "$BRICK_PATH" 2>/dev/null || true
fi
sudo chown -R "$GLUSTER_USER:$GLUSTER_USER" "$BRICK_PATH" 2>/dev/null || true
echo "Local brick is ready."

REPLICA_COUNT=3
[[ ${#NODES[@]} -lt 3 ]] && REPLICA_COUNT=${#NODES[@]}
ACTIVE_NODES=("${NODES[@]:0:REPLICA_COUNT}")

BRICKS=()
for h in "${ACTIVE_NODES[@]}"; do BRICKS+=("$h:$BRICK_PATH"); done

echo ""
echo "Volume creation $VOL_NAME (replica $REPLICA_COUNT)..."
gluster volume create "$VOL_NAME" replica "$REPLICA_COUNT" "${BRICKS[@]}" force 2>&1 || {
    echo "ERROR creating volume."
    exit 1
}

# ==========================================================
# ENABLING TLS ENCRYPTION
# ==========================================================
echo ""
echo "Enabling TLS encryption (client.ssl + server.ssl at the volume level)..."

CURRENT_CLIENT_SSL=$(gluster volume get "$VOL_NAME" client.ssl 2>/dev/null | tail -1 | awk '{print $2}' || echo "off")
CURRENT_SERVER_SSL=$(gluster volume get "$VOL_NAME" server.ssl 2>/dev/null | tail -1 | awk '{print $2}' || echo "off")

if [[ "$CURRENT_CLIENT_SSL" == "on" ]]; then
    echo "    client.ssl is already enabled. Skipping."
else
    gluster volume set "$VOL_NAME" client.ssl on 2>&1 || { echo "ERROR: failed to enable client.ssl."; exit 1; }
fi

if [[ "$CURRENT_SERVER_SSL" == "on" ]]; then
    echo "    server.ssl is already enabled. Skipping."
else
    gluster volume set "$VOL_NAME" server.ssl on 2>&1 || { echo "ERROR: failed to enable server.ssl."; exit 1; }
fi

echo ""
echo "Checking and creating secure-access on remote nodes..."
for i in "${!ALIASES[@]}"; do
    echo "    >>> Node: ${ALIASES[$i]} (${IPS[$i]})"
    REMOTE_SECURE=$(ssh "${USERS[$i]}@${ALIASES[$i]}" "test -f /var/lib/glusterd/secure-access && echo yes || echo no")
    if [[ "$REMOTE_SECURE" == "yes" ]]; then
        echo "    [Operation] File /var/lib/glusterd/secure-access already exists. Skipping."
    else
        echo "    [Operation] Creating /var/lib/glusterd/secure-access file to activate TLS"
        echo "    >>> Enter the sudo password for the node: ${ALIASES[$i]} (${IPS[$i]})"
        ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo touch /var/lib/glusterd/secure-access"
    fi
done

echo "    Locally:"
if [[ -f /var/lib/glusterd/secure-access ]]; then
    echo "    secure-access already exists. Skipping."
else
    sudo touch /var/lib/glusterd/secure-access
fi
echo "    secure-access is ready on all nodes."

echo ""
echo "Restart glusterd on all nodes to activate TLS..."
for i in "${!ALIASES[@]}"; do
    echo "    >>> Node: ${ALIASES[$i]} (${IPS[$i]})"
    echo "    [Operation] Restarting the glusterd service to apply TLS settings"
    echo "    >>> Enter the sudo password for the node: ${ALIASES[$i]} (${IPS[$i]})"
    ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo systemctl restart glusterd"
done
echo "    Restarting local glusterd..."
sudo systemctl restart glusterd
sleep 3

echo ""
echo "Volume start..."
gluster volume start "$VOL_NAME" 2>&1 || {
    echo "ERROR starting volume."
    exit 1
}

echo ""
echo "TLS status check..."
CLIENT_SSL=$(gluster volume get "$VOL_NAME" client.ssl 2>/dev/null | tail -1 | awk '{print $2}')
SERVER_SSL=$(gluster volume get "$VOL_NAME" server.ssl 2>/dev/null | tail -1 | awk '{print $2}')

echo "    client.ssl: $CLIENT_SSL"
echo "    server.ssl: $SERVER_SSL"

if [[ "$CLIENT_SSL" == "on" && "$SERVER_SSL" == "on" ]]; then
    echo "TLS encryption is ACTIVE."
else
    echo "WARNING: TLS is not fully activated."
fi

echo "The volume is created, running, and TLS encryption is enabled."

# ==========================================================
# MOUNTING (aggressive hung FUSE mount cleanup)
# ==========================================================
echo ""
echo "Mounting a volume on all nodes..."
for i in "${!ALIASES[@]}"; do
    echo ""
    echo ">>> Node: ${ALIASES[$i]} (${IPS[$i]})"
    
    ssh "${USERS[$i]}@${ALIASES[$i]}" "cat > /tmp/gluster_mount.sh" <<MOUNT_SCRIPT
set +e  

umount -l /mnt/$VOL_NAME 2>/dev/null
umount -f /mnt/$VOL_NAME 2>/dev/null
sleep 2

if ! stat /mnt/$VOL_NAME >/dev/null 2>&1; then
    # Directory is hung/broken - remove and recreate
    rmdir /mnt/$VOL_NAME 2>/dev/null
    rm -rf /mnt/$VOL_NAME 2>/dev/null
fi

mkdir -p /mnt/$VOL_NAME

set -e

NODE_IP=$(hostname -I | awk '{print $1}')

if ! grep -q "/mnt/$VOL_NAME" /etc/fstab; then
    echo "${NODE_IP}:/${VOL_NAME} /mnt/${VOL_NAME} glusterfs defaults,_netdev,x-systemd.requires=glusterd.service,x-systemd.after=network-online.target,x-systemd.device-timeout=15 0 0" >> /etc/fstab
    echo "Entry added to /etc/fstab for ${NODE_IP}:/${VOL_NAME}"
else
    echo "Entry already exists in /etc/fstab. Skipping."
fi

#if ! grep -q "/mnt/$VOL_NAME" /etc/fstab; then
#    localhost:/$VOL_NAME /mnt/$VOL_NAME glusterfs _netdev,transport=socket 0 0
#    echo "localhost:/gv0 /mnt/gv0 glusterfs defaults,_netdev,x-systemd.requires=glusterd.service,x-systemd.after=network-online.target 0 0" >> /etc/fstab
#fi
systemctl daemon-reload

if ! mountpoint -q /mnt/$VOL_NAME 2>/dev/null; then
    mount -t glusterfs localhost:/$VOL_NAME /mnt/$VOL_NAME
fi
MOUNT_SCRIPT
    
    REMOTE_MOUNTED=$(ssh "${USERS[$i]}@${ALIASES[$i]}" "df /mnt/$VOL_NAME 2>/dev/null | tail -1 | awk '{print \$1}'" 2>/dev/null || echo "no")
    
    if [[ "$REMOTE_MOUNTED" == "localhost:/$VOL_NAME" ]]; then
        echo "    [Operation] Volume is already mounted at /mnt/$VOL_NAME. Skipping."
    else
        echo "    [Operation] Aggressive cleanup and mounting the volume"
        echo "    >>> Enter the sudo password for the node: ${ALIASES[$i]} (${IPS[$i]})"
        ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo bash /tmp/gluster_mount.sh && rm -f /tmp/gluster_mount.sh" || {
            echo "    WARNING: Mounting error. Check: journalctl -u glusterd -f"
        }
    fi
    echo "    Done."
done

echo ""
echo "Local mount..."

set +e
umount -l "/mnt/$VOL_NAME" 2>/dev/null
umount -f "/mnt/$VOL_NAME" 2>/dev/null
sleep 2

if ! stat "/mnt/$VOL_NAME" >/dev/null 2>&1; then
    rmdir "/mnt/$VOL_NAME" 2>/dev/null
    rm -rf "/mnt/$VOL_NAME" 2>/dev/null
fi

mkdir -p "/mnt/$VOL_NAME"
set -e

NODE_IP=$(hostname -I | awk '{print $1}')

if ! grep -q "/mnt/$VOL_NAME" /etc/fstab; then
    echo "${NODE_IP}:/${VOL_NAME} /mnt/${VOL_NAME} glusterfs defaults,_netdev,x-systemd.requires=glusterd.service,x-systemd.after=network-online.target,x-systemd.device-timeout=15 0 0" >> /etc/fstab
    echo "Entry added to /etc/fstab for ${NODE_IP}:/${VOL_NAME}"
else
    echo "Entry already exists in /etc/fstab. Skipping."
fi

#if ! grep -q "/mnt/$VOL_NAME" /etc/fstab; then
    #localhost:/$VOL_NAME /mnt/$VOL_NAME glusterfs _netdev,transport=socket 0 0
    #localhost:/gv0 /mnt/gv0 glusterfs defaults,_netdev,x-systemd.requires=glusterd.service,x-systemd.after=network-online.target 0 0
#    echo "localhost:/gv0 /mnt/gv0 glusterfs defaults,_netdev,x-systemd.requires=glusterd.service,x-systemd.after=network-online.target 0 0" >> /etc/fstab
#fi
systemctl daemon-reload 2>/dev/null || true

LOCAL_STATUS=$(df "/mnt/$VOL_NAME" 2>/dev/null | tail -1 | awk '{print $1}' || echo "no")
if [[ "$LOCAL_STATUS" != "localhost:/$VOL_NAME" ]]; then
    mount -t glusterfs "localhost:/$VOL_NAME" "/mnt/$VOL_NAME" 2>/dev/null || {
        echo "WARNING: Local mount failed."
    }
else
    echo "    Local volume is already mounted correctly."
fi

echo ""
echo "============================================================"
echo "=== DONE ==="
echo "============================================================"
echo "Cluster status:"
gluster peer status | grep -E "Hostname|State"
echo ""
echo "Volume information:"
gluster volume info "$VOL_NAME" | grep -E "Volume Name|Type|Status|Number of Bricks|client.ssl|server.ssl"
echo ""
echo "Mount verification (all nodes):"
for i in "${!ALIASES[@]}"; do
    REMOTE_MOUNT_STATUS=$(ssh "${USERS[$i]}@${ALIASES[$i]}" "df -h /mnt/$VOL_NAME 2>/dev/null | tail -1" || echo "NOT MOUNTED")
    echo "    ${ALIASES[$i]}: $REMOTE_MOUNT_STATUS"
done
echo "    Local: $(df -h /mnt/$VOL_NAME 2>/dev/null | tail -1 || echo 'NOT MOUNTED')"
echo ""
echo "Disk usage:"
df -h "/mnt/$VOL_NAME" 2>/dev/null || echo "Volume is not mounted locally."
echo ""
echo "The volume is accessible at the path: /mnt/$VOL_NAME on all nodes."
