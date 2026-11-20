# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This is a server initialization script repository that creates an `admin_init` user with sudo privileges and SSH access. The script is deployed via GitHub Pages and can be executed remotely on fresh server installations using:

```bash
curl -sSL https://anshibanov.github.io/basic-setup/admin_init.sh | sudo bash
```

## Architecture

The repository contains a single bash script (`admin_init.sh`) that:

1. Installs `sudo` if it is missing (Proxmox VE and minimal Debian ship without it); fails before creating any account if that is impossible
2. Creates an `admin_init` user with a randomly generated password
3. Configures passwordless sudo access
4. Sets up SSH access: the keys from `SSH_KEYS` (4 public keys) live in a managed block of `authorized_keys`, and keys from `REVOKED_SSH_KEYS` are removed from the whole file
5. Detects and configures Proxmox VE if running on a Proxmox system
6. Applies the same SSH keys to the `ubuntu` user if it exists
7. Creates `orange` and `byak` users with the same SSH keys and passwordless sudo (`provision_user`)
8. Disables SSH password authentication (with sshd config validation and rollback on failure or interruption)
9. Encrypts the `admin_init` password using Age (age-encryption.org) with a hardcoded public key
10. Sends a notification to ntfy.sh with server details and the encrypted password. The password is sent until ntfy has accepted its ciphertext once (marker `/root/.admin_init_password.sent`); after that the notification states the password is unchanged
11. If the run fails or is interrupted, `on_exit` sends a high-priority "Server Setup FAILED" notification with the step (`CURRENT_STEP`) and the exit code

Passwords are saved on the server as `/root/.<username>_password.txt` (one file per user). The file is written before the account gets the password, so a user left without a password by an interrupted run is repaired on the next run.

The script uses `set -e` to stop on critical errors, including SSH setup/restart failures. SSH changes are backed up and restored on failure. Notifications and password encryption remain non-critical.

Password authentication is only disabled when key login will keep working: `sshd -T` must report `pubkeyauthentication yes` and an `authorizedkeysfile` that includes `.ssh/authorized_keys`. A damaged admin_init block in `sshd_config` or in `authorized_keys` (unpaired BEGIN/END markers) is an error, never a reason to delete lines.

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/ci.yml`) performs:

1. **Lint**: Runs `shellcheck` on `admin_init.sh` and `tests/*.sh`

2. **Testing**: Runs `tests/container-test.sh` in Docker containers (matrix: `debian:12`, `debian:13`, `ubuntu:24.04`, `ubuntu:26.04`)
   - Installs dependencies: `openssl`, `curl`, `iproute2`, `openssh-server`, `age`. `sudo` is deliberately not preinstalled: the test fails if it is, because the script must install it (also while another process holds the dpkg lock)
   - Executes the script **twice** (idempotency check) and asserts the results: users exist, sudoers is valid, authorized_keys contents/permissions/ownership, password files exist with mode 600 and don't change on re-run, SSH password authentication is disabled (`sshd -T`), no leftover config backups
   - Then runs `tests/users-test.sh`, `tests/ssh-keys-test.sh`, `tests/notification-test.sh` and `tests/ssh-config-test.sh`

3. **Deployment**: After lint and tests pass (push to `main` only), deploys `admin_init.sh` to GitHub Pages for public access. The deploy job uses the `github-pages` environment and a `pages` concurrency group. Only this job has `pages: write` and `id-token: write`; the workflow default is `contents: read`.

Actions are pinned to commit SHAs (with `# vN` comments); container images are pinned to specific releases — update both explicitly when bumping versions.

Tests replace curl with a no-op, so CI does not send real notifications or contact the IP lookup service. `tests/notification-test.sh` is the exception: it runs a copy of the script whose `NTFY_TOPIC`, `IP_LOOKUP_URL` and `AGE_PUBLIC_KEY` lines are rewritten to point at `tests/fake-http-server.pl` on 127.0.0.1 and at a throwaway Age key, and refuses to run if the rewrite did not apply. Keep those three settings as single `readonly NAME="value"` lines. It checks the real HTTP requests: the ciphertext decrypts to the account's password, the password is re-sent after a rejected delivery, failures and signals produce the failure notification.

`tests/ssh-config-test.sh` also checks case-insensitive directives, missing Include, trailing Match blocks, symlinked configs, stable repeat runs, a live SSH handshake, rollback after validation/restart failures and after a signal, and the refusal to disable passwords when key login would not work. `tests/ssh-keys-test.sh` covers the managed block, migration of the legacy layout, revocation and damaged blocks; its end-to-end part rewrites the `readonly REVOKED_SSH_KEYS=''` line of a script copy. `tests/users-test.sh` covers repair after a failed `chpasswd`. Run these destructive tests only in disposable containers.

`test-systemd` builds `tests/systemd.Dockerfile` for each distro and runs `tests/systemd-test.sh` with a real PID-1 systemd. Both service and socket activation modes verify public-key login and the live server's offered authentication methods. The test waits for real login readiness after asynchronous reload.

`test-proxmox` builds `tests/proxmox.Dockerfile` using the official archive signing key's published SHA256 and signed apt metadata. `tests/proxmox-test.sh` exercises real Proxmox 9 pveum and local-mode pmxcfs: userid matching, enabled PAM user, propagating Administrator ACL, effective privileges, idempotence and persistence. Separate fault injection verifies explicit failures even when Bash errexit is suppressed by a conditional caller. `tests/proxmox-main-test.sh` runs the whole script twice on the same image, which has no `sudo` or `age` like a fresh PVE node; it needs network access because the script installs both. These fixtures use privileged disposable containers, private cgroup namespaces (and no network for `proxmox-test.sh`) and read-only source mounts. They do not test a complete PVE node, GUI or VM lifecycle.

OpenSSH older than 8.7 (Ubuntu 20.04, Debian 11) is handled by adding `ChallengeResponseAuthentication no` to the block, but no such release is in the CI matrix: after touching `disable_password_auth`, run `tests/ssh-config-test.sh` in an `ubuntu:20.04` container by hand.

SSH rewriting supports the main config and `/etc/ssh/sshd_config.d/*.conf`. External Include paths with password-enabled Match overrides need separate validation and configuration changes.

## Testing Locally

To run the same test as CI locally in a Docker container:

```bash
# Test on Debian (other matrix images: debian:12, ubuntu:24.04, ubuntu:26.04)
docker run --rm -v $(pwd):/app -w /app debian:13 bash -c "\
  apt-get -qq update > /dev/null && \
  apt-get -qq install -y openssl curl iproute2 openssh-server age > /dev/null && \
  ./tests/container-test.sh"
```

`openssh-server` is required because the script validates the sshd config (`sshd -t`) when disabling password authentication. `age` is needed by the notification tests. Do not add `sudo` to the list: the test expects a container without it.

## Script Modification Guidelines

When modifying `admin_init.sh`:

- The script must be idempotent (safe to run multiple times)
- All critical operations should fail-fast due to `set -e`
- Non-critical operations (like ntfy.sh notifications, password encryption) should be wrapped in error handling to prevent script termination
- Changes to SSH keys in `authorized_keys` require updating the `SSH_KEYS` variable at the top of the script
- To revoke a key, move its line from `SSH_KEYS` to `REVOKED_SSH_KEYS` instead of deleting it: only revoked keys are removed outside the managed block, which is where earlier script versions wrote them
- Set `CURRENT_STEP` before each new critical stage in `main`: it is what the failure notification reports
- Target systems differ in their coreutils (Ubuntu 26.04 uses uutils): avoid GNU-only shorthands such as `chown user:` and rely on the matrix to catch the rest
- The ntfy.sh topic is hardcoded in the `NTFY_TOPIC` variable: `https://ntfy.sh/Sg3N35kJvdkna1eA`
- The Age public key for password encryption is hardcoded in the `AGE_PUBLIC_KEY` variable
- NEVER commit the Age private key (or any other secret) to this repository — it is public

## Dependencies

The script requires these system utilities:
- `openssl` - password generation
- `useradd`, `usermod`, `chpasswd` - user management
- `openssh-server` (`sshd`) - config validation when disabling password authentication
- `sudo` - privilege escalation configuration. The script installs it via apt when it is missing and stops if that fails
- `curl` - external IP detection and ntfy.sh notifications
- `ip` command (from `iproute2`) - internal IP detection
- `age` - password encryption (age-encryption.org). The script tries to install it via apt; if unavailable, it continues without encrypting the password
- `pveum` (optional) - Proxmox user management

## Password Encryption

The script encrypts the generated password using [Age encryption](https://age-encryption.org) before sending it via ntfy.sh notification:

- **Public key** (embedded in script, `AGE_PUBLIC_KEY` variable): `age1d593fwksp2sfer6h9zz04p8vu05phtl4fuh47lpntutrvc44lukskcksth`
- **Private key**: NOT stored in this repository (the repo is public). It is kept by the repository owner (e.g., in `~/.age/key.txt` and a password manager). If the key pair is ever rotated, update `AGE_PUBLIC_KEY` in the script and this file.
- Key history: the pair was rotated on 2026-08-10 because the previous private key had been committed to this repository. Notifications encrypted with the old keys (`age1sdrr0z...`, `age1txm7sf...`) should be considered compromised/undecryptable respectively.

### Decryption

To decrypt the password from ntfy.sh notification, see [DECRYPT.md](DECRYPT.md) for detailed instructions.

**Quick method:** the notification carries only the encrypted block, never a command (the topic is public, so a command in it could be forged). Copy the block and pipe it into age:
```bash
pbpaste | age -d -i ~/.age/key.txt
```


### Fallback behavior

If `age` is not installed on the target server:
- The script continues without encrypting the password
- A warning is included in the ntfy.sh notification
- The password is still saved to `/root/.admin_init_password.txt` (accessible on the server)
- The password stays undelivered, so a later run on which `age` is available sends it
