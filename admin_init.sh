#!/usr/bin/env bash

# Exit on any error
set -e

# ============================================================================
# CONFIGURATION
# ============================================================================

readonly USERNAME="admin_init"
readonly PASSWORD_FILE="/root/.${USERNAME}_password.txt"
readonly NTFY_TOPIC="https://ntfy.sh/Sg3N35kJvdkna1eA"

# SSH public keys for authorized_keys
readonly SSH_KEYS='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIhwA1TX1DmrCX/8+SwxC0s89CJhKBYAeRWcZ0ew+2Vz admin_init
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG5WNDdQOhqLHcR74n3HcLcXgdfQ0vjkRm3KqPxvDAG5 ansible@servapp.ru
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJzFqnmBbzi+PAAwftRHUfUB0f8zx2Xtt5EhFsPeWAQ orange'

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Пожалуйста, запустите этот скрипт от имени root (или через sudo)."
        exit 1
    fi
}

generate_password() {
    openssl rand -base64 12
}

create_user() {
    local username="$1"
    local password="$2"

    if id "$username" &>/dev/null; then
        echo "Пользователь $username уже существует. Пропускаем создание..."
        return 0
    fi

    useradd -m -s /bin/bash -p "$(openssl passwd -1 "$password")" "$username"

    echo "========================="
    echo "Пользователь: $username"
    echo "Сгенерированный пароль: $password"
    echo "Пароль сохранён в $PASSWORD_FILE"
    echo "========================="
    echo "Пользователь $username успешно создан."

    echo "Пароль $username: $password" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
}

setup_sudo() {
    local username="$1"

    # Add user to sudo group
    usermod -aG sudo "$username"

    # Configure passwordless sudo
    cat << EOF > "/etc/sudoers.d/90-${username}"
${username} ALL=(ALL) NOPASSWD:ALL
EOF
    chmod 440 "/etc/sudoers.d/90-${username}"
}

setup_ssh() {
    local username="$1"
    local home_dir="/home/${username}"
    local ssh_dir="${home_dir}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    echo "$SSH_KEYS" > "$auth_keys"
    chmod 600 "$auth_keys"
    chown -R "${username}:${username}" "$ssh_dir"
}

setup_proxmox() {
    local username="$1"
    local pam_user="${username}@pam"

    # Check if running on Proxmox
    if [ ! -d "/etc/pve" ] || ! command -v pveum &>/dev/null; then
        return 0
    fi

    echo "========================="
    echo "Обнаружена система Proxmox VE"
    echo "Добавляем пользователя $username в Proxmox с правами Administrator..."

    # Check if user exists in Proxmox
    if pveum user list | grep -q "$pam_user"; then
        echo "Пользователь $pam_user уже существует в Proxmox."
    else
        pveum user add "$pam_user" -comment "System Administrator" || true
        echo "Пользователь $pam_user добавлен в Proxmox."
    fi

    # Assign Administrator role
    pveum acl modify / --roles Administrator --users "$pam_user"
    echo "Пользователю $pam_user назначена роль Administrator."
    echo "Теперь пользователь может логиниться в Proxmox GUI."
    echo "========================="
}

get_external_ip() {
    curl -s --max-time 10 ifconfig.io || echo "N/A"
}

get_internal_ip() {
    if command -v ip &>/dev/null; then
        ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1 || echo "N/A"
    else
        echo "N/A"
    fi
}

get_os_info() {
    grep PRETTY_NAME /etc/os-release | cut -d '"' -f2 || echo "Unknown OS"
}

send_notification() {
    local username="$1"

    echo "Отправка уведомления..."

    # Check for required commands
    if ! command -v curl &>/dev/null; then
        echo "Предупреждение: curl не установлен, уведомление не будет отправлено"
        return 0
    fi

    # Gather server information
    local external_ip=$(get_external_ip)
    local internal_ip=$(get_internal_ip)
    local hostname=$(hostname)
    local os_info=$(get_os_info)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')

    # Build message
    local message="🔧 Новый сервер настроен!

👤 Пользователь: $username
🌐 Внешний IP: $external_ip
🏠 Внутренний IP: $internal_ip
🖥️  Hostname: $hostname
💻 OS: $os_info
⏰ Время: $timestamp"

    # Send notification
    if curl -s -H "Title: Server Setup Complete" \
         -H "Priority: default" \
         -H "Tags: white_check_mark,server" \
         -d "$message" \
         "$NTFY_TOPIC" > /dev/null; then
        echo "Уведомление отправлено в ntfy.sh"
    else
        echo "Предупреждение: не удалось отправить уведомление"
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    check_root

    local password=$(generate_password)

    create_user "$USERNAME" "$password"
    setup_sudo "$USERNAME"
    setup_ssh "$USERNAME"
    setup_proxmox "$USERNAME"

    echo "Готово!"

    # Send notification (non-critical, don't fail on error)
    send_notification "$USERNAME" || echo "Предупреждение: ошибка при отправке уведомления (не критично)"
}

# Run main function
main
