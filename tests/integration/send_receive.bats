#!/usr/bin/env bats
# bats test_tags=integration

setup() {
  if [[ "${FBACKUP_INTEGRATION:-0}" != "1" ]]; then
    skip "set FBACKUP_INTEGRATION=1 (and run as root) to enable"
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    skip "integration tests require root"
  fi
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/snapshots.sh"

  WORK="$(mktemp -d)"
  SRC_IMG="$WORK/src.img"
  DST_IMG="$WORK/dst.img"
  SRC_MNT="$WORK/src"
  DST_MNT="$WORK/dst"
  truncate -s 600M "$SRC_IMG"
  truncate -s 600M "$DST_IMG"
  mkfs.btrfs -q "$SRC_IMG"
  mkfs.btrfs -q "$DST_IMG"
  mkdir -p "$SRC_MNT" "$DST_MNT"
  mount -o loop "$SRC_IMG" "$SRC_MNT"
  mount -o loop "$DST_IMG" "$DST_MNT"
  btrfs subvolume create "$SRC_MNT/root" >/dev/null
  mkdir -p "$SRC_MNT/_snapshots"
}

teardown() {
  [[ "${FBACKUP_INTEGRATION:-0}" != "1" ]] && return 0
  mountpoint -q "$SRC_MNT" && umount "$SRC_MNT"
  mountpoint -q "$DST_MNT" && umount "$DST_MNT"
  rm -rf "$WORK"
}

@test "full then incremental send/receive lands real subvolumes on the target" {
  echo "hello" >"$SRC_MNT/root/file1"
  ts1="20260527T100000Z"
  fb_snapshot "$SRC_MNT/root" "$SRC_MNT/_snapshots/root.$ts1"
  fb_send_receive "$SRC_MNT/_snapshots" "root.$ts1" "" "$DST_MNT"
  [ -f "$DST_MNT/root.$ts1/file1" ]

  echo "world" >"$SRC_MNT/root/file2"
  ts2="20260527T110000Z"
  fb_snapshot "$SRC_MNT/root" "$SRC_MNT/_snapshots/root.$ts2"
  parent="$(select_parent root \
    "$(find "$SRC_MNT/_snapshots" -maxdepth 1 -name 'root.*' -printf '%f\n')" \
    "$(find "$DST_MNT" -maxdepth 1 -name 'root.*' -printf '%f\n')")"
  [ "$parent" = "root.$ts1" ]
  fb_send_receive "$SRC_MNT/_snapshots" "root.$ts2" "$parent" "$DST_MNT"
  [ -f "$DST_MNT/root.$ts2/file2" ]
}
