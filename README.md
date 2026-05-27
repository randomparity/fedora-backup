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
sudo dnf5 install -y bats ShellCheck shfmt
bats tests/                 # unit + command-construction tests (runs shellcheck on bin/)
shfmt -d bin/ lib/          # formatting check
```

Integration tests touch real loopback btrfs filesystems and need root:

```bash
sudo FBACKUP_INTEGRATION=1 bats tests/integration/
```
