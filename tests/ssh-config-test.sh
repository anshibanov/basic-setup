#!/usr/bin/env bash
# Destructive SSH regression tests. Run only inside a disposable root container.
set -euo pipefail
source ./admin_init.sh

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

is_empty_dir() {
    [ -d "$1" ] && [ -z "$(ls -A "$1")" ]
}

assert_passwords_disabled() {
    local effective
    effective=$(sshd -T "$@")
    assert "PasswordAuthentication no" grep -qx 'passwordauthentication no' <<< "$effective"
    assert "KbdInteractiveAuthentication no" grep -qx 'kbdinteractiveauthentication no' <<< "$effective"
}

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p /etc/ssh/sshd_config.d /run/sshd
ssh-keygen -A

echo "=== Директивы в нижнем регистре и ранний drop-in ==="
printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > /etc/ssh/sshd_config
printf 'passwordauthentication yes\nkbdinteractiveauthentication=yes\n' > /etc/ssh/sshd_config.d/00-regression.conf
disable_password_auth
assert_passwords_disabled

echo "=== Отсутствующий Include и завершающий Match ==="
printf 'PasswordAuthentication yes\nMatch User nobody\n  KbdInteractiveAuthentication yes\n  passwordauthentication=yes\n' > /etc/ssh/sshd_config
mv /etc/ssh/sshd_config.d "$test_dir/drop-ins"
disable_password_auth
assert_passwords_disabled
assert_passwords_disabled -C user=nobody,host=localhost,addr=127.0.0.1
cp /etc/ssh/sshd_config "$test_dir/once"
disable_password_auth
assert "повторный запуск не меняет конфигурацию" cmp "$test_dir/once" /etc/ssh/sshd_config
assert "sshd принимает соединения после перезапуска" bash -c 'ssh-keyscan -T 5 127.0.0.1 2>/dev/null | grep -q " ssh-"'
mv "$test_dir/drop-ins" /etc/ssh/sshd_config.d

echo "=== Откат при невалидной конфигурации ==="
printf 'Include /etc/ssh/sshd_config.d/*.conf\nInvalidDirective yes\n' > /etc/ssh/sshd_config
printf '# Existing policy\nPasswordAuthentication no\n' > /etc/ssh/sshd_config.d/99-disable-password-auth.conf
cp -a /etc/ssh/sshd_config "$test_dir/main"
cp -a /etc/ssh/sshd_config.d/99-disable-password-auth.conf "$test_dir/drop-in"
if disable_password_auth > "$test_dir/run.log" 2>&1; then
    echo 'FAIL: невалидная конфигурация принята' >&2
    exit 1
fi
assert "исходный основной конфиг восстановлен" cmp "$test_dir/main" /etc/ssh/sshd_config
assert "существовавший drop-in сохранён" cmp "$test_dir/drop-in" /etc/ssh/sshd_config.d/99-disable-password-auth.conf
assert "ошибка называет непройденную проверку" grep -q 'sshd -t' "$test_dir/run.log"
rm -f /etc/ssh/sshd_config.d/99-disable-password-auth.conf

echo "=== Повреждённый блок admin_init: остальной конфиг не удаляется ==="
printf '%s\n' '# managed header' '# BEGIN admin_init password authentication' \
    'PasswordAuthentication no' 'KbdInteractiveAuthentication no' \
    'Port 2222' 'PermitRootLogin no' > /etc/ssh/sshd_config
cp -a /etc/ssh/sshd_config "$test_dir/main"
if disable_password_auth > "$test_dir/run.log" 2>&1; then
    echo 'FAIL: блок без метки END принят' >&2
    exit 1
fi
assert "конфигурация с незакрытым блоком не изменена" cmp "$test_dir/main" /etc/ssh/sshd_config
assert "ошибка называет повреждённый блок" grep -q 'END admin_init password authentication' "$test_dir/run.log"

echo "=== Вход по ключам отключён: пароли остаются ==="
printf 'PubkeyAuthentication no\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config
cp -a /etc/ssh/sshd_config "$test_dir/main"
if disable_password_auth > "$test_dir/run.log" 2>&1; then
    echo 'FAIL: отключён последний рабочий способ входа' >&2
    exit 1
fi
assert "конфигурация восстановлена" cmp "$test_dir/main" /etc/ssh/sshd_config
assert "ошибка называет причину" grep -qi 'pubkeyauthentication' "$test_dir/run.log"

echo "=== Ключи читаются из другого места: пароли остаются ==="
printf 'AuthorizedKeysFile /etc/ssh/keys/%%u\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config
cp -a /etc/ssh/sshd_config "$test_dir/main"
if disable_password_auth > "$test_dir/run.log" 2>&1; then
    echo 'FAIL: пароли отключены, хотя sshd не читает установленные ключи' >&2
    exit 1
fi
assert "конфигурация восстановлена" cmp "$test_dir/main" /etc/ssh/sshd_config
assert "ошибка называет причину" grep -qi 'authorizedkeysfile' "$test_dir/run.log"

echo "=== Стандартный путь ключей, заданный явно, допустим ==="
printf 'AuthorizedKeysFile /etc/ssh/keys/%%u %%h/.ssh/authorized_keys\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config
disable_password_auth
assert_passwords_disabled

echo "=== Каталог с именем *.conf среди drop-in файлов ==="
printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config
mkdir /etc/ssh/sshd_config.d/sub.conf
disable_password_auth
assert_passwords_disabled
assert "каталог не тронут" is_empty_dir /etc/ssh/sshd_config.d/sub.conf
rmdir /etc/ssh/sshd_config.d/sub.conf

echo "=== Основной конфиг и drop-in — символические ссылки ==="
printf 'Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.real
rm -f /etc/ssh/sshd_config
ln -s sshd_config.real /etc/ssh/sshd_config
printf 'KbdInteractiveAuthentication yes\n' > /etc/ssh/managed-drop-in
ln -s ../managed-drop-in /etc/ssh/sshd_config.d/50-link.conf
disable_password_auth
assert_passwords_disabled
assert "основной конфиг остался ссылкой" test -L /etc/ssh/sshd_config
assert "изменён файл, на который указывает ссылка" grep -qx 'PasswordAuthentication no' /etc/ssh/sshd_config.real
assert "drop-in остался ссылкой" test -L /etc/ssh/sshd_config.d/50-link.conf
assert "директива в целевом файле drop-in закомментирована" grep -qx '# KbdInteractiveAuthentication yes' /etc/ssh/managed-drop-in
rm -f /etc/ssh/sshd_config /etc/ssh/sshd_config.real /etc/ssh/sshd_config.d/50-link.conf /etc/ssh/managed-drop-in

echo "=== Сигнал во время правки: конфигурация откатывается ==="
printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config
cp -a /etc/ssh/sshd_config "$test_dir/main"
# Runs inside disable_password_auth's subshell: the signal arrives after the
# config was edited and before it is validated.
# shellcheck disable=SC2317,SC2329
sshd() {
    if [ "${1:-}" = -t ]; then
        kill -TERM "$BASHPID"
    fi
    command sshd "$@"
}
if disable_password_auth > "$test_dir/run.log" 2>&1; then
    echo 'FAIL: прерванная настройка сообщила об успехе' >&2
    exit 1
fi
unset -f sshd
assert "конфигурация восстановлена после сигнала" cmp "$test_dir/main" /etc/ssh/sshd_config
assert "временные бэкапы убраны" bash -c '! compgen -G "/etc/ssh/.admin-init.*"'

echo "=== Откат при ошибке перезапуска ==="
printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config
cp -a /etc/ssh/sshd_config "$test_dir/main"
restart_sshd() { return 1; }
if disable_password_auth > "$test_dir/restart.log" 2>&1; then
    echo 'FAIL: ошибка перезапуска проигнорирована' >&2
    exit 1
fi
assert "конфигурация восстановлена после ошибки перезапуска" cmp "$test_dir/main" /etc/ssh/sshd_config
# The inner shell receives the log path as $1.
# shellcheck disable=SC2016
assert "ошибка перезапуска не сообщает об успехе" bash -c '! grep -q "Парольная аутентификация SSH отключена" "$1"' _ "$test_dir/restart.log"
assert "временные бэкапы убраны" bash -c '! compgen -G "/etc/ssh/.admin-init.*"'

echo '=== SSH regression tests passed ==='
