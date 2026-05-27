#!/usr/bin/env bats

load helpers/stubs

setup() {
  setup_stubs
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../lib/snapshots.sh"
}
teardown() { teardown_stubs; }

@test "fb_snapshot creates a read-only snapshot" {
  make_stub btrfs
  run fb_snapshot /mnt/btrfs-root/root /mnt/btrfs-root/_snapshots/root.20260527T143000Z
  [ "$status" -eq 0 ]
  grep -q "btrfs subvolume snapshot -r /mnt/btrfs-root/root /mnt/btrfs-root/_snapshots/root.20260527T143000Z" "$STUB_LOG"
}

@test "fb_send_receive does a full send when parent is empty" {
  make_stub btrfs
  run fb_send_receive /snaps root.20260527T143000Z "" /mnt/backup/host/subvols/root
  [ "$status" -eq 0 ]
  grep -q "btrfs send /snaps/root.20260527T143000Z" "$STUB_LOG"
  grep -q "btrfs receive /mnt/backup/host/subvols/root" "$STUB_LOG"
}

@test "fb_send_receive does an incremental send when parent is given" {
  make_stub btrfs
  run fb_send_receive /snaps root.20260527T143000Z root.20260526T143000Z /mnt/backup/host/subvols/root
  [ "$status" -eq 0 ]
  grep -q "btrfs send -p /snaps/root.20260526T143000Z /snaps/root.20260527T143000Z" "$STUB_LOG"
}

@test "fb_send_receive deletes partial target subvolume on failure" {
  make_stub btrfs 1
  run fb_send_receive /snaps root.20260527T143000Z "" /mnt/backup/host/subvols/root
  [ "$status" -ne 0 ]
  grep -q "btrfs subvolume delete /mnt/backup/host/subvols/root/root.20260527T143000Z" "$STUB_LOG"
}
