#!/usr/bin/env bash
set -euo pipefail

# 1. Root check
if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

# 2. Hostname & /etc/hosts
LOCAL_IP=$(hostname -I | awk '{print $1}')
LOCAL_HOST=$(hostname)

if ! grep -q "$LOCAL_IP" /etc/hosts; then
    read -p "Set hostname? (y/n): " yn
    if [[ "$yn" =~ ^(y|yes)$ ]]; then
        while true; do
            read -p "Enter the hostname: " newhostname
            [[ "$newhostname" =~ ^[a-zA-Z0-9-]+$ ]] && break
            echo "Invalid format (only a-z, 0-9, -)"
done
        hostnamectl set-hostname "$newhostname"
        LOCAL_HOST="$newhostname"
    fi
    echo "$LOCAL_IP $LOCAL_HOST" >> /etc/hosts
fi

# 3. Time sync
if ! timedatectl | grep -q "System clock synchronized: yes"; then
    echo "The time is not synchronized. GlusterFS requires precise timing."
    dnf install -y chrony &>/dev/null && systemctl enable --now chronyd && systemctl restart chronyd
    timedatectl
    echo "Restart the script after synchronization. Give it 1-2 minutes; chronyd has already restarted."
exit 1
fi

# 4. Repo & Install
if [[ ! -f /etc/yum.repos.d/CentOS-Gluster-9.repo ]]; then
    cat > /etc/yum.repos.d/CentOS-Gluster-9.repo << 'EOF'
[centos-gluster9-storage]
name=CentOS Gluster 9 Storage
baseurl=https://buildlogs.centos.org/centos/9-stream/storage/x86_64/gluster-9/
gpgcheck=0
enabled=1
EOF
    dnf install -y glusterfs-server
fi

# 5. Firewall (one reload)
if ! firewall-cmd --query-service=glusterfs &>/dev/null || ! firewall-cmd --query-port=49152-49251/tcp &>/dev/null; then
    firewall-cmd --permanent --add-service=glusterfs
    firewall-cmd --permanent --add-port=49152-49251/tcp
    firewall-cmd --reload
fi

# 6. Glusterd & TLS
systemctl enable --now glusterd
touch /var/lib/glusterd/secure-access

if [[ ! -f /etc/ssl/glusterfs.key ]]; then
    openssl genrsa -out /etc/ssl/glusterfs.key 2048
    openssl req -new -x509 -key /etc/ssl/glusterfs.key -subj "/CN=$LOCAL_HOST" -days 3650 -out /etc/ssl/glusterfs.pem
    chmod 640 /etc/ssl/glusterfs.{key,pem}
    chown root:root /etc/ssl/glusterfs.{key,pem}
fi

echo "Local GlusterFS setup and installation is complete. Run the "Part 2" script on the first node."
