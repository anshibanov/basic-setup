#!/usr/bin/env bash
# Actual PVE access-control integration; run only in its disposable fixture.
set -euo pipefail

if [ "$(hostname)" != basic-setup-pve-validation ] || [ ! -f /.dockerenv ]; then
    echo "Run this test in the disposable Proxmox test container." >&2
    exit 1
fi
if pgrep -x pmxcfs >/dev/null || id admin_init >/dev/null 2>&1; then
    echo "The Proxmox test requires a fresh disposable container." >&2
    exit 1
fi

# shellcheck source=/dev/null
source /app/admin_init.sh

pmxcfs_pid=
checks=0
pass() {
    checks=$((checks + 1))
    printf '  OK: %s\n' "$1"
}
cleanup() {
    if [ -n "$pmxcfs_pid" ]; then
        kill "$pmxcfs_pid" 2>/dev/null || true
        wait "$pmxcfs_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ ! -c /dev/fuse ]; then
    mknod /dev/fuse c 10 229
fi
# pmxcfs requires a non-loopback address even in local mode. No network is used.
printf '192.0.2.10 %s\n' "$(hostname)" >> /etc/hosts
mkdir -p /etc/pve /run/pve-cluster

start_pmxcfs() {
    pmxcfs -l -f >/tmp/pmxcfs.log 2>&1 &
    pmxcfs_pid=$!
    for ((i=0; i<100; i++)); do
        if mountpoint -q /etc/pve && pveum user list --output-format json >/tmp/pve-users.json 2>/tmp/pve-ready.log; then
            return 0
        fi
        if ! kill -0 "$pmxcfs_pid" 2>/dev/null; then
            cat /tmp/pmxcfs.log >&2
            return 1
        fi
        sleep 0.1
    done
    cat /tmp/pmxcfs.log /tmp/pve-ready.log >&2
    return 1
}

check_user_acl() {
    pveum user list --output-format json >/tmp/pve-users.json
    pveum acl list --output-format json >/tmp/pve-acls.json
    pveum user permissions admin_init@pam --path / --output-format json >/tmp/pve-permissions.json
    python3 - <<'PY'
import json
users = json.load(open('/tmp/pve-users.json'))
admin = [user for user in users if user['userid'] == 'admin_init@pam']
assert len(admin) == 1, admin
assert admin[0]['enable'] == 1, admin
acls = json.load(open('/tmp/pve-acls.json'))
admin_acls = [acl for acl in acls if acl['path'] == '/' and acl['ugid'] == 'admin_init@pam' and acl['type'] == 'user' and acl['roleid'] == 'Administrator']
assert len(admin_acls) == 1, admin_acls
assert admin_acls[0]['propagate'] == 1, admin_acls
perms = json.load(open('/tmp/pve-permissions.json'))['/']
assert perms['Permissions.Modify'] == 1, perms
assert perms['Sys.Modify'] == 1, perms
assert perms['VM.Allocate'] == 1, perms
PY
}

start_pmxcfs
# Full PVE creates this directory in pvecm updatecerts. Initialize only the
# supported lock directory required by the minimal access-control fixture.
mkdir -p /etc/pve/priv/lock
useradd -m -s /bin/bash admin_init
/usr/sbin/pveum user add decoy@pam -comment admin_init@pam
setup_proxmox admin_init
check_user_acl
pass 'real pveum creates the exact PAM userid despite another user comment containing it'
pass 'real Administrator ACL propagates root permissions'
cp /etc/pve/user.cfg /tmp/user.cfg.first
setup_proxmox admin_init
check_user_acl
cmp /tmp/user.cfg.first /etc/pve/user.cfg
pass 'repeat setup preserves user/ACL configuration'

# Fault injection checks shell error propagation only. The successful user,
# ACL and permissions checks above use the actual installed pveum and pmxcfs.
# Called indirectly by the sourced setup_proxmox helper.
# shellcheck disable=SC2317
pveum() {
    printf '%s %s\n' "$1" "$2" >> /tmp/pve-calls
    case "$failure:$1 $2" in
        'list:user list') return 41 ;;
        'add:user add') return 42 ;;
        'acl:acl modify') return 43 ;;
        'invalid-json:user list') printf 'not json\n'; return 0 ;;
    esac
    command pveum "$@"
}
for failure in list add acl invalid-json; do
    : >/tmp/pve-calls
    test_user=admin_init
    if [ "$failure" = add ]; then test_user=failed_create; fi
    # A conditional suppresses Bash errexit inside a function; explicit error
    # checks must still prevent a failed command from being reported as success.
    if setup_proxmox "$test_user" >/tmp/pve-failure.log 2>&1; then
        cat /tmp/pve-failure.log >&2
        echo "Expected $failure to return an error." >&2
        exit 1
    fi
    if grep -Eq 'назначена роль Administrator|может логиниться' /tmp/pve-failure.log; then
        echo "Failure $failure emitted a success message." >&2
        exit 1
    fi
    case "$failure" in
        list|invalid-json) [ "$(wc -l </tmp/pve-calls)" -eq 1 ] ;;
        add|acl) [ "$(wc -l </tmp/pve-calls)" -eq 2 ] ;;
    esac
    pass "fault injection: $failure returns failure without continuing or reporting success"
done
unset -f pveum

kill "$pmxcfs_pid"
wait "$pmxcfs_pid"
pmxcfs_pid=
if setup_proxmox admin_init >/tmp/pve-offline.log 2>&1; then
    cat /tmp/pve-offline.log >&2
    echo "Expected an offline real pmxcfs to return an error." >&2
    exit 1
fi
if grep -Eq 'назначена роль Administrator|может логиниться' /tmp/pve-offline.log; then
    echo "An offline real pmxcfs emitted a success message." >&2
    exit 1
fi
pass 'real pveum reports an offline pmxcfs as failure'
start_pmxcfs
check_user_acl
pass 'real user and Administrator privileges persist across pmxcfs restart'
dpkg-query -W -f='${Package} ${Version}\n' libpve-access-control pve-cluster libpve-common-perl
printf 'Proxmox checks passed: %s\n' "$checks"
