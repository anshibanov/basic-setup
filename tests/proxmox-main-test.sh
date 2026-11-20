#!/usr/bin/env bash
# Full admin_init.sh run on the Proxmox fixture, which ships without sudo like a
# real PVE node. Unlike proxmox-test.sh it needs network access: the script has
# to install sudo and age by itself. Run only in the disposable fixture.
set -euo pipefail

if [ "$(hostname)" != basic-setup-pve-validation ] || [ ! -f /.dockerenv ]; then
    echo "Run this test in the disposable Proxmox test container." >&2
    exit 1
fi
if pgrep -x pmxcfs >/dev/null || id admin_init >/dev/null 2>&1; then
    echo "The Proxmox test requires a fresh disposable container." >&2
    exit 1
fi
if command -v sudo >/dev/null || [ -e /etc/sudoers.d ]; then
    echo "The Proxmox fixture must not have sudo preinstalled." >&2
    exit 1
fi

work=$(mktemp -d)
pmxcfs_pid=
cleanup() {
    local attempt
    if [ -n "$pmxcfs_pid" ]; then
        # The checks are over by now: never let a slow pmxcfs teardown hang the job.
        kill "$pmxcfs_pid" 2>/dev/null || true
        for ((attempt=0; attempt<50; attempt++)); do
            kill -0 "$pmxcfs_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$pmxcfs_pid" 2>/dev/null || true
        wait "$pmxcfs_pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

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

lacks() {
    ! grep -q -- "$1" "$2"
}

# No real notifications: every curl call is only recorded.
mkdir "$work/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s"\n' "$work/curl.log" > "$work/bin/curl"
chmod 755 "$work/bin/curl"
export PATH="$work/bin:$PATH"

if [ ! -c /dev/fuse ]; then
    mknod /dev/fuse c 10 229
fi
# pmxcfs requires the hostname to resolve to a non-loopback address.
if ! getent hosts "$(hostname)" | grep -qv '^127\.'; then
    printf '192.0.2.10 %s\n' "$(hostname)" >> /etc/hosts
fi
mkdir -p /etc/pve /run/pve-cluster

pmxcfs -l -f > "$work/pmxcfs.log" 2>&1 &
pmxcfs_pid=$!
ready=0
for ((i=0; i<100; i++)); do
    if mountpoint -q /etc/pve && pveum user list --output-format json > /dev/null 2>&1; then
        ready=1
        break
    fi
    if ! kill -0 "$pmxcfs_pid" 2>/dev/null; then
        break
    fi
    sleep 0.1
done
if [ "$ready" -ne 1 ]; then
    cat "$work/pmxcfs.log" >&2
    echo "FAIL: pmxcfs did not start" >&2
    exit 1
fi
# Full PVE creates this directory in pvecm updatecerts.
mkdir -p /etc/pve/priv/lock

pve_admin_is_administrator() {
    pveum user list --output-format json > "$work/users.json"
    pveum acl list --output-format json > "$work/acls.json"
    python3 - "$work" <<'PY'
import json, sys
work = sys.argv[1]
users = json.load(open(f'{work}/users.json'))
admin = [user for user in users if user['userid'] == 'admin_init@pam']
assert len(admin) == 1 and admin[0]['enable'] == 1, admin
acls = json.load(open(f'{work}/acls.json'))
admin_acls = [acl for acl in acls if acl['path'] == '/' and acl['ugid'] == 'admin_init@pam' and acl['roleid'] == 'Administrator']
assert len(admin_acls) == 1 and admin_acls[0]['propagate'] == 1, admin_acls
PY
}

check_state() {
    local user

    assert "sudo установлен скриптом" bash -c 'command -v sudo > /dev/null'
    assert "sudoers валиден" bash -c 'visudo -c > /dev/null'
    for user in admin_init orange byak; do
        assert "пользователь $user существует" id "$user"
        assert "sudoers.d для $user" grep -q "^${user} ALL=(ALL) NOPASSWD:ALL$" "/etc/sudoers.d/90-${user}"
        assert "authorized_keys для $user содержит 4 ключа" \
            test "$(grep -c '^ssh-' "/home/${user}/.ssh/authorized_keys")" -eq 4
    done
    assert "admin_init@pam — Administrator в Proxmox" pve_admin_is_administrator
    assert "парольная аутентификация SSH отключена" \
        bash -c "sshd -T | grep -q '^passwordauthentication no$'"
}

echo "=== Первый запуск на Proxmox без sudo ==="
bash /app/admin_init.sh
check_state
assert "age установлен скриптом, пароль отправлен шифртекстом" grep -q 'BEGIN AGE ENCRYPTED FILE' "$work/curl.log"
assert "отправлено уведомление об успехе" grep -q 'Новый сервер настроен' "$work/curl.log"
assert "уведомления о сбое нет" lacks 'Настройка сервера не завершена' "$work/curl.log"
cp /etc/pve/user.cfg "$work/user.cfg"

echo "=== Второй запуск (идемпотентность) ==="
bash /app/admin_init.sh
check_state
assert "повторный запуск не меняет конфигурацию доступа Proxmox" cmp "$work/user.cfg" /etc/pve/user.cfg

echo "=== Proxmox full-run checks passed ==="
