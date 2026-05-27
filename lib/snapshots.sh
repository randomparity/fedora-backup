# shellcheck shell=bash
# Snapshot naming, parent selection, retention, and transfer primitives.
[[ -n "${_FB_SNAPSHOTS_SH:-}" ]] && return 0
_FB_SNAPSHOTS_SH=1

# UTC timestamp safe for paths, fixed width so lexical sort == chronological.
snap_timestamp() { date -u +%Y%m%dT%H%M%SZ; }

# snap_name <subvol> <timestamp>
snap_name() { printf '%s.%s\n' "$1" "$2"; }
