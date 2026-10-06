#!/usr/bin/env bash
# Run on the Docker host, or with --inside inside a disposable systemd container.
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

check_inside() {
    local mode="$1" test_dir methods attempt
    if [ "$(hostname)" != basic-setup-systemd-validation ] || [ ! -f /.dockerenv ]; then
        echo 'Run --inside only in the disposable systemd test container.' >&2
        exit 1
    fi
    source ./admin_init.sh
    assert 'systemd is PID 1' test "$(cat /proc/1/comm)" = systemd
    test_dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$test_dir'" EXIT

    # Called indirectly by assert.
    # shellcheck disable=SC2317
    key_login() {
        local attempt result
        # systemctl's ExecReload completes after SIGHUP, before sshd re-execs.
        for ((attempt=0; attempt<30; attempt++)); do
            if result=$(ssh -i "$test_dir/client" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile="$test_dir/known_hosts" ssh_test@127.0.0.1 id -un 2> "$test_dir/key-login.log"); then
                [ "$result" = ssh_test ]
                return
            fi
            sleep 0.1
        done
        cat "$test_dir/key-login.log" >&2
        return 1
    }

    useradd -m -s /bin/bash ssh_test
    echo 'ssh_test:disposable-test-password' | chpasswd
    ssh-keygen -q -t ed25519 -N '' -f "$test_dir/client"
    install -d -m 700 -o ssh_test -g ssh_test /home/ssh_test/.ssh
    install -m 600 -o ssh_test -g ssh_test "$test_dir/client.pub" /home/ssh_test/.ssh/authorized_keys
    printf 'Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\nUsePAM yes\n' > /etc/ssh/sshd_config

    systemctl disable --now ssh.socket
    systemctl stop ssh.service
    if [ "$mode" = socket ]; then
        systemctl enable --now ssh.socket
        assert 'ssh.socket is listening before the first connection' systemctl is-active --quiet ssh.socket
        assert 'ssh.service is initially inactive' test "$(systemctl show ssh.service -p ActiveState --value)" = inactive
    else
        systemctl start ssh.service
        assert 'ssh.service starts normally' systemctl is-active --quiet ssh.service
        assert 'socket activation is disabled' test "$(systemctl show ssh.socket -p ActiveState --value)" = inactive
    fi

    disable_password_auth
    assert 'ssh.service is running after reload-or-restart' systemctl is-active --quiet ssh.service
    if [ "$mode" = socket ]; then
        assert 'ssh.socket remains active' systemctl is-active --quiet ssh.socket
    fi
    assert 'effective PasswordAuthentication is no' bash -c "sshd -T | grep -qx 'passwordauthentication no'"
    assert 'effective KbdInteractiveAuthentication is no' bash -c "sshd -T | grep -qx 'kbdinteractiveauthentication no'"

    for ((attempt=0; attempt<30; attempt++)); do
        if ssh-keyscan -T 5 127.0.0.1 > "$test_dir/known_hosts" 2>/dev/null && [ -s "$test_dir/known_hosts" ]; then
            break
        fi
        sleep 0.1
    done
    assert 'real public-key authentication succeeds' key_login
    if ssh -v -o PubkeyAuthentication=no -o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile="$test_dir/known_hosts" ssh_test@127.0.0.1 true > "$test_dir/auth.log" 2>&1; then
        echo 'FAIL: authenticated without a public key' >&2
        exit 1
    fi
    methods=$(sed -n 's/.*Authentications that can continue: //p' "$test_dir/auth.log" | head -n1)
    assert 'server advertised authentication methods' test -n "$methods"
    assert 'password authentication is not offered by the live server' test "${methods/password/}" = "$methods"
    assert 'keyboard-interactive authentication is not offered' test "${methods/keyboard-interactive/}" = "$methods"

    cp /etc/ssh/sshd_config "$test_dir/once"
    disable_password_auth
    assert 'repeated configuration is stable' cmp "$test_dir/once" /etc/ssh/sshd_config
    assert 'public-key login still works after the second reload' key_login
    echo "=== systemd $mode checks passed ==="
}

if [ "${1:-}" = --inside ]; then
    check_inside "$2"
    exit
fi

if [ "$#" -eq 0 ]; then
    set -- basic-setup-test:debian13 basic-setup-test:ubuntu2604
fi
container_id=''
cleanup() {
    if [ -n "$container_id" ]; then
        docker rm -f "$container_id" >/dev/null
    fi
}
trap cleanup EXIT
for image in "$@"; do
    for mode in service socket; do
        echo "=== $image: systemd $mode ==="
        # Private cgroup namespace and writable cgroups are required by systemd.
        # Use a private network/cgroup namespace and mount the checkout read-only.
        container_id=$(docker run -d --hostname basic-setup-systemd-validation --privileged --cgroupns private --network none --tmpfs /run --tmpfs /run/lock -e container=docker -v "$(pwd):/app:ro" -w /app "$image" /lib/systemd/systemd --unit=multi-user.target)
        ready=0
        for ((attempt=0; attempt<30; attempt++)); do
            if docker exec "$container_id" systemctl is-active --quiet multi-user.target 2>/dev/null; then
                ready=1
                break
            fi
            if [ "$(docker inspect -f '{{.State.Running}}' "$container_id")" != true ]; then
                break
            fi
            sleep 1
        done
        if [ "$ready" -ne 1 ]; then
            docker logs "$container_id"
            echo 'FAIL: systemd did not reach multi-user.target' >&2
            exit 1
        fi
        docker exec "$container_id" bash tests/systemd-test.sh --inside "$mode"
        cleanup
        container_id=''
    done
done
