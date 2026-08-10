# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This is a server initialization script repository that creates an `admin_init` user with sudo privileges and SSH access. The script is deployed via GitHub Pages and can be executed remotely on fresh server installations using:

```bash
curl -sSL https://anshibanov.github.io/basic-setup/admin_init.sh | sudo bash
```

## Architecture

The repository contains a single bash script (`admin_init.sh`) that:

1. Creates an `admin_init` user with a randomly generated password
2. Configures passwordless sudo access
3. Sets up SSH access with pre-configured authorized_keys (4 SSH public keys)
4. Detects and configures Proxmox VE if running on a Proxmox system
5. Adds the same SSH keys to the `ubuntu` user if it exists
6. Creates an `orange` user with the same SSH keys and passwordless sudo
7. Disables SSH password authentication (with sshd config validation and rollback on failure)
8. Encrypts the `admin_init` password using Age (age-encryption.org) with a hardcoded public key
9. Sends a notification to ntfy.sh with server details and the encrypted password (only if the user was just created; on re-runs the notification states the password is unchanged)

Passwords are saved on the server as `/root/.<username>_password.txt` (one file per user).

The script uses `set -e` to stop on any error and includes error handling for non-critical operations (ntfy.sh notification, password encryption, sshd restart).

The script uses `set -e` to stop on any error and includes error handling for non-critical operations (ntfy.sh notification, password encryption).

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/ci.yml`) performs:

1. **Lint**: Runs `shellcheck` on `admin_init.sh` and `tests/container-test.sh`

2. **Testing**: Runs `tests/container-test.sh` in Docker containers (matrix: `debian:13`, `ubuntu:26.04`)
   - Installs dependencies: `openssl`, `sudo`, `curl`, `iproute2`, `openssh-server`
   - Executes the script **twice** (idempotency check) and asserts the results: users exist, sudoers is valid, authorized_keys contents/permissions/ownership, password files exist with mode 600 and don't change on re-run, SSH password authentication is disabled (`sshd -T`), no leftover config backups

3. **Deployment**: After lint and tests pass (push to `main` only), deploys `admin_init.sh` to GitHub Pages for public access. The deploy job uses the `github-pages` environment and a `pages` concurrency group.

Actions are pinned to commit SHAs (with `# vN` comments); container images are pinned to specific releases — update both explicitly when bumping versions.

Note: each test run sends real notifications to the ntfy.sh topic (the script's notification step is not disabled in CI).

## Testing Locally

To run the same test as CI locally in a Docker container:

```bash
# Test on Debian (replace image with ubuntu:26.04 for Ubuntu)
docker run --rm -v $(pwd):/app -w /app debian:13 bash -c "\
  apt-get -qq update > /dev/null && \
  apt-get -qq install -y openssl sudo curl iproute2 openssh-server > /dev/null && \
  ./tests/container-test.sh"
```

`openssh-server` is required because the script validates the sshd config (`sshd -t`) when disabling password authentication. `age` is optional — the script attempts to install it itself.

## Script Modification Guidelines

When modifying `admin_init.sh`:

- The script must be idempotent (safe to run multiple times)
- All critical operations should fail-fast due to `set -e`
- Non-critical operations (like ntfy.sh notifications, password encryption) should be wrapped in error handling to prevent script termination
- Changes to SSH keys in `authorized_keys` require updating the `SSH_KEYS` variable at the top of the script
- The ntfy.sh topic is hardcoded in the `NTFY_TOPIC` variable: `https://ntfy.sh/Sg3N35kJvdkna1eA`
- The Age public key for password encryption is hardcoded in the `AGE_PUBLIC_KEY` variable
- NEVER commit the Age private key (or any other secret) to this repository — it is public

## Dependencies

The script requires these system utilities:
- `openssl` - password generation
- `useradd`, `usermod`, `chpasswd` - user management
- `openssh-server` (`sshd`) - config validation when disabling password authentication
- `sudo` - privilege escalation configuration
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

**Quick method:**
```bash
# Copy ready-to-use command from ntfy.sh notification
echo "-----BEGIN AGE ENCRYPTED FILE-----
...
-----END AGE ENCRYPTED FILE-----" | age -d -i ~/.age/key.txt
```


### Fallback behavior

If `age` is not installed on the target server:
- The script continues without encrypting the password
- A warning is included in the ntfy.sh notification
- The password is still saved to `/root/.admin_init_password.txt` (accessible on the server)
