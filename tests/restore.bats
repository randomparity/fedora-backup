#!/usr/bin/env bats

load helpers/stubs

setup() {
  setup_stubs
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../lib/restore.sh"
}
teardown() { teardown_stubs; }

@test "restore_receive streams a snapshot from target back to a destination" {
  make_stub btrfs
  run restore_receive /mnt/backup/host/subvols/root root.20260527T143000Z /mnt/btrfs-root
  [ "$status" -eq 0 ]
  grep -q "btrfs send /mnt/backup/host/subvols/root/root.20260527T143000Z" "$STUB_LOG"
  grep -q "btrfs receive /mnt/btrfs-root" "$STUB_LOG"
}

@test "restore_boot extracts a tarball into a mountpoint" {
  make_stub tar
  run restore_boot /mnt/backup/host/boot/boot.20260527T143000Z.tar.zst /boot
  [ "$status" -eq 0 ]
  grep -q "tar --xattrs --acls -xpf /mnt/backup/host/boot/boot.20260527T143000Z.tar.zst -C /boot" "$STUB_LOG"
}

@test "restore_receive honors DRY_RUN" {
  run env DRY_RUN=1 bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; source '$BATS_TEST_DIRNAME/../lib/restore.sh'; restore_receive /t/sub snap /dest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] btrfs send /t/sub/snap | btrfs receive /dest"* ]]
}

@test "restore_canonicalize creates a writable subvol from the received snapshot" {
  make_stub btrfs
  run restore_canonicalize /mnt/restore-target root.20260527T143000Z root
  [ "$status" -eq 0 ]
  grep -q "btrfs subvolume snapshot /mnt/restore-target/root.20260527T143000Z /mnt/restore-target/root" "$STUB_LOG"
}

@test "restore_receive deletes the partial target on receive failure" {
  cat >"$STUB_DIR/btrfs" <<'EOF'
#!/usr/bin/env bash
printf 'btrfs %s\n' "$*" >>"$STUB_LOG"
cat >/dev/null 2>&1 || true
[[ "$1" == "receive" ]] && exit 1
exit 0
EOF
  chmod +x "$STUB_DIR/btrfs"
  run restore_receive /mnt/backup/host/subvols/root root.20260527T143000Z /mnt/restore-target
  [ "$status" -ne 0 ]
  [[ "$output" == *"restore receive failed for root.20260527T143000Z (cleaned up partial /mnt/restore-target/root.20260527T143000Z)"* ]]
  grep -q "btrfs subvolume delete /mnt/restore-target/root.20260527T143000Z" "$STUB_LOG"
}
