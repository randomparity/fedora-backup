# Review Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four failure-path findings from the adversarial review so the recovery and backup paths fail safely, idempotently, and visibly.

**Architecture:** Four independent hardening changes across `lib/` and `bin/`. Library primitives gain symmetric partial-failure cleanup; `frestore` gains a cleanup trap, idempotent mount, mount-ownership tracking, and a pre-flight that refuses to clobber an existing restore target; `fbackup` only unmounts what it mounted and serializes runs with `flock`. Each change is test-first using the existing bats + PATH-stub harness (`tests/helpers/stubs.bash`).

**Tech Stack:** Bash (`set -euo pipefail`), bats-core test runner, PATH command stubs, `flock` (util-linux), shellcheck, shfmt.

**Design decisions (assumptions stated for review):**
- **frestore re-run policy:** refuse and exit with a clear message when a canonical subvol or a leftover received snapshot already exists at the destination. Fail fast; do not auto-delete a target the operator may not expect us to touch.
- **Lock scope:** only `fbackup` acquires the lock. `fsnapshot-preupgrade` shells out to `fbackup`, so it is covered transitively; adding a second lock there would self-deadlock. `frestore` runs in a one-shot recovery environment and is not locked.
- **Lock path:** `${FB_LOCK:-/run/fedora-backup.lock}`. Overridable so tests use a writable temp path.
- **fbackup-init is out of scope:** its unconditional unmount is correct by design (it formats the device and mounts the fresh filesystem itself), so it is left unchanged to avoid scope creep.

---

## File Structure

- `lib/snapshots.sh` — `fb_send_receive` gains a loud, distinct error when the partial-target delete fails (Finding 4).
- `lib/restore.sh` — `restore_receive` gains partial-target cleanup mirroring `fb_send_receive` (Finding 1).
- `bin/frestore` — cleanup trap, idempotent + tracked mount, pre-flight existence check (Finding 1).
- `bin/fbackup` — mount-ownership flags so cleanup only unmounts what it mounted (Finding 2); `flock` serialization (Finding 3).
- `tests/snapshots_transfer.bats` — new coverage for both delete-success and delete-failure branches.
- `tests/restore.bats` — new coverage for the partial-cleanup branch.
- `tests/bin_smoke.bats` — updated fbackup/frestore stubs and env; new tests for mount-ownership and lock contention.

---

## Task 1: `fb_send_receive` reports a wedged target loudly (Finding 4)

**Files:**
- Modify: `lib/snapshots.sh:69-72`
- Test: `tests/snapshots_transfer.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/snapshots_transfer.bats`:

```bash
@test "fb_send_receive reports removed partial target when delete succeeds" {
  cat >"$STUB_DIR/btrfs" <<'EOF'
#!/usr/bin/env bash
printf 'btrfs %s\n' "$*" >>"$STUB_LOG"
cat >/dev/null 2>&1 || true
[[ "$1" == "receive" ]] && exit 1
exit 0
EOF
  chmod +x "$STUB_DIR/btrfs"
  run fb_send_receive /snaps root.20260527T143000Z "" /mnt/backup/host/subvols/root
  [ "$status" -ne 0 ]
  [[ "$output" == *"removed partial target /mnt/backup/host/subvols/root/root.20260527T143000Z"* ]]
  grep -q "btrfs subvolume delete /mnt/backup/host/subvols/root/root.20260527T143000Z" "$STUB_LOG"
}

@test "fb_send_receive demands manual cleanup when delete also fails" {
  cat >"$STUB_DIR/btrfs" <<'EOF'
#!/usr/bin/env bash
printf 'btrfs %s\n' "$*" >>"$STUB_LOG"
cat >/dev/null 2>&1 || true
[[ "$1" == "receive" ]] && exit 1
[[ "$1 $2" == "subvolume delete" ]] && exit 1
exit 0
EOF
  chmod +x "$STUB_DIR/btrfs"
  run fb_send_receive /snaps root.20260527T143000Z "" /mnt/backup/host/subvols/root
  [ "$status" -ne 0 ]
  [[ "$output" == *"MANUAL CLEANUP REQUIRED"* ]]
  [[ "$output" == *"btrfs subvolume delete /mnt/backup/host/subvols/root/root.20260527T143000Z"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/snapshots_transfer.bats`
Expected: the two new tests FAIL (current code prints `cleaned up partial target`, never `removed partial target` or `MANUAL CLEANUP REQUIRED`).

- [ ] **Step 3: Implement the loud failure branch**

In `lib/snapshots.sh`, replace lines 69-72:

```bash
  if [[ "$ok" -ne 1 ]]; then
    btrfs subvolume delete "$target/$new" >/dev/null 2>&1 || true
    die "send/receive failed for $new (cleaned up partial target)"
  fi
```

with:

```bash
  if [[ "$ok" -ne 1 ]]; then
    if btrfs subvolume delete "$target/$new" >/dev/null 2>&1; then
      die "send/receive failed for $new (removed partial target $target/$new)"
    fi
    log_error "send/receive failed for $new and the partial target could not be removed"
    die "MANUAL CLEANUP REQUIRED: run 'btrfs subvolume delete $target/$new' before the next backup"
  fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/snapshots_transfer.bats`
Expected: PASS, including the pre-existing `fb_send_receive deletes partial target subvolume on failure` test (which uses `make_stub btrfs 1`, exercising the MANUAL branch).

- [ ] **Step 5: Lint**

Run: `shellcheck -x lib/snapshots.sh && shfmt -d lib/snapshots.sh`
Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add lib/snapshots.sh tests/snapshots_transfer.bats
git commit -m "Make fb_send_receive flag an unremovable partial target" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `restore_receive` cleans up a partial target (Finding 1, part 1)

**Files:**
- Modify: `lib/restore.sh:8-17`
- Test: `tests/restore.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/restore.bats`:

```bash
@test "restore_receive deletes the partial target on receive failure" {
  cat >"$STUB_DIR/btrfs" <<'EOF'
#!/usr/bin/env bash
printf 'btrfs %s\n' "$*" >>"$STUB_LOG"
cat >/dev/null 2>&1 || true
[[ "$1" == "receive" ]] && exit 1
exit 0
EOF
  chmod +x "$STUB_DIR/btrfs"
  run restore_receive /mnt/backup/host/subvols/root root.20260527T143000Z /mnt/restore-target
  [ "$status" -ne 0 ]
  [[ "$output" == *"restore receive failed for root.20260527T143000Z"* ]]
  grep -q "btrfs subvolume delete /mnt/restore-target/root.20260527T143000Z" "$STUB_LOG"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/restore.bats`
Expected: new test FAILS (current `restore_receive` never runs `btrfs subvolume delete`).

- [ ] **Step 3: Implement partial cleanup**

In `lib/restore.sh`, replace the `restore_receive` body (lines 8-17):

```bash
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
```

with:

```bash
restore_receive() {
  local target_dir="$1" snap="$2" dest="$3"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '[DRY-RUN] btrfs send %s | btrfs receive %s\n' \
      "$target_dir/$snap" "$dest" >&2
    return 0
  fi
  if ! btrfs send "$target_dir/$snap" | btrfs receive "$dest"; then
    btrfs subvolume delete "$dest/$snap" >/dev/null 2>&1 || true
    die "restore receive failed for $snap (cleaned up partial $dest/$snap)"
  fi
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/restore.bats`
Expected: PASS, including the pre-existing `restore_receive streams...` and `restore_receive honors DRY_RUN` tests.

- [ ] **Step 5: Lint**

Run: `shellcheck -x lib/restore.sh && shfmt -d lib/restore.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/restore.sh tests/restore.bats
git commit -m "Clean up partial target on restore_receive failure" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `frestore` cleanup trap, idempotent mount, and pre-flight (Finding 1, part 2)

**Files:**
- Modify: `bin/frestore:18` (globals), `bin/frestore:41-99` (cleanup + mount + pre-flight), `bin/frestore:126` (remove trailing umount)
- Test: `tests/bin_smoke.bats:68-118` (update existing frestore tests to set `DEST_TOPLEVEL`), plus new failure-path tests

This task depends on Task 2 (`restore_receive` now cleans its own partial subvol).

- [ ] **Step 1: Write the failing tests**

First, make the two existing frestore dry-run tests hermetic by adding `DEST_TOPLEVEL` to their `run env` lines so the new pre-flight check never reads a real `/mnt/restore-target`.

In `tests/bin_smoke.bats`, change line 85 from:

```bash
  run env FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/frestore --snapshot root.20260527T143000Z
```

to:

```bash
  run env FBACKUP_CONFIG="$cfg" DEST_TOPLEVEL="$STUB_DIR/dest" SKIP_ROOT_CHECK=1 bin/frestore --snapshot root.20260527T143000Z
```

and change lines 112-113 from:

```bash
  run env FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/frestore \
    --snapshot root.20260527T143000Z --boot-dir "$STUB_DIR/nb" --efi-dir "$STUB_DIR/ne"
```

to:

```bash
  run env FBACKUP_CONFIG="$cfg" DEST_TOPLEVEL="$STUB_DIR/dest" SKIP_ROOT_CHECK=1 bin/frestore \
    --snapshot root.20260527T143000Z --boot-dir "$STUB_DIR/nb" --efi-dir "$STUB_DIR/ne"
```

Then append two new tests to `tests/bin_smoke.bats`:

```bash
@test "frestore --apply refuses to overwrite an existing destination subvol" {
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
  mkdir -p "$STUB_DIR/dest/root"
  run env FBACKUP_CONFIG="$cfg" DEST_TOPLEVEL="$STUB_DIR/dest" SKIP_ROOT_CHECK=1 \
    bin/frestore --apply --snapshot root.20260527T143000Z
  log="$STUB_LOG"
  has_send=0; grep -q "btrfs send" "$log" && has_send=1
  teardown_stubs
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has a subvolume named 'root'"* ]]
  [ "$has_send" -eq 0 ]
}

@test "frestore --apply cleans the partial target and unmounts on receive failure" {
  load helpers/stubs
  setup_stubs
  for c in tar mount umount mkdir; do make_stub "$c"; done
  # findmnt reports nothing mounted, so frestore mounts and must unmount on exit.
  make_stub findmnt 1
  cat >"$STUB_DIR/btrfs" <<'EOF'
#!/usr/bin/env bash
printf 'btrfs %s\n' "$*" >>"$STUB_LOG"
cat >/dev/null 2>&1 || true
[[ "$1" == "receive" ]] && exit 1
exit 0
EOF
  chmod +x "$STUB_DIR/btrfs"
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
  run env FBACKUP_CONFIG="$cfg" DEST_TOPLEVEL="$STUB_DIR/dest" SKIP_ROOT_CHECK=1 \
    bin/frestore --apply --snapshot root.20260527T143000Z
  log="$STUB_LOG"
  has_delete=0; grep -q "btrfs subvolume delete $STUB_DIR/dest/root.20260527T143000Z" "$log" && has_delete=1
  has_umount=0; grep -q "umount $STUB_DIR/backup" "$log" && has_umount=1
  teardown_stubs
  [ "$status" -ne 0 ]
  [ "$has_delete" -eq 1 ]
  [ "$has_umount" -eq 1 ]
}
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `bats tests/bin_smoke.bats`
Expected: the two new tests FAIL — current `frestore` has no pre-flight check (so it proceeds and never prints the refusal) and no cleanup trap (so `umount` does not run after a `die`). The updated existing frestore dry-run tests should still PASS.

- [ ] **Step 3: Add the mount-ownership global and cleanup function**

In `bin/frestore`, change the globals block at lines 17-18 from:

```bash
# Populated by load_config; declared here so shellcheck tracks them as globals.
BACKUP_DEV="" BACKUP_MNT="" HOSTNAME_TAG=""
```

to:

```bash
# Populated by load_config; declared here so shellcheck tracks them as globals.
BACKUP_DEV="" BACKUP_MNT="" HOSTNAME_TAG=""
mounted_backup=0

# cleanup : unmount the backup target only if this run mounted it.
cleanup() {
  [[ "$mounted_backup" == "1" ]] && { run umount "$BACKUP_MNT" || true; }
  return 0
}
```

- [ ] **Step 4: Make the mount idempotent and tracked, and add the pre-flight check**

In `bin/frestore`, replace lines 98-106:

```bash
  run mkdir -p "$BACKUP_MNT" "$DEST_TOPLEVEL"
  run mount "$BACKUP_DEV" "$BACKUP_MNT"

  for subvol in "${SUBVOLS[@]}"; do
    snap="$subvol.$ts"
    log_info "Receiving $snap onto $DEST_TOPLEVEL"
    restore_receive "$base/subvols/$subvol" "$snap" "$DEST_TOPLEVEL"
    restore_canonicalize "$DEST_TOPLEVEL" "$snap" "$subvol"
  done
```

with:

```bash
  run mkdir -p "$BACKUP_MNT" "$DEST_TOPLEVEL"
  trap cleanup EXIT
  if ! findmnt -rno TARGET "$BACKUP_MNT" >/dev/null 2>&1; then
    run mount "$BACKUP_DEV" "$BACKUP_MNT"
    mounted_backup=1
  fi

  for subvol in "${SUBVOLS[@]}"; do
    snap="$subvol.$ts"
    if [[ -e "$DEST_TOPLEVEL/$subvol" ]]; then
      die "destination already has a subvolume named '$subvol' at $DEST_TOPLEVEL; refusing to overwrite (clean the target first)"
    fi
    if [[ -e "$DEST_TOPLEVEL/$snap" ]]; then
      die "destination already has '$snap' at $DEST_TOPLEVEL (leftover from a previous run?); remove it first"
    fi
  done

  for subvol in "${SUBVOLS[@]}"; do
    snap="$subvol.$ts"
    log_info "Receiving $snap onto $DEST_TOPLEVEL"
    restore_receive "$base/subvols/$subvol" "$snap" "$DEST_TOPLEVEL"
    restore_canonicalize "$DEST_TOPLEVEL" "$snap" "$subvol"
  done
```

- [ ] **Step 5: Remove the trailing unconditional umount (now handled by the trap)**

In `bin/frestore`, delete line 126:

```bash
  run umount "$BACKUP_MNT"
```

(The cleanup trap unmounts on every exit path, including the success path, but only if this run mounted the target.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats tests/bin_smoke.bats`
Expected: PASS, including the updated frestore dry-run tests and both new failure-path tests.

- [ ] **Step 7: Lint**

Run: `shellcheck -x bin/frestore && shfmt -d bin/frestore`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add bin/frestore tests/bin_smoke.bats
git commit -m "Harden frestore: cleanup trap, idempotent mount, target guard" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `fbackup` unmounts only what it mounted (Finding 2)

**Files:**
- Modify: `bin/fbackup:14` (globals), `bin/fbackup:90-94` (cleanup), `bin/fbackup:121` and `bin/fbackup:128-130` (tracked mounts)
- Test: `tests/bin_smoke.bats:168` (stub change) + new ownership test

- [ ] **Step 1: Write the failing test and update the existing smoke test**

First, update the existing `fbackup --dry-run plans ...` test so the mount path runs (and the umount assertions still hold under the new flag-based cleanup). In `tests/bin_smoke.bats`, change line 168 from:

```bash
  for c in btrfs tar mount umount mkdir sync findmnt rpm zstd; do make_stub "$c"; done
```

to:

```bash
  for c in btrfs tar mount umount mkdir sync rpm zstd; do make_stub "$c"; done
  make_stub findmnt 1
```

Then append a new test to `tests/bin_smoke.bats`:

```bash
@test "fbackup does not unmount a backup target it did not mount" {
  load helpers/stubs
  setup_stubs
  for c in btrfs tar mount umount mkdir sync rpm zstd; do make_stub "$c"; done
  # findmnt: report BACKUP_MNT already mounted, everything else not mounted.
  cat >"$STUB_DIR/findmnt" <<EOF
#!/usr/bin/env bash
printf 'findmnt %s\n' "\$*" >>"\$STUB_LOG"
for a in "\$@"; do
  [[ "\$a" == "$STUB_DIR/backup" ]] && exit 0
done
exit 1
EOF
  chmod +x "$STUB_DIR/findmnt"
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
  mkdir -p "$STUB_DIR/backup/host/subvols/root" "$STUB_DIR/backup/host/subvols/home" "$STUB_DIR/backup/host/manifests" "$STUB_DIR/top/_snapshots"
  run env DRY_RUN=1 FB_LOCK="$STUB_DIR/fb.lock" FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/fbackup
  teardown_stubs
  [ "$status" -eq 0 ]
  # We mounted SRC ourselves, so we unmount it...
  [[ "$output" == *"[DRY-RUN] umount $STUB_DIR/top"* ]]
  # ...but the backup target was already mounted, so we must NOT unmount it.
  [[ "$output" != *"umount $STUB_DIR/backup"* ]]
}
```

(The `FB_LOCK` env is harmless now and required after Task 5; including it here avoids editing this test twice.)

- [ ] **Step 2: Run the tests to verify the new one fails**

Run: `bats tests/bin_smoke.bats`
Expected: the new ownership test FAILS — current `cleanup` calls `findmnt` and unmounts `BACKUP_MNT` because it reports mounted, regardless of who mounted it.

- [ ] **Step 3: Add mount-ownership globals**

In `bin/fbackup`, change line 14 from:

```bash
PREUPGRADE_TAG=""
```

to:

```bash
PREUPGRADE_TAG=""
mounted_backup=0
mounted_src=0
```

- [ ] **Step 4: Make cleanup flag-driven**

In `bin/fbackup`, replace the `cleanup` body (lines 90-94):

```bash
cleanup() {
  findmnt -rno TARGET "$SRC_TOPLEVEL_MNT" >/dev/null 2>&1 && { run umount "$SRC_TOPLEVEL_MNT" || true; }
  findmnt -rno TARGET "$BACKUP_MNT" >/dev/null 2>&1 && { run umount "$BACKUP_MNT" || true; }
  return 0
}
```

with:

```bash
cleanup() {
  [[ "$mounted_src" == "1" ]] && { run umount "$SRC_TOPLEVEL_MNT" || true; }
  [[ "$mounted_backup" == "1" ]] && { run umount "$BACKUP_MNT" || true; }
  return 0
}
```

- [ ] **Step 5: Set the flags when mounting**

In `bin/fbackup`, replace line 121:

```bash
  findmnt -rno TARGET "$BACKUP_MNT" >/dev/null 2>&1 || run mount "$BACKUP_DEV" "$BACKUP_MNT"
```

with:

```bash
  if ! findmnt -rno TARGET "$BACKUP_MNT" >/dev/null 2>&1; then
    run mount "$BACKUP_DEV" "$BACKUP_MNT"
    mounted_backup=1
  fi
```

and replace lines 128-129:

```bash
  findmnt -rno TARGET "$SRC_TOPLEVEL_MNT" >/dev/null 2>&1 ||
    run mount -o subvolid=5 "$root_src" "$SRC_TOPLEVEL_MNT"
```

with:

```bash
  if ! findmnt -rno TARGET "$SRC_TOPLEVEL_MNT" >/dev/null 2>&1; then
    run mount -o subvolid=5 "$root_src" "$SRC_TOPLEVEL_MNT"
    mounted_src=1
  fi
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats tests/bin_smoke.bats`
Expected: PASS, including the updated `fbackup --dry-run plans ...` test (now mounts via `findmnt 1`, then unmounts both) and the new ownership test.

- [ ] **Step 7: Lint**

Run: `shellcheck -x bin/fbackup && shfmt -d bin/fbackup`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add bin/fbackup tests/bin_smoke.bats
git commit -m "fbackup: unmount only filesystems this run mounted" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `fbackup` serializes concurrent runs with a lock (Finding 3)

**Files:**
- Modify: `bin/fbackup:111-112` (insert lock acquisition after the root check)
- Test: `tests/bin_smoke.bats:141` (pass `FB_LOCK` to the fsnapshot-preupgrade test) + new lock-contention test

- [ ] **Step 1: Write the failing test and update the preupgrade test**

First, give the `fsnapshot-preupgrade --dry-run does not write the local stash` test a writable lock path, since it shells out to `fbackup`. In `tests/bin_smoke.bats`, change line 141 from:

```bash
  run env FBACKUP_CONFIG="$cfg" LOCAL_BOOT_STASH="$stash" SKIP_ROOT_CHECK=1 bin/fsnapshot-preupgrade --dry-run
```

to:

```bash
  run env FBACKUP_CONFIG="$cfg" LOCAL_BOOT_STASH="$stash" FB_LOCK="$STUB_DIR/fb.lock" SKIP_ROOT_CHECK=1 bin/fsnapshot-preupgrade --dry-run
```

Then append a new test to `tests/bin_smoke.bats`:

```bash
@test "fbackup refuses to start when another run holds the lock" {
  load helpers/stubs
  setup_stubs
  for c in btrfs tar mount umount mkdir sync rpm zstd; do make_stub "$c"; done
  make_stub findmnt 1
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
  mkdir -p "$STUB_DIR/backup/host/subvols/root" "$STUB_DIR/backup/host/subvols/home" "$STUB_DIR/backup/host/manifests" "$STUB_DIR/top/_snapshots"
  lock="$STUB_DIR/fb.lock"
  # Hold the lock in a background process for the duration of the run.
  flock -x "$lock" -c 'sleep 2' &
  holder=$!
  sleep 0.3
  run env DRY_RUN=1 FB_LOCK="$lock" FBACKUP_CONFIG="$cfg" SKIP_ROOT_CHECK=1 bin/fbackup
  wait "$holder" 2>/dev/null || true
  teardown_stubs
  [ "$status" -ne 0 ]
  [[ "$output" == *"another fbackup"* ]]
}
```

- [ ] **Step 2: Run the tests to verify the new one fails**

Run: `bats tests/bin_smoke.bats`
Expected: the lock-contention test FAILS — current `fbackup` has no lock, so it runs to completion (exit 0) even while the lock is held.

- [ ] **Step 3: Acquire the lock in `fbackup` main**

In `bin/fbackup`, replace lines 111-112:

```bash
  [[ "${SKIP_ROOT_CHECK:-0}" == "1" ]] || require_root
  load_config "$CONFIG"
```

with:

```bash
  [[ "${SKIP_ROOT_CHECK:-0}" == "1" ]] || require_root

  local lock="${FB_LOCK:-/run/fedora-backup.lock}"
  : >"$lock" 2>/dev/null || die "cannot write lock file $lock (need root?)"
  exec 9>"$lock"
  flock -n 9 || die "another fbackup run holds $lock; aborting"

  load_config "$CONFIG"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/bin_smoke.bats`
Expected: PASS, including the lock-contention test, the updated fsnapshot-preupgrade test, the fbackup dry-run test, and the mount-ownership test.

- [ ] **Step 5: Lint**

Run: `shellcheck -x bin/fbackup && shfmt -d bin/fbackup`
Expected: no output.

- [ ] **Step 6: Full suite + final commit**

Run: `bats tests/`
Expected: all tests PASS (the opt-in integration test stays skipped without `FBACKUP_INTEGRATION=1`).

```bash
git add bin/fbackup tests/bin_smoke.bats
git commit -m "fbackup: serialize runs with an flock guard" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Finding 1 (frestore robustness) → Task 2 (`restore_receive` partial cleanup) + Task 3 (cleanup trap, idempotent mount, mount tracking, pre-flight existence guard). ✔
- Finding 2 (unconditional unmount) → Task 4 (mount-ownership flags). ✔
- Finding 3 (no locking) → Task 5 (`flock` guard). ✔
- Finding 4 (swallowed cleanup-delete error) → Task 1 (loud MANUAL CLEANUP branch). ✔

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows the exact before/after and every test step shows full test bodies and run commands with expected results.

**Type/name consistency:** Globals `mounted_backup` (frestore + fbackup) and `mounted_src` (fbackup) are declared before the `cleanup` functions that read them and set in the mount blocks. `FB_LOCK` is used consistently across `bin/fbackup` and the three tests that invoke `fbackup` directly or transitively (`fbackup --dry-run`, the mount-ownership test, the lock test) and the `fsnapshot-preupgrade` test. Stub-failure tests fail on the pipeline's last stage (`btrfs receive`) so they are deterministic regardless of whether `pipefail` is set in the test shell.

**Behavioral interactions handled:**
- Task 4 changes cleanup from `findmnt`-driven to flag-driven, which would break the existing `fbackup --dry-run` test's `umount` assertions; the task switches that test's `findmnt` stub to `make_stub findmnt 1` so the mount path runs and the flags get set, keeping the assertions valid and meaningful.
- Task 3 makes the two existing frestore dry-run tests set `DEST_TOPLEVEL` to a temp dir so the new pre-flight `-e` checks never read a real path.
- Task 5's lock requires a writable `FB_LOCK`; every test that reaches `fbackup` passes one.
