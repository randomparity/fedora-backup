# shellcheck shell=bash
# Snapshot naming, parent selection, retention, and transfer primitives.
[[ -n "${_FB_SNAPSHOTS_SH:-}" ]] && return 0
_FB_SNAPSHOTS_SH=1

# UTC timestamp safe for paths, fixed width so lexical sort == chronological.
snap_timestamp() { date -u +%Y%m%dT%H%M%SZ; }

# snap_name <subvol> <timestamp>
snap_name() { printf '%s.%s\n' "$1" "$2"; }

# Regex matching a regular (non-preupgrade) snapshot for a given subvol.
_snap_regular_re() { printf '^%s\.[0-9]{8}T[0-9]{6}Z$' "$1"; }

# select_parent <subvol> <source_list> <target_list>
# Lists are newline-separated basenames. Prints the newest regular snapshot
# present in both lists, or nothing if there is no common parent.
select_parent() {
  local subvol="$1" source_list="$2" target_list="$3" re
  re="$(_snap_regular_re "$subvol")"
  comm -12 \
    <(printf '%s\n' "$source_list" | grep -E "$re" | sort) \
    <(printf '%s\n' "$target_list" | grep -E "$re" | sort) |
    tail -n1
}
