#!/usr/bin/env bash

# CI test: runs admin_init.sh twice inside a container and asserts the results.
# Expects to be run as root with dependencies already installed
# (openssl, sudo, curl, iproute2, openssh-server).

set -euo pipefail

assert() {
    local description="$1"
    shift
    if "$@"; then
        echo "  OK: $description"
    else
        echo "  FAIL: $description" >&2
        exit 1
    fi
}

check_state() {
    local user keys pwfile

    assert "пользователь admin_init существует" id admin_init
    assert "пользователь orange существует" id orange
    assert "sudoers валиден" visudo -c

    for user in admin_init orange; do
        assert "sudoers.d для $user" grep -q "^${user} ALL=(ALL) NOPASSWD:ALL$" "/etc/sudoers.d/90-${user}"

        keys="/home/${user}/.ssh/authorized_keys"
        assert "authorized_keys для $user содержит 4 ключа" test "$(grep -c '^ssh-' "$keys")" -eq 4
        assert "права 600 на authorized_keys для $user" test "$(stat -c %a "$keys")" = "600"
        assert "владелец authorized_keys — $user" test "$(stat -c %U "$keys")" = "$user"

        pwfile="/root/.${user}_password.txt"
        assert "файл пароля $user существует" test -f "$pwfile"
        assert "права 600 на файл пароля $user" test "$(stat -c %a "$pwfile")" = "600"
    done

    mkdir -p /run/sshd
    assert "парольная аутентификация SSH отключена" \
        bash -c "sshd -T | grep -q '^passwordauthentication no$'"
    assert "keyboard-interactive аутентификация отключена" \
        bash -c "sshd -T | grep -q '^kbdinteractiveauthentication no$'"
}

echo "=== Первый запуск ==="
./admin_init.sh

echo "=== Проверки после первого запуска ==="
check_state

admin_pw_before=$(cat /root/.admin_init_password.txt)
orange_pw_before=$(cat /root/.orange_password.txt)

echo "=== Второй запуск (идемпотентность) ==="
./admin_init.sh

echo "=== Проверки после второго запуска ==="
check_state
assert "пароль admin_init не изменился" test "$(cat /root/.admin_init_password.txt)" = "$admin_pw_before"
assert "пароль orange не изменился" test "$(cat /root/.orange_password.txt)" = "$orange_pw_before"
assert "нет остаточных бэкапов sshd-конфига" \
    bash -c "! ls /etc/ssh/sshd_config.admin_init.bak /etc/ssh/sshd_config.d/*.admin_init.bak 2>/dev/null | grep -q ."

echo "=== Все проверки пройдены ==="
