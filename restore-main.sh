#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_NAME
readonly RESTORE_ROOT="/home/$USER"
readonly LOCK_DIR="/tmp/restore-main.lock"
readonly RESTORE_NAMES=(
  Documents
  Downloads
  Pictures
  Music
  Obsidian
  Working
  Shared
  VM
  Code
  Videos
  .icons
  .themes
)
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
declare -a RESTORE_SOURCES=()
declare -a PARTIAL_WARNINGS=()

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

build_restore_sources() {
  local name
  local source_path

  # Build the list of backed-up folders that exist beside this script.
  RESTORE_SOURCES=()

  for name in "${RESTORE_NAMES[@]}"; do
    source_path="${SOURCE_DIR}/${name}"
    if [[ -e "$source_path" ]]; then
      RESTORE_SOURCES+=("$source_path")
    else
      warn "Skipping missing restore source: $source_path"
    fi
  done

  ((${#RESTORE_SOURCES[@]} > 0)) ||
    die "No restore folders were found in: $SOURCE_DIR"
}

restore_one_source() {
  local source
  local rsync_exit
  local warning_message

  # Copy one backed-up folder into the user's home directory.
  source=$1
  log "Restoring $source -> $RESTORE_ROOT"

  set +e
  rsync "${RSYNC_OPTS[@]}" "$source" "$RESTORE_ROOT/"
  rsync_exit=$?
  set -e

  case "$rsync_exit" in
    0) ;;
    23 | 24)
      warning_message="rsync returned partial-transfer code ${rsync_exit} for $source"
      PARTIAL_WARNINGS+=("$warning_message")
      warn "${warning_message}; continuing."
      ;;
    *)
      die "rsync failed with exit code ${rsync_exit} for source: $source"
      ;;
  esac
}

run_restore() {
  local source

  # Restore each available folder into /home/$USER.
  for source in "${RESTORE_SOURCES[@]}"; do
    restore_one_source "$source"
  done
}

main() {
  require_command rsync date
  acquire_lock
  resolve_source_dir
  build_restore_sources

  log "Restore source directory: $SOURCE_DIR"
  log "Restore destination: $RESTORE_ROOT"

  run_restore

  if ((${#PARTIAL_WARNINGS[@]} > 0)); then
    warn "Restore completed with rsync partial-transfer warnings."
  fi

  log "Restore completed."
}

main "$@"
