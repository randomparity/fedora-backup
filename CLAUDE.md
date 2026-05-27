# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Bash tooling to back up one Fedora 43 btrfs system (root + home subvolumes, plus
the non-btrfs `/boot` and `/boot/efi` partitions) to a USB btrfs drive via
incremental `btrfs send/receive`, then upgrade to Fedora 44 with both
local-snapshot and external-disk restore paths. End-user docs: `README.md` and
`docs/RUNBOOK.md`. Design record: `docs/superpowers/specs/`.

## Commands

```bash
bats tests/                            # unit + command-construction tests; also runs shellcheck on bin/
bats tests/snapshots_naming.bats       # one test file
bats tests/ --filter "select_parent"   # one test by name
shellcheck -x bin/* lib/*.sh           # -x follows `source` directives (see .shellcheckrc)
shfmt -i 2 -ci -d bin/ lib/            # formatting check (diff); -w to write
prek run                               # all hooks: shellcheck, shfmt, bats

sudo FBACKUP_INTEGRATION=1 bats tests/integration/   # real loopback btrfs; needs root
```

Tooling installs via `sudo dnf5 install -y bats ShellCheck shfmt`.

## Architecture

**Thin executables, testable libraries.** Each `bin/` script is a CLI wrapper:
parse flags, check root, load config, then orchestrate calls into `lib/`. The
real logic lives in `lib/*.sh` as small functions that take all facts as
arguments and avoid global state, so they can be sourced and tested directly
(see `tests/snapshots_*.bats`, `tests/manifest.bats`).

The `bin → lib` wiring:

| bin | sources | does |
|---|---|---|
| `fbackup-init` | `common`, `backup_target` | format the USB target, create the dir layout |
| `fbackup` | `common`, `snapshots`, `manifest` | snapshot → send/receive → boot tarballs → manifest → prune |
| `fsnapshot-preupgrade` | `common` | local /boot stash, then calls `fbackup --preupgrade` |
| `fupgrade` | `common`, `upgrade` | one dnf5 upgrade boundary per subcommand; `snapshot` shells out to `fsnapshot-preupgrade` |
| `frestore` | `common`, `restore` | disaster recovery: receive subvols onto a new disk |

Every `bin/` script resolves `REPO_DIR` from `BASH_SOURCE`, sources libs by
absolute path, and ends with `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"`
so it can be sourced without executing. Library files are idempotent via a
`_FB_<NAME>_SH` source guard.

### Cross-cutting conventions (in `lib/common.sh`)

- **`run <cmd...>`** wraps every side-effecting command. When `DRY_RUN=1` it
  prints `[DRY-RUN] <cmd>` to stderr and returns 0 instead of executing. New
  mutating operations MUST go through `run` (or check `DRY_RUN` explicitly, as
  `fb_send_receive`/`restore_receive` do for pipelines) — this is what makes
  `--dry-run` safe and is asserted throughout `tests/bin_smoke.bats`.
- **`load_config`** sources `etc/backup.conf` (override with `FBACKUP_CONFIG`)
  and dies if any required variable is unset. Copy `etc/backup.conf.example`;
  `etc/backup.conf` is gitignored.
- The backup device is addressed by its **`/dev/disk/by-id/` path**, never
  `/dev/sdX`, so a device-letter shuffle can't misdirect a format.
- `die` logs to stderr and `exit 1`; `confirm_phrase` gates destructive ops on
  an exact typed word (e.g. `FORMAT`).

### Safety invariants to preserve when editing

- **Dry-run never mutates.** `fbackup --dry-run` does not even mount the target,
  so an initialized-but-unmounted target reads as uninitialized — it warns and
  previews instead of dying. `frestore` defaults to dry-run; `--apply` is the
  only thing that sets `DRY_RUN=0`.
- **Single backup at a time.** `fbackup` takes a `flock` on `FB_LOCK`
  (`/run/fedora-backup.lock`); dry-run skips the lock.
- **Failed transfers leave no usable partial.** `fb_send_receive` deletes a
  partially received subvolume on failure so it can never be picked as a future
  incremental parent; `frestore` rolls back every subvolume it created if a
  later step fails (EXIT trap with the real exit code).
- **Incremental parent selection** (`select_parent`) is the newest *regular*
  snapshot present on both source and target. Pruning (`prune_candidates`)
  keeps `RETENTION_KEEP` regular sets, never deletes a `preupgrade` snapshot,
  and never deletes the current common parent.
- `/home` is intentionally not rolled back by the local-rollback path.

### Testing strategy

Unit tests source a lib and assert on pure functions. Command-construction tests
(`tests/bin_smoke.bats`) run the `bin/` scripts under `SKIP_ROOT_CHECK=1` with
external commands replaced by stubs from `tests/helpers/stubs.bash` — each stub
logs its argv to `$STUB_LOG` and drains stdin — then assert on the `[DRY-RUN]`
output or the recorded calls. Prefer this stubbing approach over real I/O; only
`tests/integration/` touches actual loopback filesystems and is opt-in via
`FBACKUP_INTEGRATION=1`. Tests pin a fixed timestamp like
`root.20260527T143000Z`; mirror that format (`%Y%m%dT%H%M%SZ`, UTC).

## Project conventions

### Planning artifacts

`docs/superpowers/plans/` is gitignored on purpose. Plan files written there
(e.g. by the superpowers planning and execution skills) are local working
artifacts, not part of the repository. Do not commit them, and do not force
them in with `git add -f`.

Design specs under `docs/superpowers/specs/` are different: they stay under
version control as design records.
