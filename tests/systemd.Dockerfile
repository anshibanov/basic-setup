ARG BASE=debian:13
FROM ${BASE}
# systemd is named explicitly: older releases (Debian 12, Ubuntu 24.04) do not
# pull it in through openssh-server when recommended packages are skipped.
RUN apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends systemd openssl sudo curl iproute2 openssh-server age shellcheck ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
