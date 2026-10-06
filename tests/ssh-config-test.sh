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
if disable_password_auth; then
    echo 'FAIL: невалидная конфигурация принята' >&2
    exit 1
fi
assert "исходный основной конфиг восстановлен" cmp "$test_dir/main" /etc/ssh/sshd_config
assert "существовавший drop-in сохранён" cmp "$test_dir/drop-in" /etc/ssh/sshd_config.d/99-disable-password-auth.conf

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
