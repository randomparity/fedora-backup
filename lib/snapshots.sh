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

# prune_candidates <keep_n> <list>
# list = newline-separated basenames. Prints regular snapshots to delete
# (everything older than the newest keep_n), oldest first. Never preupgrade.
prune_candidates() {
  local keep="$1" list="$2"
  printf '%s\n' "$list" |
    grep -E '^[^.]+\.[0-9]{8}T[0-9]{6}Z$' |
    sort -r |
    tail -n "+$((keep + 1))" |
    sort
}

# fb_snapshot <src_subvol_path> <dest_snapshot_path> : read-only snapshot.
fb_snapshot() {
  run btrfs subvolume snapshot -r "$1" "$2"
}

# fb_send_receive <snapshot_dir> <new_name> <parent_name|""> <target_subvol_dir>
# Streams a (possibly incremental) snapshot to the target. On failure, removes
# the partially received subvolume so it cannot be chosen as a future parent.
fb_send_receive() {
  local snapshot_dir="$1" new="$2" parent="$3" target="$4"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    if [[ -n "$parent" ]]; then
      printf '[DRY-RUN] btrfs send -p %s %s | btrfs receive %s\n' \
        "$snapshot_dir/$parent" "$snapshot_dir/$new" "$target" >&2
    else
      printf '[DRY-RUN] btrfs send %s | btrfs receive %s\n' \
        "$snapshot_dir/$new" "$target" >&2
    fi
    return 0
  fi

  local ok=1
  if [[ -n "$parent" ]]; then
    btrfs send -p "$snapshot_dir/$parent" "$snapshot_dir/$new" | btrfs receive "$target" || ok=0
  else
    btrfs send "$snapshot_dir/$new" | btrfs receive "$target" || ok=0
  fi

  if [[ "$ok" -ne 1 ]]; then
    btrfs subvolume delete "$target/$new" >/dev/null 2>&1 || true
    die "send/receive failed for $new (cleaned up partial target)"
  fi
}
