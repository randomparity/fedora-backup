#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../lib/manifest.sh"
}

@test "build_manifest_json emits valid JSON with expected keys" {
  out="$(build_manifest_json 20260527T143000Z root.20260526T143000Z 43 myhost \
    "UUID=abc / btrfs" "ID 256 ... root" "Label: fedora" "kernel-6.x")"
  echo "$out" | jq -e . >/dev/null
  [ "$(echo "$out" | jq -r .timestamp)" = "20260527T143000Z" ]
  [ "$(echo "$out" | jq -r .parent)" = "root.20260526T143000Z" ]
  [ "$(echo "$out" | jq -r .fedora_version)" = "43" ]
  [ "$(echo "$out" | jq -r .hostname)" = "myhost" ]
  [ "$(echo "$out" | jq -r .fstab)" = "UUID=abc / btrfs" ]
}

@test "build_manifest_json handles empty parent (full backup)" {
  out="$(build_manifest_json 20260527T143000Z "" 43 myhost "fstab" "subvols" "fsshow" "kernels")"
  echo "$out" | jq -e . >/dev/null
  [ "$(echo "$out" | jq -r .parent)" = "" ]
}
