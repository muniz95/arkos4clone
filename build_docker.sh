#!/usr/bin/env bash
set -euo pipefail

# Runs build_image.sh inside a Docker container so no build tooling
# (parted, resize2fs, btrfs-progs, Go, rsync, xz, ...) needs to be
# installed on the host.
#
# The container still runs --privileged: loop-device mounting and
# partition resizing require real kernel block-device access that
# cannot be virtualized away, so this does not remove the need for
# elevated privileges -- it only removes the need to install anything
# on the host besides Docker itself.
#
# Usage:
#   ./build_docker.sh <source_image> [work_dir] [--ci]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_TAG="arkos4clone-builder"

RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <source_image> [work_dir] [--ci]"
  exit 1
fi

SOURCE_IMAGE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORK_DIR="${2:-$SCRIPT_DIR/work}"
CI_FLAG="${3:-}"

if [[ ! -f "$SOURCE_IMAGE" ]]; then
  log_error "Source image not found: $SOURCE_IMAGE"
  exit 1
fi

mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  log_error "Docker is required but not found on this host."
  exit 1
fi

log_info "Building builder image ($IMAGE_TAG)..."
sudo docker build -t "$IMAGE_TAG" "$SCRIPT_DIR"

log_info "Running build inside container (--privileged, required for loop/mount/parted)..."
sudo docker run --rm -it \
  --privileged \
  -v "$SCRIPT_DIR":/workspace \
  -v "$SOURCE_IMAGE":/input/"$(basename "$SOURCE_IMAGE")":ro \
  -v "$WORK_DIR":/work \
  -w /workspace \
  "$IMAGE_TAG" \
  -c "./build_image.sh /input/$(basename "$SOURCE_IMAGE") /work $CI_FLAG"
