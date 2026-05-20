#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# It runs ONLY on the first (local) node of the cluster
#==========================================================

# --- 1. Root verification ---
if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

# --- 2. SSH configuration (interactive) ---
echo " === SSH ACCESS CONFIGURATION ==="
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

if [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
    echo "SSH key generation (RSA 4096)..."
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa" -q
    echo "Key created: $HOME/.ssh/id_rsa"
else
echo "SSH key already exists. Skipping the generation."
fi

[[ ! -f "$HOME/.ssh/config" ]] && touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"

read -p "How many remote nodes should I add? (Total will be: N + 1 local): " node_count
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
    if ssh-copy-id -i "$HOME/.ssh/id_rsa.pub" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$user@$ip"; then
        echo "Key copied successfully."
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

# --- 3. Parsing ~/.ssh/config into arrays ---
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

# --- 4. Checking SSH connectivity ---
echo "Checking SSH access to all nodes..."
for i in "${!ALIASES[@]}"; do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${USERS[$i]}@${ALIASES[$i]}" true; then
        echo "No access to ${ALIASES[$i]} (${USERS[$i]}@${IPS[$i]})"
exit 1
    fi
done
echo "SSH is available on all nodes."

# --- 5. Synchronization of /etc/hosts (NEW) ---
echo "Synchronization of /etc/hosts on all nodes..."
declare -a NODE_IPS=("$LOCAL_IP" "${IPS[@]}")
declare -a NODE_NAMES=("$(hostname)")
for i in "${!ALIASES[@]}"; do
    NODE_NAMES+=("$(ssh "${USERS[$i]}@${ALIASES[$i]}" hostname 2>/dev/null || echo "node-${IPS[$i]}")")
done

# Creating a block of records in a temporary file
HOSTS_BLOCK=$(mktemp)
{
    echo "# GLUSTERFS_CLUSTER_START"
    for idx in "${!NODE_IPS[@]}"; do
        printf "%-16s %s\n" "${NODE_IPS[$idx]}" "${NODE_NAMES[$idx]}"
    done
    echo "# GLUSTERFS_CLUSTER_END"
} > "$HOSTS_BLOCK"

# Application function /etc/hosts
apply_hosts() {
local user="$1" host="$2"
ssh"${user:+$user@}$host" sudo bash <<EOF
sed -i '/# GLUSTERFS_CLUSTER_START/,/# GLUSTERFS_CLUSTER_END/d' /etc/hosts
cat >> /etc/hosts <<'INNER_EOF'
$(cat "$HOSTS_BLOCK")
INNER_EOF
EOF
}

apply_hosts "" "localhost" 2>/dev/null || sudo bash <<EOF
sed -i '/# GLUSTERFS_CLUSTER_START/,/# GLUSTERFS_CLUSTER_END/d' /etc/hosts
cat >> /etc/hosts <<'INNER_EOF'
$(cat "$HOSTS_BLOCK")
INNER_EOF
EOF

for i in "${!ALIASES[@]}"; do
    apply_hosts "${USERS[$i]}" "${ALIASES[$i]}"
done
rm -f "$HOSTS_BLOCK"
echo "/etc/hosts successfully synchronized."

# --- 6. TLS certificate distribution ---
CA_DIR="/etc/ssl/glusterfs/ca"
echo "Collection and distribution of TLS certificates..."
mkdir -p "$CA_DIR"
cp /etc/ssl/glusterfs.pem "$CA_DIR/$(hostname).pem"

for i in "${!ALIASES[@]}"; do
    scp -q "${USERS[$i]}@${ALIASES[$i]}:/etc/ssl/glusterfs.pem" "$CA_DIR/${ALIASES[$i]}.pem"
done

for i in "${!ALIASES[@]}"; do
    ssh "${USERS[$i]}@${ALIASES[$i]}" "sudo mkdir -p $CA_DIR"
    for cert in "$CA_DIR"/*.pem; do
        scp -q "$cert" "${USERS[$i]}@${ALIASES[$i]}:$CA_DIR/"
    done
    ssh "${USERS[$i]}@${ALIASES[$i]}" "sudo systemctl restart glusterd"
done
sudo systemctl restart glusterd
echo "TLS bundle has been successfully distributed."

# --- 7. Peer Probe & Waiting for connectivity ---
echo "Adding nodes to the cluster (peer probe)..."
for ip in "${IPS[@]}"; do gluster peer probe "$ip" 2>/dev/null || true; done

echo "Waiting for node state synchronization..."
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

# --- 8. Volume Creation/Re-creation ---
VOL_NAME="${VOL_NAME:-gv0}"
BRICK_PATH="${BRICK_PATH:-/data/gluster/brick}"

if gluster volume info "$VOL_NAME" &>/dev/null; then
    echo "Volume '$VOL_NAME' already exists. Deleting metadata (data in brick will be saved)..."
gluster volume stop "$VOL_NAME" force || true
    gluster volume delete "$VOL_NAME"
fi

echo "Creating brick directories..."
for i in "${!ALIASES[@]}"; do
    ssh "${USERS[$i]}@${ALIASES[$i]}" "sudo mkdir -p $BRICK_PATH && sudo chown -R glusterfs:glusterfs $BRICK_PATH"
done
sudo mkdir -p "$BRICK_PATH" && sudo chown -R glusterfs:glusterfs "$BRICK_PATH"

#GlusterFS requires multiple replicas. Safely take a multiple of 3 or all if <=3
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

# --- 9. Automatic mounting on all nodes ---
echo "Mounting a volume on all nodes..."
mount_on_node() {
local user="$1" host="$2"
ssh"${user:+$user@}$host" sudo bash <<MOUNT_EOF
mkdir -p /mnt/$VOL_NAME
if ! grep -q "/mnt/$VOL_NAME" /etc/fstab; then
    echo "localhost:/$VOL_NAME /mnt/$VOL_NAME glusterfs _netdev,transport=socket 0 0" >> /etc/fstab
fi
mount -a 2>/dev/null || mount -t glusterfs localhost:/$VOL_NAME /mnt/$VOL_NAME
MOUNT_EOF
}

mount_on_node "" "localhost"
for i in "${!ALIASES[@]}"; do
    mount_on_node "${USERS[$i]}" "${ALIASES[$i]}"
done

# --- 10. Final check ---
echo " === DONE ==="
echo "Cluster status:"
gluster peer status | grep -E "Hostname|State"
echo ""
echo "Volume Information:"
gluster volume info "$VOL_NAME" | grep -E "Volume Name|Status|Encryption|Type"
echo ""
echo "Disk:"
df -h "/mnt/$VOL_NAME"
echo "The volume is accessible by path: /mnt/$VOL_NAME on all nodes."
