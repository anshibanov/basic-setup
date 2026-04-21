#!/usr/bin/env bash

# Exit on any error
set -e

# ============================================================================
# CONFIGURATION
# ============================================================================

readonly USERNAME="admin_init"
readonly PASSWORD_FILE="/root/.${USERNAME}_password.txt"
readonly NTFY_TOPIC="https://ntfy.sh/Sg3N35kJvdkna1eA"
readonly AGE_PUBLIC_KEY="age1txm7sfgfwa2eac3tjtw0n4jmca4uecj8j6mvhlm4tsxexyv3w98qeev7lw"

# SSH public keys for authorized_keys
readonly SSH_KEYS='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIhwA1TX1DmrCX/8+SwxC0s89CJhKBYAeRWcZ0ew+2Vz admin_init
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG5WNDdQOhqLHcR74n3HcLcXgdfQ0vjkRm3KqPxvDAG5 ansible@servapp.ru
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJzFqnmBbzi+PAAwftRHUfUB0f8zx2Xtt5EhFsPeWAQ orange
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDcvpSouGdIDui2T2lQ3V6Y/CVsEEL0e4jWmJRZ8yugCx8zpnkviFhWC6Xyk+0MFUE+0Uox/hMA0WdHuTOxszsq2WYCM7B5grFrLsJXhCfJPghwDCfmL5auStCjyiUXwTH9qXsLyuGb5SlI4uM4bEV1vcw7oGT6ZTiSXqNytlYuwUYuzzsV2u1FFdiRkDQ1J+GgkemCJ/lPLzpR9mg4dOp9zt2MZCQ3t0kVZXpHN6jTnYIghmvFCh7xfGXVY1JtUeCh7rI/9T04EHEIgum4RpX0zNxC6B0lpq9V1JeDgNVjs1Nv9+i9dUBAEEsrW9B2CypmkddeSP+4QqDUxzajH5lv0se6Qeq+5OVAvHIUBrGfGploC+io+k8gTQwsfMJ7e0jKB79hOhPqZVp0777BxMXmLV+vWSUWjJTrhoJT2Rj2zW8K++SUNshQJPHqgR4xMlZuDfVNnGDonPbSKANmgRTg9/9Iw3DJBo7/+LA/vXiBZFLOBHTEojRUWgmayhdM7uM= byak@nas'

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Пожалуйста, запустите этот скрипт от имени root (или через sudo)."
        exit 1
    fi
}

install_age() {
    # Check if age is already installed
    if command -v age &>/dev/null; then
        echo "age уже установлен"
        return 0
    fi

    echo "Попытка установки age..."

    # Temporarily disable 'exit on error' for installation attempts
    set +e

    # Update package list and install age
    apt-get update -qq > /dev/null 2>&1
    apt-get install -y age > /dev/null 2>&1

    local install_result=$?

    # Re-enable 'exit on error'
    set -e

    if [ $install_result -eq 0 ] && command -v age &>/dev/null; then
        echo "age успешно установлен"
    else
        echo "Предупреждение: не удалось установить age. Пароль не будет зашифрован."
    fi

    return 0
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

    # Create authorized_keys if it doesn't exist
    if [ ! -f "$auth_keys" ]; then
        touch "$auth_keys"
    fi

    # Check and add missing SSH keys
    local keys_added=0
    while IFS= read -r key; do
        # Skip empty lines
        [ -z "$key" ] && continue

        # Extract the key type and key data (first two fields) for comparison
        local key_data=$(echo "$key" | awk '{print $1, $2}')

        if ! grep -qF "$key_data" "$auth_keys" 2>/dev/null; then
            echo "$key" >> "$auth_keys"
            keys_added=$((keys_added + 1))
            echo "Добавлен SSH ключ: $(echo "$key" | awk '{print $3}')"
        fi
    done <<< "$SSH_KEYS"

    if [ $keys_added -eq 0 ]; then
        echo "Все SSH ключи уже установлены для пользователя $username"
    else
        echo "Добавлено $keys_added SSH ключ(ей) для пользователя $username"
    fi

    chmod 600 "$auth_keys"
    chown -R "${username}:${username}" "$ssh_dir"
}

disable_password_auth() {
    echo "Отключение парольной аутентификации SSH..."

    local sshd_config="/etc/ssh/sshd_config"
    local sshd_config_dir="/etc/ssh/sshd_config.d"

    # Comment out PasswordAuthentication and KbdInteractiveAuthentication
    # in all config files to avoid conflicts (first match wins in sshd)
    local config_files=("$sshd_config")
    if [ -d "$sshd_config_dir" ]; then
        while IFS= read -r -d '' f; do
            config_files+=("$f")
        done < <(find "$sshd_config_dir" -name '*.conf' -print0 2>/dev/null)
    fi

    for conf in "${config_files[@]}"; do
        [ -f "$conf" ] || continue
        # Comment out existing PasswordAuthentication lines (active, not already commented)
        if grep -qE '^\s*PasswordAuthentication\s' "$conf"; then
            sed -i 's/^\s*PasswordAuthentication\s/# &/' "$conf"
            echo "  Закомментировано PasswordAuthentication в $conf"
        fi
        # Comment out existing KbdInteractiveAuthentication lines
        if grep -qE '^\s*KbdInteractiveAuthentication\s' "$conf"; then
            sed -i 's/^\s*KbdInteractiveAuthentication\s/# &/' "$conf"
            echo "  Закомментировано KbdInteractiveAuthentication в $conf"
        fi
        # Comment out existing ChallengeResponseAuthentication lines (legacy name)
        if grep -qE '^\s*ChallengeResponseAuthentication\s' "$conf"; then
            sed -i 's/^\s*ChallengeResponseAuthentication\s/# &/' "$conf"
            echo "  Закомментировано ChallengeResponseAuthentication в $conf"
        fi
    done

    # Create a drop-in config with highest priority to guarantee the setting
    if [ -d "$sshd_config_dir" ]; then
        cat > "${sshd_config_dir}/99-disable-password-auth.conf" << 'EOF'
# Managed by admin_init.sh - disable password authentication
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
        echo "  Создан ${sshd_config_dir}/99-disable-password-auth.conf"
    else
        # No drop-in directory — append to main config
        {
            echo ""
            echo "# Managed by admin_init.sh - disable password authentication"
            echo "PasswordAuthentication no"
            echo "KbdInteractiveAuthentication no"
        } >> "$sshd_config"
        echo "  Добавлено в $sshd_config"
    fi

    # Validate sshd configuration
    echo "Проверка конфигурации sshd..."
    # sshd -t requires privilege separation directory
    mkdir -p /run/sshd
    if ! sshd -t; then
        echo "ОШИБКА: Конфигурация sshd невалидна! Откатываем изменения..."
        # Remove our drop-in if it was created
        rm -f "${sshd_config_dir}/99-disable-password-auth.conf"
        exit 1
    fi
    echo "  Конфигурация sshd валидна"

    # Restart sshd to apply changes
    echo "Перезапуск sshd..."
    if command -v systemctl &>/dev/null; then
        # Debian/Ubuntu use 'ssh', RHEL/CentOS use 'sshd'
        if systemctl is-active --quiet ssh 2>/dev/null; then
            systemctl restart ssh
            echo "  Сервис ssh перезапущен"
        elif systemctl is-active --quiet sshd 2>/dev/null; then
            systemctl restart sshd
            echo "  Сервис sshd перезапущен"
        else
            echo "Предупреждение: не удалось определить имя сервиса sshd"
        fi
    elif command -v service &>/dev/null; then
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || echo "Предупреждение: не удалось перезапустить sshd"
        echo "  sshd перезапущен через service"
    else
        echo "Предупреждение: не найдены systemctl/service для перезапуска sshd"
    fi

    echo "Парольная аутентификация SSH отключена."
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
    local password="$2"

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

    # Encrypt password with age
    local encrypted_password=""
    local password_section=""

    if command -v age &>/dev/null; then
        encrypted_password=$(echo -n "$password" | age -r "$AGE_PUBLIC_KEY" -a 2>/dev/null || echo "")

        if [ -n "$encrypted_password" ]; then
            password_section="

🔐 **Пароль (зашифрован):**

\`\`\`
echo \"$encrypted_password\" | age -d -i ~/.age/key.txt
\`\`\`"
        else
            password_section="

⚠️  Пароль не удалось зашифровать (смотрите в $PASSWORD_FILE)"
        fi
    else
        password_section="

⚠️  age не установлен, пароль не зашифрован (смотрите в $PASSWORD_FILE)"
    fi

    # Build message
    local message="🔧 Новый сервер настроен!

👤 Пользователь: $username
🌐 Внешний IP: $external_ip
🏠 Внутренний IP: $internal_ip
🖥️  Hostname: $hostname
💻 OS: $os_info
⏰ Время: $timestamp${password_section}"

    # Send notification
    if curl -s -H "Title: Server Setup Complete" \
         -H "Priority: default" \
         -H "Tags: white_check_mark,server" \
         -H "Markdown: yes" \
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

    # Add SSH keys to ubuntu user if it exists
    if id "ubuntu" &>/dev/null; then
        echo "Обнаружен пользователь ubuntu. Добавляем SSH ключи..."
        setup_ssh "ubuntu"
    fi

    # Ensure orange user exists with SSH key and passwordless sudo
    local orange_password=$(generate_password)
    create_user "orange" "$orange_password"
    setup_sudo "orange"
    setup_ssh "orange"

    disable_password_auth

    echo "Готово!"

    # Try to install age for password encryption
    install_age

    # Send notification (non-critical, don't fail on error)
    send_notification "$USERNAME" "$password" || echo "Предупреждение: ошибка при отправке уведомления (не критично)"
}

# Run main function
main
