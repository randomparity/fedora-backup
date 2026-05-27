# Fedora 43 → 44 btrfs Backup & Upgrade — Design

**Date:** 2026-05-27
**Status:** Approved (design)

## Goal

Back up the local Fedora 43 system (btrfs) to external media, then upgrade to
Fedora 44 with both a fast local rollback and an external disaster-recovery path.

## System facts (surveyed 2026-05-27)

- **OS:** Fedora Linux 43 Workstation (EOL 2026-12-02). Package manager: dnf5
  5.2.18. The `dnf5-plugin-system-upgrade` package is **not** installed.
- **Root btrfs:** label `fedora`, top level `subvolid=5`, mounted from
  `/dev/nvme1n1p3`. Reports ~1.9 TB total / 576 GB used, which exceeds the
  951 GB `nvme1n1p3` partition — the second `fedora`-labeled device
  `nvme3n1p1` (954 GB) almost certainly belongs to the same multi-device
  filesystem. **Confirm topology with `btrfs filesystem show` at execution
  (needs root) before relying on it.**
- **Subvolumes:** `root` (subvolid 256, mounted `/`), `home` (subvolid 257,
  mounted `/home`). Mount options include `compress=zstd:1`.
- **Boot partitions (separate, non-btrfs):** `/boot` ext4 on `nvme1n1p2`
  (794 MB used), `/boot/efi` vfat on `nvme1n1p1` (20 MB used). A btrfs snapshot
  of `root` does **not** capture these.
- **Destination:** `sdc`, unformatted, 3.6 TB. To be wiped and formatted as a
  dedicated btrfs backup target. 576 GB of source data fits comfortably.
- **Out of scope:** `/mnt/pool0` (btrfs multi-device data pool) and
  `/mnt/raid0` (43.7 TB ext4 md-RAID) — too large for the destination and not
  needed for upgrade rollback.

## Scope

Back up `root` + `home` subvolumes and the `/boot` + `/boot/efi` partitions.
Provide a reusable, incremental backup tool with retention, a pre-upgrade local
snapshot, upgrade orchestration, and a documented restore path.

## Approach

Native **`btrfs send/receive`** for the subvolumes (block-exact, preserves all
btrfs metadata and reflinks, atomic per subvolume, cheap incrementals via parent
snapshots). `/boot` and `/boot/efi` are captured as `tar` archives alongside
each backup (small, faithful, trivially restorable). Rejected alternatives:
restic/borg (loses btrfs semantics, redundant given a btrfs destination) and
dd/partclone images (no incrementals, copies free space, fragile across
topology).

## Architecture & on-disk layout

Three roles:

- **Source (internal):** the root btrfs top level (`subvolid=5`), holding
  subvols `root` and `home`.
- **Local snapshots (internal):** a `_snapshots/` directory at the btrfs top
  level holds read-only snapshots — both the rolling send/receive sources and
  the tagged pre-upgrade rollback anchor. Same disk: instant rollback, lost if
  the disk dies.
- **External target (sdc):** btrfs, label `fedora-backup`, mounted at
  `/mnt/backup`.

Target layout:

```
/mnt/backup/<hostname>/
  subvols/root/root.<timestamp>      # received read-only snapshots
  subvols/home/home.<timestamp>
  boot/boot.<timestamp>.tar.zst      # ext4 /boot contents
  boot/efi.<timestamp>.tar.zst       # vfat /boot/efi contents
  manifests/manifest.<timestamp>.json
```

**Manifest** (per backup) records what a restore needs: source filesystem
UUIDs, `/etc/fstab`, full subvolume list, `btrfs filesystem show` topology,
installed kernel list, Fedora version, and the per-subvolume parent snapshots
used for the incrementals (recorded as a `subvol=parent` summary).

**Safety:** config references the backup disk by `/dev/disk/by-id/...`, never
`/dev/sdc`, so a device-letter reshuffle cannot misdirect a format command.

## Tool set

Bash (`set -euo pipefail`, shellcheck/shfmt-clean, `--dry-run` on every
destructive tool):

| Tool | Job |
|---|---|
| `lib/common.sh` | Shared: logging, `die`, root check, config load, mount helpers, typed-confirmation prompt |
| `etc/backup.conf` | Backup device by-id, label, subvol list, boot mounts, retention count |
| `bin/fbackup-init` | One-time: format sdc as btrfs (verifies by-id, shows current contents, requires typed confirmation, refuses if data present without `--force`) |
| `bin/fbackup` | Main: RO snapshot → incremental send/receive → boot+efi tarballs → manifest → prune by retention |
| `bin/fsnapshot-preupgrade` | Tags a local snapshot set as `preupgrade` (exempt from pruning) |
| `bin/fupgrade` | Orchestrates F43→44: preflight → install plugin → refresh → `system-upgrade download` → reboot phase → post checks |
| `bin/frestore` | Disaster recovery from sdc (receive back, restore boot, fix UUIDs/bootloader); run from live/rescue, dry-run by default |
| `docs/RUNBOOK.md` | Human step-by-step plan + rollback decision tree |
| `tests/` | bats tests with `btrfs`/`dnf5`/`blkid`/`tar` stubbed on PATH |

## Backup flow (`bin/fbackup`)

Run as root:

1. **Preflight:** load config; confirm backup disk present by-id and mounted at
   `/mnt/backup`; verify free space on target ≥ estimated delta; verify source
   subvols exist.
2. **Snapshot:** create read-only snapshots at the btrfs top level —
   `_snapshots/root.<ts>`, `_snapshots/home.<ts>` (atomic, instant).
3. **Send/receive (incremental):** find the newest snapshot of each subvol that
   also exists on the target (the common parent). If one exists →
   `btrfs send -p <parent> <new> | btrfs receive <target>` (changed blocks
   only). If none → full send (first run). `--full` forces a fresh baseline.
4. **Boot/efi:** `tar` `/boot` and `/boot/efi` into `boot.<ts>.tar.zst` /
   `efi.<ts>.tar.zst` on the target.
5. **Manifest:** write `manifest.<ts>.json`.
6. **Prune:** keep the last `RETENTION_KEEP` (default **3**) snapshot sets on
   both source and target; never prune anything tagged `preupgrade`. Always
   retain at least one snapshot pair common to both sides so the next
   incremental has a parent.
7. **`sync` + report:** flush, then print what was sent, sizes, and the new
   common parent.

**Failure handling:** a failed send/receive deletes the half-received target
snapshot so a partial never poses as a valid parent. Incremental-chain
integrity is the hardest-guarded invariant.

## Upgrade orchestration (`bin/fupgrade`)

1. **Preflight:** confirm a backup dated today exists on sdc; check root fs free
   space (≥ ~5–10 GB for the download); run `dnf5 check` for broken deps.
2. **Refresh current system:** `dnf5 upgrade --refresh`; reboot if the running
   kernel changed (upgrade from a fully-patched F43, per Fedora docs).
3. **Pre-upgrade rollback point:** invoke `fsnapshot-preupgrade` → RO snapshots
   `_snapshots/root.preupgrade-f43.<ts>` + home, and stash copies of the current
   `/boot` + `/boot/efi` tarballs locally (so the F43 kernel survives even if
   F44 removes it).
4. **Install plugin + download:** `dnf5 install dnf5-plugin-system-upgrade`,
   then `dnf5 system-upgrade download --releasever=44`. Resolve conflicts /
   retired-package prompts here, before committing.
5. **Apply:** `dnf5 system-upgrade reboot` — boots into the offline transaction;
   installs F44 and reboots into it.
6. **Post-upgrade verification:** after first F44 boot, check `/etc/os-release`
   = 44, `dnf5 check`, desktop session, booted kernel. `fupgrade --post` prints
   a checklist and offers cleanup (`dnf5 autoremove`, retired packages).

The tool stops at each human-decision boundary (after preflight, after
download/conflict resolution) — no unattended march to reboot.

## Rollback & restore (`bin/frestore` + `docs/RUNBOOK.md`)

Decision tree:

| Situation | Path |
|---|---|
| F44 boots but broken; disk OK | Local rollback (fast) |
| F44 won't boot; disk OK | Boot F43 kernel entry if present, else live USB → local rollback |
| NVMe dead / replaced | External disaster recovery from sdc |

**Local rollback** (from F43 rescue or live USB):

1. Mount btrfs top level (`subvolid=5`).
2. Rename broken F44 root aside: `mv root root.broken-f44`.
3. Recreate root from the anchor:
   `btrfs subvolume snapshot _snapshots/root.preupgrade-f43.<ts> root`.
4. Restore `/boot` + `/boot/efi` from the locally-stashed F43 tarballs.
5. Reboot. Same filesystem ⇒ UUIDs/fstab unchanged; if GRUB entries were
   rewritten, run `grub2-mkconfig`.

`/home` is deliberately **not** rolled back by default — keep data created after
the upgrade. The runbook flags this as an explicit choice.

**External disaster recovery** (new/blank disk, from live USB):

1. Partition the new disk per manifest (EFI vfat, `/boot` ext4, btrfs root);
   recreate btrfs topology.
2. `btrfs send` chosen snapshot from sdc → `btrfs receive` onto new root;
   snapshot received subvols to canonical `root`/`home`.
3. Restore `/boot`, `/boot/efi` tarballs.
4. Rewrite `/etc/fstab` UUIDs (new filesystems = new UUIDs) using the manifest
   as reference; reinstall bootloader + regenerate initramfs.

`frestore` automates steps 2–4; bootloader reinstall is guided/interactive
because UEFI specifics vary. Default mode is dry-run.

## Testing

- **Unit (bats):** retention selection (keep N, never drop `preupgrade`),
  parent-snapshot selection (newest snapshot common to source and target),
  timestamp parsing, manifest JSON validity.
- **Command-construction:** `btrfs`/`dnf5`/`blkid`/`tar` stubbed on `PATH` to
  capture args — assert incremental send uses the correct `-p` parent.
- **Integration (opt-in, sandboxed):** loopback btrfs images (`truncate` →
  `mkfs.btrfs` → mount) exercise real send/receive without touching real disks;
  gated behind a flag, not default CI.
- **Dry-run assertion:** every destructive tool's `--dry-run` prints exact
  commands and touches nothing.
- **Static:** `shellcheck` + `shfmt` via prek hook and CI.

## Key risks

- **Multi-device root topology** must be confirmed before restore planning; a
  bare-metal restore must recreate the same topology or consciously collapse to
  a single device.
- **Boot partitions are separate from the btrfs snapshot** — the tarball capture
  is what makes rollback bootable; it must not be skipped.
- **Incremental parent integrity** — pruning must never break the common-parent
  chain; partial receives must be cleaned up.
