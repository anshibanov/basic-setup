# syntax=docker/dockerfile:1
FROM debian:13

RUN apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends ca-certificates curl python3 procps && rm -rf /var/lib/apt/lists/*

# Optional public trust bundle already trusted by the cloud host. CI normally
# uses Debian's public CAs. Never introduce a TLS verification exception.
RUN --mount=type=secret,id=proxy_ca,required=false \
    if [ -f /run/secrets/proxy_ca ]; then \
        cp /run/secrets/proxy_ca /usr/local/share/ca-certificates/cloud-proxy.crt; \
        update-ca-certificates; \
    fi

# Official checksum and no-subscription repository:
# https://github.com/proxmox/pve-docs/blob/b423460d22af888462b3d31dfff374abcfda95fa/pve-package-repos.adoc
# That repository publishes signed apt metadata over HTTP. The initial signing
# key is obtained over verified HTTPS and checked against the published SHA256.
RUN curl --fail --show-error --silent --location \
      https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
      -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
    && printf '%s  %s\n' \
      136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45 \
      /usr/share/keyrings/proxmox-archive-keyring.gpg | sha256sum --check --strict \
    && printf '%s\n' \
      'Types: deb' \
      'URIs: http://download.proxmox.com/debian/pve' \
      'Suites: trixie' \
      'Components: pve-no-subscription' \
      'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
      > /etc/apt/sources.list.d/proxmox.sources \
    && apt-get -qq update \
    && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends \
      libpve-access-control pve-cluster proxmox-archive-keyring \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
