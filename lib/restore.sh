# shellcheck shell=bash
# Restore primitives used by disaster recovery (bin/frestore).
[[ -n "${_FB_RESTORE_SH:-}" ]] && return 0
_FB_RESTORE_SH=1

# restore_receive <target_subvol_dir> <snap_name> <dest_toplevel>
# Streams a snapshot stored on the backup target back to a destination btrfs.
restore_receive() {
  local target_dir="$1" snap="$2" dest="$3"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '[DRY-RUN] btrfs send %s | btrfs receive %s\n' \
      "$target_dir/$snap" "$dest" >&2
    return 0
  fi
  btrfs send "$target_dir/$snap" | btrfs receive "$dest" ||
    die "restore receive failed for $snap"
}

# restore_boot <tarball> <mountpoint> : extract a boot/efi archive, preserving metadata.
restore_boot() {
  run tar --xattrs --acls -xpf "$1" -C "$2"
}

# restore_canonicalize <dest_toplevel> <snap_name> <subvol>
# Create a writable canonical subvolume from the received read-only snapshot.
restore_canonicalize() {
  run btrfs subvolume snapshot "$1/$2" "$1/$3"
}
