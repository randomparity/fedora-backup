#!/usr/bin/env bats

@test "fbackup-init --help exits 0 and documents usage" {
  run bin/fbackup-init --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"fbackup-init"* ]]
}

@test "fbackup-init is shellcheck-clean" {
  run shellcheck -x bin/fbackup-init
  [ "$status" -eq 0 ]
}

@test "fbackup --help exits 0" {
  run bin/fbackup --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "fbackup is shellcheck-clean" {
  run shellcheck -x bin/fbackup
  [ "$status" -eq 0 ]
}

@test "fbackup --dry-run plans snapshot, send/receive, tar, and manifest" {
  load helpers/stubs
  setup_stubs
  cfg="$STUB_DIR/backup.conf"
  cat >"$cfg" <<EOF
BACKUP_DEV=/dev/x
BACKUP_LABEL=fedora-backup
BACKUP_MNT=$STUB_DIR/backup
SRC_TOPLEVEL_MNT=$STUB_DIR/top
SUBVOLS=(root home)
SNAP_DIR=_snapshots
BOOT_MNT=/boot
EFI_MNT=/boot/efi
RETENTION_KEEP=3
HOSTNAME_TAG=host
EOF
  mkdir -p "$STUB_DIR/backup/host/subvols/root" "$STUB_DIR/backup/host/subvols/home" "$STUB_DIR/backup/host/manifests" "$STUB_DIR/top/_snapshots"
  for c in btrfs tar mount umount mkdir sync findmnt rpm zstd; do make_stub "$c"; done
  run env DRY_RUN=1 FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/fbackup
  teardown_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] btrfs send"* ]]
  [[ "$output" == *"receive"* ]]
  [[ "$output" == *"[DRY-RUN] umount $STUB_DIR/top"* ]]
  [[ "$output" == *"[DRY-RUN] umount $STUB_DIR/backup"* ]]
}
