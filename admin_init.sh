#!/usr/bin/env bash

# Exit on any error
set -e

# ============================================================================
# CONFIGURATION
# ============================================================================

readonly USERNAME="admin_init"
readonly NTFY_TOPIC="https://ntfy.sh/Sg3N35kJvdkna1eA"
readonly IP_LOOKUP_URL="https://ifconfig.io"
readonly AGE_PUBLIC_KEY="age1d593fwksp2sfer6h9zz04p8vu05phtl4fuh47lpntutrvc44lukskcksth"

# Password files are stored as /root/.<username>_password.txt
password_file_for() {
    echo "/root/.${1}_password.txt"
}

# Created once ntfy has accepted the encrypted password of <username>
password_sent_marker_for() {
    echo "/root/.${1}_password.sent"
}

# SSH public keys for authorized_keys. They live in a managed block that is
# rebuilt on every run, so a key removed from this list leaves that block.
readonly SSH_KEYS='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIhwA1TX1DmrCX/8+SwxC0s89CJhKBYAeRWcZ0ew+2Vz admin_init
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG5WNDdQOhqLHcR74n3HcLcXgdfQ0vjkRm3KqPxvDAG5 ansible@servapp.ru
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJzFqnmBbzi+PAAwftRHUfUB0f8zx2Xtt5EhFsPeWAQ orange
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDcvpSouGdIDui2T2lQ3V6Y/CVsEEL0e4jWmJRZ8yugCx8zpnkviFhWC6Xyk+0MFUE+0Uox/hMA0WdHuTOxszsq2WYCM7B5grFrLsJXhCfJPghwDCfmL5auStCjyiUXwTH9qXsLyuGb5SlI4uM4bEV1vcw7oGT6ZTiSXqNytlYuwUYuzzsV2u1FFdiRkDQ1J+GgkemCJ/lPLzpR9mg4dOp9zt2MZCQ3t0kVZXpHN6jTnYIghmvFCh7xfGXVY1JtUeCh7rI/9T04EHEIgum4RpX0zNxC6B0lpq9V1JeDgNVjs1Nv9+i9dUBAEEsrW9B2CypmkddeSP+4QqDUxzajH5lv0se6Qeq+5OVAvHIUBrGfGploC+io+k8gTQwsfMJ7e0jKB79hOhPqZVp0777BxMXmLV+vWSUWjJTrhoJT2Rj2zW8K++SUNshQJPHqgR4xMlZuDfVNnGDonPbSKANmgRTg9/9Iw3DJBo7/+LA/vXiBZFLOBHTEojRUWgmayhdM7uM= byak@nas'

# Keys that must stop working, in the same format as SSH_KEYS. They are removed
# from the whole authorized_keys file of every managed user, including lines
# written by earlier versions of this script or added by hand. To revoke a key,
# move its line from SSH_KEYS here. A key listed in both is treated as revoked.
readonly REVOKED_SSH_KEYS=''

readonly SSH_KEYS_BEGIN="# BEGIN admin_init managed keys"
readonly SSH_KEYS_END="# END admin_init managed keys"
readonly SSHD_BLOCK_BEGIN="# BEGIN admin_init password authentication"
readonly SSHD_BLOCK_END="# END admin_init password authentication"

# Read by on_exit to report a run that did not finish.
CURRENT_STEP="запуск"
SETUP_COMPLETED=0

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Пожалуйста, запустите этот скрипт от имени root (или через sudo)."
        exit 1
    fi
}

# Install a package with apt. Waits for a busy dpkg lock: on a freshly booted
# server cloud-init or unattended-upgrades usually holds it for a while.
apt_install() {
    local package="$1" output

    if ! command -v apt-get &>/dev/null; then
        echo "apt-get не найден, пакет $package не установлен" >&2
        return 1
    fi

    # One broken repository (for example Proxmox enterprise without a
    # subscription) fails the update while the package is still installable.
    DEBIAN_FRONTEND=noninteractive apt-get update -qq < /dev/null > /dev/null 2>&1 || true
    if ! output=$(DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 \
        install -y "$package" < /dev/null 2>&1); then
        printf '%s\n' "$output" >&2
        return 1
    fi
}

# Proxmox VE and minimal Debian images come without sudo.
ensure_sudo() {
    if command -v sudo &>/dev/null && [ -d /etc/sudoers.d ]; then
        return 0
    fi

    echo "sudo не установлен. Устанавливаем..."
    if ! apt_install sudo || ! command -v sudo &>/dev/null || [ ! -d /etc/sudoers.d ]; then
        echo "ОШИБКА: не удалось установить sudo. Установите его вручную и запустите скрипт снова." >&2
        return 1
    fi
    echo "sudo успешно установлен"
}

install_age() {
    # Check if age is already installed
    if command -v age &>/dev/null; then
        echo "age уже установлен"
        return 0
    fi

    echo "Попытка установки age..."
    if apt_install age && command -v age &>/dev/null; then
        echo "age успешно установлен"
    else
        echo "Предупреждение: не удалось установить age. Пароль не будет зашифрован."
    fi

    return 0
}

generate_password() {
    openssl rand -base64 12
}

# True when the account has no password hash at all, as right after useradd.
# An account locked on purpose (passwd -l) keeps its hash and does not match.
account_without_password() {
    local hash
    hash=$(getent shadow "$1" | cut -d: -f2)
    [[ $hash =~ ^[!*]*$ ]]
}

save_password() {
    local username="$1" password="$2" password_file
    password_file=$(password_file_for "$username")

    (umask 077 && echo "Пароль $username: $password" > "$password_file")
    chmod 600 "$password_file"
    # A new password has not been delivered yet.
    rm -f "$(password_sent_marker_for "$username")"
}

create_user() {
    local username="$1"
    local password="$2"
    local password_file
    password_file=$(password_file_for "$username")

    # The password is saved before the account gets it. If a run stops in
    # between, the account has no password while its file exists, and the next
    # run repairs it instead of skipping the user for good.
    if ! id "$username" &>/dev/null; then
        save_password "$username" "$password"
        useradd -m -s /bin/bash "$username"
    elif [ -f "$password_file" ] && account_without_password "$username"; then
        echo "Пользователь $username остался без пароля после прерванного запуска. Устанавливаем пароль..."
        save_password "$username" "$password"
    else
        echo "Пользователь $username уже существует. Пропускаем создание..."
        return 0
    fi

    echo "${username}:${password}" | chpasswd

    echo "========================="
    echo "Пользователь: $username"
    echo "Сгенерированный пароль: $password"
    echo "Пароль сохранён в $password_file"
    echo "========================="
    echo "Пользователь $username успешно создан."
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

# sync_authorized_keys FILE MANAGED_KEYS REVOKED_KEYS
# Rewrites FILE so that the managed block holds exactly MANAGED_KEYS and no
# revoked key is left anywhere in it. Other lines outside the block are kept.
# Prints one line per added or removed key, nothing when FILE is up to date.
sync_authorized_keys() {
    local auth_keys="$1" managed_keys="$2" revoked_keys="$3"
    local tmp status=0

    if [ ! -f "$auth_keys" ]; then
        : > "$auth_keys"
    fi
    tmp=$(mktemp "${auth_keys}.XXXXXX")

    MANAGED_KEYS="$managed_keys" REVOKED_KEYS="$revoked_keys" \
        awk -v begin="$SSH_KEYS_BEGIN" -v end="$SSH_KEYS_END" -v out="$tmp" '
        # The key itself is the field after the key type; options may precede it.
        function key_blob(line,    fields, count, i) {
            count = split(line, fields, " ")
            for (i = 1; i < count; i++)
                if (fields[i] ~ /^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp[0-9]+)@openssh\.com)$/)
                    return fields[i + 1]
            return ""
        }
        function key_name(line,    fields, count) {
            count = split(line, fields, " ")
            return count >= 3 ? fields[count] : "(без комментария)"
        }
        BEGIN {
            managed_count = split(ENVIRON["MANAGED_KEYS"], managed_lines, "\n")
            for (i = 1; i <= managed_count; i++)
                if ((blob = key_blob(managed_lines[i])) != "")
                    managed[blob] = 1
            revoked_count = split(ENVIRON["REVOKED_KEYS"], revoked_lines, "\n")
            for (i = 1; i <= revoked_count; i++)
                if ((blob = key_blob(revoked_lines[i])) != "")
                    revoked[blob] = 1
        }
        # An unpaired marker means the block was edited by hand: stop rather
        # than guess which lines are ours.
        $0 == begin { if (in_block) { damaged = 1; exit } in_block = 1; next }
        $0 == end   { if (!in_block) { damaged = 1; exit } in_block = 0; next }
        {
            blob = ($0 ~ /^[ \t]*#/) ? "" : key_blob($0)
            if (blob != "") {
                if (blob in revoked) {
                    print "Отозван SSH ключ: " key_name($0)
                    next
                }
                present[blob] = 1
            }
            if (in_block) {
                if (blob != "" && !(blob in managed))
                    print "Удалён SSH ключ, которого больше нет в SSH_KEYS: " key_name($0)
                next
            }
            # Managed keys found outside the block move into it.
            if (blob != "" && (blob in managed))
                next
            print > out
        }
        END {
            if (damaged || in_block)
                exit 2
            print begin > out
            for (i = 1; i <= managed_count; i++) {
                blob = key_blob(managed_lines[i])
                if (blob == "" || (blob in revoked))
                    continue
                if (!(blob in present))
                    print "Добавлен SSH ключ: " key_name(managed_lines[i])
                print managed_lines[i] > out
            }
            print end > out
        }
    ' "$auth_keys" || status=$?

    if [ "$status" -ne 0 ]; then
        rm -f "$tmp"
        if [ "$status" -eq 2 ]; then
            echo "ОШИБКА: в $auth_keys повреждён управляемый блок ключей: метки '$SSH_KEYS_BEGIN' и '$SSH_KEYS_END' должны идти парами. Исправьте файл вручную." >&2
        else
            echo "ОШИБКА: не удалось обработать $auth_keys" >&2
        fi
        return 1
    fi

    if cmp -s "$tmp" "$auth_keys"; then
        rm -f "$tmp"
        return 0
    fi

    # Replace atomically, keeping the owner and mode of the original file.
    chown --reference="$auth_keys" "$tmp"
    chmod --reference="$auth_keys" "$tmp"
    mv -f "$tmp" "$auth_keys"
}

setup_ssh() {
    local username="$1"
    local home_dir group changes
    home_dir=$(getent passwd "$username" | cut -d: -f6)
    if [ -z "$home_dir" ]; then
        echo "ОШИБКА: не найден домашний каталог пользователя $username"
        return 1
    fi
    local ssh_dir="${home_dir}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    changes=$(sync_authorized_keys "$auth_keys" "$SSH_KEYS" "$REVOKED_SSH_KEYS")
    if [ -n "$changes" ]; then
        printf '%s\n' "$changes"
        echo "SSH ключи пользователя $username обновлены"
    else
        echo "Все SSH ключи уже установлены для пользователя $username"
    fi

    chmod 600 "$auth_keys"
    # The login group is not always named after the user. Ask for it: the
    # "user:" shorthand is not honoured by every chown (uutils on Ubuntu 26.04).
    group=$(id -gn "$username")
    chown -R "${username}:${group}" "$ssh_dir"
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
    local sshd_config sshd_config_dir="/etc/ssh/sshd_config.d"
    local config_files=()
    local conf f backup_dir block effective_config setting keys_files
    local backed_up=0 restart_attempted=0 completed=0

    # Edit the files the paths point to: sed -i would replace a symlink with a
    # regular file and leave its target untouched.
    sshd_config=$(readlink -f /etc/ssh/sshd_config) || sshd_config=""
    if [ ! -f "$sshd_config" ]; then
        echo "ОШИБКА: не найден /etc/ssh/sshd_config" >&2
        exit 1
    fi
    config_files=("$sshd_config")

    if [ -d "$sshd_config_dir" ]; then
        while IFS= read -r -d '' f; do
            # Directories and dangling links may match the pattern too.
            if f=$(readlink -f "$f") && [ -f "$f" ]; then
                config_files+=("$f")
            fi
        done < <(find "$sshd_config_dir" -maxdepth 1 -name '*.conf' -print0)
    fi

    # Our block is removed below with a sed range. Without its END marker the
    # range would run to the end of the file and delete unrelated settings.
    if ! awk -v begin="$SSHD_BLOCK_BEGIN" -v end="$SSHD_BLOCK_END" '
        $0 == begin { if (in_block) damaged = 1; in_block = 1 }
        $0 == end   { if (!in_block) damaged = 1; in_block = 0 }
        END { exit (damaged || in_block) }
    ' "$sshd_config"; then
        echo "ОШИБКА: в $sshd_config повреждён блок admin_init: метки '$SSHD_BLOCK_BEGIN' и '$SSHD_BLOCK_END' должны идти парами. Исправьте файл вручную." >&2
        exit 1
    fi

    mkdir -p /run/sshd || exit 1

    block="${SSHD_BLOCK_BEGIN}\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n"
    # OpenSSH before 8.7 has a separate ChallengeResponseAuthentication option:
    # it defaults to yes and turns keyboard-interactive back on. Only those
    # versions list it in the effective configuration.
    effective_config=$(sshd -T 2>/dev/null) || effective_config=""
    if grep -q '^challengeresponseauthentication ' <<< "$effective_config"; then
        block+="ChallengeResponseAuthentication no\n"
    fi
    block+="$SSHD_BLOCK_END"

    backup_dir=$(mktemp -d /etc/ssh/.admin-init.XXXXXX) || exit 1
    # Called indirectly by the EXIT trap.
    # shellcheck disable=SC2317,SC2329
    rollback_on_exit() {
        local status=$? i restore_failed=0
        trap - EXIT HUP INT TERM
        if [ "$completed" -ne 1 ]; then
            # An exit caused by a signal can arrive here with status 0.
            if [ "$status" -eq 0 ]; then
                status=1
            fi
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
    # Turn fatal signals into an ordinary exit, so that an interrupted run is
    # rolled back like any other failure.
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Back up every affected file before any edits, including existing managed
    # drop-ins. Never remove a pre-existing file during rollback.
    for conf in "${config_files[@]}"; do
        cp -a "$conf" "$backup_dir/$backed_up" || exit 1
        backed_up=$((backed_up + 1))
    done

    # Replace our block on repeat runs rather than accumulating directives.
    sed -i "/^${SSHD_BLOCK_BEGIN}\$/,/^${SSHD_BLOCK_END}\$/d" "$sshd_config" || exit 1
    for conf in "${config_files[@]}"; do
        # sshd directive names are case-insensitive. Remove Match overrides too.
        sed -i -E 's/^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]=]/# &/I' "$conf" || exit 1
    done

    # Put global settings before Include and Match: a drop-in directory need
    # not be included at all, and appending can inherit a trailing Match block.
    sed -i "1i${block}" "$sshd_config" || exit 1

    if ! sshd -t; then
        echo "ОШИБКА: проверка sshd -t отклонила изменённую конфигурацию." >&2
        exit 1
    fi
    if ! effective_config=$(sshd -T); then
        echo "ОШИБКА: sshd -T не смог показать итоговую конфигурацию." >&2
        exit 1
    fi
    for setting in 'passwordauthentication no' 'kbdinteractiveauthentication no'; do
        if ! grep -qx "$setting" <<< "$effective_config"; then
            echo "ОШИБКА: sshd должен сообщать '$setting', но в итоговой конфигурации: $(grep "^${setting%% *} " <<< "$effective_config" || echo "нет значения ${setting%% *}")" >&2
            exit 1
        fi
    done

    # Never remove the last working login method: the keys installed above are
    # only useful if sshd accepts public keys and reads ~/.ssh/authorized_keys.
    if ! grep -qx 'pubkeyauthentication yes' <<< "$effective_config"; then
        echo "ОШИБКА: вход по ключам отключён (PubkeyAuthentication no). Парольная аутентификация оставлена, иначе сервер остался бы без SSH-доступа." >&2
        exit 1
    fi
    keys_files=$(sed -n 's/^authorizedkeysfile //p' <<< "$effective_config")
    case " $keys_files " in
        *" .ssh/authorized_keys "* | *" %h/.ssh/authorized_keys "*) ;;
        *)
            echo "ОШИБКА: sshd читает ключи не из ~/.ssh/authorized_keys (AuthorizedKeysFile $keys_files). Парольная аутентификация оставлена: установленные ключи не дали бы войти." >&2
            exit 1
            ;;
    esac

    echo "Перезапуск sshd..."
    restart_attempted=1
    restart_sshd || exit 1
    completed=1
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
    local ip_addr
    # --fail: an HTTP error page must not end up in the notification.
    ip_addr=$(curl -fsS --max-time 10 "$IP_LOOKUP_URL" 2>/dev/null) || ip_addr=""
    echo "${ip_addr:-N/A}"
}

get_internal_ip() {
    local ip_addr=""
    if command -v ip &>/dev/null; then
        # The pipeline status is that of head, so test the output instead.
        ip_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1) || ip_addr=""
    fi
    echo "${ip_addr:-N/A}"
}

get_os_info() {
    local os_name
    os_name=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '"' -f2) || os_name=""
    echo "${os_name:-Unknown OS}"
}

# Server details shared by the success and failure notifications.
server_info() {
    echo "🌐 Внешний IP: $(get_external_ip)"
    echo "🏠 Внутренний IP: $(get_internal_ip)"
    echo "🖥️  Hostname: $(hostname)"
    echo "💻 OS: $(get_os_info)"
    echo "⏰ Время: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# ntfy_publish TITLE PRIORITY TAGS MESSAGE
ntfy_publish() {
    # --fail: a rejected request (rate limit, server error) is not a delivery.
    curl -fsS --max-time 10 -H "Title: $1" \
         -H "Priority: $2" \
         -H "Tags: $3" \
         -H "Markdown: yes" \
         -d "$4" \
         "$NTFY_TOPIC" > /dev/null
}

send_notification() {
    local username="$1"
    local password_file sent_marker
    password_file=$(password_file_for "$username")
    sent_marker=$(password_sent_marker_for "$username")

    echo "Отправка уведомления..."

    # Check for required commands
    if ! command -v curl &>/dev/null; then
        echo "Предупреждение: curl не установлен, уведомление не будет отправлено"
        return 0
    fi

    # The password is sent until ntfy has accepted its ciphertext once: a run
    # that failed before this point must not lose it.
    local password=""
    if [ -f "$password_file" ] && [ ! -f "$sent_marker" ]; then
        password=$(awk 'NR == 1 { print $NF }' "$password_file")
    fi

    # Encrypt password with age
    local encrypted_password=""
    local password_section=""
    local delivers_password=0

    if [ -z "$password" ]; then
        password_section="ℹ️  Пользователь $username уже существовал, пароль не менялся."
    elif command -v age &>/dev/null; then
        encrypted_password=$(echo -n "$password" | age -r "$AGE_PUBLIC_KEY" -a 2>/dev/null || echo "")

        if [ -n "$encrypted_password" ]; then
            delivers_password=1
            # Ciphertext only, never a ready-made command: the topic is public,
            # and anything pasted from it into a terminal could be forged.
            password_section="🔐 **Пароль (зашифрован Age, расшифровка описана в DECRYPT.md):**

\`\`\`
$encrypted_password
\`\`\`"
        else
            password_section="⚠️  Пароль не удалось зашифровать (смотрите в $password_file)"
        fi
    else
        password_section="⚠️  age не установлен, пароль не зашифрован (смотрите в $password_file)"
    fi

    # Build message
    local message
    message="🔧 Новый сервер настроен!

👤 Пользователь: $username
$(server_info)

$password_section"

    # Send notification
    if ntfy_publish "Server Setup Complete" default "white_check_mark,server" "$message"; then
        echo "Уведомление отправлено в ntfy.sh"
        if [ "$delivers_password" -eq 1 ]; then
            touch "$sent_marker"
        fi
    else
        echo "Предупреждение: не удалось отправить уведомление"
    fi
}

send_failure_notification() {
    local status="$1" step="$2"
    local password_file sent_marker password_note=""
    password_file=$(password_file_for "$USERNAME")
    sent_marker=$(password_sent_marker_for "$USERNAME")

    if ! command -v curl &>/dev/null; then
        return 0
    fi

    if [ -f "$password_file" ] && [ ! -f "$sent_marker" ] && id "$USERNAME" &>/dev/null; then
        password_note="

ℹ️  Пароль $USERNAME ещё не доставлен: он сохранён на сервере в $password_file и будет отправлен при следующем успешном запуске."
    fi

    local message
    message="❌ Настройка сервера не завершена!

🧩 Шаг: $step
🔢 Код выхода: $status
$(server_info)${password_note}"

    if ntfy_publish "Server Setup FAILED" high "rotating_light,server" "$message"; then
        echo "Уведомление о сбое отправлено в ntfy.sh" >&2
    else
        echo "Предупреждение: не удалось отправить уведомление о сбое" >&2
    fi
}

# EXIT trap of main: reports a run that did not finish.
# shellcheck disable=SC2317,SC2329
on_exit() {
    local status=$?
    trap - EXIT HUP INT TERM
    # Reporting is best effort: nothing in here may abort the handler.
    set +e
    if [ "$SETUP_COMPLETED" -ne 1 ]; then
        # An exit caused by a signal can arrive here with status 0.
        if [ "$status" -eq 0 ]; then
            status=1
        fi
        echo "ОШИБКА: настройка не завершена (шаг: $CURRENT_STEP, код выхода: $status)." >&2
        send_failure_notification "$status" "$CURRENT_STEP"
    fi
    exit "$status"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Create the account if it is missing, then give it passwordless sudo and the
# SSH keys.
provision_user() {
    local username="$1"
    # Assign separately from 'local' so 'set -e' catches generation failures
    local password
    password=$(generate_password)

    CURRENT_STEP="создание пользователя $username"
    create_user "$username" "$password"
    CURRENT_STEP="настройка sudo для $username"
    setup_sudo "$username"
    CURRENT_STEP="SSH-ключи пользователя $username"
    setup_ssh "$username"
}

main() {
    check_root

    trap on_exit EXIT
    # Turn fatal signals into an ordinary exit, so that on_exit reports them.
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Before any account exists: without sudo the run cannot be completed.
    CURRENT_STEP="проверка sudo"
    ensure_sudo

    provision_user "$USERNAME"
    CURRENT_STEP="настройка Proxmox VE"
    setup_proxmox "$USERNAME"

    # Add SSH keys to ubuntu user if it exists
    if id "ubuntu" &>/dev/null; then
        echo "Обнаружен пользователь ubuntu. Добавляем SSH ключи..."
        CURRENT_STEP="SSH-ключи пользователя ubuntu"
        setup_ssh "ubuntu"
    fi

    # Ensure orange and byak users exist with SSH keys and passwordless sudo
    provision_user "orange"
    provision_user "byak"

    CURRENT_STEP="отключение парольной аутентификации SSH"
    disable_password_auth

    SETUP_COMPLETED=1
    echo "Готово!"

    # Try to install age for password encryption
    install_age

    # Send notification (non-critical, don't fail on error)
    send_notification "$USERNAME" || echo "Предупреждение: ошибка при отправке уведомления (не критично)"
}

# Run when executed (including curl | bash), but allow tests to source helpers.
if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then
    main
fi
