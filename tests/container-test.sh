#!/usr/bin/env bash

# CI test: runs admin_init.sh inside a fresh container and asserts the results.
# Expects to be run as root with openssl, curl, iproute2, openssh-server and age
# already installed. sudo must NOT be preinstalled: the script installs it.

set -euo pipefail

if [ ! -f /.dockerenv ] || [ "$EUID" -ne 0 ]; then
    echo 'Run this test only inside a disposable root container.' >&2
    exit 1
fi

# Tests must not send real notifications or disclose container metadata.
original_path=$PATH
test_bin=$(mktemp -d)
trap 'rm -rf "$test_bin"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$test_bin/curl"
chmod 755 "$test_bin/curl"
export PATH="$test_bin:$PATH"

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

    assert "sudo установлен" bash -c 'command -v sudo > /dev/null'
    assert "пользователь admin_init существует" id admin_init
    assert "пользователь orange существует" id orange
    assert "пользователь byak существует" id byak
    assert "sudoers валиден" visudo -c

    for user in admin_init orange byak; do
        assert "sudoers.d для $user" grep -q "^${user} ALL=(ALL) NOPASSWD:ALL$" "/etc/sudoers.d/90-${user}"

        keys="/home/${user}/.ssh/authorized_keys"
        assert "authorized_keys для $user содержит 4 ключа" test "$(grep -c '^ssh-' "$keys")" -eq 4
        assert "ключи $user лежат в управляемом блоке" grep -qxF '# BEGIN admin_init managed keys' "$keys"
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

if command -v sudo > /dev/null || [ -e /etc/sudoers.d ]; then
    echo 'FAIL: тест ожидает контейнер без sudo (скрипт должен установить его сам)' >&2
    exit 1
fi

echo "=== Без sudo и без возможности его установить ==="
mkdir "$test_bin/no-apt"
printf '#!/bin/sh\nexit 100\n' > "$test_bin/no-apt/apt-get"
chmod 755 "$test_bin/no-apt/apt-get"
if PATH="$test_bin/no-apt:$PATH" ./admin_init.sh > "$test_bin/no-sudo.log" 2>&1; then
    echo 'FAIL: скрипт завершился успешно без sudo' >&2
    exit 1
fi
assert "ошибка объясняет, что нужен sudo" grep -q 'не удалось установить sudo' "$test_bin/no-sudo.log"
assert "пользователи не созданы до установки sudo" bash -c '! id admin_init > /dev/null 2>&1'

echo "=== Первый запуск (dpkg занят другим процессом) ==="
# A freshly booted server usually has cloud-init or unattended-upgrades holding
# the dpkg lock: the script has to wait for it instead of giving up.
# Removing a locally built empty package keeps apt busy without any download
# (Docker images delete cached archives whenever another apt-get finishes).
mkdir -p "$test_bin/lock-test/DEBIAN"
printf '%s\n' 'Package: basic-setup-lock-test' 'Version: 1' 'Architecture: all' \
    'Maintainer: basic-setup tests' 'Description: holds the dpkg lock in tests' \
    > "$test_bin/lock-test/DEBIAN/control"
dpkg-deb --build "$test_bin/lock-test" "$test_bin/lock-test.deb" > /dev/null
dpkg -i "$test_bin/lock-test.deb" > /dev/null
apt-get -qq -o DPkg::Pre-Invoke::="touch $test_bin/lock-held; sleep 15" \
    remove -y basic-setup-lock-test > /dev/null 2>&1 &
lock_holder=$!
for ((attempt=0; attempt<300; attempt++)); do
    [ -e "$test_bin/lock-held" ] && break
    sleep 0.1
done
assert "блокировка dpkg удерживается другим процессом" test -e "$test_bin/lock-held"
./admin_init.sh
wait "$lock_holder"

echo "=== Проверки после первого запуска ==="
check_state

admin_pw_before=$(cat /root/.admin_init_password.txt)
orange_pw_before=$(cat /root/.orange_password.txt)
byak_pw_before=$(cat /root/.byak_password.txt)

echo "=== Второй запуск (идемпотентность) ==="
./admin_init.sh

echo "=== Проверки после второго запуска ==="
check_state
assert "пароль admin_init не изменился" test "$(cat /root/.admin_init_password.txt)" = "$admin_pw_before"
assert "пароль orange не изменился" test "$(cat /root/.orange_password.txt)" = "$orange_pw_before"
assert "пароль byak не изменился" test "$(cat /root/.byak_password.txt)" = "$byak_pw_before"
assert "нет остаточных бэкапов sshd-конфига" bash -c '! compgen -G "/etc/ssh/.admin-init.*"'

bash ./tests/users-test.sh
bash ./tests/ssh-keys-test.sh
# This one talks to its own local fake server through the real curl.
PATH="$original_path" bash ./tests/notification-test.sh
bash ./tests/ssh-config-test.sh
echo "=== Все проверки пройдены ==="
