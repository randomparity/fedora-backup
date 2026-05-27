#!/usr/bin/env bats

load helpers/stubs

setup() {
  setup_stubs
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../lib/upgrade.sh"
}
teardown() { teardown_stubs; }

@test "up_refresh refreshes the current system" {
  make_stub dnf5
  run up_refresh
  [ "$status" -eq 0 ]
  grep -q "dnf5 upgrade --refresh" "$STUB_LOG"
}

@test "up_download installs the plugin then downloads the target release" {
  make_stub dnf5
  run up_download 44
  [ "$status" -eq 0 ]
  grep -q "dnf5 install dnf5-plugin-system-upgrade" "$STUB_LOG"
  grep -q "dnf5 system-upgrade download --releasever=44" "$STUB_LOG"
}

@test "up_apply triggers the offline upgrade reboot" {
  make_stub dnf5
  run up_apply
  [ "$status" -eq 0 ]
  grep -q "dnf5 system-upgrade reboot" "$STUB_LOG"
}

@test "up_preflight fails when no backup manifest exists for today" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/host/manifests"
  run up_preflight "$tmp" host
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no backup manifest dated today"* ]]
}

@test "up_preflight passes when a manifest dated today exists" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/host/manifests"
  today="$(date -u +%Y%m%d)"
  touch "$tmp/host/manifests/manifest.${today}T120000Z.json"
  make_stub dnf5
  run up_preflight "$tmp" host
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}
