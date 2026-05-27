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
  run env FBACKUP_CONFIG="$cfg" DEST_TOPLEVEL="$STUB_DIR/dest" SKIP_ROOT_CHECK=1 bin/frestore --snapshot root.20260527T143000Z
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
  run env FBACKUP_CONFIG="$cfg" DEST_TOPLEVEL="$STUB_DIR/dest" SKIP_ROOT_CHECK=1 bin/frestore \
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
  run env FBACKUP_CONFIG="$cfg" LOCAL_BOOT_STASH="$stash" FB_LOCK="$STUB_DIR/fb.lock" SKIP_ROOT_CHECK=1 bin/fsnapshot-preupgrade --dry-run
  # Check before teardown_stubs removes STUB_DIR (which would hide the bug).
  local stash_created=0
  [ -d "$stash" ] && stash_created=1
  teardown_stubs
  [ "$status" -eq 0 ]
  [ "$stash_created" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
}

@test "frestore --apply refuses to overwrite an existing destination subvol" {
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
  mkdir -p "$STUB_DIR/dest/root"
  for c in btrfs tar mount umount mkdir findmnt; do make_stub "$c"; done
  run env FBACKUP_CONFIG="$cfg" DEST_TOPLEVEL="$STUB_DIR/dest" SKIP_ROOT_CHECK=1 \
    bin/frestore --apply --snapshot root.20260527T143000Z
  log="$STUB_LOG"
  has_send=0; grep -q "btrfs send" "$log" && has_send=1
  has_umount=0; grep -q "umount $STUB_DIR/backup" "$log" && has_umount=1
  teardown_stubs
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has a subvolume named 'root'"* ]]
  [ "$has_send" -eq 0 ]
  [ "$has_umount" -eq 0 ]
}

@test "frestore --apply cleans the partial target and unmounts on receive failure" {
  load helpers/stubs
  setup_stubs
  # Real source snapshots so the new source pre-check passes and we still
  # exercise restore_receive's own partial cleanup. Must precede make_stub.
  mkdir -p "$STUB_DIR/backup/host/subvols/root/root.20260527T143000Z" \
    "$STUB_DIR/backup/host/subvols/home/home.20260527T143000Z"
  for c in tar mount umount mkdir; do make_stub "$c"; done
  make_stub findmnt 1
  cat >"$STUB_DIR/btrfs" <<'EOF'
#!/usr/bin/env bash
printf 'btrfs %s\n' "$*" >>"$STUB_LOG"
cat >/dev/null 2>&1 || true
[[ "$1" == "receive" ]] && exit 1
exit 0
EOF
  chmod +x "$STUB_DIR/btrfs"
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
  run env FBACKUP_CONFIG="$cfg" DEST_TOPLEVEL="$STUB_DIR/dest" SKIP_ROOT_CHECK=1 \
    bin/frestore --apply --snapshot root.20260527T143000Z
  log="$STUB_LOG"
  has_delete=0; grep -q "btrfs subvolume delete $STUB_DIR/dest/root.20260527T143000Z" "$log" && has_delete=1
  has_umount=0; grep -q "umount $STUB_DIR/backup" "$log" && has_umount=1
  teardown_stubs
  [ "$status" -ne 0 ]
  [ "$has_delete" -eq 1 ]
  [ "$has_umount" -eq 1 ]
}

@test "frestore --apply refuses when a leftover received snapshot exists" {
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
  mkdir -p "$STUB_DIR/dest/root.20260527T143000Z"
  for c in btrfs tar mount umount mkdir findmnt; do make_stub "$c"; done
  run env FBACKUP_CONFIG="$cfg" DEST_TOPLEVEL="$STUB_DIR/dest" SKIP_ROOT_CHECK=1 \
    bin/frestore --apply --snapshot root.20260527T143000Z
  log="$STUB_LOG"
  has_send=0; grep -q "btrfs send" "$log" && has_send=1
  teardown_stubs
  [ "$status" -ne 0 ]
  [[ "$output" == *"leftover from a previous run"* ]]
  [ "$has_send" -eq 0 ]
}

@test "frestore --apply refuses up front when a source snapshot is missing" {
  load helpers/stubs
  setup_stubs
  # Only root has a source snapshot; home is missing (e.g. a past fbackup
  # aborted mid-loop). Must precede make_stub (mkdir gets stubbed).
  mkdir -p "$STUB_DIR/backup/host/subvols/root/root.20260527T143000Z"
  for c in btrfs tar mount umount mkdir; do make_stub "$c"; done
  make_stub findmnt 1
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
  run env FBACKUP_CONFIG="$cfg" DEST_TOPLEVEL="$STUB_DIR/dest" SKIP_ROOT_CHECK=1 \
    bin/frestore --apply --snapshot root.20260527T143000Z
  log="$STUB_LOG"
  has_send=0
  grep -q "btrfs send" "$log" && has_send=1
  teardown_stubs
  [ "$status" -ne 0 ]
  [[ "$output" == *"source snapshot not found"* ]]
  [ "$has_send" -eq 0 ]
}

@test "frestore --apply rolls back completed subvolumes when a later subvolume fails" {
  load helpers/stubs
  setup_stubs
  # Both sources present so the pre-check passes; the counter btrfs stub then
  # fails the SECOND receive (home) after root has fully completed.
  mkdir -p "$STUB_DIR/backup/host/subvols/root/root.20260527T143000Z" \
    "$STUB_DIR/backup/host/subvols/home/home.20260527T143000Z"
  for c in tar mount umount mkdir; do make_stub "$c"; done
  make_stub findmnt 1
  cat >"$STUB_DIR/btrfs" <<'EOF'
#!/usr/bin/env bash
printf 'btrfs %s\n' "$*" >>"$STUB_LOG"
cat >/dev/null 2>&1 || true
if [[ "$1" == "receive" ]]; then
  n=$(( $(cat "$STUB_DIR/recv_n" 2>/dev/null || echo 0) + 1 ))
  echo "$n" >"$STUB_DIR/recv_n"
  [[ "$n" -ge 2 ]] && exit 1
fi
exit 0
EOF
  chmod +x "$STUB_DIR/btrfs"
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
  run env FBACKUP_CONFIG="$cfg" DEST_TOPLEVEL="$STUB_DIR/dest" SKIP_ROOT_CHECK=1 \
    bin/frestore --apply --snapshot root.20260527T143000Z
  log="$STUB_LOG"
  has_root_canon_delete=0
  grep -q "btrfs subvolume delete $STUB_DIR/dest/root$" "$log" && has_root_canon_delete=1
  has_root_snap_delete=0
  grep -q "btrfs subvolume delete $STUB_DIR/dest/root.20260527T143000Z$" "$log" && has_root_snap_delete=1
  has_umount=0
  grep -q "umount $STUB_DIR/backup" "$log" && has_umount=1
  teardown_stubs
  [ "$status" -ne 0 ]
  [ "$has_root_canon_delete" -eq 1 ]
  [ "$has_root_snap_delete" -eq 1 ]
  [ "$has_umount" -eq 1 ]
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
  for c in btrfs tar mount umount mkdir sync rpm zstd; do make_stub "$c"; done
  cat >"$STUB_DIR/findmnt" <<'EOF'
#!/usr/bin/env bash
printf 'findmnt %s\n' "$*" >>"$STUB_LOG"
for a in "$@"; do
  [[ "$a" == "SOURCE" ]] && { echo /dev/sda2; exit 0; }
done
exit 1
EOF
  chmod +x "$STUB_DIR/findmnt"
  run env DRY_RUN=1 FB_LOCK="$STUB_DIR/fb.lock" FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/fbackup
  teardown_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] btrfs send"* ]]
  [[ "$output" == *"receive"* ]]
  [[ "$output" == *"[DRY-RUN] umount $STUB_DIR/top"* ]]
  [[ "$output" == *"[DRY-RUN] umount $STUB_DIR/backup"* ]]
}

@test "fbackup does not unmount a backup target it did not mount" {
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
  for c in btrfs tar mount umount mkdir sync rpm zstd; do make_stub "$c"; done
  # findmnt: report BACKUP_MNT already mounted, everything else not mounted.
  cat >"$STUB_DIR/findmnt" <<EOF
#!/usr/bin/env bash
printf 'findmnt %s\n' "\$*" >>"\$STUB_LOG"
for a in "\$@"; do
  [[ "\$a" == "$STUB_DIR/backup" ]] && exit 0
  [[ "\$a" == "SOURCE" ]] && { echo /dev/sda2; exit 0; }
done
exit 1
EOF
  chmod +x "$STUB_DIR/findmnt"
  run env DRY_RUN=1 FB_LOCK="$STUB_DIR/fb.lock" FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/fbackup
  teardown_stubs
  [ "$status" -eq 0 ]
  # We mounted SRC ourselves, so we unmount it...
  [[ "$output" == *"[DRY-RUN] umount $STUB_DIR/top"* ]]
  # ...but the backup target was already mounted, so we must NOT unmount it.
  [[ "$output" != *"umount $STUB_DIR/backup"* ]]
}

@test "fbackup refuses to start when another run holds the lock" {
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
  for c in btrfs tar mount umount mkdir sync rpm zstd findmnt; do make_stub "$c"; done
  lock="$STUB_DIR/fb.lock"
  # Hold the lock in a background process while fbackup runs. The 2s hold must
  # exceed the dry-run contender's runtime; the 0.3s pre-sleep lets the holder
  # acquire the lock before the contender starts.
  flock -x "$lock" -c 'sleep 2' &
  holder=$!
  sleep 0.3
  run env FB_LOCK="$lock" FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/fbackup
  wait "$holder" 2>/dev/null || true
  teardown_stubs
  [ "$status" -ne 0 ]
  [[ "$output" == *"another fbackup"* ]]
}

@test "fbackup --dry-run ignores the held lock" {
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
  for c in btrfs tar mount umount mkdir sync rpm zstd; do make_stub "$c"; done
  cat >"$STUB_DIR/findmnt" <<'EOF'
#!/usr/bin/env bash
printf 'findmnt %s\n' "$*" >>"$STUB_LOG"
for a in "$@"; do
  [[ "$a" == "SOURCE" ]] && { echo /dev/sda2; exit 0; }
done
exit 1
EOF
  chmod +x "$STUB_DIR/findmnt"
  lock="$STUB_DIR/fb.lock"
  # Hold the lock: a real backup would block here, but a dry-run preview must
  # skip the lock entirely and still complete.
  flock -x "$lock" -c 'sleep 2' &
  holder=$!
  sleep 0.3
  run env DRY_RUN=1 FB_LOCK="$lock" FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/fbackup
  wait "$holder" 2>/dev/null || true
  teardown_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] btrfs send"* ]]
}
