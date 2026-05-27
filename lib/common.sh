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
