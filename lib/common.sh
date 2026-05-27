# shellcheck shell=bash
# Shared helpers. Source this file; it is safe to source more than once.
[[ -n "${_FB_COMMON_SH:-}" ]] && return 0
_FB_COMMON_SH=1

log_info() { printf '[INFO] %s\n' "$*" >&2; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

die() {
  log_error "$*"
  exit 1
}

# run <cmd...> : execute, or print and skip when DRY_RUN=1.
# Skip redefining if already defined (e.g. bats test runner defines its own 'run').
if ! declare -f run >/dev/null 2>&1; then
  run() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      printf '[DRY-RUN] %s\n' "$*" >&2
      return 0
    fi
    "$@"
  }
fi

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "must run as root (try: sudo $0 ...)"
}

# confirm_phrase <expected> [prompt] : read a line from stdin; succeed only on exact match.
confirm_phrase() {
  local expected="$1" answer
  local prompt="${2:-}"
  [[ -n "$prompt" ]] || prompt="Type '$expected' to continue: "
  read -r -p "$prompt" answer || true
  [[ "$answer" == "$expected" ]]
}

# load_config <path> : source config and validate required variables.
load_config() {
  local cfg="$1" var
  [[ -f "$cfg" ]] || die "config not found: $cfg"
  # shellcheck source=/dev/null
  source "$cfg"
  for var in BACKUP_DEV BACKUP_LABEL BACKUP_MNT SRC_TOPLEVEL_MNT SNAP_DIR \
    BOOT_MNT EFI_MNT RETENTION_KEEP; do
    [[ -n "${!var:-}" ]] || die "config missing required variable: $var"
  done
  [[ "${#SUBVOLS[@]}" -gt 0 ]] || die "config missing required variable: SUBVOLS"
  : "${HOSTNAME_TAG:=$(hostname)}"
}
