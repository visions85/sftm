FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Core tool deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    iverilog \
    ghdl \
    verilator \
    git \
    make \
    python3 \
    python3-pip \
    wget \
    curl \
    ca-certificates \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Go 1.23 — jtframe go.mod requires >= 1.22, toolchain 1.23.4
ARG GO_VERSION=1.23.5
RUN wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm /tmp/go.tgz
ENV PATH="/usr/local/go/bin:${PATH}"

# JTROOT layout:
#   /workspace/cores/sftm     <- bind-mounted from host repo
#   /workspace/modules/jtframe <- named Docker volume (populated by entrypoint)
ENV JTROOT=/workspace
ENV PATH="/workspace/modules/jtframe/bin:${PATH}"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
