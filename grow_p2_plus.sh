#!/usr/bin/env bash
set -euo pipefail

# ============ Configuration ============
# Quiet mode when ARKOS_QUIET=1 (passed in by build_image.sh --ci)
if [[ "${ARKOS_QUIET:-}" == "1" ]]; then
  RSYNC_PROGRESS="--quiet"
else
  RSYNC_PROGRESS="--info=progress2"
fi
ADD_MB=2536                   # Extra capacity (MiB); currently about +2.48 GiB
# Temp directory prefers ARKOS_WORK_DIR, otherwise uses the current directory
WORK_BASE="${ARKOS_WORK_DIR:-$(pwd)}"
TMP_DIR="${WORK_BASE}/tmp"    # Backup/restore directory; the script creates it and deletes it when done
# The P3 filesystem type and label are auto-detected from the original p3
# =======================================

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <image file path>"
  exit 1
fi
IMG="$1"
[[ -f "$IMG" ]] || { echo "Image not found: $IMG"; exit 1; }

# Runtime resources (mount points, etc.)
P3_OLD_MNT="$(mktemp -d -t p3_old.XXXXXX)"
P3_NEW_MNT="$(mktemp -d -t p3_new.XXXXXX)"
LOOP=""

settle() {
  # Wait for the kernel/udev to create device nodes; fall back to sleep on systems without udev (e.g. WSL)
  if command -v udevadm >/dev/null 2>&1; then
    sudo udevadm settle || true
  else
    sleep 1
  fi
  # In environments without a udev daemon (e.g. Docker containers, where /dev is a
  # separate tmpfs), the kernel creates the partitions in sysfs but does not create
  # the matching device nodes in /dev, so we fall back to mknod'ing them from sysfs
  if [[ -n "${LOOP:-}" ]]; then
    local loop_name sys_dir part dev_t major minor
    loop_name="$(basename "$LOOP")"
    sys_dir="/sys/class/block/${loop_name}"
    if [[ -d "$sys_dir" ]]; then
      for part in "$sys_dir"/"${loop_name}"p*; do
        [[ -d "$part" ]] || continue
        local node="/dev/$(basename "$part")"
        dev_t="$(cat "$part/dev" 2>/dev/null)" || continue
        major="${dev_t%:*}"; minor="${dev_t#*:}"
        # The node may already exist but point at a stale major:minor (e.g. the kernel
        # reassigned the numbers after the loop device was re-attached), so compare and
        # recreate it when it does not match
        if [[ -b "$node" ]]; then
          local cur_rdev
          cur_rdev="$(stat -c '%t:%T' "$node" 2>/dev/null)"
          if [[ "$cur_rdev" == "$(printf '%x:%x' "$major" "$minor")" ]]; then
            continue
          fi
          sudo rm -f "$node"
        fi
        sudo mknod "$node" b "$major" "$minor" 2>/dev/null || true
      done
    fi
  fi
}

cleanup() {
  set +e
  mountpoint -q "$P3_OLD_MNT" && sudo umount "$P3_OLD_MNT"
  mountpoint -q "$P3_NEW_MNT" && sudo umount "$P3_NEW_MNT"
  [[ -d "$P3_OLD_MNT" ]] && rmdir "$P3_OLD_MNT" || true
  [[ -d "$P3_NEW_MNT" ]] && rmdir "$P3_NEW_MNT" || true
  # Clean up the temporary btrfs mount point
  local btrfs_mnt="${WORK_BASE:-$(pwd)}/btrfs_resize"
  if [[ -d "$btrfs_mnt" ]]; then
    mountpoint -q "$btrfs_mnt" && sudo umount -l "$btrfs_mnt"
    sudo rmdir "$btrfs_mnt" 2>/dev/null
  fi
  # Detach the current loop device
  if [[ -n "${LOOP:-}" ]] && losetup -a | grep -q "^$LOOP:"; then
    sudo losetup -d "$LOOP" || true
  fi
}
trap cleanup EXIT

# Detach any loop devices already mapped to this image (if any)
echo "== Detaching old loop devices (if any) =="
while read -r dev; do
  [[ -n "$dev" ]] && sudo losetup -d "$dev" || true
done < <(losetup -j "$IMG" | cut -d: -f1)

# Map the image to a loop device (with partition scanning enabled); atomically returns the unique device name
echo "== Mapping image to a loop device (with partitions) =="
LOOP="$(sudo losetup --find --show -P "$IMG")"
settle
echo "Using loop device: $LOOP"

# Clean up any leftover mount points (the device may be mounted by another process)
echo "== Cleaning up leftover mount points =="
for part in "${LOOP}p1" "${LOOP}p2" "${LOOP}p3"; do
  if [[ -b "$part" ]]; then
    while read -r mnt; do
      [[ -n "$mnt" ]] && sudo umount -l "$mnt" 2>/dev/null || true
    done < <(findmnt -n -o TARGET "$part" 2>/dev/null || true)
  fi
done

# Sector information
SECTOR_SIZE="$(sudo blockdev --getss "$LOOP")"  # commonly 512
ADD_BYTES=$(( ADD_MB * 1024 * 1024 ))
ADD_SECTORS=$(( ADD_BYTES / SECTOR_SIZE ))

# Helper: check whether p3 exists (machine-readable mode)
has_p3() {
  sudo parted -sm "$LOOP" unit s print | grep -qE '^3:'
}

# Read the p2 end sector (machine-readable output is more reliable)
CUR_END="$(sudo parted -sm "$LOOP" unit s print | awk -F: '$1=="2"{gsub(/s/,"",$3); print $3}')"
[[ -n "${CUR_END:-}" ]] || { echo "Could not read partition 2 information, exiting."; exit 1; }
echo "Current p2 End: $CUR_END"
echo "Sector size: ${SECTOR_SIZE} B, sectors to add: ${ADD_SECTORS}"

# ======= Step 1: back up p3 to TMP_DIR (if it exists) =======
if has_p3; then
  echo "p3 detected, backing it up to $TMP_DIR"
  mkdir -p "$TMP_DIR"
  P3_DEV="${LOOP}p3"

  # Auto-detect the original p3 filesystem type and label
  ORIG_P3_FS="$(sudo blkid -s TYPE -o value "$P3_DEV" 2>/dev/null || echo 'vfat')"
  ORIG_P3_LABEL="$(sudo blkid -s LABEL -o value "$P3_DEV" 2>/dev/null || echo 'EASYROMS')"
  echo "Original p3 filesystem: $ORIG_P3_FS, label: $ORIG_P3_LABEL"

  echo "Mounting old p3 at $P3_OLD_MNT (read-only preferred)"
  if ! sudo mount -o ro "$P3_DEV" "$P3_OLD_MNT"; then
    echo "Read-only mount failed, trying a normal mount"
    sudo mount "$P3_DEV" "$P3_OLD_MNT"
  fi

  echo "Backing up p3 -> $TMP_DIR (rsync -aH --delete, so tmp is an exact mirror)"
  sudo rsync -aH --delete $RSYNC_PROGRESS "$P3_OLD_MNT"/ "$TMP_DIR"/

  echo "Unmounting the old p3 mount point"
  sudo umount "$P3_OLD_MNT"
else
  echo "No p3 found, skipping the backup."
  # Set defaults (used when creating a new p3)
  ORIG_P3_FS="exfat"
  ORIG_P3_LABEL="EASYROMS"
  echo "Creating p3 with defaults: filesystem=$ORIG_P3_FS, label=$ORIG_P3_LABEL"
fi

# ======= Step 2: delete the p3 partition (required to clear the way) =======
echo "== Deleting the old partition 3 =="
if sudo parted -s "$LOOP" rm 3 2>/dev/null; then
  echo "p3 deleted (if it existed)"
else
  echo "Could not delete p3 (it may not have existed), continuing."
fi

# Verify again; abort if p3 still exists
if has_p3; then
  echo "Error: p3 still exists, cannot continue resizing. Check the partition table and retry."
  sudo parted "$LOOP" unit s print || true
  exit 1
fi

# ======= Step 3: grow the image file and expand p2 =======
echo "== Growing the image by +${ADD_MB}MiB =="
truncate -s +"${ADD_MB}"M "$IMG"

echo "== Refreshing the loop device size =="
sudo losetup -d "$LOOP"
LOOP="$(sudo losetup --find --show -P "$IMG")"
settle
echo "Loop device refreshed: $LOOP"

# Re-read the p2 End (in case a parted/kernel refresh changed the boundary)
CUR_END="$(sudo parted -sm "$LOOP" unit s print | awk -F: '$1=="2"{gsub(/s/,"",$3); print $3}')"
[[ -n "${CUR_END:-}" ]] || { echo "Could not read partition 2 information after the refresh, exiting."; exit 1; }
NEW_END=$(( CUR_END + ADD_SECTORS ))
echo "Extending the p2 end sector to: $NEW_END"

echo "== Extending p2 to the given sector (not 100%) =="
sudo parted -s "$LOOP" unit s "resizepart 2 ${NEW_END}s"
sudo partprobe "$LOOP" || true
settle

echo "== Growing the filesystem inside p2 (auto-detects ext4 / f2fs) =="
P2_DEV="${LOOP}p2"
P2_FS="$(blkid -s TYPE -o value "$P2_DEV" || true)"
case "$P2_FS" in
  ext4|"")
    sudo e2fsck -fy "$P2_DEV"
    sudo resize2fs "$P2_DEV"
    ;;
  f2fs)
    sudo fsck.f2fs -f "$P2_DEV" || true
    sudo resize.f2fs "$P2_DEV"
    ;;
  btrfs)
    # Use a fixed mount point under the work directory to keep things clean
    P2_MNT="${WORK_BASE}/btrfs_resize"
    sudo mkdir -p "$P2_MNT"
    # Make sure any existing mount is unmounted
    sudo umount -l "$P2_MNT" 2>/dev/null || true
    sudo umount -l "$P2_DEV" 2>/dev/null || true
    # Clear the btrfs kernel device cache (critical!)
    echo "Clearing the btrfs device cache..."
    sudo btrfs device scan --forget 2>/dev/null || true
    # Mount and resize
    sudo mount -t btrfs "$P2_DEV" "$P2_MNT"
    sudo btrfs filesystem resize max "$P2_MNT"
    sudo umount "$P2_MNT"
    sudo rmdir "$P2_MNT" 2>/dev/null || true
    ;;
  *)
    echo "Warning: unknown/unsupported p2 filesystem type: $P2_FS"
    echo "Please expand the p2 filesystem manually before continuing."
    ;;
esac

# ======= Step 4: recreate p3 (from just after p2 to the end of the disk) =======
echo "== Computing the new p3 start sector (p2 End + 1) =="
P2_END_NOW="$(sudo parted -sm "$LOOP" unit s print | awk -F: '$1=="2"{gsub(/s/,"",$3); print $3}')"
[[ -n "${P2_END_NOW:-}" ]] || { echo "Could not read the latest p2 End, exiting."; exit 1; }
P3_START=$(( P2_END_NOW + 1 ))
echo "p2 End: $P2_END_NOW"
echo "p3 Start: $P3_START"

echo "== Recreating p3 at the end of the disk =="
sudo parted -s "$LOOP" unit s "mkpart primary ${P3_START}s 100%"
sudo partprobe "$LOOP" || true
settle

echo "== Formatting the new p3 =="
P3_DEV="${LOOP}p3"
echo "Using filesystem: $ORIG_P3_FS, label: $ORIG_P3_LABEL"
case "$ORIG_P3_FS" in
  vfat|fat32|fat16)
    sudo mkfs.vfat -F 32 -n "$ORIG_P3_LABEL" "$P3_DEV"
    ;;
  ntfs)
    sudo mkfs.ntfs -F -L "$ORIG_P3_LABEL" "$P3_DEV"
    ;;
  exfat)
    sudo mkfs.exfat -n "$ORIG_P3_LABEL" "$P3_DEV"
    ;;
  *)
    echo "Warning: unknown filesystem type $ORIG_P3_FS, falling back to exfat"
    sudo mkfs.exfat -n "$ORIG_P3_LABEL" "$P3_DEV"
    ;;
esac

# ======= Step 5: restore the data (exact mirror) =======
if [[ -d "$TMP_DIR" ]] && [[ -n "$(ls -A "$TMP_DIR" 2>/dev/null || true)" ]]; then
  echo "== Restoring data (exact mirror): $TMP_DIR -> new p3 =="
  sudo mount "$P3_DEV" "$P3_NEW_MNT"
  # FAT32/exFAT do not support Unix permissions, so use --no-perms --no-owner --no-group
  case "$ORIG_P3_FS" in
    vfat|fat32|fat16|exfat)
      sudo rsync -rltD --no-perms --no-owner --no-group --delete $RSYNC_PROGRESS "$TMP_DIR"/ "$P3_NEW_MNT"/
      ;;
    *)
      sudo rsync -aH --delete $RSYNC_PROGRESS "$TMP_DIR"/ "$P3_NEW_MNT"/
      ;;
  esac
  sync
  sudo umount "$P3_NEW_MNT"
  echo "Restore complete."
else
  echo "No backup content found, skipping the restore."
fi

# ======= Step 6: optional verification output =======
echo "== Final partition layout (MiB) =="
sudo parted "$LOOP" unit MiB print || true

# ======= Step 7: remove tmp and detach the loop device =======
echo "== Removing the backup directory $TMP_DIR =="
sudo rm -rf "$TMP_DIR"

echo "== Detaching the loop device =="
sudo losetup -d "$LOOP" || true
LOOP=""

echo "✅ Done, in order: [back up p3 -> delete p3 -> expand p2 -> recreate p3 -> restore -> clean tmp -> detach loop]"
