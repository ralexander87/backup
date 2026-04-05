#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

log() {
  printf '[setup-dev] %s\n' "$1"
}

require_command() {
  local cmd

  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      printf '[setup-dev] Missing required command: %s\n' "$cmd" >&2
      return 1
    }
  done
}

main() {
  local missing=()
  local cmd

  require_command git pacman

  cd "$REPO_ROOT"

  git config core.hooksPath .githooks
  log "Configured Git hooks path to .githooks"

  for cmd in shfmt shellcheck; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if ((${#missing[@]} > 0)); then
    log "Install missing developer tools with:"
    printf '  sudo pacman -S --needed'
    printf ' %s' "${missing[@]}"
    printf '\n'
  else
    log "Developer tools already installed"
  fi

  log "Done"
}

main "$@"
