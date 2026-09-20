# Build environment for arkos4clone image assembly.
# Provides every host tool build_image.sh needs (loop/parted/fs-resize
# utilities, rsync, xz, Go for dtb_selector, JDK build deps) so nothing has
# to be installed on the host. Must still be run --privileged (see
# build_docker.sh) because loop-device mounting and partition resizing
# require real kernel block-device access that a container cannot fake.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    wget \
    curl \
    unzip \
    xz-utils \
    rsync \
    parted \
    util-linux \
    e2fsprogs \
    f2fs-tools \
    btrfs-progs \
    dosfstools \
    exfatprogs \
    ntfs-3g \
    kmod \
    udev \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Debian bookworm's golang-go package (1.19) is too old for build_dtb_selector.sh's
# macOS build step (pulls in a module requiring the Go 1.23+ "iter" package), so
# install a current upstream toolchain instead.
ARG GO_VERSION=1.23.4
RUN ARCH="$(dpkg --print-architecture)" && \
    case "$ARCH" in \
      amd64) GOARCH=amd64 ;; \
      arm64) GOARCH=arm64 ;; \
      *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; \
    esac && \
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -O /tmp/go.tar.gz && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && \
    rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"

WORKDIR /workspace

ENTRYPOINT ["/bin/bash"]
