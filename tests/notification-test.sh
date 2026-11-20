#!/usr/bin/env bash
# Notification tests: real curl requests against a local fake ntfy/IP-lookup
# server, with a throwaway Age key so the delivered ciphertext can be opened.
# Destructive: run only inside a disposable root container with age installed.
set -euo pipefail

if [ ! -f /.dockerenv ] || [ "$EUID" -ne 0 ]; then
    echo 'Run this test only inside a disposable root container.' >&2
    exit 1
fi

work=$(mktemp -d)
server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
    fi
    if [ -e "$work/os-release" ]; then
        mv "$work/os-release" /etc/os-release
    fi
    rm -rf "$work"
}
trap cleanup EXIT

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

mkdir "$work/http"
perl tests/fake-http-server.pl "$work/http" &
server_pid=$!
for ((attempt=0; attempt<50; attempt++)); do
    [ -s "$work/http/port" ] && break
    sleep 0.1
done
base="http://127.0.0.1:$(cat "$work/http/port")"
requests="$work/http/requests.log"

age-keygen -o "$work/age.key" 2>/dev/null
recipient=$(age-keygen -y "$work/age.key")

# The script under test, pointed at the fake endpoints and the throwaway key.
script="$work/admin_init.sh"
sed -E \
    -e "s|^readonly NTFY_TOPIC=.*|readonly NTFY_TOPIC=\"$base/topic\"|" \
    -e "s|^readonly IP_LOOKUP_URL=.*|readonly IP_LOOKUP_URL=\"$base/ip\"|" \
    -e "s|^readonly AGE_PUBLIC_KEY=.*|readonly AGE_PUBLIC_KEY=\"$recipient\"|" \
    admin_init.sh > "$script"
# Refuse to run a copy that could still reach a real service.
if grep -qE 'ntfy\.sh/|ifconfig\.io' "$script" \
    || ! grep -qxF "readonly NTFY_TOPIC=\"$base/topic\"" "$script" \
    || ! grep -qxF "readonly IP_LOOKUP_URL=\"$base/ip\"" "$script" \
    || ! grep -qxF "readonly AGE_PUBLIC_KEY=\"$recipient\"" "$script"; then
    echo 'FAIL: не удалось перенаправить скрипт на тестовый сервер' >&2
    exit 1
fi

password_file=/root/.admin_init_password.txt
sent_marker=/root/.admin_init_password.sent
status=0

# run [VAR=value...]: runs the script, keeps its output and exit status.
run() {
    : > "$requests"
    status=0
    env "$@" bash "$script" > "$work/output.log" 2>&1 || status=$?
}
fresh_admin() {
    userdel -r admin_init > /dev/null 2>&1 || true
    rm -f "$password_file" "$sent_marker"
}
stub() {
    mkdir -p "$work/stubs/$1"
    printf '#!/bin/sh\n%s\n' "$3" > "$work/stubs/$1/$2"
    chmod 755 "$work/stubs/$1/$2"
}
status_is() {
    [ "$status" -eq "$1" ]
}
sent() {
    grep -q -- "$1" "$requests"
}
not_sent() {
    ! grep -q -- "$1" "$requests"
}
posts_are() {
    [ "$(grep -c '^POST /topic ' "$requests")" -eq "$1" ]
}
output_has() {
    grep -q -- "$1" "$work/output.log"
}
output_lacks() {
    ! grep -q -- "$1" "$work/output.log"
}
stored_password() {
    awk 'NR == 1 { print $NF }' "$password_file"
}
delivered_password() {
    sed -n '/^-----BEGIN AGE ENCRYPTED FILE-----$/,/^-----END AGE ENCRYPTED FILE-----$/p' "$requests" \
        | age -d -i "$work/age.key" 2>/dev/null
}
delivered_password_is_stored() {
    local stored
    stored=$(stored_password)
    [ -n "$stored" ] && [ "$(delivered_password)" = "$stored" ]
}
# True when the stored password opens the account (same check login performs).
stored_password_works() {
    perl -e 'exit(crypt($ARGV[0], $ARGV[1]) eq $ARGV[1] ? 0 : 1)' \
        "$(stored_password)" "$(getent shadow admin_init | cut -d: -f2)"
}
plaintext_password_not_sent() {
    local stored
    stored=$(stored_password)
    [ -n "$stored" ] && ! grep -qF -- "$stored" "$requests"
}

stub fail-sshd sshd 'exit 1'
# setup_sudo calls usermod from the main shell: its parent is the script.
# The stub body is expanded when the stub runs, not here.
# shellcheck disable=SC2016
stub term-usermod usermod 'kill -TERM "$PPID"'
stub no-ip ip 'exit 0'

echo "=== Первый запуск: пароль доставлен шифртекстом ==="
fresh_admin
run
check "скрипт завершился успешно" status_is 0
check "отправлено ровно одно уведомление" posts_are 1
check "заголовок об успехе" sent '^Title: Server Setup Complete'
check "обычный приоритет" sent '^Priority: default'
check "текст об успешной настройке" sent 'Новый сервер настроен'
check "внешний IP получен от сервиса" sent 'Внешний IP: 203.0.113.7'
check "шифртекст расшифровывается в сохранённый пароль" delivered_password_is_stored
check "сохранённый пароль подходит к учётной записи" stored_password_works
check "открытого пароля в уведомлении нет" plaintext_password_not_sent
check "в уведомлении нет готовой команды для терминала" not_sent 'age -d'
check "доставка отмечена" test -e "$sent_marker"

echo "=== Повторный запуск: пароль повторно не отправляется ==="
run
check "скрипт завершился успешно" status_is 0
check "сообщение, что пароль не менялся" sent 'пароль не менялся'
check "шифртекста нет" not_sent 'BEGIN AGE ENCRYPTED FILE'

echo "=== ntfy отклонил запрос: доставка повторяется при следующем запуске ==="
fresh_admin
echo 429 > "$work/http/post-status"
run
check "сбой уведомления не роняет скрипт" status_is 0
check "скрипт сообщает, что уведомление не отправлено" output_has 'не удалось отправить уведомление'
check "скрипт не сообщает об отправке" output_lacks 'Уведомление отправлено'
check "доставка не отмечена" test ! -e "$sent_marker"
echo 200 > "$work/http/post-status"
run
check "повторный запуск завершился успешно" status_is 0
check "пароль доставлен, хотя пользователь уже существовал" delivered_password_is_stored
check "доставка отмечена" test -e "$sent_marker"

echo "=== Запасные значения вместо пустых полей и страниц ошибок ==="
echo 500 > "$work/http/get-status"
mv /etc/os-release "$work/os-release"
run PATH="$work/stubs/no-ip:$PATH"
mv "$work/os-release" /etc/os-release
echo 200 > "$work/http/get-status"
check "скрипт завершился успешно" status_is 0
check "внешний IP: N/A при ошибке сервиса" sent 'Внешний IP: N/A'
check "страница ошибки не попала в уведомление" not_sent '<html'
check "внутренний IP: N/A" sent 'Внутренний IP: N/A'
check "ОС: Unknown OS" sent 'OS: Unknown OS'

echo "=== Сбой настройки: уведомление с шагом и кодом ==="
run PATH="$work/stubs/fail-sshd:$PATH"
check "скрипт завершился с ошибкой" status_is 1
check "отправлено ровно одно уведомление" posts_are 1
check "заголовок о сбое" sent '^Title: Server Setup FAILED'
check "высокий приоритет" sent '^Priority: high'
check "текст о незавершённой настройке" sent 'Настройка сервера не завершена'
check "указан шаг" sent 'Шаг: отключение парольной аутентификации SSH'
check "указан код выхода" sent 'Код выхода: 1'
check "сведения о сервере" sent 'Hostname: '
check "уведомления об успехе нет" not_sent 'Новый сервер настроен'
check "доставленный пароль не упоминается" not_sent 'admin_init_password'

echo "=== Сбой первого запуска: пароль не теряется ==="
fresh_admin
run PATH="$work/stubs/fail-sshd:$PATH"
check "скрипт завершился с ошибкой" status_is 1
check "уведомление о сбое говорит, где лежит пароль" sent "$password_file"
check "открытого пароля в уведомлении нет" plaintext_password_not_sent
run
check "следующий запуск завершился успешно" status_is 0
check "пароль доставлен после сбойного первого запуска" delivered_password_is_stored
check "сохранённый пароль подходит к учётной записи" stored_password_works

echo "=== Прерывание сигналом ==="
run PATH="$work/stubs/term-usermod:$PATH"
check "код выхода соответствует SIGTERM" status_is 143
check "отправлено уведомление о сбое" sent '^Title: Server Setup FAILED'
check "указан код выхода" sent 'Код выхода: 143'
check "указан шаг" sent 'Шаг: настройка sudo для admin_init'

if [ "$failures" -ne 0 ]; then
    echo "=== Notification tests: $failures failed ===" >&2
    exit 1
fi
echo '=== Notification tests passed ==='
