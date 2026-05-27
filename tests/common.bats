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
