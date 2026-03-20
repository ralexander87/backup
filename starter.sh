#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

main() {
  local script_dir source_conf target_conf fonts_dir install_script

  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  source_conf="${script_dir}/hyprland.conf"
  target_conf="/home/$USER/.config/hypr/hyprland.conf"
  fonts_dir="${script_dir}/fonts"
  install_script="${fonts_dir}/install.sh"

  if [[ -f "$source_conf" ]]; then
    mkdir -p "$(dirname "$target_conf")"
    cp -f "$source_conf" "$target_conf"
    log "Copied ${source_conf} to ${target_conf}"
  else
    warn "File not found: ${source_conf}"
  fi

  if [[ -d "$fonts_dir" ]]; then
    if [[ -x "$install_script" ]]; then
      log "Running fonts installer: ${install_script}"
      "$install_script"
    elif [[ -f "$install_script" ]]; then
      log "Running fonts installer with bash: ${install_script}"
      bash "$install_script"
    else
      warn "fonts directory exists, but install.sh was not found in ${fonts_dir}"
    fi
  else
    warn "fonts directory not found: ${fonts_dir}"
  fi
}

main "$@"
