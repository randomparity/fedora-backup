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
2. Mount the new btrfs top level at `/mnt/restore-target`, then:
   ```bash
   # Mount the recovery disk's /boot and /boot/efi first, then:
   sudo ./bin/frestore --snapshot root.<ts> --boot-dir /mnt/newboot --efi-dir /mnt/newefi          # dry-run
   sudo ./bin/frestore --snapshot root.<ts> --boot-dir /mnt/newboot --efi-dir /mnt/newefi --apply
   ```
3. frestore receives every configured subvolume and creates the canonical
   writable subvols automatically. Remaining manual steps: rewrite /etc/fstab
   UUIDs from the manifest, reinstall the bootloader, regenerate initramfs.

## Notes

- The root filesystem may span two NVMe devices (`nvme1n1p3` + `nvme3n1p1`).
  Confirm with `btrfs filesystem show` and record it before any restore.
- `/boot` and `/boot/efi` are separate non-btrfs partitions; their tarballs are
  what make a rollback bootable. Never skip them.
