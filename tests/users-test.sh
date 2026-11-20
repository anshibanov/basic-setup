#!/usr/bin/env bash
# Account creation: an interrupted or failed run must stay repairable.
# Destructive: run only inside a disposable root container.
set -euo pipefail

if [ ! -f /.dockerenv ] || [ "$EUID" -ne 0 ]; then
    echo 'Run this test only inside a disposable root container.' >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
check() {
    local description="$1"
    shift
    if "$@"; then
        echo "  OK: $description"
    else
        echo "  FAIL: $description" >&2
        failures=$((failures + 1))
    fi
}

# A separate shell keeps errexit active inside create_user, as in a real run.
create_user_run() {
    bash -c 'source ./admin_init.sh; create_user "$1" "$2"' _ "$@" > "$work/create.log" 2>&1
}
create_user_fails() {
    ! create_user_run "$@"
}
shadow_hash() {
    getent shadow "$1" | cut -d: -f2
}
stored_password() {
    awk 'NR == 1 { print $NF }' "/root/.${1}_password.txt"
}
# True when the password opens the account (same check login performs).
password_works() {
    perl -e 'exit(crypt($ARGV[0], $ARGV[1]) eq $ARGV[1] ? 0 : 1)' "$2" "$(shadow_hash "$1")"
}

mkdir "$work/broken-chpasswd"
printf '#!/bin/sh\ncat > /dev/null\nexit 1\n' > "$work/broken-chpasswd/chpasswd"
chmod 755 "$work/broken-chpasswd/chpasswd"

echo "=== Обычное создание ==="
check "создание проходит" create_user_run users_ok 'first-Password1'
check "пароль из файла подходит к учётной записи" password_works users_ok "$(stored_password users_ok 2>/dev/null)"
check "файл пароля доступен только root" test "$(stat -c %a /root/.users_ok_password.txt 2>/dev/null)" = 600

echo "=== Сбой установки пароля, затем повторный запуск ==="
PATH="$work/broken-chpasswd:$PATH" check "сбой chpasswd останавливает создание" create_user_fails users_retry 'never-Applied1'
touch /root/.users_retry_password.sent
check "повторный запуск проходит" create_user_run users_retry 'second-Password2'
check "пароль установлен и совпадает с файлом" password_works users_retry "$(stored_password users_retry 2>/dev/null)"
check "в файле пароль повторного запуска" test "$(stored_password users_retry 2>/dev/null)" = 'second-Password2'
check "отметка о доставке старого пароля снята" test ! -e /root/.users_retry_password.sent

echo "=== Намеренно заблокированная учётная запись не трогается ==="
passwd -l users_retry > /dev/null
locked_hash=$(shadow_hash users_retry)
check "повторный запуск проходит" create_user_run users_retry 'third-Password3'
check "хеш не изменён" test "$(shadow_hash users_retry)" = "$locked_hash"
check "файл пароля не изменён" test "$(stored_password users_retry 2>/dev/null)" = 'second-Password2'

echo "=== Чужой пользователь без файла пароля не трогается ==="
useradd -m -s /bin/bash users_foreign
foreign_hash=$(shadow_hash users_foreign)
check "запуск проходит" create_user_run users_foreign 'fourth-Password4'
check "хеш не изменён" test "$(shadow_hash users_foreign)" = "$foreign_hash"
check "файл пароля не создан" test ! -e /root/.users_foreign_password.txt

if [ "$failures" -ne 0 ]; then
    echo "=== User tests: $failures failed ===" >&2
    exit 1
fi
echo '=== User tests passed ==='
