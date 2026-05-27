# shellcheck shell=bash
# Manifest builder. Pure: takes all facts as arguments, emits JSON via jq.
[[ -n "${_FB_MANIFEST_SH:-}" ]] && return 0
_FB_MANIFEST_SH=1

# build_manifest_json <ts> <parent> <fedora> <host> <fstab> <subvols> <fsshow> <kernels>
build_manifest_json() {
  jq -n \
    --arg ts "$1" \
    --arg parent "$2" \
    --arg fedora "$3" \
    --arg host "$4" \
    --arg fstab "$5" \
    --arg subvols "$6" \
    --arg fsshow "$7" \
    --arg kernels "$8" \
    '{
      timestamp: $ts,
      parent: $parent,
      fedora_version: $fedora,
      hostname: $host,
      fstab: $fstab,
      subvolumes: $subvols,
      fs_show: $fsshow,
      kernels: $kernels
    }'
}
