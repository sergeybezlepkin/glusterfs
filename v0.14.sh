#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# It runs ONLY on the first (local) node of the cluster
# ==========================================================

if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

echo "=== SSH ACCESS SETTINGS ==="
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

if [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
    echo "SSH key generation (RSA 4096)..."
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa" -q
    echo "Key created: $HOME/.ssh/id_rsa"
else
    echo "The SSH key already exists. Skipping the generation."
fi

[[ ! -f "$HOME/.ssh/config" ]] && touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"

read -p "How many remote nodes should I add?? (Total will be: N + 1 local): " node_count
[[ "$node_count" =~ ^[1-9][0-9]*$ ]] || { echo "Enter a number >= 1"; exit 1; }

for (( i=1; i<=node_count; i++ )); do
    echo "--- Node $i ---"
while true; do
        read -p "IPv4 address: " ip
        [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
        echo "Invalid IPv4 format."
    done
    while true; do
        read -p "User name: " user
        [[ "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] && break
        echo "The name must start with a letter and contain only a-z, 0-9, _ or -"
done
    while true; do
        read -p "Short alias (for example, node$i): " alias
        [[ "$alias" =~ ^[a-zA-Z0-9-]+$ ]] && break
        echo "Alias: only letters, numbers and '-'."
done

    echo "Copying the key to $user@$ip..."
if ssh-copy-id -i "$HOME/.ssh/id_rsa.pub" -o "StrictHostKeyChecking=no" "$user@$ip"; then
        echo "The key has been copied successfully."
else
        echo "Copy error. Check the access and password."
        exit 1
    fi

    if ! grep -q "^Host $alias$" "$HOME/.ssh/config" 2>/dev/null; then
        cat >> "$HOME/.ssh/config" <<SSHCONF
Host $alias
    HostName $ip
    User $user
    Port 22
SSHCONF
        echo "Alias '$alias' has been added to ~/.ssh/config"
else
echo "Alias '$alias' already exists. Skip it."
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

if [[ ${#IPS[@]} -eq 0 ]]; then
    echo "Nodes not found in ~/.ssh/config."
exit 1
fi

LOCAL_IP=$(hostname -I | awk '{print $1}')
NODES=("$LOCAL_IP" "${IPS[@]}")
echo "Final list of cluster nodes: ${NODES[*]}"

echo "Checking SSH access to all nodes..."
for i in "${!ALIASES[@]}"; do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${USERS[$i]}@${ALIASES[$i]}" true; then
        echo "No access to ${ALIASES[$i]} (${USERS[$i]}@${IPS[$i]})"
exit 1
    fi
done
echo "SSH is available on all nodes."

# --- 1. Sync /etc/hosts ---
echo "Sync /etc/hosts on all nodes..."
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
    echo ">>> Enter the sudo password for the node: ${ALIASES[$i]} (${IPS[$i]})"
    
    # Step 1: Download data and script (files belong to a regular user)
    ssh "${USERS[$i]}@${ALIASES[$i]}" "cat > /tmp/gluster_hosts_block" < "$HOSTS_BLOCK"
    ssh "${USERS[$i]}@${ALIASES[$i]}" "cat > /tmp/sync_hosts.sh" <<'SYNC_EOF'
sed -i '/^# GLUSTERFS_CLUSTER_START$/,/^# GLUSTERFS_CLUSTER_END$/d' /etc/hosts
cat /tmp/gluster_hosts_block >> /etc/hosts
rm -f /tmp/gluster_hosts_block
SYNC_EOF

    # Step 2: Run as root + clean up the script (it's ours, rm will work)
    ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo bash /tmp/sync_hosts.sh && rm -f /tmp/sync_hosts.sh"
done

sed -i '/^# GLUSTERFS_CLUSTER_START$/,/^# GLUSTERFS_CLUSTER_END$/d' /etc/hosts
cat "$HOSTS_BLOCK" >> /etc/hosts
rm -f "$HOSTS_BLOCK"
echo "/etc/hosts successfully synchronized."

# --- 2. TLS certificate distribution ---
CA_DIR="/etc/ssl/glusterfs/ca"
echo "Collection and distribution of TLS certificates..."
mkdir -p "$CA_DIR"
cp /etc/ssl/glusterfs.pem "$CA_DIR/$(hostname).pem"

# Collection from remote nodes (via pipe: there is no intermediate file with root rights)
for i in "${!ALIASES[@]}"; do
    echo ">>> Enter the sudo password for the node: ${ALIASES[$i]} (${IPS[$i]})"
ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo cat /etc/ssl/glusterfs.pem" \
        | tr -d '\r' > "$CA_DIR/${ALIASES[$i]}.pem"
done

# Distribution to all nodes (via /tmp from a regular user)
for i in "${!ALIASES[@]}"; do
    echo ">>> Enter the sudo password for the node: ${ALIASES[$i]} (${IPS[$i]})"
ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo mkdir -p $CA_DIR"
for cert in "$CA_DIR"/*.pem; do
        cert_name=$(basename "$cert")
# The file is created by a regular user via scp
        scp -q "$cert" "${USERS[$i]}@${ALIASES[$i]}:/tmp/gluster_cert_tmp.pem"
# Moving and cleaning under sudo
        ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo mv /tmp/gluster_cert_tmp.pem $CA_DIR/$cert_name"
    done
    ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo systemctl restart glusterd"
done
sudo systemctl restart glusterd
echo "TLS bundle has been successfully distributed."

# --- 3. Peer Probe ---
echo "Adding nodes to the cluster (peer probe)..."
for ip in "${IPS[@]}"; do gluster peer probe "$ip" 2>/dev/null || true; done

echo "Waiting for synchronization of node status..."
CONNECTED=0
for attempt in {1..15}; do
    CONNECTED=$(gluster peer status | grep -c "State: Peer in Cluster (Connected)" || true)
    if [[ "$CONNECTED" -eq "${#IPS[@]}" ]]; then break; fi
    sleep 2
done

if [[ "$CONNECTED" -ne "${#IPS[@]}" ]]; then
    echo "Connected nodes: $CONNECTED from ${#IPS[@]}. Check: journalctl -u glusterd -f"
else
echo "All nodes are Connected."
fi

# --- 4. Volume Creation ---
VOL_NAME="${VOL_NAME:-gv0}"
BRICK_PATH="${BRICK_PATH:-/data/gluster/brick}"

if gluster volume info "$VOL_NAME" &>/dev/null; then
    echo "Volume '$VOL_NAME' already exists. Deleting metadata (data in brick will be saved)..."
gluster volume stop "$VOL_NAME" force || true
    gluster volume delete "$VOL_NAME"
fi

echo "Creating brick directories..."
for i in "${!ALIASES[@]}"; do
    echo ">>> Enter the sudo password for the node: ${ALIASES[$i]} (${IPS[$i]})"
ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo mkdir -p $BRICK_PATH && sudo chown -R glusterfs:glusterfs $BRICK_PATH"
done
sudo mkdir -p "$BRICK_PATH" && sudo chown -R glusterfs:glusterfs "$BRICK_PATH"

REPLICA_COUNT=3
if [[ ${#NODES[@]} -lt 3 ]]; then REPLICA_COUNT=${#NODES[@]}; fi
ACTIVE_NODES=("${NODES[@]:0:REPLICA_COUNT}")

BRICKS=()
for h in "${ACTIVE_NODES[@]}"; do BRICKS+=("$h:$BRICK_PATH"); done

echo "Create volume $VOL_NAME (replica $REPLICA_COUNT)..."
gluster volume create "$VOL_NAME" replica $REPLICA_COUNT "${BRICKS[@]}" force
gluster volume set "$VOL_NAME" encryption on
gluster volume start "$VOL_NAME"
echo "Volume created, running, and encryption enabled."

# --- 5. Mounting ---
echo "Mounting a volume on all nodes..."
for i in "${!ALIASES[@]}"; do
    echo ">>> Enter the sudo password for the node: ${ALIASES[$i]} (${IPS[$i]})"
    
    # Step 1: Download the mount script (the file belongs to a regular user)
    ssh "${USERS[$i]}@${ALIASES[$i]}" "cat > /tmp/gluster_mount.sh" <<MOUNT_SCRIPT
mkdir -p /mnt/$VOL_NAME
if ! grep -q "/mnt/$VOL_NAME" /etc/fstab; then
    echo "localhost:/$VOL_NAME /mnt/$VOL_NAME glusterfs _netdev,transport=socket 0 0" >> /etc/fstab
fi
mount -a 2>/dev/null || mount -t glusterfs localhost:/$VOL_NAME /mnt/$VOL_NAME
MOUNT_SCRIPT

    # Step 2: Run as root + clean up
    ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo bash /tmp/gluster_mount.sh && rm -f /tmp/gluster_mount.sh"
done

mkdir -p "/mnt/$VOL_NAME"
if ! grep -q "/mnt/$VOL_NAME" /etc/fstab; then
    echo "localhost:/$VOL_NAME /mnt/$VOL_NAME glusterfs _netdev,transport=socket 0 0" >> /etc/fstab
fi
mount -a 2>/dev/null || mount -t glusterfs "localhost:/$VOL_NAME" "/mnt/$VOL_NAME"

# --- 6. Bottom line ---
echo "=== DONE ==="
echo "Cluster status:"
gluster peer status | grep -E "Hostname|State"
echo ""
echo "Volume Information:"
gluster volume info "$VOL_NAME" | grep -E "Volume Name|Status|Encryption|Type"
echo ""
echo "Disk:"
df -h "/mnt/$VOL_NAME The "
echo" volume is accessible via the path: /mnt/$VOL_NAME on all nodes."
