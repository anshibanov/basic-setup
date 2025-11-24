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
3. Sets up SSH access with pre-configured authorized_keys (3 SSH public keys)
4. Detects and configures Proxmox VE if running on a Proxmox system
5. Encrypts the password using Age (age-encryption.org) with a hardcoded public key
6. Sends a notification to ntfy.sh with server details and encrypted password

The script uses `set -e` to stop on any error and includes error handling for non-critical operations (ntfy.sh notification, password encryption).

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/ci.yml`) performs:

1. **Testing**: Runs the script in Docker containers (Debian and Ubuntu) to verify functionality
   - Installs dependencies: `openssl`, `sudo`, `curl`, `iproute2`, `age`
   - Executes the script to ensure no errors occur

2. **Deployment**: After tests pass, deploys `admin_init.sh` to GitHub Pages for public access

## Testing Locally

To test the script locally in a Docker container:

```bash
# Test on Debian
docker run --rm -v $(pwd):/app -w /app debian:latest bash -c "\
  apt-get -qq update > /dev/null && \
  apt-get -qq install -y openssl sudo curl iproute2 age > /dev/null && \
  ./admin_init.sh"

# Test on Ubuntu
docker run --rm -v $(pwd):/app -w /app ubuntu:latest bash -c "\
  apt-get -qq update > /dev/null && \
  apt-get -qq install -y openssl sudo curl iproute2 age > /dev/null && \
  ./admin_init.sh"
```

## Script Modification Guidelines

When modifying `admin_init.sh`:

- The script must be idempotent (safe to run multiple times)
- All critical operations should fail-fast due to `set -e`
- Non-critical operations (like ntfy.sh notifications, password encryption) should be wrapped in error handling to prevent script termination
- Changes to SSH keys in `authorized_keys` require updating lines 15-17 in the SSH_KEYS variable
- The ntfy.sh topic is hardcoded at line 12: `https://ntfy.sh/Sg3N35kJvdkna1eA`
- The Age public key for password encryption is hardcoded at line 13

## Dependencies

The script requires these system utilities:
- `openssl` - password generation and hashing
- `useradd`, `usermod` - user management
- `sudo` - privilege escalation configuration
- `curl` - external IP detection and ntfy.sh notifications
- `ip` command (from `iproute2`) - internal IP detection
- `age` - password encryption (age-encryption.org). If not available, the script will continue without encrypting the password
- `pveum` (optional) - Proxmox user management

## Password Encryption

The script encrypts the generated password using [Age encryption](https://age-encryption.org) before sending it via ntfy.sh notification:

- **Public key** (embedded in script, line 13): `age1sdrr0z0f2uue3rh8t3dp6ce7m6d80g994wvcgphrm3a9r3qxnccs7h8dzc`
- **Private key** (store securely!): `AGE-SECRET-KEY-1X0JS40SZAYP2KQQ302V9QLEEP7KETYU7EX27Q9R7WXSJL60P8PKQVD0A9Y`

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
