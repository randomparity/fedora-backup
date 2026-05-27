# shellcheck shell=bash
# Backup target preparation: guard checks and formatting.
[[ -n "${_FB_BACKUP_TARGET_SH:-}" ]] && return 0
_FB_BACKUP_TARGET_SH=1

# target_guard <device> : refuse if device already has a filesystem, unless FORCE=1.
target_guard() {
  local dev="$1"
  if blkid "$dev" >/dev/null 2>&1; then
    if [[ "${FORCE:-0}" != "1" ]]; then
      die "device $dev already contains a filesystem; set FORCE=1 to wipe it"
    fi
    log_warn "device $dev already contains a filesystem; FORCE=1 set, will wipe"
  fi
  return 0
}

# target_format <device> <label> : create a btrfs filesystem.
# -K (--nodiscard) skips the whole-device TRIM. The default TRIM floods the USB
# bridge with discard/UNMAP commands, which wedges flaky UAS bridges such as the
# SanDisk PRO-G40 (it drops to 0 capacity mid-discard and mkfs fails with
# "Operation not permitted"). The TRIM is only an SSD pre-clean optimization, so
# dropping it costs nothing for correctness.
target_format() {
  run mkfs.btrfs -f -K -L "$2" "$1"
}
