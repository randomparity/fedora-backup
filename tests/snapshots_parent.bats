#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../lib/snapshots.sh"
}

@test "select_parent returns newest snapshot common to both sides" {
  src=$'root.20260101T000000Z\nroot.20260201T000000Z\nroot.20260301T000000Z'
  tgt=$'root.20260101T000000Z\nroot.20260201T000000Z'
  run select_parent root "$src" "$tgt"
  [ "$status" -eq 0 ]
  [ "$output" = "root.20260201T000000Z" ]
}

@test "select_parent is empty when there is no common snapshot" {
  src=$'root.20260301T000000Z'
  tgt=$'root.20260101T000000Z'
  run select_parent root "$src" "$tgt"
  [ "$output" = "" ]
}

@test "select_parent ignores other subvols" {
  src=$'home.20260301T000000Z\nroot.20260101T000000Z'
  tgt=$'home.20260301T000000Z\nroot.20260101T000000Z'
  run select_parent root "$src" "$tgt"
  [ "$output" = "root.20260101T000000Z" ]
}

@test "select_parent ignores preupgrade snapshots" {
  src=$'root.preupgrade-f43.20260301T000000Z\nroot.20260101T000000Z'
  tgt=$'root.preupgrade-f43.20260301T000000Z\nroot.20260101T000000Z'
  run select_parent root "$src" "$tgt"
  [ "$output" = "root.20260101T000000Z" ]
}
