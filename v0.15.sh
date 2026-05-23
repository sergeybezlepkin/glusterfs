#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# PART 2: Configuring SSH → /etc/hosts → TLS → Peer → Volume → Mount
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
        echo "The name must start with a letter."
    done
    while true; do
        read -p "Short alias (for example, node$i): " alias
        [[ "$alias" =~ ^[a-zA-Z0-9-]+$ ]] && break
        echo "Alias: only letters, numbers and '-'."
done

    echo "Copying the key to $user@$ip..."
if ssh-copy-id -i "$HOME/.ssh/id_rsa.pub" -o "StrictHostKeyChecking=no" "$user@$ip"; then
        echo "Key copied successfully."
else
echo "Copy error."
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

[[${#IPS[@]} -eq 0 ]] &&{ echo " Nodes not found."; exit 1; }

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
# 1. SYNCHRONIZATION OF /etc/hosts
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
echo " [1/2] Uploading the hosts_block file to a remote node..."
    ssh "${USERS[$i]}@${ALIASES[$i]}" "cat > /tmp/gluster_hosts_block" < "$HOSTS_BLOCK"
    ssh "${USERS[$i]}@${ALIASES[$i]}" "cat > /tmp/sync_hosts.sh" <<'SYNC_EOF'
sed -i '/^# GLUSTERFS_CLUSTER_START$/,/^# GLUSTERFS_CLUSTER_END$/d' /etc/hosts
cat /tmp/gluster_hosts_block >> /etc/hosts
rm -f /tmp/gluster_hosts_block
SYNC_EOF
echo " [2/2] Applying changes to /etc/hosts (requires sudo password)..."
ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo bash /tmp/sync_hosts.sh && rm -f /tmp/sync_hosts.sh "
echo " is ready."
done

echo ""
echo "Updating the local /etc/hosts..."
sed -i'/^# GLUSTERFS_CLUSTER_START$/,/^# GLUSTERFS_CLUSTER_END$/d' /etc/hosts
cat "$HOSTS_BLOCK" >> /etc/hosts
rm -f "$HOSTS_BLOCK"
echo"/etc/hosts successfully synchronized."

# ==========================================================
# 2. DETERMINING THE OWNER OF BRICK (gluster / glusterfs)
# ==========================================================
echo ""
echo "============================================================"
echo "[2/5] DEFINING THE GLUSTERFS SYSTEM USER"
echo "============================================================"

# We check on the first remote node (assuming that all nodes are the same)
GLUSTER_USER=""
if id glusterfs >/dev/null 2>&1; then
    GLUSTER_USER="glusterfs"
elif id gluster >/dev/null 2>&1; then
    GLUSTER_USER="gluster"
else
echo "The glusterfs/gluster user was not found locally. I define it through the owner /var/lib/glusterd..."
GLUSTER_USER=$(stat -c '%U' /var/lib/glusterd 2>/dev/null || echo "root")
fi

# Checking on remote nodes (for warranty)
for i in "${!ALIASES[@]}"; do
    REMOTE_USER=$(ssh "${USERS[$i]}@${ALIASES[$i]}" "stat -c '%U' /var/lib/glusterd 2>/dev/null || echo root")
    if [[ "$REMOTE_USER" != "$GLUSTER_USER" ]]; then
        echo "ATTENTION: On ${ALIASES[$i]} owner /var/lib/glusterd = '$REMOTE_USER', locally = '$GLUSTER_USER'. I use a local one."
    fi
done

echo "The system user has been identified: $GLUSTER_USER"

# ==========================================================
# 3. COLLECTION AND DISTRIBUTION OF TLS CERTIFICATES
# ==========================================================
echo ""
echo "============================================================"
echo "[3/5] COLLECTION AND DISTRIBUTION OF TLS CERTIFICATES OF "
echo "============================================================"

CA_DIR="/etc/ssl/glusterfs/ca"
CA_FILE="/etc/ssl/glusterfs.ca"

echo "Preparing the local directory $CA_DIR..."
mkdir -p "$CA_DIR"
cp /etc/ssl/glusterfs.pem "$CA_DIR/$(hostname).pem"

# Collecting certificates from remote nodes
for i in "${!ALIASES[@]}"; do
    echo ""
echo ">>> Node: ${ALIASES[$i]} (${IPS[$i]})"
echo " Reading the remote certificate /etc/ssl/glusterfs.pem..."
    # Without -t, since there is no stdout redirect. sudo via stdin.
    ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo cat /etc/ssl/glusterfs.pem" \
| tr -d '\r' > "$CA_DIR/${ALIASES[$i]}.pem"
echo " Certificate saved locally: $CA_DIR/${ALIASES[$i]}.pem"
done

# Creating a single CA file (concatenation of all PEMS)
echo ""
echo "Creating a common CA file $CA_FILE (concatenation of all certificates)..."
cat "$CA_DIR"/*.pem > "$CA_FILE"
chmod 644 "$CA_FILE"
echo "CA file created ($(wc -l < "$CA_FILE") lines)."

# Distributing the CA file and directory to remote nodes
for i in "${!ALIASES[@]}"; do
    echo ""
echo ">>> Node: ${ALIASES[$i]} (${IPS[$i]})"
    
    # Step 1: Transfer files to /tmp (from a regular user, without sudo)
    echo " [1/3] Uploading a CA file and certificates to /tmp on a remote host..."
scp -q "$CA_FILE" "${USERS[$i]}@${ALIASES[$i]}:/tmp/gluster_ca_file.pem"
    
    # We transfer all PEM files via tar in one file
    tar -czf /tmp/gluster_ca_bundle.tar.gz -C "$CA_DIR" . 2>/dev/null
    scp -q /tmp/gluster_ca_bundle.tar.gz "${USERS[$i]}@${ALIASES[$i]}:/tmp/gluster_ca_bundle.tar.gz"
    rm -f /tmp/gluster_ca_bundle.tar.gz
    
    # Step 2: Download the application script
    ssh "${USERS[$i]}@${ALIASES[$i]}" "cat > /tmp/apply_tls.sh" <<APPLY_TLS
mkdir -p $CA_DIR
tar -xzf /tmp/gluster_ca_bundle.tar.gz -C $CA_DIR
rm -f /tmp/gluster_ca_bundle.tar.gz
cp /tmp/gluster_ca_file.pem $CA_FILE
chmod 644 $CA_FILE
rm -f /tmp/gluster_ca_file.pem
systemctl restart glusterd
APPLY_TLS
    
    # Step 3: Execution with sudo (one time, one password)
    echo " [2/3] TLS application on a remote node (sudo password required)..."
ssh -t "${USERS[$i]}@${ALIASES[$i]}" "sudo bash /tmp/apply_tls.sh && rm -f /tmp/apply_tls.sh "
    echo " [3/3] TLS applied, glusterd restarted."
done

echo ""
echo "Restarting local glusterd..."
sudo systemctl restart glusterd
echo "TLS bundle has been successfully distributed."

# ==========================================================
# 4. PEER PROBE AND CONNECTIVITY EXPECTATION
# ==========================================================
echo ""
echo "============================================================"
echo "[4/5] ADDING NODES TO THE CLUSTER (PEER PROBE)"
echo "============================================================"

for ip in "${IPS[@]}"; do
    echo "Probe: $ip"
    gluster peer probe "$ip" 2>/dev/null || true
done

echo ""
echo "Waiting for the 'Connected' state..."
CONNECTED=0
for attempt in {1..20}; do
    CONNECTED=$(gluster peer status | grep -c "State: Peer in Cluster (Connected)" || true)
echo " Attempt $attempt/20: connected $CONNECTED from ${#IPS[@]}"
if [[ "$CONNECTED" -eq "${#IPS[@]}" ]]; then break; fi
    sleep 3
done

if [[ "$CONNECTED" -ne "${#IPS[@]}" ]]; then
    echo "ATTENTION: not all nodes are connected. Checking the status:"
gluster peer status
    echo ""
    echo "If the nodes are in the 'Accepted' or 'Disconnected' state, it may be because of TLS. I continue..."
else
echo "All nodes are in the Connected state."
fi

# ==========================================================
# 5. VOLUME CREATION AND MOUNTING
# ==========================================================
echo ""
