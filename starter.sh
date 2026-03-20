#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="1.0.0"
readonly LOCK_DIR="/tmp/starter.lock"

LOG_FILE=
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

  # Ensure required tools exist before the setup starts.
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

acquire_lock() {
  # Prevent more than one starter run at the same time.
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_ACQUIRED=1
    printf '%s\n' "$$" >"${LOCK_DIR}/pid"
    return 0
  fi

  die "Another starter process appears to be running. Lock directory: $LOCK_DIR"
}

initialize_logging() {
  local script_dir

  # Mirror terminal output into a log file next to the starter script.
  script_dir=$1
  LOG_FILE="${script_dir}/starter.log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "Logging initialized: $LOG_FILE"
  log "Script version: $SCRIPT_VERSION"
}

copy_hyprland_config() {
  local script_dir
  local source_conf
  local target_conf

  # Copy the local Hyprland config into the user's home config directory.
  script_dir=$1
  source_conf="${script_dir}/hyprland.conf"
  target_conf="/home/$USER/.config/hypr/hyprland.conf"

  if [[ -f "$source_conf" ]]; then
    mkdir -p "$(dirname "$target_conf")"
    cp -f "$source_conf" "$target_conf"
    log "Copied ${source_conf} to ${target_conf}"
  else
    warn "File not found: ${source_conf}"
  fi
}

run_fonts_installer() {
  local script_dir
  local fonts_dir
  local install_script

  # Run the optional font installation helper if it is present.
  script_dir=$1
  fonts_dir="${script_dir}/fonts"
  install_script="${fonts_dir}/install.sh"

  if [[ -d "$fonts_dir" ]]; then
    if [[ -x "$install_script" ]]; then
      log "Running fonts installer: ${install_script}"
      "$install_script"
    elif [[ -f "$install_script" ]]; then
      log "Running fonts installer with bash: ${install_script}"
      bash "$install_script"
    else
      warn \
        "fonts directory exists, but install.sh was not found in ${fonts_dir}"
    fi
  else
    warn "fonts directory not found: ${fonts_dir}"
  fi
}

main() {
  local script_dir

  # Resolve the directory where this script is located.
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

  # Validate dependencies, set up logging, and prevent concurrent runs.
  require_command sudo cp sed date tee grep
  acquire_lock
  initialize_logging "$script_dir"

  # Run non-root setup tasks first.
  copy_hyprland_config "$script_dir"
  run_fonts_installer "$script_dir"

  # Run the root-required SDDM change last.
  update_sddm_user
}

update_sddm_user() {
  local sddm_conf
  local backup_suffix
  local backup_conf

  # Backup the SDDM config and set the autologin user with sudo.
  sddm_conf="/usr/lib/sddm/sddm.conf.d/default.conf"

  if [[ ! -f "$sddm_conf" ]]; then
    warn "SDDM config not found: ${sddm_conf}"
    return 0
  fi

  if ! grep -q '^User=' "$sddm_conf"; then
    die "Could not find a User= line in ${sddm_conf}"
  fi

  backup_suffix=$(date '+%Y%m%d-%H%M%S')
  backup_conf="${sddm_conf}.bak-${backup_suffix}"

  if [[ -e "$backup_conf" ]]; then
    die "Backup file already exists: ${backup_conf}"
  fi

  log "Creating SDDM config backup: ${backup_conf}"
  sudo cp -a "$sddm_conf" "$backup_conf"

  log "Updating SDDM autologin user in ${sddm_conf}"
  sudo sed -i 's/^User=.*/User=ralexander/' "$sddm_conf"
}

main "$@"
