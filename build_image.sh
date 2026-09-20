#!/usr/bin/env bash
set -euo pipefail

# ArkOS4Clone one-click build script
# Usage: sudo ./build_image.sh <image path> [work directory]
# The work directory holds the image copy and intermediate files; ext4 is recommended for best performance

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Timestamp format (matches clone_support.sh)
BUILD_DATE="$(TZ=Asia/Shanghai date +%m%d%Y)"
OUTPUT_NAME="ArkOS4Clone-${BUILD_DATE}"

# Colored output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    log_error "Please run this script with sudo"
    exit 1
  fi
}

check_image() {
  local img="$1"
  if [[ ! -f "$img" ]]; then
    log_error "Image file does not exist: $img"
    exit 1
  fi
  if [[ ! -r "$img" ]]; then
    log_error "Cannot read image file: $img"
    exit 1
  fi
  log_ok "Source image: $img"
}

check_tools() {
  local tools=(losetup mount umount parted rsync dd xz)
  for t in "${tools[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      log_error "Missing tool: $t"
      exit 1
    fi
  done
  log_ok "Required tools check passed"
}

check_uboot_files() {
  local uboot_dir="$SCRIPT_DIR/uboot"
  local files=("idbloader.img" "uboot.img" "trust.img" "flash_uboot.sh")
  for f in "${files[@]}"; do
    if [[ ! -f "$uboot_dir/$f" ]]; then
      log_error "Missing U-Boot file: $uboot_dir/$f"
      exit 1
    fi
  done
  log_ok "U-Boot files check passed"
}

check_jdk_file() {
  local jdk_file="zulu11.48.21-ca-jdk11.0.11-linux_aarch64.tar.gz"
  local jdk_url="https://cdn.azul.com/zulu-embedded/bin/zulu11.48.21-ca-jdk11.0.11-linux_aarch64.tar.gz"
  
  if [[ -f "$SCRIPT_DIR/$jdk_file" ]]; then
    log_ok "JDK file already present: $jdk_file"
    return
  fi
  
  log_info "Downloading JDK file..."
  # Download as the original user (avoids permission problems)
  if [[ -n "${SUDO_USER:-}" ]]; then
    if sudo -u "$SUDO_USER" wget $WGET_OPTS -O "$SCRIPT_DIR/$jdk_file" "$jdk_url"; then
      log_ok "JDK download complete: $jdk_file"
    else
      log_error "JDK download failed"
      sudo -u "$SUDO_USER" rm -f "$SCRIPT_DIR/$jdk_file" 2>/dev/null || true
      exit 1
    fi
  else
    if wget $WGET_OPTS -O "$SCRIPT_DIR/$jdk_file" "$jdk_url"; then
      log_ok "JDK download complete: $jdk_file"
    else
      log_error "JDK download failed"
      rm -f "$SCRIPT_DIR/$jdk_file" 2>/dev/null || true
      exit 1
    fi
  fi
}

check_pm_libs() {
  local pm_libs_dir="$SCRIPT_DIR/bin/pm_libs"
  local runtimes_url="https://github.com/PortsMaster/PortMaster-New/releases/download/2026-08-05_0732/runtimes.all.aarch64.zip"

  # List of required files
  local required_files=(
    "ags_3.6.squashfs"
    "dotnet-8.0.12.squashfs"
    "frt_2.1.6.squashfs"
    "frt_3.0.6_v1.squashfs"
    "frt_3.1.2.squashfs"
    "frt_3.2.3.squashfs"
    "frt_3.3.4.squashfs"
    "frt_3.4.5.squashfs"
    "frt_3.5.2.squashfs"
    "frt_3.5.3.squashfs"
    "frt_3.6.squashfs"
    "frt_4.0.4.squashfs"
    "frt_4.1.3.squashfs"
    "gmtoolkit.squashfs"
    "godot_4.2.2.mono.squashfs"
    "godot_4.2.2.squashfs"
    "godot_4.3.mono.squashfs"
    "godot_4.3.squashfs"
    "godot_4.4.1.mono.squashfs"
    "godot_4.4.1.squashfs"
    "godot_4.4.mono.squashfs"
    "godot_4.4.squashfs"
    "godot_4.5.mono.squashfs"
    "godot_4.5.squashfs"
    "godot_4.6.3.mono.squashfs"
    "godot_4.6.3.squashfs"
    "godot_4.7.1.mono.squashfs"
    "godot_4.7.1.squashfs"
    "mesa_pkg_0.1.squashfs"
    "mono-6.12.0.122-aarch64.squashfs"
    "python_3.11.squashfs"
    "pyxel_2.2.8_python_3.11.squashfs"
    "pyxel_2.3.18_python_3.11.squashfs"
    "pyxel_2.4.6_python_3.11.squashfs"
    "pyxel_2.9.5_python_3.11.squashfs"
    "renpy_8.1.3.squashfs"
    "renpy_8.3.4.squashfs"
    "rlvm.squashfs"
    "solarus-1.6.5.squashfs"
    "weston_pkg_0.2.squashfs"
    "zulu11.48.21-ca-jdk11.0.11-linux.squashfs"
    "zulu17.48.15-ca-jdk17.0.10-linux.squashfs"
    "zulu17.54.21-ca-jre17.0.13-linux.squashfs"
    "zulu23.32.11-ca-jre23.0.2-linux.squashfs"
    "zulu8.86.0.25-ca-jdk8.0.452-linux.squashfs"
  )

  # Check whether the directory exists
  if [[ ! -d "$pm_libs_dir" ]]; then
    mkdir -p "$pm_libs_dir"
  fi

  # Check for missing files
  local missing=0
  for f in "${required_files[@]}"; do
    if [[ ! -f "$pm_libs_dir/$f" ]]; then
      missing=1
      break
    fi
  done

  if [[ $missing -eq 0 ]]; then
    log_ok "pm_libs files are complete"
    return
  fi

  log_info "Downloading PortMaster runtimes (about 1.6GB)..."
  local zip_file="$pm_libs_dir/runtimes.zip"

  # Download
  if [[ -n "${SUDO_USER:-}" ]]; then
    if sudo -u "$SUDO_USER" wget $WGET_OPTS -O "$zip_file" "$runtimes_url"; then
      log_ok "runtimes download complete"
    else
      log_error "runtimes download failed"
      sudo -u "$SUDO_USER" rm -f "$zip_file" 2>/dev/null || true
      exit 1
    fi
    # Extract
    log_info "Extracting runtimes..."
    sudo -u "$SUDO_USER" unzip -o -q "$zip_file" -d "$pm_libs_dir"
    sudo -u "$SUDO_USER" rm -f "$zip_file"
  else
    if wget $WGET_OPTS -O "$zip_file" "$runtimes_url"; then
      log_ok "runtimes download complete"
    else
      log_error "runtimes download failed"
      rm -f "$zip_file" 2>/dev/null || true
      exit 1
    fi
    # Extract
    log_info "Extracting runtimes..."
    unzip -o -q "$zip_file" -d "$pm_libs_dir"
    rm -f "$zip_file"
  fi

  log_ok "pm_libs files are ready"
}

check_work_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    log_info "Creating work directory: $dir"
    mkdir -p "$dir"
  fi
  # Check that it is writable
  if [[ ! -w "$dir" ]]; then
    log_error "Work directory is not writable: $dir"
    exit 1
  fi
  log_ok "Work directory: $dir"
}

check_portmaster() {
  local pm_dir="$SCRIPT_DIR/PortMaster"
  local pm_url="https://github.com/PortsMaster/PortMaster-GUI/releases/download/2026.07.28-1212/PortMaster.zip"

  if [[ -d "$pm_dir" && -f "$pm_dir/PortMaster.sh" ]]; then
    log_ok "PortMaster directory already exists"
    return
  fi

  log_info "Downloading PortMaster..."
  local zip_file="$SCRIPT_DIR/PortMaster.zip"

  if [[ -n "${SUDO_USER:-}" ]]; then
    if sudo -u "$SUDO_USER" wget $WGET_OPTS -O "$zip_file" "$pm_url"; then
      log_ok "PortMaster download complete"
    else
      log_error "PortMaster download failed"
      sudo -u "$SUDO_USER" rm -f "$zip_file" 2>/dev/null || true
      exit 1
    fi
    log_info "Extracting PortMaster..."
    sudo -u "$SUDO_USER" unzip -q -o "$zip_file" -d "$SCRIPT_DIR"
    sudo -u "$SUDO_USER" rm -f "$zip_file"
  else
    if wget $WGET_OPTS -O "$zip_file" "$pm_url"; then
      log_ok "PortMaster download complete"
    else
      log_error "PortMaster download failed"
      rm -f "$zip_file" 2>/dev/null || true
      exit 1
    fi
    log_info "Extracting PortMaster..."
    unzip -q -o "$zip_file" -d "$SCRIPT_DIR"
    rm -f "$zip_file"
  fi

  log_ok "PortMaster is ready"
}

check_clone_dependencies() {
  log_info "Checking clone_support.sh dependencies..."
  local missing=0
  local missing_list=""

  # Check required directories
  local dirs=(
    "consoles"
    "bin"
    "bin/aic8800DC"
    "bin/json-c3"
    "mod_so/32"
    "mod_so/64"
    "replace_file"
    "replace_file/drastic"
    "replace_file/drastic-kk"
    "replace_file/onscripter"
    "replace_file/retroarch"
    "replace_file/ppsspp"
    "replace_file/flycastsa"
    "replace_file/freej2mesa"
    "replace_file/rufflesa"
    "replace_file/gametank"
    "replace_file/pymo"
    "replace_file/resources"
    "replace_file/retrorun"
    "replace_file/scummvm"
    "replace_file/services"
    "replace_file/yabasanshiro"
    "replace_file/tools"
    "replace_file/351Files"
    "sh"
    "Jason3_Scripte"
    "Jason3_Scripte/Bluetooth-Manager"
    "Jason3_Scripte/GhostLoader"
    "Jason3_Scripte/InfoSystem"
    "Jason3_Scripte/wifi-toggle"
  )

  for d in "${dirs[@]}"; do
    if [[ ! -d "$SCRIPT_DIR/$d" ]]; then
      missing=1
      missing_list="$missing_list\n  Missing directory: $d"
    fi
  done

  # Check required files
  local files=(
    "dtb_selector_macos"
    "dtb_selector_win32.exe"
    "sh/clone.sh"
    "sh/expandtoexfat.sh"
    "sh/darkos-expandtoexfat.sh"
    "bin/mcu_led"
    "bin/ws2812"
    "bin/sdljoymap"
    "bin/sdljoytest"
    "bin/console_detect"
    "replace_file/351Files/351Files"
    "replace_file/es_systems.cfg"
    "replace_file/es_systems.cfg.dual"
    "replace_file/emulationstation"
    "replace_file/pymo/cpymo"
    "replace_file/pymo/pymo.sh"
    "replace_file/pymo/Scan_for_new_games.pymo"
    "replace_file/retrorun/retrorun"
    "replace_file/retrorun/retrorun32"
    "replace_file/services/351mp.service"
    "Jason3_Scripte/Bluetooth-Manager/Bluetooth Manager.sh"
    "Jason3_Scripte/Bluetooth-Manager/patch.pak"
    "Jason3_Scripte/GhostLoader/GhostLoader.sh"
    "Jason3_Scripte/InfoSystem/InfoSystem.sh"
    "Jason3_Scripte/wifi-toggle/Wifi-toggle.sh"
  )

  for f in "${files[@]}"; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
      missing=1
      missing_list="$missing_list\n  Missing file: $f"
    fi
  done

  if [[ $missing -eq 1 ]]; then
    log_error "clone_support.sh dependency check failed"
    echo -e "$missing_list"
    exit 1
  fi

  log_ok "clone_support.sh dependency check passed"
}

step_build_dtb_selector() {
  log_info "Step 0: Building the dtb_selector tool..."
  if [[ -f "$SCRIPT_DIR/build_dtb_selector.sh" ]]; then
    cd "$SCRIPT_DIR"
    # Build as the original user (preserving the PATH environment variable)
    if [[ -n "${SUDO_USER:-}" ]]; then
      if sudo -u "$SUDO_USER" env PATH="$PATH" ./build_dtb_selector.sh; then
        log_ok "dtb_selector build complete"
      else
        log_warn "dtb_selector build failed, skipping (it may already exist)"
      fi
    else
      if ./build_dtb_selector.sh; then
        log_ok "dtb_selector build complete"
      else
        log_warn "dtb_selector build failed, skipping (it may already exist)"
      fi
    fi
    cd - > /dev/null
  else
    log_warn "build_dtb_selector.sh not found, skipping"
  fi
}

copy_image() {
  local src="$1"
  local dst="$2"
  log_info "Copying the source image to the work directory..."
  cp "$src" "$dst"
  log_ok "Work copy created: $dst"
}

step_grow() {
  local img="$1"
  log_info "Step 2/7: Expanding the image partitions..."
  if "$SCRIPT_DIR/grow_p2_plus.sh" "$img"; then
    log_ok "Partition expansion complete"
  else
    log_error "Partition expansion failed"
    exit 1
  fi
}

step_flash_uboot() {
  local img="$1"
  log_info "Step 3/7: Writing U-Boot..."
  # Must run inside the uboot directory and use an absolute path
  local abs_img
  if [[ "$img" = /* ]]; then
    abs_img="$img"
  else
    abs_img="$(pwd)/$img"
  fi
  cd "$SCRIPT_DIR/uboot"
  if ./flash_uboot.sh -y -i "$abs_img"; then
    log_ok "U-Boot write complete"
  else
    log_error "U-Boot write failed"
    cd "$SCRIPT_DIR"
    exit 1
  fi
  cd "$SCRIPT_DIR"
}

step_mount() {
  local img="$1"
  log_info "Step 4/7: Mounting the image..."
  if "$SCRIPT_DIR/mount_arkos.sh" mount "$img"; then
    log_ok "Image mounted successfully"
  else
    log_error "Failed to mount the image"
    exit 1
  fi
}

step_inject() {
  log_info "Step 5/7: Injecting the customized content..."
  if "$SCRIPT_DIR/clone_support.sh"; then
    log_ok "Content injection complete"
  else
    log_error "Content injection failed"
    # Try to unmount
    "$SCRIPT_DIR/mount_arkos.sh" unmount 2>/dev/null || true
    exit 1
  fi
}

step_unmount() {
  log_info "Step 6/7: Unmounting the image..."
  if "$SCRIPT_DIR/mount_arkos.sh" unmount; then
    log_ok "Image unmounted successfully"
  else
    log_error "Failed to unmount the image"
    exit 1
  fi
}

step_compress() {
  local img="$1"
  local xz_file="${img}.xz"
  log_info "Step 7/7: Compressing the image (xz -5)..."
  
  # Compression level 5, multi-threaded
  if xz -5 -T0 -v "$img"; then
    log_ok "Compression complete: $xz_file"
    log_ok "File size: $(du -h "$xz_file" | cut -f1)"
  else
    log_error "Compression failed"
    exit 1
  fi
}

move_to_script_dir() {
  local xz_file="$1"
  local dest="$SCRIPT_DIR/$(basename "$xz_file")"
  log_info "Moving the output file to the script directory..."
  mv "$xz_file" "$dest" || true
  log_ok "Output file: $dest"
}

show_usage() {
  cat << USAGE
ArkOS4Clone one-click build script

Usage:
  sudo ./build_image.sh <source image path> [work directory] [--ci]

Arguments:
  source image path   Required. Path to the original ArkOS image file.
  work directory      Optional. Holds the image copy and intermediate files.
                      ext4 is recommended for best performance.
                      Default: the directory containing the source image.
  --ci                Optional. Quiet mode; reduces noisy logs such as download progress.

Environment variables:
  ARKOS_MNT       Mount path (default: <work directory>/mnt)
  ARKOS_WORK_DIR  Temporary work directory (default: <work directory>)

Examples:
  # Use the default work directory (the directory containing the source image)
  sudo ./build_image.sh /path/to/ArkOS-*.img

  # Specify a work directory (recommended, on an ext4 filesystem)
  sudo ./build_image.sh /mnt/e/ArkOS.img /home/lcdyk/arkos

Steps performed:
  0. Build the dtb_selector tool (build_dtb_selector.sh)
  1. Copy the source image to the work directory
  2. Expand the image partitions (grow_p2_plus.sh)
  3. Write U-Boot (flash_uboot.sh)
  4. Mount the image (mount_arkos.sh mount)
  5. Inject the customized content (clone_support.sh)
  6. Unmount the image (mount_arkos.sh unmount)
  7. Compress to xz format (level 5)
  8. Move the output file to the script directory

Output:
  <script directory>/ArkOS4Clone-MMDDYYYY.img.xz

Notes:
  - The source image file is never modified.
  - An ext4 work directory is recommended; avoid WSL /mnt paths for better performance.

USAGE
}

main() {
  # Check for root privileges first
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    log_error "Please run this script with sudo"
    exit 1
  fi

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
  fi

  if [[ $# -lt 1 ]]; then
    log_error "Missing argument: image path"
    echo ""
    show_usage
    exit 1
  fi

  local source_image="$1"
  
  # Determine the work directory
  local work_dir
  if [[ $# -ge 2 ]]; then
    work_dir="$2"
  else
    # Default to the directory containing the source image
    work_dir="$(cd "$(dirname "$source_image")" && pwd)"
  fi
  
  # Convert to an absolute path
  if [[ "$work_dir" != /* ]]; then
    work_dir="$(pwd)/$work_dir"
  fi

  # Set environment variables
  ARKOS_MNT="${ARKOS_MNT:-${work_dir}/mnt}"
  ARKOS_WORK_DIR="${ARKOS_WORK_DIR:-${work_dir}}"
  ARKOS_IMAGE_NAME="$(basename "$source_image")"
  export ARKOS_MNT ARKOS_WORK_DIR ARKOS_IMAGE_NAME

  # Third argument --ci: quiet mode, reduces noisy logs in CI environments
  if [[ "${3:-}" == "--ci" ]]; then
    WGET_OPTS="-q"
    export ARKOS_QUIET=1
  else
    WGET_OPTS="-q --show-progress"
  fi

  # Choose the output prefix based on the source image name
  local output_prefix
  if [[ "$ARKOS_IMAGE_NAME" == *dArkOS* ]]; then
    output_prefix="dArkOS4Clone"
  else
    output_prefix="ArkOS4Clone"
  fi
  local work_image="${work_dir}/${output_prefix}-${BUILD_DATE}.img"

  echo "========================================"
  echo "  ArkOS4Clone one-click build script"
  echo "========================================"
  echo "Source image: $source_image"
  echo "Work dir:     $work_dir"
  echo "Work copy:    $work_image"
  echo "Mount path:   $ARKOS_MNT"
  echo "========================================"
  echo ""

  # Step 0: Build dtb_selector (does not need root)
  step_build_dtb_selector
  echo ""

  # Pre-flight checks (do not need root)
  check_tools
  check_jdk_file
  check_portmaster
  check_pm_libs
  check_clone_dependencies

  # Checks that need root
  check_image "$source_image"
  check_work_dir "$work_dir"
  check_uboot_files

  # Step 1: Copy the image
  echo ""
  copy_image "$source_image" "$work_image"

  # Run the build pipeline
  echo ""
  step_grow "$work_image"
  echo ""
  step_flash_uboot "$work_image"
  echo ""
  step_mount "$work_image"
  echo ""
  step_inject
  echo ""
  step_unmount

  # Compress and move
  echo ""
  step_compress "$work_image"
  move_to_script_dir "${work_image}.xz"

  echo ""
  echo "========================================"
  log_ok "Build complete!"
  echo "Output file: $SCRIPT_DIR/$(basename "${work_image}").xz"
  echo "Source file kept: $source_image"
  echo "========================================"
}

main "$@"
