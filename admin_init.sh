#!/usr/bin/env bash

# Exit on any error
set -e

# ============================================================================
# CONFIGURATION
# ============================================================================

readonly USERNAME="admin_init"
readonly NTFY_TOPIC="https://ntfy.sh/Sg3N35kJvdkna1eA"
readonly AGE_PUBLIC_KEY="age1d593fwksp2sfer6h9zz04p8vu05phtl4fuh47lpntutrvc44lukskcksth"

# Password files are stored as /root/.<username>_password.txt
password_file_for() {
    echo "/root/.${1}_password.txt"
}

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
    local password_file
    password_file=$(password_file_for "$username")

    if id "$username" &>/dev/null; then
        echo "Пользователь $username уже существует. Пропускаем создание..."
        return 0
    fi

    useradd -m -s /bin/bash "$username"
    echo "${username}:${password}" | chpasswd

    echo "========================="
    echo "Пользователь: $username"
    echo "Сгенерированный пароль: $password"
    echo "Пароль сохранён в $password_file"
    echo "========================="
    echo "Пользователь $username успешно создан."

    echo "Пароль $username: $password" > "$password_file"
    chmod 600 "$password_file"
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
    local home_dir
    home_dir=$(getent passwd "$username" | cut -d: -f6)
    if [ -z "$home_dir" ]; then
        echo "ОШИБКА: не найден домашний каталог пользователя $username"
        return 1
    fi
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
        local key_data
        key_data=$(echo "$key" | awk '{print $1, $2}')

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

restart_sshd() {
    # Containers may have systemctl installed without a running systemd.
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd 2>/dev/null
    elif command -v service &>/dev/null; then
        service ssh restart || service sshd restart
    else
        echo "ОШИБКА: не найден работающий способ перезапуска sshd" >&2
        return 1
    fi
}

disable_password_auth() (
    # Keep the rollback trap local to this operation. Explicit checks are needed
    # because Bash ignores errexit when a function is called in an if/|| context.
    echo "Отключение парольной аутентификации SSH..."
    local sshd_config="/etc/ssh/sshd_config"
    local sshd_config_dir="/etc/ssh/sshd_config.d"
    local config_files=("$sshd_config")
    local conf f backup_dir effective_config
    local backed_up=0 restart_attempted=0

    if [ -d "$sshd_config_dir" ]; then
        while IFS= read -r -d '' f; do
            config_files+=("$f")
        done < <(find "$sshd_config_dir" -name '*.conf' -print0)
    fi

    backup_dir=$(mktemp -d /etc/ssh/.admin-init.XXXXXX) || exit 1
    # Called indirectly by the EXIT trap.
    # shellcheck disable=SC2317
    rollback_on_exit() {
        local status=$? i restore_failed=0
        trap - EXIT
        if [ "$status" -ne 0 ]; then
            echo "ОШИБКА: настройка SSH не применена. Восстанавливаем исходную конфигурацию..." >&2
            for ((i=0; i<backed_up; i++)); do
                if ! cp -a "$backup_dir/$i" "${config_files[$i]}"; then
                    echo "ОШИБКА: не удалось восстановить ${config_files[$i]}" >&2
                    restore_failed=1
                fi
            done
            if [ "$restart_attempted" -eq 1 ]; then
                restart_sshd || echo "ОШИБКА: не удалось запустить sshd с исходной конфигурацией" >&2
            fi
        fi
        if [ "$restore_failed" -eq 0 ]; then
            rm -rf "$backup_dir"
        else
            echo "Резервные копии сохранены в $backup_dir для ручного восстановления" >&2
        fi
        exit "$status"
    }
    trap rollback_on_exit EXIT

    # Back up every affected file before any edits, including existing managed
    # drop-ins. Never remove a pre-existing file during rollback.
    for conf in "${config_files[@]}"; do
        cp -a "$conf" "$backup_dir/$backed_up" || exit 1
        backed_up=$((backed_up + 1))
    done

    # Replace our block on repeat runs rather than accumulating directives.
    sed -i '/^# BEGIN admin_init password authentication$/,/^# END admin_init password authentication$/d' "$sshd_config" || exit 1
    for conf in "${config_files[@]}"; do
        # sshd directive names are case-insensitive. Remove Match overrides too.
        sed -i -E 's/^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]=]/# &/I' "$conf" || exit 1
    done

    # Put global settings before Include and Match: a drop-in directory need
    # not be included at all, and appending can inherit a trailing Match block.
    sed -i '1i# BEGIN admin_init password authentication\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n# END admin_init password authentication' "$sshd_config" || exit 1

    mkdir -p /run/sshd || exit 1
    sshd -t || exit 1
    effective_config=$(sshd -T) || exit 1
    grep -qx 'passwordauthentication no' <<< "$effective_config" || exit 1
    grep -qx 'kbdinteractiveauthentication no' <<< "$effective_config" || exit 1

    echo "Перезапуск sshd..."
    restart_attempted=1
    restart_sshd || exit 1
    echo "Парольная аутентификация SSH отключена."
)

setup_proxmox() {
    local username="$1"
    local pam_user="${username}@pam"
    local user_list user_exists

    # Check if running on Proxmox
    if [ ! -d "/etc/pve" ] || ! command -v pveum &>/dev/null; then
        return 0
    fi

    echo "========================="
    echo "Обнаружена система Proxmox VE"
    echo "Добавляем пользователя $username в Proxmox с правами Administrator..."

    # Read machine output: another user's comment may contain our userid.
    if ! user_list=$(pveum user list --output-format json); then
        echo "ОШИБКА: не удалось получить список пользователей Proxmox." >&2
        return 1
    fi
    if ! user_exists=$(perl -MJSON::PP -e '
        my $users = decode_json(do { local $/; <STDIN> });
        die "Invalid Proxmox user list\n" if ref($users) ne "ARRAY";
        print (scalar(grep {
            ref($_) eq "HASH" && defined($_->{userid}) && $_->{userid} eq $ARGV[0]
        } @$users) ? "yes" : "no");
    ' "$pam_user" <<< "$user_list"); then
        echo "ОШИБКА: не удалось разобрать список пользователей Proxmox." >&2
        return 1
    fi
    if [ "$user_exists" = yes ]; then
        echo "Пользователь $pam_user уже существует в Proxmox."
    else
        if ! pveum user add "$pam_user" -comment "System Administrator"; then
            echo "ОШИБКА: не удалось добавить пользователя $pam_user в Proxmox." >&2
            return 1
        fi
        echo "Пользователь $pam_user добавлен в Proxmox."
    fi

    # Assign Administrator role
    if ! pveum acl modify / --roles Administrator --users "$pam_user"; then
        echo "ОШИБКА: не удалось назначить роль Administrator пользователю $pam_user." >&2
        return 1
    fi
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
    local password="$2"  # empty = user already existed, password unchanged
    local password_file
    password_file=$(password_file_for "$username")

    echo "Отправка уведомления..."

    # Check for required commands
    if ! command -v curl &>/dev/null; then
        echo "Предупреждение: curl не установлен, уведомление не будет отправлено"
        return 0
    fi

    # Gather server information
    local external_ip internal_ip hostname os_info timestamp
    external_ip=$(get_external_ip)
    internal_ip=$(get_internal_ip)
    hostname=$(hostname)
    os_info=$(get_os_info)
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')

    # Encrypt password with age
    local encrypted_password=""
    local password_section=""

    if [ -z "$password" ]; then
        password_section="

ℹ️  Пользователь $username уже существовал, пароль не менялся."
    elif command -v age &>/dev/null; then
        encrypted_password=$(echo -n "$password" | age -r "$AGE_PUBLIC_KEY" -a 2>/dev/null || echo "")

        if [ -n "$encrypted_password" ]; then
            password_section="

🔐 **Пароль (зашифрован):**

\`\`\`
echo \"$encrypted_password\" | age -d -i ~/.age/key.txt
\`\`\`"
        else
            password_section="

⚠️  Пароль не удалось зашифровать (смотрите в $password_file)"
        fi
    else
        password_section="

⚠️  age не установлен, пароль не зашифрован (смотрите в $password_file)"
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
    if curl -s --max-time 10 -H "Title: Server Setup Complete" \
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

    # Remember whether the admin user already existed: in that case the freshly
    # generated password is never applied and must not be sent in the notification
    local admin_existed=0
    if id "$USERNAME" &>/dev/null; then
        admin_existed=1
    fi

    # Assign separately from 'local' so 'set -e' catches generation failures
    local password
    password=$(generate_password)

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
    local orange_password
    orange_password=$(generate_password)
    create_user "orange" "$orange_password"
    setup_sudo "orange"
    setup_ssh "orange"

    disable_password_auth

    echo "Готово!"

    # Try to install age for password encryption
    install_age

    # Send notification (non-critical, don't fail on error)
    if [ "$admin_existed" -eq 1 ]; then
        send_notification "$USERNAME" "" || echo "Предупреждение: ошибка при отправке уведомления (не критично)"
    else
        send_notification "$USERNAME" "$password" || echo "Предупреждение: ошибка при отправке уведомления (не критично)"
    fi
}

# Run when executed (including curl | bash), but allow tests to source helpers.
if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then
    main
fi
