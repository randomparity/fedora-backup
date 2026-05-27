# Fedora 43 → 44 btrfs Backup & Upgrade — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable bash toolkit that backs up this Fedora 43 btrfs system (root + home subvolumes, plus /boot and /boot/efi) to a USB btrfs target via incremental `btrfs send/receive`, then orchestrates a guarded upgrade to Fedora 44 with local-snapshot and external restore paths.

**Architecture:** Pure, testable logic lives in sourceable `lib/*.sh` modules (no `set -e`, double-source guards). The `bin/*` scripts are thin CLI wrappers (`set -euo pipefail`) that source libs and call their functions from a `main()` guarded by `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`. Tests source the libs directly and stub external commands (`btrfs`, `dnf5`, `mkfs.btrfs`, `blkid`, `tar`) on `PATH` to assert command construction. Pure functions (parent selection, retention, manifest JSON) get real unit tests.

**Tech Stack:** Bash (`set -euo pipefail`, 2-space indent), `btrfs-progs`, `dnf5` + `dnf5-plugin-system-upgrade`, `jq` for manifests, `bats` for tests, `shellcheck` + `shfmt` via `prek`.

---

## Concrete environment values (from survey 2026-05-27)

- Backup target by-id: `/dev/disk/by-id/usb-SanDisk_PRO-G40_32343335334D383031333039-0:0`
- Backup label: `fedora-backup`; mount point: `/mnt/backup`
- Source btrfs top level: `subvolid=5` on the root filesystem (label `fedora`)
- Subvolumes: `root`, `home`
- Boot mounts: `/boot` (ext4), `/boot/efi` (vfat)
- Package manager: `dnf5`; system-upgrade plugin NOT yet installed

## File structure

```
fedora-backup/
  bin/
    fbackup-init           # format/prepare USB target (guarded)
    fbackup                # snapshot -> incremental send/receive -> boot tar -> manifest -> prune
    fsnapshot-preupgrade   # tagged local rollback anchor + local boot stash
    fupgrade               # F43->44 orchestration (subcommands)
    frestore               # disaster recovery from target
  lib/
    common.sh              # logging, die, run, require_root, confirm_phrase, load_config
    snapshots.sh           # timestamp/naming, select_parent, prune_candidates, fb_snapshot, fb_send_receive
    manifest.sh            # build_manifest_json
    backup_target.sh       # target_guard, target_format
    upgrade.sh             # up_preflight, up_refresh, up_download, up_apply, up_post
    restore.sh             # restore_receive, restore_boot
  etc/
    backup.conf.example    # config template (committed); real backup.conf is gitignored
  tests/
    helpers/stubs.bash     # PATH-stub helpers
    common.bats
    snapshots_naming.bats
    snapshots_parent.bats
    snapshots_prune.bats
    snapshots_transfer.bats
    manifest.bats
    backup_target.bats
    upgrade.bats
    restore.bats
    bin_smoke.bats
    integration/send_receive.bats   # opt-in, needs root + loopback
  docs/
    RUNBOOK.md
    superpowers/specs/2026-05-27-fedora-backup-upgrade-design.md
    superpowers/plans/2026-05-27-fedora-backup-upgrade.md
  .shellcheckrc
  .editorconfig
  .pre-commit-config.yaml
  .gitignore
  README.md
```

---

### Task 1: Scaffolding, tooling guardrails, config template

**Files:**
- Create: `.gitignore`, `.editorconfig`, `.shellcheckrc`, `.pre-commit-config.yaml`
- Create: `tests/helpers/stubs.bash`
- Create: `etc/backup.conf.example`
- Create: `lib/.gitkeep`, `bin/.gitkeep`

- [ ] **Step 1: Install bats (test runner)**

Run: `sudo dnf5 install -y bats && bats --version`
Expected: prints `Bats 1.x`

- [ ] **Step 2: Write `.gitignore`**

```gitignore
etc/backup.conf
*.tar.zst
.DS_Store
```

- [ ] **Step 3: Write `.editorconfig`**

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true

[*.{sh,bash,bats}]
indent_style = space
indent_size = 2

[bin/*]
indent_style = space
indent_size = 2
```

- [ ] **Step 4: Write `.shellcheckrc`**

```
# Follow sourced files for cross-file checks.
external-sources=true
```

- [ ] **Step 5: Write `.pre-commit-config.yaml` (prek-compatible, local hooks using installed tools)**

```yaml
repos:
  - repo: local
    hooks:
      - id: shellcheck
        name: shellcheck
        entry: shellcheck
        language: system
        types: [shell]
        args: [-x]
      - id: shfmt
        name: shfmt
        entry: shfmt
        language: system
        types: [shell]
        args: [-i, "2", -ci, -d]
      - id: bats
        name: bats
        entry: bash -c 'bats tests/ --filter-tags !integration || bats tests/*.bats'
        language: system
        pass_filenames: false
        files: '\.(bats|sh|bash)$|^bin/'
```

- [ ] **Step 6: Write `tests/helpers/stubs.bash`**

```bash
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
```

- [ ] **Step 7: Write `etc/backup.conf.example`**

```bash
# Copy to etc/backup.conf and adjust. etc/backup.conf is gitignored.

# Backup USB target, addressed by stable by-id path (never /dev/sdX).
BACKUP_DEV="/dev/disk/by-id/usb-SanDisk_PRO-G40_32343335334D383031333039-0:0"
BACKUP_LABEL="fedora-backup"
BACKUP_MNT="/mnt/backup"

# Source btrfs top level (subvolid=5) gets mounted here during a run.
SRC_TOPLEVEL_MNT="/mnt/btrfs-root"

# Subvolumes to back up (names under the top level).
SUBVOLS=(root home)

# Local read-only snapshots are kept here (directory under the top level).
SNAP_DIR="_snapshots"

# Non-btrfs boot partitions, captured as tarballs.
BOOT_MNT="/boot"
EFI_MNT="/boot/efi"

# How many regular snapshot sets to keep on each side (preupgrade exempt).
RETENTION_KEEP=3

# Tag used in the target directory path; defaults to hostname if empty.
HOSTNAME_TAG=""
```

- [ ] **Step 8: Create keep files so empty dirs are tracked**

Run: `mkdir -p bin lib tests/helpers tests/integration && touch lib/.gitkeep bin/.gitkeep`

- [ ] **Step 9: Verify shellcheck/shfmt run clean on the helper**

Run: `shellcheck -x tests/helpers/stubs.bash && shfmt -i 2 -ci -d tests/helpers/stubs.bash`
Expected: no output (clean), exit 0

- [ ] **Step 10: Commit**

```bash
git add .gitignore .editorconfig .shellcheckrc .pre-commit-config.yaml tests/helpers/stubs.bash etc/backup.conf.example lib/.gitkeep bin/.gitkeep
git commit -m "Add repo scaffolding, lint/test guardrails, config template"
```

---

### Task 2: lib/common.sh — logging, die, run, require_root

**Files:**
- Create: `lib/common.sh`
- Test: `tests/common.bats`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
}

@test "die logs to stderr and exits 1" {
  run die "boom"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ERROR] boom"* ]]
}

@test "run executes the command when DRY_RUN unset" {
  run env -u DRY_RUN bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; run echo hello"
  [ "$status" -eq 0 ]
  [[ "$output" == "hello" ]]
}

@test "run prints but does not execute when DRY_RUN=1" {
  run env DRY_RUN=1 bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; run rm -rf /tmp/should-not-happen"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] rm -rf /tmp/should-not-happen"* ]]
}

@test "log_info writes to stderr with prefix" {
  run log_info "hi there"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[INFO] hi there"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/common.bats`
Expected: FAIL — `lib/common.sh` does not exist / functions undefined

- [ ] **Step 3: Write `lib/common.sh`**

```bash
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
run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '[DRY-RUN] %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "must run as root (try: sudo $0 ...)"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/common.bats`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh tests/common.bats
git commit -m "Add common.sh logging, die, run, require_root"
```

---

### Task 3: lib/common.sh — confirm_phrase and load_config

**Files:**
- Modify: `lib/common.sh`
- Test: `tests/common.bats` (append)

- [ ] **Step 1: Append failing tests to `tests/common.bats`**

```bash
@test "confirm_phrase succeeds when input matches" {
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; echo 'YES' | { confirm_phrase YES; }"
  [ "$status" -eq 0 ]
}

@test "confirm_phrase fails when input differs" {
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; echo 'no' | { confirm_phrase YES; }"
  [ "$status" -ne 0 ]
}

@test "load_config dies on missing file" {
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; load_config /no/such/file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config not found"* ]]
}

@test "load_config dies when a required var is missing" {
  cfg="$(mktemp)"
  echo 'BACKUP_DEV=/dev/x' >"$cfg"
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; load_config '$cfg'"
  rm -f "$cfg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config missing required variable"* ]]
}

@test "load_config succeeds with all required vars" {
  cfg="$(mktemp)"
  cat >"$cfg" <<'EOF'
BACKUP_DEV=/dev/x
BACKUP_LABEL=fedora-backup
BACKUP_MNT=/mnt/backup
SRC_TOPLEVEL_MNT=/mnt/btrfs-root
SUBVOLS=(root home)
SNAP_DIR=_snapshots
BOOT_MNT=/boot
EFI_MNT=/boot/efi
RETENTION_KEEP=3
EOF
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; load_config '$cfg' && echo OK"
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}
```

- [ ] **Step 2: Run test to verify the new tests fail**

Run: `bats tests/common.bats`
Expected: FAIL — `confirm_phrase` / `load_config` undefined

- [ ] **Step 3: Append to `lib/common.sh`**

```bash
# confirm_phrase <expected> [prompt] : read a line from stdin; succeed only on exact match.
confirm_phrase() {
  local expected="$1" prompt="${2:-Type '$1' to continue: }" answer
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/common.bats`
Expected: PASS (9 tests total)

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh tests/common.bats
git commit -m "Add confirm_phrase and load_config to common.sh"
```

---

### Task 4: lib/snapshots.sh — timestamp and naming

**Files:**
- Create: `lib/snapshots.sh`
- Test: `tests/snapshots_naming.bats`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../lib/snapshots.sh"
}

@test "snap_timestamp is UTC, fixed width, path-safe" {
  ts="$(snap_timestamp)"
  [[ "$ts" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
}

@test "snap_name joins subvol and timestamp with a dot" {
  run snap_name root 20260527T143000Z
  [ "$status" -eq 0 ]
  [ "$output" = "root.20260527T143000Z" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/snapshots_naming.bats`
Expected: FAIL — `lib/snapshots.sh` missing

- [ ] **Step 3: Write `lib/snapshots.sh`**

```bash
# Snapshot naming, parent selection, retention, and transfer primitives.
[[ -n "${_FB_SNAPSHOTS_SH:-}" ]] && return 0
_FB_SNAPSHOTS_SH=1

# UTC timestamp safe for paths, fixed width so lexical sort == chronological.
snap_timestamp() { date -u +%Y%m%dT%H%M%SZ; }

# snap_name <subvol> <timestamp>
snap_name() { printf '%s.%s\n' "$1" "$2"; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/snapshots_naming.bats`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/snapshots.sh tests/snapshots_naming.bats
git commit -m "Add snapshot timestamp and naming helpers"
```

---

### Task 5: lib/snapshots.sh — select_parent

**Files:**
- Modify: `lib/snapshots.sh`
- Test: `tests/snapshots_parent.bats`

The parent for an incremental send is the newest *regular* snapshot of a subvol present on **both** source and target. Regular snapshot names match `<subvol>.<YYYYmmddTHHMMSSZ>`; `preupgrade` snapshots are excluded so chains stay deterministic.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../lib/snapshots.sh"
}

@test "select_parent returns newest snapshot common to both sides" {
  src=$'root.20260101T000000Z\nroot.20260201T000000Z\nroot.20260301T000000Z'
  tgt=$'root.20260101T000000Z\nroot.20260201T000000Z'
  run select_parent root "$src" "$tgt"
  [ "$status" -eq 0 ]
  [ "$output" = "root.20260201T000000Z" ]
}

@test "select_parent is empty when there is no common snapshot" {
  src=$'root.20260301T000000Z'
  tgt=$'root.20260101T000000Z'
  run select_parent root "$src" "$tgt"
  [ "$output" = "" ]
}

@test "select_parent ignores other subvols" {
  src=$'home.20260301T000000Z\nroot.20260101T000000Z'
  tgt=$'home.20260301T000000Z\nroot.20260101T000000Z'
  run select_parent root "$src" "$tgt"
  [ "$output" = "root.20260101T000000Z" ]
}

@test "select_parent ignores preupgrade snapshots" {
  src=$'root.preupgrade-f43.20260301T000000Z\nroot.20260101T000000Z'
  tgt=$'root.preupgrade-f43.20260301T000000Z\nroot.20260101T000000Z'
  run select_parent root "$src" "$tgt"
  [ "$output" = "root.20260101T000000Z" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/snapshots_parent.bats`
Expected: FAIL — `select_parent` undefined

- [ ] **Step 3: Append to `lib/snapshots.sh`**

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/snapshots_parent.bats`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/snapshots.sh tests/snapshots_parent.bats
git commit -m "Add incremental parent selection"
```

---

### Task 6: lib/snapshots.sh — prune_candidates

**Files:**
- Modify: `lib/snapshots.sh`
- Test: `tests/snapshots_prune.bats`

Retention keeps the newest N regular snapshots; everything older is a prune candidate. `preupgrade` snapshots are never candidates.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../lib/snapshots.sh"
}

@test "prune_candidates returns regular snapshots beyond keep N, oldest first" {
  list=$'root.20260101T000000Z\nroot.20260201T000000Z\nroot.20260301T000000Z\nroot.20260401T000000Z'
  run prune_candidates 2 "$list"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "root.20260101T000000Z" ]
  [ "${lines[1]}" = "root.20260201T000000Z" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "prune_candidates returns nothing when count <= keep" {
  list=$'root.20260101T000000Z\nroot.20260201T000000Z'
  run prune_candidates 3 "$list"
  [ "$output" = "" ]
}

@test "prune_candidates never returns preupgrade snapshots" {
  list=$'root.preupgrade-f43.20260101T000000Z\nroot.20260201T000000Z\nroot.20260301T000000Z\nroot.20260401T000000Z'
  run prune_candidates 1 "$list"
  [[ "$output" != *"preupgrade"* ]]
  [ "${lines[0]}" = "root.20260201T000000Z" ]
  [ "${lines[1]}" = "root.20260301T000000Z" ]
  [ "${#lines[@]}" -eq 2 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/snapshots_prune.bats`
Expected: FAIL — `prune_candidates` undefined

- [ ] **Step 3: Append to `lib/snapshots.sh`**

```bash
# prune_candidates <keep_n> <list>
# list = newline-separated basenames. Prints regular snapshots to delete
# (everything older than the newest keep_n), oldest first. Never preupgrade.
prune_candidates() {
  local keep="$1" list="$2"
  printf '%s\n' "$list" |
    grep -E '\.[0-9]{8}T[0-9]{6}Z$' |
    sort -r |
    tail -n "+$((keep + 1))" |
    sort
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/snapshots_prune.bats`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/snapshots.sh tests/snapshots_prune.bats
git commit -m "Add retention prune candidate selection"
```

---

### Task 7: lib/snapshots.sh — fb_snapshot and fb_send_receive

**Files:**
- Modify: `lib/snapshots.sh`
- Test: `tests/snapshots_transfer.bats`

These wrap the privileged btrfs operations. Tests stub `btrfs` on PATH and assert command construction. `fb_send_receive` cleans up a half-received target subvolume on failure so a partial never becomes a parent.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats

load helpers/stubs

setup() {
  setup_stubs
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../lib/snapshots.sh"
}
teardown() { teardown_stubs; }

@test "fb_snapshot creates a read-only snapshot" {
  make_stub btrfs
  run fb_snapshot /mnt/btrfs-root/root /mnt/btrfs-root/_snapshots/root.20260527T143000Z
  [ "$status" -eq 0 ]
  grep -q "btrfs subvolume snapshot -r /mnt/btrfs-root/root /mnt/btrfs-root/_snapshots/root.20260527T143000Z" "$STUB_LOG"
}

@test "fb_send_receive does a full send when parent is empty" {
  make_stub btrfs
  run fb_send_receive /snaps root.20260527T143000Z "" /mnt/backup/host/subvols/root
  [ "$status" -eq 0 ]
  grep -q "btrfs send /snaps/root.20260527T143000Z" "$STUB_LOG"
  grep -q "btrfs receive /mnt/backup/host/subvols/root" "$STUB_LOG"
}

@test "fb_send_receive does an incremental send when parent is given" {
  make_stub btrfs
  run fb_send_receive /snaps root.20260527T143000Z root.20260526T143000Z /mnt/backup/host/subvols/root
  [ "$status" -eq 0 ]
  grep -q "btrfs send -p /snaps/root.20260526T143000Z /snaps/root.20260527T143000Z" "$STUB_LOG"
}

@test "fb_send_receive deletes partial target subvolume on failure" {
  make_stub btrfs 1
  run fb_send_receive /snaps root.20260527T143000Z "" /mnt/backup/host/subvols/root
  [ "$status" -ne 0 ]
  grep -q "btrfs subvolume delete /mnt/backup/host/subvols/root/root.20260527T143000Z" "$STUB_LOG"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/snapshots_transfer.bats`
Expected: FAIL — `fb_snapshot` / `fb_send_receive` undefined

- [ ] **Step 3: Append to `lib/snapshots.sh`**

```bash
# fb_snapshot <src_subvol_path> <dest_snapshot_path> : read-only snapshot.
fb_snapshot() {
  run btrfs subvolume snapshot -r "$1" "$2"
}

# fb_send_receive <snap_dir> <new_name> <parent_name|""> <target_subvol_dir>
# Streams a (possibly incremental) snapshot to the target. On failure, removes
# the partially received subvolume so it cannot be chosen as a future parent.
fb_send_receive() {
  local snap_dir="$1" new="$2" parent="$3" target="$4"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    if [[ -n "$parent" ]]; then
      printf '[DRY-RUN] btrfs send -p %s %s | btrfs receive %s\n' \
        "$snap_dir/$parent" "$snap_dir/$new" "$target" >&2
    else
      printf '[DRY-RUN] btrfs send %s | btrfs receive %s\n' \
        "$snap_dir/$new" "$target" >&2
    fi
    return 0
  fi

  local ok=1
  if [[ -n "$parent" ]]; then
    btrfs send -p "$snap_dir/$parent" "$snap_dir/$new" | btrfs receive "$target" || ok=0
  else
    btrfs send "$snap_dir/$new" | btrfs receive "$target" || ok=0
  fi

  if [[ "$ok" -ne 1 ]]; then
    btrfs subvolume delete "$target/$new" >/dev/null 2>&1 || true
    die "send/receive failed for $new (cleaned up partial target)"
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/snapshots_transfer.bats`
Expected: PASS (4 tests)

Note: with `set -o pipefail` in the calling bin scripts, a failing `send` is detected. In these tests pipefail is off, so the explicit `|| ok=0` on the pipeline (which reflects `receive`'s status) drives the failure path; the stubbed `btrfs 1` makes `receive` exit non-zero.

- [ ] **Step 5: Commit**

```bash
git add lib/snapshots.sh tests/snapshots_transfer.bats
git commit -m "Add snapshot and send/receive transfer primitives"
```

---

### Task 8: lib/manifest.sh — build_manifest_json

**Files:**
- Create: `lib/manifest.sh`
- Test: `tests/manifest.bats`

- [ ] **Step 1: Write the failing test**

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/manifest.bats`
Expected: FAIL — `lib/manifest.sh` missing

- [ ] **Step 3: Write `lib/manifest.sh`**

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/manifest.bats`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/manifest.sh tests/manifest.bats
git commit -m "Add manifest JSON builder"
```

---

### Task 9: lib/backup_target.sh — target_guard and target_format

**Files:**
- Create: `lib/backup_target.sh`
- Test: `tests/backup_target.bats`

`target_guard` refuses to format a device that already holds a filesystem unless `FORCE=1`. `target_format` builds the `mkfs.btrfs` command.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats

load helpers/stubs

setup() {
  setup_stubs
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../lib/backup_target.sh"
}
teardown() { teardown_stubs; }

# blkid stub that reports an existing filesystem (exit 0 = found).
_blkid_found() {
  cat >"$STUB_DIR/blkid" <<EOF
#!/usr/bin/env bash
echo "/dev/x: TYPE=\"ext4\""
exit 0
EOF
  chmod +x "$STUB_DIR/blkid"
}
# blkid stub that reports no filesystem (exit 2 = nothing found).
_blkid_empty() {
  cat >"$STUB_DIR/blkid" <<EOF
#!/usr/bin/env bash
exit 2
EOF
  chmod +x "$STUB_DIR/blkid"
}

@test "target_guard refuses a device with an existing filesystem when FORCE unset" {
  _blkid_found
  run env -u FORCE bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; source '$BATS_TEST_DIRNAME/../lib/backup_target.sh'; target_guard /dev/x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already contains a filesystem"* ]]
}

@test "target_guard allows an existing filesystem when FORCE=1" {
  _blkid_found
  run env FORCE=1 bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; source '$BATS_TEST_DIRNAME/../lib/backup_target.sh'; target_guard /dev/x && echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "target_guard allows an empty device" {
  _blkid_empty
  run target_guard /dev/x
  [ "$status" -eq 0 ]
}

@test "target_format builds a labeled mkfs.btrfs command" {
  make_stub mkfs.btrfs
  run target_format /dev/x fedora-backup
  [ "$status" -eq 0 ]
  grep -q "mkfs.btrfs -f -L fedora-backup /dev/x" "$STUB_LOG"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/backup_target.bats`
Expected: FAIL — `lib/backup_target.sh` missing

- [ ] **Step 3: Write `lib/backup_target.sh`**

```bash
# Backup target preparation: guard checks and formatting.
[[ -n "${_FB_BACKUP_TARGET_SH:-}" ]] && return 0
_FB_BACKUP_TARGET_SH=1

# target_guard <device> : refuse if device already has a filesystem, unless FORCE=1.
target_guard() {
  local dev="$1"
  if blkid "$dev" >/dev/null 2>&1; then
    if [[ "${FORCE:-0}" != "1" ]]; then
      die "device $dev already contains a filesystem; set FORCE=1 to wipe it"
    fi
    log_warn "device $dev already contains a filesystem; FORCE=1 set, will wipe"
  fi
  return 0
}

# target_format <device> <label> : create a btrfs filesystem.
target_format() {
  run mkfs.btrfs -f -L "$2" "$1"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/backup_target.bats`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/backup_target.sh tests/backup_target.bats
git commit -m "Add backup target guard and format helpers"
```

---

### Task 10: lib/upgrade.sh — upgrade step functions

**Files:**
- Create: `lib/upgrade.sh`
- Test: `tests/upgrade.bats`

Each function is one upgrade boundary. Tests stub `dnf5` and assert command construction.

- [ ] **Step 1: Write the failing test**

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/upgrade.bats`
Expected: FAIL — `lib/upgrade.sh` missing

- [ ] **Step 3: Write `lib/upgrade.sh`**

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/upgrade.bats`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/upgrade.sh tests/upgrade.bats
git commit -m "Add upgrade orchestration step functions"
```

---

### Task 11: lib/restore.sh — restore_receive and restore_boot

**Files:**
- Create: `lib/restore.sh`
- Test: `tests/restore.bats`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats

load helpers/stubs

setup() {
  setup_stubs
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../lib/restore.sh"
}
teardown() { teardown_stubs; }

@test "restore_receive streams a snapshot from target back to a destination" {
  make_stub btrfs
  run restore_receive /mnt/backup/host/subvols/root root.20260527T143000Z /mnt/btrfs-root
  [ "$status" -eq 0 ]
  grep -q "btrfs send /mnt/backup/host/subvols/root/root.20260527T143000Z" "$STUB_LOG"
  grep -q "btrfs receive /mnt/btrfs-root" "$STUB_LOG"
}

@test "restore_boot extracts a tarball into a mountpoint" {
  make_stub tar
  run restore_boot /mnt/backup/host/boot/boot.20260527T143000Z.tar.zst /boot
  [ "$status" -eq 0 ]
  grep -q "tar --xattrs --acls -xpf /mnt/backup/host/boot/boot.20260527T143000Z.tar.zst -C /boot" "$STUB_LOG"
}

@test "restore_receive honors DRY_RUN" {
  run env DRY_RUN=1 bash -c "source '$BATS_TEST_DIRNAME/../lib/common.sh'; source '$BATS_TEST_DIRNAME/../lib/restore.sh'; restore_receive /t/sub snap /dest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] btrfs send /t/sub/snap | btrfs receive /dest"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/restore.bats`
Expected: FAIL — `lib/restore.sh` missing

- [ ] **Step 3: Write `lib/restore.sh`**

```bash
# Restore primitives used by disaster recovery (bin/frestore).
[[ -n "${_FB_RESTORE_SH:-}" ]] && return 0
_FB_RESTORE_SH=1

# restore_receive <target_subvol_dir> <snap_name> <dest_toplevel>
# Streams a snapshot stored on the backup target back to a destination btrfs.
restore_receive() {
  local target_dir="$1" snap="$2" dest="$3"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '[DRY-RUN] btrfs send %s | btrfs receive %s\n' \
      "$target_dir/$snap" "$dest" >&2
    return 0
  fi
  btrfs send "$target_dir/$snap" | btrfs receive "$dest" ||
    die "restore receive failed for $snap"
}

# restore_boot <tarball> <mountpoint> : extract a boot/efi archive, preserving metadata.
restore_boot() {
  run tar --xattrs --acls -xpf "$1" -C "$2"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/restore.bats`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/restore.sh tests/restore.bats
git commit -m "Add restore receive and boot extraction primitives"
```

---

### Task 12: bin/fbackup-init — format/prepare the USB target

**Files:**
- Create: `bin/fbackup-init`
- Test: `tests/bin_smoke.bats`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats

@test "fbackup-init --help exits 0 and documents usage" {
  run bin/fbackup-init --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"fbackup-init"* ]]
}

@test "fbackup-init is shellcheck-clean" {
  run shellcheck -x bin/fbackup-init
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/bin_smoke.bats`
Expected: FAIL — `bin/fbackup-init` missing

- [ ] **Step 3: Write `bin/fbackup-init`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=../lib/backup_target.sh
source "$REPO_DIR/lib/backup_target.sh"

CONFIG="${FBACKUP_CONFIG:-$REPO_DIR/etc/backup.conf}"

usage() {
  cat <<'EOF'
Usage: fbackup-init [--config PATH] [--dry-run]

One-time preparation of the USB backup target. Formats BACKUP_DEV as btrfs with
label BACKUP_LABEL and creates the directory layout. Refuses to wipe a device
that already holds a filesystem unless FORCE=1 is set in the environment.
EOF
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --help | -h)
        usage
        return 0
        ;;
      --dry-run) export DRY_RUN=1 ;;
      --config=*) CONFIG="${arg#--config=}" ;;
    esac
  done

  require_root
  load_config "$CONFIG"

  [[ -b "$BACKUP_DEV" ]] || die "backup device is not a block device: $BACKUP_DEV"

  log_info "Target device:"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$BACKUP_DEV" >&2 || true
  target_guard "$BACKUP_DEV"

  if ! confirm_phrase "FORMAT" "This ERASES $BACKUP_DEV. Type 'FORMAT' to proceed: "; then
    die "aborted by user"
  fi

  target_format "$BACKUP_DEV" "$BACKUP_LABEL"

  run mkdir -p "$BACKUP_MNT"
  run mount "$BACKUP_DEV" "$BACKUP_MNT"
  local base="$BACKUP_MNT/$HOSTNAME_TAG"
  run mkdir -p "$base/subvols/root" "$base/subvols/home" \
    "$base/boot" "$base/manifests"
  run umount "$BACKUP_MNT"
  log_info "Backup target ready: $BACKUP_LABEL at $BACKUP_DEV"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

- [ ] **Step 4: Make executable and verify the tests pass**

Run: `chmod +x bin/fbackup-init && bats tests/bin_smoke.bats`
Expected: PASS (2 tests)

- [ ] **Step 5: Verify shfmt formatting**

Run: `shfmt -i 2 -ci -d bin/fbackup-init`
Expected: no output, exit 0

- [ ] **Step 6: Commit**

```bash
git add bin/fbackup-init tests/bin_smoke.bats
git commit -m "Add fbackup-init target preparation tool"
```

---

### Task 13: bin/fbackup — main backup orchestration

**Files:**
- Create: `bin/fbackup`
- Test: `tests/bin_smoke.bats` (append)

`fbackup` ties together the lib primitives: mount the top level, snapshot each subvol, send/receive incrementally, tar boot+efi, write the manifest, prune. A `--dry-run` end-to-end test exercises the full flow with stubs.

- [ ] **Step 1: Append failing tests to `tests/bin_smoke.bats`**

```bash
@test "fbackup --help exits 0" {
  run bin/fbackup --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "fbackup is shellcheck-clean" {
  run shellcheck -x bin/fbackup
  [ "$status" -eq 0 ]
}

@test "fbackup --dry-run plans snapshot, send/receive, tar, and manifest" {
  load helpers/stubs
  setup_stubs
  for c in btrfs tar mount umount mkdir sync findmnt rpm; do make_stub "$c"; done
  cfg="$STUB_DIR/backup.conf"
  cat >"$cfg" <<EOF
BACKUP_DEV=/dev/x
BACKUP_LABEL=fedora-backup
BACKUP_MNT=$STUB_DIR/backup
SRC_TOPLEVEL_MNT=$STUB_DIR/top
SUBVOLS=(root home)
SNAP_DIR=_snapshots
BOOT_MNT=/boot
EFI_MNT=/boot/efi
RETENTION_KEEP=3
HOSTNAME_TAG=host
EOF
  mkdir -p "$STUB_DIR/backup/host/manifests" "$STUB_DIR/top/_snapshots"
  run env DRY_RUN=1 FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/fbackup
  teardown_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] btrfs send"* ]]
  [[ "$output" == *"receive"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/bin_smoke.bats`
Expected: FAIL — `bin/fbackup` missing

- [ ] **Step 3: Write `bin/fbackup`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=../lib/snapshots.sh
source "$REPO_DIR/lib/snapshots.sh"
# shellcheck source=../lib/manifest.sh
source "$REPO_DIR/lib/manifest.sh"

CONFIG="${FBACKUP_CONFIG:-$REPO_DIR/etc/backup.conf}"
PREUPGRADE_TAG=""

usage() {
  cat <<'EOF'
Usage: fbackup [--config PATH] [--dry-run] [--preupgrade] [--full]

Snapshot root+home, send/receive incrementally to the USB target, archive
/boot and /boot/efi, write a manifest, and prune old snapshots.

  --preupgrade  tag this snapshot set "preupgrade-f43" (exempt from pruning)
  --full        force a full send (ignore any common parent)
EOF
}

# list_snaps <dir> <subvol> : basenames of snapshots for a subvol in a directory.
list_snaps() {
  local dir="$1" subvol="$2"
  find "$dir" -maxdepth 1 -name "$subvol.*" -printf '%f\n' 2>/dev/null | sort
}

backup_subvol() {
  local subvol="$1" ts="$2" snap_dir="$3" target_base="$4" force_full="$5"
  local name
  if [[ -n "$PREUPGRADE_TAG" ]]; then
    name="$subvol.$PREUPGRADE_TAG.$ts"
  else
    name="$subvol.$ts"
  fi

  fb_snapshot "$SRC_TOPLEVEL_MNT/$subvol" "$snap_dir/$name"

  local parent=""
  if [[ "$force_full" != "1" ]]; then
    parent="$(select_parent "$subvol" \
      "$(list_snaps "$snap_dir" "$subvol")" \
      "$(list_snaps "$target_base/subvols/$subvol" "$subvol")")"
  fi

  fb_send_receive "$snap_dir" "$name" "$parent" "$target_base/subvols/$subvol"
  printf '%s' "$parent"
}

archive_boot() {
  local target_base="$1" ts="$2"
  run tar --xattrs --acls -C "$BOOT_MNT" -cpf - . |
    run_zstd_to "$target_base/boot/boot.$ts.tar.zst"
  run tar --xattrs --acls -C "$EFI_MNT" -cpf - . |
    run_zstd_to "$target_base/boot/efi.$ts.tar.zst"
}

# Helper kept tiny so DRY_RUN handling stays in one place.
run_zstd_to() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '[DRY-RUN] zstd > %s\n' "$1" >&2
    cat >/dev/null
    return 0
  fi
  zstd -q -o "$1"
}

prune_side() {
  local dir="$1" subvol="$2" del
  while IFS= read -r del; do
    [[ -z "$del" ]] && continue
    run btrfs subvolume delete "$dir/$del"
  done < <(prune_candidates "$RETENTION_KEEP" "$(list_snaps "$dir" "$subvol")")
}

main() {
  local force_full=0 arg
  for arg in "$@"; do
    case "$arg" in
      --help | -h)
        usage
        return 0
        ;;
      --dry-run) export DRY_RUN=1 ;;
      --preupgrade) PREUPGRADE_TAG="preupgrade-f43" ;;
      --full) force_full=1 ;;
      --config=*) CONFIG="${arg#--config=}" ;;
    esac
  done

  [[ "${SKIP_ROOT_CHECK:-0}" == "1" ]] || require_root
  load_config "$CONFIG"

  local ts snap_dir target_base
  ts="$(snap_timestamp)"
  snap_dir="$SRC_TOPLEVEL_MNT/$SNAP_DIR"
  target_base="$BACKUP_MNT/$HOSTNAME_TAG"

  run mkdir -p "$SRC_TOPLEVEL_MNT" "$BACKUP_MNT"
  run mount "$BACKUP_DEV" "$BACKUP_MNT"
  local root_src
  root_src="$(findmnt -no SOURCE / | sed 's/\[.*\]//')"
  run mount -o subvolid=5 "$root_src" "$SRC_TOPLEVEL_MNT"
  run mkdir -p "$snap_dir"

  local subvol parent_used=""
  for subvol in "${SUBVOLS[@]}"; do
    parent_used="$(backup_subvol "$subvol" "$ts" "$snap_dir" "$target_base" "$force_full")"
  done

  archive_boot "$target_base" "$ts"

  local manifest
  manifest="$(build_manifest_json "$ts" "$parent_used" \
    "$(. /etc/os-release && printf '%s' "$VERSION_ID")" "$HOSTNAME_TAG" \
    "$(cat /etc/fstab 2>/dev/null || true)" \
    "$(btrfs subvolume list "$SRC_TOPLEVEL_MNT" 2>/dev/null || true)" \
    "$(btrfs filesystem show 2>/dev/null || true)" \
    "$(rpm -q kernel 2>/dev/null || true)")"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '[DRY-RUN] write manifest.%s.json\n' "$ts" >&2
  else
    printf '%s\n' "$manifest" >"$target_base/manifests/manifest.$ts.json"
  fi

  if [[ -z "$PREUPGRADE_TAG" ]]; then
    for subvol in "${SUBVOLS[@]}"; do
      prune_side "$snap_dir" "$subvol"
      prune_side "$target_base/subvols/$subvol" "$subvol"
    done
  fi

  run sync
  run umount "$BACKUP_MNT"
  log_info "Backup complete: timestamp $ts"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

Note: the top-level source mount uses `subvolid=5` of the running root filesystem, with its device resolved via `findmnt` (the `sed` strips the `[/subvol]` suffix).

- [ ] **Step 4: Make executable and run the smoke tests**

Run: `chmod +x bin/fbackup && bats tests/bin_smoke.bats`
Expected: PASS (5 tests total in file)

If the `--dry-run` end-to-end test reveals an unstubbed command, add it to the `make_stub` loop in the test (Step 1) — every external command must be stubbed for the dry run.

- [ ] **Step 5: Verify formatting and lint**

Run: `shfmt -i 2 -ci -d bin/fbackup && shellcheck -x bin/fbackup`
Expected: no output, exit 0

- [ ] **Step 6: Commit**

```bash
git add bin/fbackup tests/bin_smoke.bats
git commit -m "Add fbackup main backup orchestration"
```

---

### Task 14: bin/fsnapshot-preupgrade — tagged rollback anchor

**Files:**
- Create: `bin/fsnapshot-preupgrade`
- Test: `tests/bin_smoke.bats` (append)

This is a thin wrapper that runs `fbackup --preupgrade` and also stashes the current `/boot` + `/boot/efi` locally so the F43 kernel survives a failed upgrade even without the USB attached.

- [ ] **Step 1: Append failing tests**

```bash
@test "fsnapshot-preupgrade --help exits 0" {
  run bin/fsnapshot-preupgrade --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "fsnapshot-preupgrade is shellcheck-clean" {
  run shellcheck -x bin/fsnapshot-preupgrade
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/bin_smoke.bats`
Expected: FAIL — `bin/fsnapshot-preupgrade` missing

- [ ] **Step 3: Write `bin/fsnapshot-preupgrade`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../lib/common.sh
source "$REPO_DIR/lib/common.sh"

CONFIG="${FBACKUP_CONFIG:-$REPO_DIR/etc/backup.conf}"
LOCAL_STASH="${LOCAL_BOOT_STASH:-/var/lib/fedora-backup/boot-stash}"

usage() {
  cat <<'EOF'
Usage: fsnapshot-preupgrade [--config PATH] [--dry-run]

Create the pre-upgrade rollback anchor: a tagged "preupgrade-f43" snapshot set
on the USB target (via fbackup --preupgrade) plus a LOCAL copy of /boot and
/boot/efi, so the F43 kernel survives a failed upgrade even without the USB.
EOF
}

main() {
  local passthru=() arg
  for arg in "$@"; do
    case "$arg" in
      --help | -h)
        usage
        return 0
        ;;
      *) passthru+=("$arg") ;;
    esac
  done

  [[ "${SKIP_ROOT_CHECK:-0}" == "1" ]] || require_root

  log_info "Stashing /boot and /boot/efi locally to $LOCAL_STASH"
  run mkdir -p "$LOCAL_STASH"
  run tar --xattrs --acls -C /boot -cpf "$LOCAL_STASH/boot.tar" .
  run tar --xattrs --acls -C /boot/efi -cpf "$LOCAL_STASH/efi.tar" .

  log_info "Creating tagged preupgrade snapshot set on the USB target"
  FBACKUP_CONFIG="$CONFIG" "$SCRIPT_DIR/fbackup" --preupgrade "${passthru[@]}"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

- [ ] **Step 4: Make executable and run tests**

Run: `chmod +x bin/fsnapshot-preupgrade && bats tests/bin_smoke.bats`
Expected: PASS

- [ ] **Step 5: Verify formatting and lint**

Run: `shfmt -i 2 -ci -d bin/fsnapshot-preupgrade && shellcheck -x bin/fsnapshot-preupgrade`
Expected: no output, exit 0

- [ ] **Step 6: Commit**

```bash
git add bin/fsnapshot-preupgrade tests/bin_smoke.bats
git commit -m "Add fsnapshot-preupgrade rollback anchor tool"
```

---

### Task 15: bin/fupgrade — F43→44 orchestration

**Files:**
- Create: `bin/fupgrade`
- Test: `tests/bin_smoke.bats` (append)

`fupgrade` exposes one subcommand per upgrade boundary so a human drives each transition explicitly.

- [ ] **Step 1: Append failing tests**

```bash
@test "fupgrade --help lists subcommands" {
  run bin/fupgrade --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"preflight"* ]]
  [[ "$output" == *"download"* ]]
  [[ "$output" == *"apply"* ]]
}

@test "fupgrade is shellcheck-clean" {
  run shellcheck -x bin/fupgrade
  [ "$status" -eq 0 ]
}

@test "fupgrade rejects an unknown subcommand" {
  run bin/fupgrade frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown subcommand"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/bin_smoke.bats`
Expected: FAIL — `bin/fupgrade` missing

- [ ] **Step 3: Write `bin/fupgrade`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=../lib/upgrade.sh
source "$REPO_DIR/lib/upgrade.sh"

CONFIG="${FBACKUP_CONFIG:-$REPO_DIR/etc/backup.conf}"
TARGET_RELEASE=44

usage() {
  cat <<'EOF'
Usage: fupgrade <subcommand> [--config PATH] [--dry-run]

Drive the Fedora 43 -> 44 upgrade one boundary at a time:

  preflight   verify a backup dated today exists and the system is healthy
  refresh     fully patch the current F43 system (reboot afterwards if asked)
  snapshot    create the pre-upgrade rollback anchor (fsnapshot-preupgrade)
  download    install the plugin and stage the F44 transaction
  apply       reboot into the offline upgrade
  post        post-upgrade health checks
EOF
}

main() {
  local sub="${1:-}" arg
  shift || true
  for arg in "$@"; do
    case "$arg" in
      --dry-run) export DRY_RUN=1 ;;
      --config=*) CONFIG="${arg#--config=}" ;;
    esac
  done

  case "$sub" in
    --help | -h | "")
      usage
      return 0
      ;;
    preflight)
      [[ "${SKIP_ROOT_CHECK:-0}" == "1" ]] || require_root
      load_config "$CONFIG"
      run mount "$BACKUP_DEV" "$BACKUP_MNT" 2>/dev/null || true
      up_preflight "$BACKUP_MNT" "$HOSTNAME_TAG"
      run umount "$BACKUP_MNT" 2>/dev/null || true
      run dnf5 check
      ;;
    refresh)
      require_root
      up_refresh
      log_info "If the kernel changed, reboot before continuing."
      ;;
    snapshot)
      require_root
      FBACKUP_CONFIG="$CONFIG" "$SCRIPT_DIR/fsnapshot-preupgrade"
      ;;
    download)
      require_root
      up_download "$TARGET_RELEASE"
      ;;
    apply)
      require_root
      up_apply
      ;;
    post)
      up_post
      log_info "Verify: cat /etc/os-release (VERSION_ID=$TARGET_RELEASE), uname -r, desktop session."
      ;;
    *)
      die "unknown subcommand: $sub (see --help)"
      ;;
  esac
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

- [ ] **Step 4: Make executable and run tests**

Run: `chmod +x bin/fupgrade && bats tests/bin_smoke.bats`
Expected: PASS

- [ ] **Step 5: Verify formatting and lint**

Run: `shfmt -i 2 -ci -d bin/fupgrade && shellcheck -x bin/fupgrade`
Expected: no output, exit 0

- [ ] **Step 6: Commit**

```bash
git add bin/fupgrade tests/bin_smoke.bats
git commit -m "Add fupgrade orchestration tool"
```

---

### Task 16: bin/frestore — disaster recovery from the target

**Files:**
- Create: `bin/frestore`
- Test: `tests/bin_smoke.bats` (append)

`frestore` automates receive + boot extraction and prints guided steps for the parts that must be human-driven (fstab UUID rewrite, bootloader reinstall). Default mode is dry-run; `--apply` is required to act.

- [ ] **Step 1: Append failing tests**

```bash
@test "frestore --help exits 0 and warns about live environment" {
  run bin/frestore --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"live"* || "$output" == *"rescue"* ]]
}

@test "frestore is shellcheck-clean" {
  run shellcheck -x bin/frestore
  [ "$status" -eq 0 ]
}

@test "frestore defaults to dry-run without --apply" {
  load helpers/stubs
  setup_stubs
  for c in btrfs tar mount umount mkdir findmnt; do make_stub "$c"; done
  cfg="$STUB_DIR/backup.conf"
  cat >"$cfg" <<EOF
BACKUP_DEV=/dev/x
BACKUP_LABEL=fedora-backup
BACKUP_MNT=$STUB_DIR/backup
SRC_TOPLEVEL_MNT=$STUB_DIR/top
SUBVOLS=(root home)
SNAP_DIR=_snapshots
BOOT_MNT=/boot
EFI_MNT=/boot/efi
RETENTION_KEEP=3
HOSTNAME_TAG=host
EOF
  run env FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/frestore --snapshot root.20260527T143000Z
  teardown_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/bin_smoke.bats`
Expected: FAIL — `bin/frestore` missing

- [ ] **Step 3: Write `bin/frestore`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=../lib/restore.sh
source "$REPO_DIR/lib/restore.sh"

CONFIG="${FBACKUP_CONFIG:-$REPO_DIR/etc/backup.conf}"
DEST_TOPLEVEL="${DEST_TOPLEVEL:-/mnt/restore-target}"
SNAPSHOT=""

usage() {
  cat <<'EOF'
Usage: frestore --snapshot <root.TIMESTAMP> [--config PATH] [--apply]

Disaster recovery from the USB target. Run from a Fedora live/rescue
environment. Without --apply this performs a DRY-RUN and changes nothing.

Automated:   receive root (and matching home) snapshots, extract /boot + /efi.
Guided only: fstab UUID rewrite and bootloader reinstall are PRINTED for you
to perform, because they depend on the new disk's UUIDs and UEFI layout.
EOF
}

main() {
  export DRY_RUN=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        usage
        return 0
        ;;
      --apply)
        export DRY_RUN=0
        shift
        ;;
      --snapshot)
        SNAPSHOT="${2:-}"
        shift 2
        ;;
      --snapshot=*)
        SNAPSHOT="${1#--snapshot=}"
        shift
        ;;
      --config)
        CONFIG="${2:-}"
        shift 2
        ;;
      --config=*)
        CONFIG="${1#--config=}"
        shift
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  [[ -n "$SNAPSHOT" ]] || die "missing --snapshot <root.TIMESTAMP>"
  [[ "${SKIP_ROOT_CHECK:-0}" == "1" ]] || require_root
  load_config "$CONFIG"

  local base ts home_snap
  base="$BACKUP_MNT/$HOSTNAME_TAG"
  ts="${SNAPSHOT#root.}"
  home_snap="home.$ts"

  run mkdir -p "$BACKUP_MNT" "$DEST_TOPLEVEL"
  run mount "$BACKUP_DEV" "$BACKUP_MNT"

  log_info "Receiving $SNAPSHOT and $home_snap onto $DEST_TOPLEVEL"
  restore_receive "$base/subvols/root" "$SNAPSHOT" "$DEST_TOPLEVEL"
  restore_receive "$base/subvols/home" "$home_snap" "$DEST_TOPLEVEL"

  log_info "Extracting boot archives (mount your new /boot and /boot/efi first)"
  restore_boot "$base/boot/boot.$ts.tar.zst" "$BOOT_MNT"
  restore_boot "$base/boot/efi.$ts.tar.zst" "$EFI_MNT"

  run umount "$BACKUP_MNT"

  cat >&2 <<'EOF'

NEXT (manual, see docs/RUNBOOK.md):
  1. Snapshot the received read-only subvols to canonical names:
       btrfs subvolume snapshot DEST/root.<ts>  DEST/root
       btrfs subvolume snapshot DEST/home.<ts>  DEST/home
  2. Rewrite /etc/fstab UUIDs to the new filesystems (use manifest as reference).
  3. Reinstall the bootloader and regenerate initramfs:
       grub2-mkconfig -o /boot/grub2/grub.cfg
       (UEFI: ensure the EFI entry points at the new ESP)
EOF
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

- [ ] **Step 4: Make executable and run tests**

Run: `chmod +x bin/frestore && bats tests/bin_smoke.bats`
Expected: PASS

- [ ] **Step 5: Verify formatting and lint**

Run: `shfmt -i 2 -ci -d bin/frestore && shellcheck -x bin/frestore`
Expected: no output, exit 0

- [ ] **Step 6: Commit**

```bash
git add bin/frestore tests/bin_smoke.bats
git commit -m "Add frestore disaster recovery tool"
```

---

### Task 17: docs/RUNBOOK.md — the human procedure

**Files:**
- Create: `docs/RUNBOOK.md`
- Modify: `README.md`

- [ ] **Step 1: Write `docs/RUNBOOK.md`**

````markdown
# Fedora 43 → 44 Backup & Upgrade Runbook

All commands run as root. Configuration lives in `etc/backup.conf` (copy from
`etc/backup.conf.example`). The backup device is addressed by its by-id path so
device-letter changes can never misdirect a format.

## 0. One-time setup

```bash
cp etc/backup.conf.example etc/backup.conf
# Confirm the by-id path of the USB target:
ls -l /dev/disk/by-id | grep -i sandisk
# Confirm the root btrfs topology (single vs multi-device) and record it:
btrfs filesystem show /
# Prepare the target (ERASES the USB):
sudo ./bin/fbackup-init
sudo dnf5 install -y bats   # only needed to run the test suite
```

## 1. Back up

```bash
sudo ./bin/fbackup --dry-run   # inspect the plan first
sudo ./bin/fbackup             # first run is a full send; later runs incremental
```

Verify on the target: `subvols/root/root.<ts>`, `subvols/home/home.<ts>`,
`boot/boot.<ts>.tar.zst`, `boot/efi.<ts>.tar.zst`, and
`manifests/manifest.<ts>.json` exist.

## 2. Upgrade to Fedora 44

```bash
sudo ./bin/fupgrade preflight   # requires a backup dated today; runs dnf5 check
sudo ./bin/fupgrade refresh     # fully patch F43; reboot if the kernel changed
sudo ./bin/fupgrade snapshot    # pre-upgrade rollback anchor + local /boot stash
sudo ./bin/fupgrade download    # installs plugin, stages F44; resolve conflicts here
sudo ./bin/fupgrade apply       # reboots into the offline upgrade
# ... system installs F44 and reboots into it ...
sudo ./bin/fupgrade post        # health checks; then optional dnf5 autoremove
```

## 3. Roll back

Decision tree:

| Situation | Path |
|---|---|
| F44 boots but broken; disk OK | Local rollback (below) |
| F44 won't boot; disk OK | Boot the F43 kernel entry if present, else live USB → local rollback |
| NVMe dead / replaced | External disaster recovery (below) |

### Local rollback (from F43 rescue or a Fedora live USB)

```bash
# Mount the btrfs top level (root fs device, subvolid=5):
ROOT_SRC=$(findmnt -no SOURCE / | sed 's/\[.*\]//')   # or identify from live USB
mount -o subvolid=5 "$ROOT_SRC" /mnt/top
cd /mnt/top
mv root root.broken-f44
btrfs subvolume snapshot _snapshots/root.preupgrade-f43.<ts> root
# Restore the F43 boot from the local stash:
tar --xattrs --acls -xpf /var/lib/fedora-backup/boot-stash/boot.tar -C /boot
tar --xattrs --acls -xpf /var/lib/fedora-backup/boot-stash/efi.tar  -C /boot/efi
reboot
```

`/home` is intentionally NOT rolled back — you keep data created after the
upgrade. Roll it back only if you specifically need the pre-upgrade home.

### External disaster recovery (new/blank disk, from a live USB)

1. Partition the new disk per the manifest (`fstab`, `fs_show`): EFI vfat,
   `/boot` ext4, btrfs root. Recreate the same btrfs topology, or consciously
   collapse a former multi-device filesystem to a single device.
2. Mount the new btrfs top level at `/mnt/restore-target`, the new `/boot` and
   `/boot/efi`, then:
   ```bash
   sudo ./bin/frestore --snapshot root.<ts>           # dry-run first
   sudo ./bin/frestore --snapshot root.<ts> --apply
   ```
3. Follow the printed NEXT steps: snapshot received subvols to canonical
   `root`/`home`, rewrite `/etc/fstab` UUIDs from the manifest, reinstall the
   bootloader, regenerate initramfs.

## Notes

- The root filesystem may span two NVMe devices (`nvme1n1p3` + `nvme3n1p1`).
  Confirm with `btrfs filesystem show` and record it before any restore.
- `/boot` and `/boot/efi` are separate non-btrfs partitions; their tarballs are
  what make a rollback bootable. Never skip them.
````

- [ ] **Step 2: Replace `README.md`**

```markdown
# Fedora 43 → 44 btrfs Backup & Upgrade Tools

Bash tooling to back up this Fedora 43 btrfs system (root + home subvolumes,
plus /boot and /boot/efi) to a USB btrfs drive via incremental
`btrfs send/receive`, then upgrade to Fedora 44 with local-snapshot and
external restore paths.

## Tools

| Tool | Purpose |
|---|---|
| `bin/fbackup-init` | One-time: format/prepare the USB backup target |
| `bin/fbackup` | Snapshot → incremental send/receive → boot archives → manifest → prune |
| `bin/fsnapshot-preupgrade` | Pre-upgrade rollback anchor + local /boot stash |
| `bin/fupgrade` | F43 → 44 upgrade, one boundary per subcommand |
| `bin/frestore` | Disaster recovery from the USB target |

## Usage

See [docs/RUNBOOK.md](docs/RUNBOOK.md). Start by copying
`etc/backup.conf.example` to `etc/backup.conf` and adjusting it.

## Development

```bash
sudo dnf5 install -y bats
bats tests/                 # unit + command-construction tests
prek run --all-files        # shellcheck + shfmt + bats
```

Integration tests touch real loopback btrfs filesystems and need root:

```bash
sudo FBACKUP_INTEGRATION=1 bats tests/integration/
```
```

- [ ] **Step 3: Commit**

```bash
git add docs/RUNBOOK.md README.md
git commit -m "Add runbook and update README"
```

---

### Task 18: Integration test — real loopback send/receive (opt-in)

**Files:**
- Create: `tests/integration/send_receive.bats`

This exercises the real `fb_snapshot` + `fb_send_receive` against loopback btrfs filesystems. It needs root and is skipped unless `FBACKUP_INTEGRATION=1`.

- [ ] **Step 1: Write the integration test**

```bash
#!/usr/bin/env bats
# bats test_tags=integration

setup() {
  if [[ "${FBACKUP_INTEGRATION:-0}" != "1" ]]; then
    skip "set FBACKUP_INTEGRATION=1 (and run as root) to enable"
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    skip "integration tests require root"
  fi
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/snapshots.sh"

  WORK="$(mktemp -d)"
  SRC_IMG="$WORK/src.img"
  DST_IMG="$WORK/dst.img"
  SRC_MNT="$WORK/src"
  DST_MNT="$WORK/dst"
  truncate -s 600M "$SRC_IMG"
  truncate -s 600M "$DST_IMG"
  mkfs.btrfs -q "$SRC_IMG"
  mkfs.btrfs -q "$DST_IMG"
  mkdir -p "$SRC_MNT" "$DST_MNT"
  mount -o loop "$SRC_IMG" "$SRC_MNT"
  mount -o loop "$DST_IMG" "$DST_MNT"
  btrfs subvolume create "$SRC_MNT/root" >/dev/null
  mkdir -p "$SRC_MNT/_snapshots"
}

teardown() {
  [[ "${FBACKUP_INTEGRATION:-0}" != "1" ]] && return 0
  mountpoint -q "$SRC_MNT" && umount "$SRC_MNT"
  mountpoint -q "$DST_MNT" && umount "$DST_MNT"
  rm -rf "$WORK"
}

@test "full then incremental send/receive lands real subvolumes on the target" {
  echo "hello" >"$SRC_MNT/root/file1"
  ts1="20260527T100000Z"
  fb_snapshot "$SRC_MNT/root" "$SRC_MNT/_snapshots/root.$ts1"
  fb_send_receive "$SRC_MNT/_snapshots" "root.$ts1" "" "$DST_MNT"
  [ -f "$DST_MNT/root.$ts1/file1" ]

  echo "world" >"$SRC_MNT/root/file2"
  ts2="20260527T110000Z"
  fb_snapshot "$SRC_MNT/root" "$SRC_MNT/_snapshots/root.$ts2"
  parent="$(select_parent root \
    "$(find "$SRC_MNT/_snapshots" -maxdepth 1 -name 'root.*' -printf '%f\n')" \
    "$(find "$DST_MNT" -maxdepth 1 -name 'root.*' -printf '%f\n')")"
  [ "$parent" = "root.$ts1" ]
  fb_send_receive "$SRC_MNT/_snapshots" "root.$ts2" "$parent" "$DST_MNT"
  [ -f "$DST_MNT/root.$ts2/file2" ]
}
```

- [ ] **Step 2: Run it disabled (should skip cleanly)**

Run: `bats tests/integration/send_receive.bats`
Expected: 1 test, skipped (not failed)

- [ ] **Step 3: Run it enabled, as root**

Run: `sudo FBACKUP_INTEGRATION=1 bats tests/integration/send_receive.bats`
Expected: PASS (1 test)

- [ ] **Step 4: Run the full suite once more**

Run: `bats tests/`
Expected: all unit/command tests PASS, integration test skipped

- [ ] **Step 5: Commit**

```bash
git add tests/integration/send_receive.bats
git commit -m "Add opt-in loopback send/receive integration test"
```

---

## Final verification

- [ ] Run the whole suite: `bats tests/` — all pass (integration skipped)
- [ ] Lint everything: `prek run --all-files` — shellcheck, shfmt, bats all clean
- [ ] Confirm no `etc/backup.conf` was committed: `git status --porcelain etc/`
- [ ] Dry-run the real flow end to end (with USB attached, config filled in):
      `sudo ./bin/fbackup --dry-run` and read the planned commands
