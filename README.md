# BKP

BKP is a Bash-based backup and restore toolkit for an Arch Linux desktop or workstation. It focuses on a practical rebuild workflow: backing up user data, preserving selected system configuration, and restoring the machine after a reinstall with a small set of standard Linux tools.

The project is intentionally lightweight. It relies on tools such as `rsync`, `tar`, `pigz`, `systemctl`, and `sudo` rather than a larger backup framework.

## Highlights

- Separate backup flows for user data and system configuration
- Restore helpers copied into each backup set
- Metadata-preserving `rsync` operations with timestamped backup folders
- Optional compressed archives for the main backup flow
- LUKS header backup support for detected NVMe devices
- Simple Bash implementation that is easy to inspect and adapt

## What This Project Does

The repository currently includes four main scripts:

- `bkp-main.sh`: backs up user-owned directories from `/home/$USER`
- `restore-main.sh`: restores those backed-up user directories back into `/home/$USER`
- `bkp-serv.sh`: backs up system and service configuration that usually requires root access
- `restore-serv.sh`: restores the system and service configuration from a `bkp-serv.sh` backup

There is also a helper script:

- `starter.sh`: an opinionated post-install helper for the author's local desktop setup

## Main Backup Scope

`bkp-main.sh` is focused on everyday user data and personal configuration. At the time of writing it backs up these paths when they exist:

- `Documents`
- `Downloads`
- `Pictures`
- `Music`
- `Obsidian`
- `Working`
- `Shared`
- `VM`
- `Code`
- `Videos`
- `.config`
- `.var`
- `.icons`
- `.themes`
- `.mydotfiles`
- `.oh-my-zsh`

The script:

- finds mounted backup destinations under `/run/media/$USER`
- lets you choose a destination when more than one is mounted
- creates a timestamped backup directory under `MAIN/`
- preserves ownership, permissions, ACLs, xattrs, and hard links via `rsync`
- can create a compressed `.tar.gz` archive with `pigz`
- writes a manifest and partial-transfer summary into the backup folder
- copies the restore scripts into the backup so restore tooling travels with the data

## System Backup Scope

`bkp-serv.sh` is for system-level state that is useful after reinstalling Arch Linux or rebuilding the machine. It currently backs up items such as:

- `sshd_config`
- the user's `.ssh` directory
- the GRUB theme directory
- `/etc/default/grub`
- `/etc/samba/smb.conf`
- Samba credential files matching `/etc/samba/creds-*`
- `/etc/fstab`
- `/etc/mkinitcpio.conf`
- Plymouth defaults
- the SDDM default config
- detected LUKS headers for NVMe devices

The script requires root privileges and stores these backups under `SERV/` on the selected external device.

## Restore Behavior

`restore-main.sh` restores the user-data backup back into `/home/$USER`.

`restore-serv.sh` restores the system backup and also performs machine setup steps such as:

- restoring SSH and Samba configuration
- restoring the GRUB theme directory and GRUB defaults
- preparing SMB mount directories
- appending expected CIFS mount entries to `/etc/fstab`
- loading the CIFS kernel module
- enabling and starting the required services
- regenerating `grub.cfg`

Because of that, `restore-serv.sh` is intentionally opinionated. It is meant for a machine that looks broadly like the system the backup came from.

## Intended Workflow

A common workflow looks like this:

1. Mount an external backup device.
2. Run `./bkp-main.sh` for user data.
3. Run `sudo ./bkp-serv.sh` for system configuration.
4. Reinstall or rebuild the machine when needed.
5. Restore user data with `./restore-main.sh` from the backup folder.
6. Restore system configuration with `./restore-serv.sh` from the system backup folder.

## Requirements

This project targets Arch Linux and assumes a fairly standard Linux userspace.

Common tools used across the scripts include:

- `bash`
- `rsync`
- `sudo`
- `find`
- `grep`
- `sed`
- `tee`
- `tar`
- `pigz`
- `mountpoint`
- `df`
- `lsblk`
- `cryptsetup`
- `grub-mkconfig`
- `modprobe`
- `systemctl`
- `shfmt`
- `shellcheck`

A practical Arch install command is:

```bash
sudo pacman -S --needed bash rsync sudo grub cifs-utils samba openssh cryptsetup pigz shfmt shellcheck
```

Depending on your system, you may also need packages that provide services referenced by the restore script, such as `avahi`, `pcsclite`, `wsdd`, `plymouth`, or `sddm`.

## Usage

Run the scripts from the repository root.

User backup:

```bash
./bkp-main.sh
```

User restore:

```bash
./restore-main.sh
```

System backup:

```bash
sudo ./bkp-serv.sh
```

System restore:

```bash
./restore-serv.sh
```

Code formatting and lint checks:

```bash
make check
```

## Project Layout

- `bkp-main.sh`: main user-data backup script
- `restore-main.sh`: main user-data restore script
- `bkp-serv.sh`: system/service backup script
- `restore-serv.sh`: system/service restore script
- `starter.sh`: optional post-install helper for the author's setup
- `Makefile`: formatting and lint convenience targets
- `config/`: placeholder directory for configuration assets
- `scripts/`: placeholder directory for future script organization
- `tests/`: placeholder directory for future validation work

## Important Notes

- This project is not a generic backup product yet. It is a personal toolkit that is gradually being cleaned up for public use.
- Some restore behavior is host-specific and network-specific, especially in the Samba, CIFS, and service sections.
- `restore-serv.sh` changes live system files. Read it before running it on a machine you care about.
- The scripts create timestamped backup copies of some targets before overwriting them, but you should still treat restore operations as high-impact.
- If you want to reuse this project, review hard-coded paths, hostnames, share names, and service assumptions first.

## Contributing

Issues and pull requests are welcome, especially for improvements that make the scripts safer, clearer, and easier to adapt to other Arch-based setups.

## License

This project is licensed under the GNU General Public License v3.0. See `LICENSE` for the full text.

## Development

The repository is plain Bash and intentionally lightweight.

Useful commands:

```bash
make fmt
make lint
make check
```

If `shfmt` or `shellcheck` are not installed, the Make targets will report that cleanly instead of crashing.

## Status

BKP is actively shaped around a real machine-rebuild workflow. It already works for the author's environment, but public-facing polish, test coverage, and generalization are still in progress.
