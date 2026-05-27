#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../lib/snapshots.sh"
}

@test "snap_timestamp is UTC, fixed width, path-safe" {
  ts="$(snap_timestamp)"
  [[ "$ts" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
}

@test "snap_name joins subvol and timestamp with a dot" {
  run snap_name root 20260527T143000Z
  [ "$status" -eq 0 ]
  [ "$output" = "root.20260527T143000Z" ]
}
