# BKP

Local project for developing backup and restore Bash scripts.

## Arch setup

After a fresh Arch Linux reinstall, install the tools this project expects:

```bash
sudo pacman -S --needed bash rsync sudo grub cifs-utils samba openssh shfmt shellcheck
```

`make check` will still run if `shfmt` or `shellcheck` are missing, but it will report that those tools are not installed.

## Initial layout

- `scripts/` for executable backup and restore scripts
- `config/` for local configuration templates
- `tests/` for validation scripts and test fixtures

## Local version control

- Git repository initialized with the `main` branch
- `.gitignore` excludes backup archives, logs, temp files, and secrets
- `.editorconfig` keeps file formatting consistent
- `.gitattributes` enforces LF line endings for shell scripts
- `.shellcheckrc` prepares the project for ShellCheck linting

## Next step

Add the first backup and restore scripts in `scripts/`.
