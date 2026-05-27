#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
}

@test "die logs to stderr and exits 1" {
  run die "boom"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ERROR] boom"* ]]
}

@test "run executes the command when DRY_RUN unset" {
  run env -u DRY_RUN bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; run echo hello"
  [ "$status" -eq 0 ]
  [[ "$output" == "hello" ]]
}

@test "run prints but does not execute when DRY_RUN=1" {
  run env DRY_RUN=1 bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; run rm -rf /tmp/should-not-happen"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] rm -rf /tmp/should-not-happen"* ]]
}

@test "log_info writes to stderr with prefix" {
  run log_info "hi there"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[INFO] hi there"* ]]
}

@test "confirm_phrase succeeds when input matches" {
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; echo 'YES' | { confirm_phrase YES; }"
  [ "$status" -eq 0 ]
}

@test "confirm_phrase fails when input differs" {
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; echo 'no' | { confirm_phrase YES; }"
  [ "$status" -ne 0 ]
}

@test "load_config dies on missing file" {
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; load_config /no/such/file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config not found"* ]]
}

@test "load_config dies when a required var is missing" {
  cfg="$(mktemp)"
  echo 'BACKUP_DEV=/dev/x' >"$cfg"
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; load_config '$cfg'"
  rm -f "$cfg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config missing required variable"* ]]
}

@test "load_config succeeds with all required vars" {
  cfg="$(mktemp)"
  cat >"$cfg" <<'EOF'
BACKUP_DEV=/dev/x
BACKUP_LABEL=fedora-backup
BACKUP_MNT=/mnt/backup
SRC_TOPLEVEL_MNT=/mnt/btrfs-root
SUBVOLS=(root home)
SNAP_DIR=_snapshots
BOOT_MNT=/boot
EFI_MNT=/boot/efi
RETENTION_KEEP=3
EOF
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; load_config '$cfg' && echo OK"
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}
