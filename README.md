# BKP

Local project for developing backup and restore Bash scripts.

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
