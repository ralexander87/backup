#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
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

  backup_suffix=$(date '+%Y%m%d-%H%M%S')
  backup_conf="${sddm_conf}.bak-${backup_suffix}"

  log "Creating SDDM config backup: ${backup_conf}"
  sudo cp -a "$sddm_conf" "$backup_conf"

  log "Updating SDDM autologin user in ${sddm_conf}"
  sudo sed -i 's/^User=.*/User=ralexander/' "$sddm_conf"
}

main "$@"
