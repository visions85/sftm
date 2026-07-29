# Pinned to amd64 regardless of host architecture. The apt packages this
# image installs (ghdl-llvm, libllvm18) are only usable here via a hardcoded
# x86_64 library symlink below; on an Apple Silicon host, a plain
# `docker build` without this pin targets the native arm64 image, where that
# symlink's source path doesn't exist and the RUN step fails. This matches
# the rest of the project anyway -- Quartus (Dockerfile.quartus) requires
# amd64 already (see the Rosetta 2 bss_size overflow note in git history).
FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Core tool deps
# ghdl-llvm provides the LLVM-backend ghdl needed for 'ghdl synth --out=verilog'.
# The Ubuntu 24.04 apt package 'ghdl' uses the mcode backend only (no synthesis).
RUN apt-get update && apt-get install -y --no-install-recommends \
    iverilog \
    ghdl-llvm \
    libllvm18 \
    verilator \
    git \
    make \
    python3 \
    python3-pip \
    wget \
    curl \
    ca-certificates \
    xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/lib/x86_64-linux-gnu/libLLVM.so.18.1 \
             /usr/lib/x86_64-linux-gnu/libLLVM-18.so.18.1

# Go 1.23 — jtframe go.mod requires >= 1.22, toolchain 1.23.4
# Auto-detect arch so this works on both x86_64 and Apple Silicon.
ARG GO_VERSION=1.23.5
RUN ARCH=$(dpkg --print-architecture) && \
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -O /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm /tmp/go.tgz
ENV PATH="/usr/local/go/bin:${PATH}"

# JTROOT layout:
#   /workspace                 <- entire sftm repo (bind-mounted; IS a git repo)
#   /workspace/modules/jtframe <- named Docker volume (shadows empty host modules/)
ENV JTROOT=/workspace
ENV JTFRAME=/workspace/modules/jtframe
ENV CORES=/workspace/cores
ENV MODULES=/workspace/modules
ENV JTBIN=/workspace/jtbin
ENV ROM=/workspace/rom
ENV MRA=/workspace/jtbin/mra
ENV TARGET=mister
ENV PATH="/workspace/modules/jtframe/bin:${PATH}"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
