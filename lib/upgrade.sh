# shellcheck shell=bash
# Fedora system-upgrade orchestration steps. Each is one human boundary.
[[ -n "${_FB_UPGRADE_SH:-}" ]] && return 0
_FB_UPGRADE_SH=1

# up_preflight <backup_mnt> <host_tag> : require a backup manifest dated today.
up_preflight() {
  local backup_mnt="$1" host="$2" today
  today="$(date -u +%Y%m%d)"
  local mdir="$backup_mnt/$host/manifests"
  if ! ls "$mdir"/manifest."$today"T*.json >/dev/null 2>&1; then
    die "no backup manifest dated today in $mdir — run fbackup first"
  fi
  log_info "preflight: found a backup dated $today"
}

# up_refresh : fully patch the current release before upgrading.
up_refresh() {
  run dnf5 upgrade --refresh
}

# up_download <releasever> : install the plugin and stage the upgrade.
up_download() {
  run dnf5 install dnf5-plugin-system-upgrade
  run dnf5 system-upgrade download --releasever="$1"
}

# up_apply : reboot into the offline upgrade transaction.
up_apply() {
  run dnf5 system-upgrade reboot
}

# up_post : checks to run after the first boot into the new release.
up_post() {
  run dnf5 check
}
