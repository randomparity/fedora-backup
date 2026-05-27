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

@test "fsnapshot-preupgrade --help exits 0" {
  run bin/fsnapshot-preupgrade --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "fsnapshot-preupgrade is shellcheck-clean" {
  run shellcheck -x bin/fsnapshot-preupgrade
  [ "$status" -eq 0 ]
}

@test "fupgrade --help lists subcommands" {
  run bin/fupgrade --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"preflight"* ]]
  [[ "$output" == *"download"* ]]
  [[ "$output" == *"apply"* ]]
}

@test "fupgrade is shellcheck-clean" {
  run shellcheck -x bin/fupgrade
  [ "$status" -eq 0 ]
}

@test "fupgrade rejects an unknown subcommand" {
  run bin/fupgrade frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown subcommand"* ]]
}

@test "frestore --help exits 0 and warns about live environment" {
  run bin/frestore --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"live"* || "$output" == *"rescue"* ]]
}

@test "frestore is shellcheck-clean" {
  run shellcheck -x bin/frestore
  [ "$status" -eq 0 ]
}

@test "frestore dry-run receives all subvols and canonicalizes, skips boot without --boot-dir" {
  load helpers/stubs
  setup_stubs
  for c in btrfs tar mount umount mkdir findmnt; do make_stub "$c"; done
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
  run env FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/frestore --snapshot root.20260527T143000Z
  teardown_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] btrfs send $STUB_DIR/backup/host/subvols/root/root.20260527T143000Z"* ]]
  [[ "$output" == *"[DRY-RUN] btrfs send $STUB_DIR/backup/host/subvols/home/home.20260527T143000Z"* ]]
  [[ "$output" == *"[DRY-RUN] btrfs subvolume snapshot"* ]]
  # No --boot-dir: must NOT extract into the live /boot
  [[ "$output" != *"-C /boot "* ]]
}

@test "frestore extracts boot archives only into the provided --boot-dir/--efi-dir" {
  load helpers/stubs
  setup_stubs
  for c in btrfs tar mount umount mkdir findmnt; do make_stub "$c"; done
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
  run env FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/frestore \
    --snapshot root.20260527T143000Z --boot-dir "$STUB_DIR/nb" --efi-dir "$STUB_DIR/ne"
  teardown_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"-C $STUB_DIR/nb"* ]]
  [[ "$output" == *"-C $STUB_DIR/ne"* ]]
}

@test "fsnapshot-preupgrade --dry-run does not write the local stash" {
  load helpers/stubs
  setup_stubs
  # Stub everything EXCEPT mkdir, so that without the fix a real mkdir would
  # create the stash dir (the bug), and with the fix DRY_RUN skips it.
  for c in tar findmnt btrfs mount umount sync rpm zstd; do make_stub "$c"; done
  stash="$STUB_DIR/stash"
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
  run env FBACKUP_CONFIG="$cfg" LOCAL_BOOT_STASH="$stash" SKIP_ROOT_CHECK=1 bin/fsnapshot-preupgrade --dry-run
  # Check before teardown_stubs removes STUB_DIR (which would hide the bug).
  local stash_created=0
  [ -d "$stash" ] && stash_created=1
  teardown_stubs
  [ "$status" -eq 0 ]
  [ "$stash_created" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
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
