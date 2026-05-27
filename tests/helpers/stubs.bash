# Test helpers for stubbing external commands on PATH.
# Usage in a .bats file:
#   load helpers/stubs
#   setup() { setup_stubs; }
#   teardown() { teardown_stubs; }

setup_stubs() {
  STUB_DIR="$(mktemp -d)"
  STUB_LOG="$STUB_DIR/calls.log"
  : >"$STUB_LOG"
  PATH="$STUB_DIR:$PATH"
  export PATH STUB_DIR STUB_LOG
}

teardown_stubs() {
  [[ -n "${STUB_DIR:-}" ]] && rm -rf "$STUB_DIR"
}

# make_stub <name> [exit_code]
# Creates an executable that appends "name <args>" to $STUB_LOG, drains stdin,
# and exits with the given code (default 0).
make_stub() {
  local name="$1" code="${2:-0}"
  cat >"$STUB_DIR/$name" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$name" "\$*" >>"$STUB_LOG"
cat >/dev/null 2>&1 || true
exit $code
EOF
  chmod +x "$STUB_DIR/$name"
}
