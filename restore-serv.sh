#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_NAME
readonly RESTORE_ROOT="/home/$USER"
readonly LOCK_DIR="/tmp/restore-serv.lock"
readonly RSYNC_OPTS=(
  --archive
  --acls
  --xattrs
  --hard-links
  --numeric-ids
  --human-readable
  --partial
  --info=progress2
)

SOURCE_DIR=
LOCK_ACQUIRED=0

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  # Release the process lock on exit.
  if ((LOCK_ACQUIRED == 1)) && [[ -d "$LOCK_DIR" ]]; then
    rm -rf "$LOCK_DIR"
  fi
}

on_error() {
  local line_no
  local exit_code

  line_no=$1
  exit_code=$2

  printf 'Error: %s failed at line %s with exit code %s\n' \
    "$SCRIPT_NAME" "$line_no" "$exit_code" >&2
}

trap 'on_error "${LINENO}" "$?"' ERR
trap cleanup EXIT

require_command() {
  local cmd

  # Ensure required tools exist before the restore starts.
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

ensure_sudo_access() {
  # Prompt for sudo access before restoring system-owned files.
  log "Root privileges are required for the system restore step."
  sudo -v
}

acquire_lock() {
  # Prevent more than one restore run at the same time.
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_ACQUIRED=1
    printf '%s\n' "$$" >"${LOCK_DIR}/pid"
    return 0
  fi

  die "Another restore process appears to be running. Lock directory: $LOCK_DIR"
}

resolve_source_dir() {
  # Restore from the directory where this script is located.
  SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
}

restore_ssh_directory() {
  local source_ssh
  local target_ssh

  # Restore the backed-up .ssh directory into the user's home directory.
  source_ssh="${SOURCE_DIR}/.ssh"
  target_ssh="${RESTORE_ROOT}/.ssh"

  [[ -d "$source_ssh" ]] || {
    warn "Restore source not found: $source_ssh"
    return 0
  }

  mkdir -p "$RESTORE_ROOT"
  log "Restoring $source_ssh -> $RESTORE_ROOT"
  rsync "${RSYNC_OPTS[@]}" "$source_ssh" "$RESTORE_ROOT/"

  # Normalize SSH permissions after restore.
  chmod 700 "$target_ssh"
  find "$target_ssh" -type f -name '*.pub' -exec chmod 644 {} +
  find "$target_ssh" -type f ! -name '*.pub' -exec chmod 600 {} +
}

restore_sshd_config() {
  local source_file
  local target_dir
  local target_file

  # Restore sshd_config into /etc/ssh when the target directory exists.
  source_file="${SOURCE_DIR}/sshd_config"
  target_dir="/etc/ssh"
  target_file="${target_dir}/sshd_config"

  if [[ ! -d "$target_dir" ]]; then
    warn "Target directory not found: $target_dir"
    return 0
  fi

  if [[ ! -f "$source_file" ]]; then
    warn "Restore source not found: $source_file"
    return 0
  fi

  log "Restoring $source_file -> $target_file"
  sudo cp -a "$source_file" "$target_file"
}

restore_samba_config() {
  local source_file
  local target_dir
  local target_file
  local creds_file
  local found_creds

  # Restore Samba config files into /etc/samba when the target directory exists.
  source_file="${SOURCE_DIR}/smb.conf"
  target_dir="/etc/samba"
  target_file="${target_dir}/smb.conf"

  if [[ ! -d "$target_dir" ]]; then
    warn "Target directory not found: $target_dir"
    return 0
  fi

  if [[ -f "$source_file" ]]; then
    log "Restoring $source_file -> $target_file"
    sudo cp -a "$source_file" "$target_file"
  else
    warn "Restore source not found: $source_file"
  fi

  found_creds=0
  for creds_file in "${SOURCE_DIR}"/creds-*; do
    if [[ -f "$creds_file" ]]; then
      found_creds=1
      log "Restoring $creds_file -> $target_dir"
      sudo cp -a "$creds_file" "$target_dir/"
    fi
  done

  if ((found_creds == 0)); then
    warn "No creds-* files found in: $SOURCE_DIR"
  fi
}

restore_root_owned_files() {
  # Run the root-required restore steps after the user-owned restore.
  ensure_sudo_access
  restore_sshd_config
  restore_samba_config
}

main() {
  require_command rsync date chmod find sudo cp
  acquire_lock
  resolve_source_dir

  log "Restore source directory: $SOURCE_DIR"
  log "Restore destination: $RESTORE_ROOT"

  # Run the non-root SSH restore flow.
  restore_ssh_directory

  # Run the root-required system restore flow.
  restore_root_owned_files

  log "Restore completed."
}

main "$@"
