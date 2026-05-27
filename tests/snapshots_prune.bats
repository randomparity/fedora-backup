#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../lib/snapshots.sh"
}

@test "prune_candidates returns regular snapshots beyond keep N, oldest first" {
  list=$'root.20260101T000000Z\nroot.20260201T000000Z\nroot.20260301T000000Z\nroot.20260401T000000Z'
  run prune_candidates 2 "$list"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "root.20260101T000000Z" ]
  [ "${lines[1]}" = "root.20260201T000000Z" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "prune_candidates returns nothing when count <= keep" {
  list=$'root.20260101T000000Z\nroot.20260201T000000Z'
  run prune_candidates 3 "$list"
  [ "$output" = "" ]
}

@test "prune_candidates never returns preupgrade snapshots" {
  list=$'root.preupgrade-f43.20260101T000000Z\nroot.20260201T000000Z\nroot.20260301T000000Z\nroot.20260401T000000Z'
  run prune_candidates 1 "$list"
  [[ "$output" != *"preupgrade"* ]]
  [ "${lines[0]}" = "root.20260201T000000Z" ]
  [ "${lines[1]}" = "root.20260301T000000Z" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "prune_candidates never deletes the protected snapshot" {
  list=$'root.20260101T000000Z\nroot.20260201T000000Z\nroot.20260301T000000Z\nroot.20260401T000000Z'
  run prune_candidates 1 "$list" root.20260101T000000Z
  [ "$status" -eq 0 ]
  [[ "$output" != *"root.20260101T000000Z"* ]]
  [[ "$output" == *"root.20260201T000000Z"* ]]
  [[ "$output" == *"root.20260301T000000Z"* ]]
  [ "${#lines[@]}" -eq 2 ]
}

@test "prune_candidates with empty protect behaves as before" {
  list=$'root.20260101T000000Z\nroot.20260201T000000Z\nroot.20260301T000000Z'
  run prune_candidates 1 "$list" ""
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "root.20260101T000000Z" ]
  [ "${lines[1]}" = "root.20260201T000000Z" ]
}
