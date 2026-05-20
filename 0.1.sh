#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# ЧАСТЬ 2: Настройка SSH → /etc/hosts → TLS → Peer → Volume → Mount
# Запускается ТОЛЬКО на первом (локальном) узле кластера
# ==========================================================

# --- 1. Проверка root ---
if [[ "$EUID" -ne 0 ]]; then
    echo "⚠️  Запустите скрипт от root: sudo $0"
    exit 1
fi

# --- 2. Конфигурация SSH (интерактивная) ---
echo "🔑 === НАСТРОЙКА SSH ДОСТУПА ==="
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

if [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
    echo "🔑 Генерация SSH ключа (RSA 4096)..."
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa" -q
    echo "✅ Ключ создан: $HOME/.ssh/id_rsa"
else
    echo "🔑 SSH ключ уже существует. Пропускаем генерацию."
fi

[[ ! -f "$HOME/.ssh/config" ]] && touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"

read -p "📊 Сколько УДАЛЁННЫХ узлов добавить? (Всего будет: N + 1 локальный): " node_count
[[ "$node_count" =~ ^[1-9][0-9]*$ ]] || { echo "❌ Введите число >= 1"; exit 1; }

for (( i=1; i<=node_count; i++ )); do
    echo "--- Узел $i ---"
    while true; do
        read -p "🌐 IPv4 адрес: " ip
        [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
        echo "❌ Неверный IPv4 формат."
    done
    while true; do
        read -p "👤 Имя пользователя: " user
        [[ "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] && break
        echo "❌ Имя должно начинаться с буквы и содержать только a-z, 0-9, _ или -"
    done
    while true; do
        read -p "🏷️ Короткий алиас (например, node$i): " alias
        [[ "$alias" =~ ^[a-zA-Z0-9-]+$ ]] && break
        echo "❌ Алиас: только буквы, цифры и '-'."
    done

    echo "📤 Копирование ключа на $user@$ip..."
    if ssh-copy-id -i "$HOME/.ssh/id_rsa.pub" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$user@$ip"; then
        echo "✅ Ключ успешно скопирован."
    else
        echo "❌ Ошибка копирования. Проверьте доступ и пароль."
        exit 1
    fi

    if ! grep -q "^Host $alias$" "$HOME/.ssh/config" 2>/dev/null; then
        cat >> "$HOME/.ssh/config" <<SSHCONF
Host $alias
    HostName $ip
    User $user
    Port 22
SSHCONF
        echo "📝 Алиас '$alias' добавлен в ~/.ssh/config"
    else
        echo "⚠️  Алиас '$alias' уже существует. Пропускаем."
    fi
    echo "----------------------------------------"
done

# --- 3. Парсинг ~/.ssh/config в массивы ---
echo "📥 Чтение настроенных узлов из ~/.ssh/config..."
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
    echo "❌ Узлы не найдены в ~/.ssh/config."
    exit 1
fi

LOCAL_IP=$(hostname -I | awk '{print $1}')
NODES=("$LOCAL_IP" "${IPS[@]}")
echo "🌐 Итоговый список узлов кластера: ${NODES[*]}"

# --- 4. Проверка SSH-связности ---
echo "🔍 Проверка SSH-доступа ко всем узлам..."
for i in "${!ALIASES[@]}"; do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${USERS[$i]}@${ALIASES[$i]}" true; then
        echo "❌ Нет доступа к ${ALIASES[$i]} (${USERS[$i]}@${IPS[$i]})"
        exit 1
    fi
done
echo "✅ SSH доступен на всех узлах."

# --- 5. Синхронизация /etc/hosts (НОВОЕ) ---
echo "🌐 Синхронизация /etc/hosts на всех узлах..."
declare -a NODE_IPS=("$LOCAL_IP" "${IPS[@]}")
declare -a NODE_NAMES=("$(hostname)")
for i in "${!ALIASES[@]}"; do
    NODE_NAMES+=("$(ssh "${USERS[$i]}@${ALIASES[$i]}" hostname 2>/dev/null || echo "node-${IPS[$i]}")")
done

# Формируем блок записей во временный файл
HOSTS_BLOCK=$(mktemp)
{
    echo "# GLUSTERFS_CLUSTER_START"
    for idx in "${!NODE_IPS[@]}"; do
        printf "%-16s %s\n" "${NODE_IPS[$idx]}" "${NODE_NAMES[$idx]}"
    done
    echo "# GLUSTERFS_CLUSTER_END"
} > "$HOSTS_BLOCK"

# Функция применения /etc/hosts
apply_hosts() {
    local user="$1" host="$2"
    ssh "${user:+$user@}$host" sudo bash <<EOF
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
echo "✅ /etc/hosts успешно синхронизирован."

# --- 6. Распространение TLS сертификатов ---
CA_DIR="/etc/ssl/glusterfs/ca"
echo "🔐 Сбор и распределение сертификатов TLS..."
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
echo "✅ TLS bundle успешно распределён."

# --- 7. Peer Probe & Ожидание связности ---
echo "🤝 Добавление узлов в кластер (peer probe)..."
for ip in "${IPS[@]}"; do gluster peer probe "$ip" 2>/dev/null || true; done

echo "⏳ Ожидание синхронизации состояния узлов..."
CONNECTED=0
for attempt in {1..15}; do
    CONNECTED=$(gluster peer status | grep -c "State: Peer in Cluster (Connected)" || true)
    if [[ "$CONNECTED" -eq "${#IPS[@]}" ]]; then break; fi
    sleep 2
done

if [[ "$CONNECTED" -ne "${#IPS[@]}" ]]; then
    echo "⚠️  Подключено узлов: $CONNECTED из ${#IPS[@]}. Проверьте: journalctl -u glusterd -f"
else
    echo "✅ Все узлы в состоянии Connected."
fi

# --- 8. Создание / Пересоздание тома ---
VOL_NAME="${VOL_NAME:-gv0}"
BRICK_PATH="${BRICK_PATH:-/data/gluster/brick}"

if gluster volume info "$VOL_NAME" &>/dev/null; then
    echo "🔄 Том '$VOL_NAME' уже существует. Удаляем метаданные (данные в brick сохранятся)..."
    gluster volume stop "$VOL_NAME" force || true
    gluster volume delete "$VOL_NAME"
fi

echo "📦 Создание директорий brick..."
for i in "${!ALIASES[@]}"; do
    ssh "${USERS[$i]}@${ALIASES[$i]}" "sudo mkdir -p $BRICK_PATH && sudo chown -R glusterfs:glusterfs $BRICK_PATH"
done
sudo mkdir -p "$BRICK_PATH" && sudo chown -R glusterfs:glusterfs "$BRICK_PATH"

# GlusterFS требует кратности replica. Безопасно берём кратное 3 или все если <=3
REPLICA_COUNT=3
if [[ ${#NODES[@]} -lt 3 ]]; then REPLICA_COUNT=${#NODES[@]}; fi
ACTIVE_NODES=("${NODES[@]:0:REPLICA_COUNT}")

BRICKS=()
for h in "${ACTIVE_NODES[@]}"; do BRICKS+=("$h:$BRICK_PATH"); done

echo "🏗 Создание тома $VOL_NAME (replica $REPLICA_COUNT)..."
gluster volume create "$VOL_NAME" replica $REPLICA_COUNT "${BRICKS[@]}" force
gluster volume set "$VOL_NAME" encryption on
gluster volume start "$VOL_NAME"
echo "✅ Том создан, запущен и шифрование включено."

# --- 9. Автоматическое монтирование на всех узлах ---
echo "📂 Монтирование тома на всех узлах..."
mount_on_node() {
    local user="$1" host="$2"
    ssh "${user:+$user@}$host" sudo bash <<MOUNT_EOF
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

# --- 10. Итоговая проверка ---
echo "🎉 === ГОТОВО ==="
echo "📊 Статус кластера:"
gluster peer status | grep -E "Hostname|State"
echo ""
echo "📊 Информация о томе:"
gluster volume info "$VOL_NAME" | grep -E "Volume Name|Status|Encryption|Type"
echo ""
echo "💾 Диск:"
df -h "/mnt/$VOL_NAME"
echo "📌 Том доступен по пути: /mnt/$VOL_NAME на всех узлах."