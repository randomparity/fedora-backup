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
