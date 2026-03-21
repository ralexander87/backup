#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_NAME
readonly RESTORE_ROOT="/home/$USER"
readonly LOCK_DIR="/tmp/restore-serv.lock"
readonly LOCAL_USER="$USER"
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

backup_user_target() {
  local target_path
  local backup_suffix
  local backup_path

  target_path=$1

  # Create a timestamped backup copy before overwriting a user-owned target.
  [[ -e "$target_path" ]] || return 0

  backup_suffix=$(date '+%Y%m%d-%H%M%S')
  backup_path="${target_path}.bak-${backup_suffix}"
  log "Creating backup: $backup_path"
  cp -a "$target_path" "$backup_path"
}

backup_root_target() {
  local target_path
  local backup_suffix
  local backup_path

  target_path=$1

  # Create a timestamped backup copy before overwriting a root-owned target.
  sudo test -e "$target_path" || return 0

  backup_suffix=$(date '+%Y%m%d-%H%M%S')
  backup_path="${target_path}.bak-${backup_suffix}"
  log "Creating backup: $backup_path"
  sudo cp -a "$target_path" "$backup_path"
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
  backup_user_target "$target_ssh"
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

  backup_root_target "$target_file"
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
    backup_root_target "$target_file"
    log "Restoring $source_file -> $target_file"
    sudo cp -a "$source_file" "$target_file"
  else
    warn "Restore source not found: $source_file"
  fi

  found_creds=0
  for creds_file in "${SOURCE_DIR}"/creds-*; do
    if [[ -f "$creds_file" ]]; then
      found_creds=1
      backup_root_target "${target_dir}/$(basename "$creds_file")"
      log "Restoring $creds_file -> $target_dir"
      sudo cp -a "$creds_file" "$target_dir/"
    fi
  done

  if ((found_creds == 0)); then
    warn "No creds-* files found in: $SOURCE_DIR"
  fi
}

load_cifs_module() {
  # Load the CIFS kernel module after restoring Samba-related files.
  log "Loading CIFS kernel module"
  sudo modprobe cifs
}

enable_and_start_services() {
  # Enable and start the restored network and smart-card related services.
  log "Enabling restored services"
  sudo systemctl enable \
    wsdd.service \
    avahi-daemon.service \
    sshd.service \
    smb.service \
    pcscd.service \
    nmb.service

  log "Starting restored services"
  sudo systemctl start \
    wsdd.service \
    avahi-daemon.service \
    sshd.service \
    smb.service \
    pcscd.service \
    nmb.service
}

prepare_smb_directories() {
  local local_group

  # Create /SMB and its child folders for Samba shares.
  local_group=$(id -gn "$LOCAL_USER")

  log "Creating /SMB share directories"
  sudo mkdir -p \
    /SMB \
    /SMB/euclid \
    /SMB/pneuma \
    /SMB/lateralus \
    /SMB/SCP \
    /SMB/SCP/HDD-01 \
    /SMB/SCP/HDD-02 \
    /SMB/SCP/HDD-03

  log "Applying ownership and permissions to /SMB"
  sudo chown -R "${LOCAL_USER}:${local_group}" /SMB
  sudo find /SMB -type d -exec chmod 750 {} +
}

update_fstab_entries() {
  local fstab_file
  local needs_append

  # Append required SMB mount entries to /etc/fstab when they are missing.
  fstab_file="/etc/fstab"

  if [[ ! -f "$fstab_file" ]]; then
    warn "Target file not found: $fstab_file"
    return 0
  fi

  needs_append=0

  if ! sudo grep -Fqx '//192.168.8.60/d   /SMB/euclid   cifs   _netdev,credentials=/etc/samba/creds-euclid,uid=1000,gid=1000   0 0' "$fstab_file"; then
    needs_append=1
  fi

  if ! sudo grep -Fqx '//192.168.8.150/hdd-01   /SMB/SCP/HDD-01   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0' "$fstab_file"; then
    needs_append=1
  fi

  if ! sudo grep -Fqx '//192.168.8.150/hdd-02   /SMB/SCP/HDD-02   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0' "$fstab_file"; then
    needs_append=1
  fi

  if ! sudo grep -Fqx '//192.168.8.150/hdd-03   /SMB/SCP/HDD-03   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0' "$fstab_file"; then
    needs_append=1
  fi

  if ((needs_append == 0)); then
    log "Required /etc/fstab entries already exist."
    return 0
  fi

  backup_root_target "$fstab_file"
  log "Appending missing SMB mount entries to $fstab_file"

  {
    printf '\n'
    if ! sudo grep -Fqx '//192.168.8.60/d   /SMB/euclid   cifs   _netdev,credentials=/etc/samba/creds-euclid,uid=1000,gid=1000   0 0' "$fstab_file"; then
      printf '# Euclid. Windows\n'
      printf '%s\n' '//192.168.8.60/d   /SMB/euclid   cifs   _netdev,credentials=/etc/samba/creds-euclid,uid=1000,gid=1000   0 0'
      printf '\n'
    fi
    if ! sudo grep -Fqx '//192.168.8.150/hdd-01   /SMB/SCP/HDD-01   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0' "$fstab_file"; then
      printf '# Proxmox\n'
      printf '%s\n' '//192.168.8.150/hdd-01   /SMB/SCP/HDD-01   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0'
    fi
    if ! sudo grep -Fqx '//192.168.8.150/hdd-02   /SMB/SCP/HDD-02   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0' "$fstab_file"; then
      printf '%s\n' '//192.168.8.150/hdd-02   /SMB/SCP/HDD-02   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0'
    fi
    if ! sudo grep -Fqx '//192.168.8.150/hdd-03   /SMB/SCP/HDD-03   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0' "$fstab_file"; then
      printf '%s\n' '//192.168.8.150/hdd-03   /SMB/SCP/HDD-03   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0'
    fi
  } | sudo tee -a "$fstab_file" >/dev/null
}

replace_or_append_grub_line() {
  local grub_file
  local match_pattern
  local replacement

  grub_file=$1
  match_pattern=$2
  replacement=$3

  # Replace an existing GRUB line or append it when missing.
  if sudo grep -Eq "$match_pattern" "$grub_file"; then
    sudo sed -i -E "s|${match_pattern}.*|${replacement}|" "$grub_file"
  else
    printf '%s\n' "$replacement" | sudo tee -a "$grub_file" >/dev/null
  fi
}

update_grub_defaults() {
  local grub_file

  # Update the restored GRUB defaults file with the requested values.
  grub_file="/etc/default/grub"

  if [[ ! -f "$grub_file" ]]; then
    warn "Target file not found: $grub_file"
    return 0
  fi

  backup_root_target "$grub_file"

  replace_or_append_grub_line \
    "$grub_file" \
    '^GRUB_CMDLINE_LINUX_DEFAULT=' \
    'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet splash"'
  replace_or_append_grub_line \
    "$grub_file" \
    '^GRUB_GFXMODE=' \
    'GRUB_GFXMODE=1440x1080x32'
  replace_or_append_grub_line \
    "$grub_file" \
    '^#GRUB_THEME=' \
    'GRUB_THEME="/boot/grub/themes/lateralus/theme.txt"'
  replace_or_append_grub_line \
    "$grub_file" \
    '^#GRUB_TERMINAL_OUTPUT=console' \
    'GRUB_TERMINAL_OUTPUT=gfxterm'

  if sudo grep -Eq '^GRUB_TERMINAL_INPUT=console$|^GRUB_TERMINA_INPUT=console$' "$grub_file"; then
    sudo sed -i -E \
      's|^GRUB_TERMINAL_INPUT=console$|#GRUB_TERMINAL_INPUT=console|' \
      "$grub_file"
    sudo sed -i -E \
      's|^GRUB_TERMINA_INPUT=console$|#GRUB_TERMINAL_INPUT=console|' \
      "$grub_file"
  else
    printf '%s\n' '#GRUB_TERMINAL_INPUT=console' | sudo tee -a "$grub_file" >/dev/null
  fi
}

update_grub_config() {
  # Regenerate grub.cfg after updating /etc/default/grub.
  backup_root_target "/boot/grub/grub.cfg"
  log "Updating /boot/grub/grub.cfg"
  sudo grub-mkconfig -o /boot/grub/grub.cfg
}

restore_root_owned_files() {
  # Run the root-required restore steps after the user-owned restore.
  ensure_sudo_access
  restore_sshd_config
  restore_samba_config
  load_cifs_module
  enable_and_start_services
  prepare_smb_directories
  update_fstab_entries
  update_grub_defaults
  update_grub_config
}

main() {
  require_command rsync date chmod find sudo cp grep sed tee grub-mkconfig modprobe systemctl id chown mkdir
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
