#!/usr/bin/env bats

load helpers/stubs

setup() {
  setup_stubs
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../lib/backup_target.sh"
}
teardown() { teardown_stubs; }

# blkid stub that reports an existing filesystem (exit 0 = found).
_blkid_found() {
  cat >"$STUB_DIR/blkid" <<EOF
#!/usr/bin/env bash
echo "/dev/x: TYPE=\"ext4\""
exit 0
EOF
  chmod +x "$STUB_DIR/blkid"
}
# blkid stub that reports no filesystem (exit 2 = nothing found).
_blkid_empty() {
  cat >"$STUB_DIR/blkid" <<EOF
#!/usr/bin/env bash
exit 2
EOF
  chmod +x "$STUB_DIR/blkid"
}

@test "target_guard refuses a device with an existing filesystem when FORCE unset" {
  _blkid_found
  run env -u FORCE bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; source '$BATS_TEST_DIRNAME/../lib/backup_target.sh'; target_guard /dev/x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already contains a filesystem"* ]]
}

@test "target_guard allows an existing filesystem when FORCE=1" {
  _blkid_found
  run env FORCE=1 bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; source '$BATS_TEST_DIRNAME/../lib/backup_target.sh'; target_guard /dev/x && echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "target_guard allows an empty device" {
  _blkid_empty
  run target_guard /dev/x
  [ "$status" -eq 0 ]
}

@test "target_format builds a labeled mkfs.btrfs command" {
  make_stub mkfs.btrfs
  run target_format /dev/x fedora-backup
  [ "$status" -eq 0 ]
  grep -q "mkfs.btrfs -f -L fedora-backup /dev/x" "$STUB_LOG"
}
