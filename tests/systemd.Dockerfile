ARG BASE=debian:13
FROM ${BASE}
RUN apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends openssl sudo curl iproute2 openssh-server age shellcheck ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
