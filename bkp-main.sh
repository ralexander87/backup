#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="1.0.0"
readonly MIN_FREE_GB=20
readonly TIMESTAMP_FORMAT='+%j-%d-%m-%H-%M-%S'
readonly BACKUP_ROOT="/home/$USER"
readonly DESTINATION_PARENT_NAME="MAIN"
readonly BACKUP_PREFIX="BKP"
readonly LOCK_DIR="/tmp/bkp-main.lock"
readonly BACKUP_NAMES=(
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
  .config
  .var
  .icons
  .themes
  .mydotfiles
  .oh-my-zsh
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

CREATE_COMPRESSED_BACKUP=1
SELECTED_DESTINATION=
BACKUP_TIMESTAMP=
BACKUP_DIR=
LOG_FILE=
MANIFEST_FILE=
PARTIAL_SUMMARY_FILE=
TEMP_ARCHIVE_PATH=
LOCK_ACQUIRED=0
declare -a SOURCES=()
declare -a PARTIAL_WARNINGS=()

usage() {
  cat <<'EOF'
Usage:
  ./bkp-main.sh

Description:
  Detects mounted external devices under /run/media/$USER, selects a
  destination, creates MAIN/BKP-<timestamp>, checks for at least 20 GB free
  space, and copies the configured home directories with rsync while
  preserving ownership, permissions, ACLs, and extended attributes.
EOF
}

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
  # Remove temporary files and release the process lock on exit.
  if [[ -n "$TEMP_ARCHIVE_PATH" && -f "$TEMP_ARCHIVE_PATH" ]]; then
    rm -f "$TEMP_ARCHIVE_PATH"
  fi

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

  # Ensure required tools exist before the backup starts.
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

acquire_lock() {
  # Prevent more than one backup run at the same time.
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_ACQUIRED=1
    printf '%s\n' "$$" >"${LOCK_DIR}/pid"
    return 0
  fi

  die "Another backup process appears to be running. Lock directory: $LOCK_DIR"
}

get_mounted_devices() {
  local media_root
  local mount_point

  # Find mounted external devices under /run/media/$USER.
  media_root="/run/media/$USER"
  [[ -d "$media_root" ]] || return 0

  while IFS= read -r mount_point; do
    [[ -n "$mount_point" ]] || continue
    if mountpoint -q "$mount_point"; then
      printf '%s\n' "$mount_point"
    fi
  done < <(find "$media_root" -mindepth 1 -maxdepth 1 -type d | sort)
}

select_destination() {
  local -n device_list_ref=$1
  local device_count
  local selection
  local index

  # Auto-select one destination or let the user choose from multiple devices.
  device_count=${#device_list_ref[@]}
  ((device_count > 0)) ||
    die "No mounted external devices found under /run/media/$USER"

  if ((device_count == 1)); then
    SELECTED_DESTINATION=${device_list_ref[0]}
    log "One mounted destination found: $SELECTED_DESTINATION"
    log "Destination auto-selected and auto-confirmed."
    return 0
  fi

  printf 'Mounted destinations:\n'
  for index in "${!device_list_ref[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${device_list_ref[index]}"
  done

  while true; do
    read -r -p 'Choose destination number: ' selection

    [[ "$selection" =~ ^[0-9]+$ ]] || {
      printf 'Please enter a valid number.\n' >&2
      continue
    }

    if ((selection < 1 || selection > device_count)); then
      printf 'Please choose a number between 1 and %d.\n' "$device_count" >&2
      continue
    fi

    SELECTED_DESTINATION=${device_list_ref[selection-1]}
    break
  done

  printf 'Selected destination: %s\n' "$SELECTED_DESTINATION"
  read -r -p 'Press Enter to confirm...' _
}

validate_destination_mount() {
  # Ensure the chosen destination is still a real mounted device.
  [[ -n "$SELECTED_DESTINATION" ]] || die "Backup destination is empty."
  [[ "$SELECTED_DESTINATION" == "/run/media/$USER/"* ]] ||
    die "Destination is outside /run/media/$USER: $SELECTED_DESTINATION"
  [[ -d "$SELECTED_DESTINATION" ]] ||
    die "Destination directory does not exist: $SELECTED_DESTINATION"
  mountpoint -q "$SELECTED_DESTINATION" ||
    die "Destination is not a mounted filesystem: $SELECTED_DESTINATION"
}

prompt_for_compression() {
  local reply

  # Ask whether a compressed archive should be created in addition to raw files.
  read -r -p 'Create compressed version with pigz? [Y/n]: ' reply
  reply=${reply:-Y}

  case "$reply" in
    Y | y)
      CREATE_COMPRESSED_BACKUP=1
      log "Compressed backup enabled."
      ;;
    N | n)
      CREATE_COMPRESSED_BACKUP=0
      log "Compressed backup disabled."
      ;;
    *)
      die "Invalid answer. Please enter Y, y, N, n, or press Enter for default Y."
      ;;
  esac
}

build_sources() {
  local name
  local source_path

  # Build the list of configured home directories that actually exist.
  SOURCES=()

  for name in "${BACKUP_NAMES[@]}"; do
    source_path="${BACKUP_ROOT}/${name}"
    if [[ -e "$source_path" ]]; then
      SOURCES+=("$source_path")
    else
      warn "Skipping missing source: $source_path"
    fi
  done

  ((${#SOURCES[@]} > 0)) ||
    die "No configured source directories found under $BACKUP_ROOT"
}

check_free_space() {
  local destination_path
  local available_gb

  # Stop early if the destination does not have enough free space.
  destination_path=$1
  available_gb=$(df -BG --output=avail "$destination_path" | tail -n 1 | tr -dc '0-9')
  [[ -n "$available_gb" ]] || die "Unable to determine free space for: $destination_path"

  if ((available_gb < MIN_FREE_GB)); then
    die "Destination has ${available_gb} GB free. Minimum required is ${MIN_FREE_GB} GB."
  fi

  log "Free space check passed: ${available_gb} GB available."
}

prepare_backup_destination() {
  local main_dir

  # Create the MAIN/BKP-<timestamp> destination directory for this run.
  BACKUP_TIMESTAMP=$(date "$TIMESTAMP_FORMAT")
  main_dir="${SELECTED_DESTINATION}/${DESTINATION_PARENT_NAME}"
  BACKUP_DIR="${main_dir}/${BACKUP_PREFIX}-${BACKUP_TIMESTAMP}"

  mkdir -p "$BACKUP_DIR"
}

initialize_logging() {
  # Mirror terminal output into a log file inside the backup directory.
  LOG_FILE="${BACKUP_DIR}/backup.log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "Logging initialized: $LOG_FILE"
}

rsync_for_source() {
  local source
  local target_dir
  local rsync_exit
  local warning_message
  local -a extra_opts=()

  # Apply source-specific excludes before syncing with preserved metadata.
  source=$1
  target_dir=$2

  case "$(basename "$source")" in
    VM)
      extra_opts+=(--exclude=ISO/)
      ;;
    Downloads)
      extra_opts+=(--exclude=*.iso)
      ;;
    .config)
      extra_opts+=(
        '--exclude=*/Cache/'
        '--exclude=*/cache/'
        '--exclude=*/Code Cache/'
        '--exclude=*/GPUCache/'
        '--exclude=*/CachedData/'
        '--exclude=*/CacheStorage/'
        '--exclude=*/Service Worker/'
        '--exclude=*/IndexedDB/'
        '--exclude=*/Local Storage/'
        '--exclude=rambox/'
      )
      ;;
    .var)
      extra_opts+=(--exclude=app/)
      ;;
  esac

  mkdir -p "$target_dir"
  log "Backing up $source -> $target_dir"

  set +e
  rsync "${RSYNC_OPTS[@]}" "${extra_opts[@]}" "$source/" "$target_dir/"
  rsync_exit=$?
  set -e

  case "$rsync_exit" in
    0) ;;
    23 | 24)
      warning_message="rsync returned partial-transfer code ${rsync_exit} for $source"
      PARTIAL_WARNINGS+=("$warning_message")
      log "${warning_message}; continuing."
      ;;
    *)
      die "rsync failed with exit code ${rsync_exit} for source: $source"
      ;;
  esac
}

run_backup() {
  local source
  local target_dir

  # Copy each configured source into its own folder inside the backup root.
  for source in "${SOURCES[@]}"; do
    target_dir="${BACKUP_DIR}/$(basename "$source")"
    rsync_for_source "$source" "$target_dir"
  done
}

create_compressed_backup() {
  local archive_name
  local archive_path

  # Create a pigz-compressed archive that matches the backup folder name.
  archive_name="$(basename "$BACKUP_DIR").tar.gz"
  TEMP_ARCHIVE_PATH="${SELECTED_DESTINATION}/${DESTINATION_PARENT_NAME}/.${archive_name}.tmp"
  archive_path="${BACKUP_DIR}/${archive_name}"

  log "Creating compressed archive with pigz: $archive_path"

  tar \
    --create \
    --acls \
    --xattrs \
    --numeric-owner \
    --use-compress-program=pigz \
    --file "$TEMP_ARCHIVE_PATH" \
    --directory "$BACKUP_DIR" \
    .

  mv -f "$TEMP_ARCHIVE_PATH" "$archive_path"
  TEMP_ARCHIVE_PATH=
  log "Compressed archive created: $archive_path"
}

write_partial_summary() {
  local warning_message

  # Save partial-transfer warnings in a separate summary file.
  PARTIAL_SUMMARY_FILE="${BACKUP_DIR}/partial-transfer-summary.log"

  if ((${#PARTIAL_WARNINGS[@]} == 0)); then
    printf 'No rsync partial-transfer warnings were recorded.\n' >"$PARTIAL_SUMMARY_FILE"
    return 0
  fi

  {
    printf 'rsync partial-transfer warnings:\n'
    for warning_message in "${PARTIAL_WARNINGS[@]}"; do
      printf '%s\n' "$warning_message"
    done
  } >"$PARTIAL_SUMMARY_FILE"
}

write_manifest() {
  local source
  local compression_state
  local host_name

  # Save metadata that describes this backup run.
  MANIFEST_FILE="${BACKUP_DIR}/backup-manifest.txt"
  host_name=$(hostname)

  if ((CREATE_COMPRESSED_BACKUP == 1)); then
    compression_state="enabled"
  else
    compression_state="disabled"
  fi

  {
    printf 'script_name=%s\n' "$SCRIPT_NAME"
    printf 'script_version=%s\n' "$SCRIPT_VERSION"
    printf 'timestamp=%s\n' "$BACKUP_TIMESTAMP"
    printf 'user=%s\n' "$USER"
    printf 'hostname=%s\n' "$host_name"
    printf 'destination=%s\n' "$SELECTED_DESTINATION"
    printf 'backup_directory=%s\n' "$BACKUP_DIR"
    printf 'compression=%s\n' "$compression_state"
    printf 'minimum_free_space_gb=%s\n' "$MIN_FREE_GB"
    printf 'log_file=%s\n' "$LOG_FILE"
    printf 'partial_summary_file=%s\n' "$PARTIAL_SUMMARY_FILE"
    printf 'sources=\n'
    for source in "${SOURCES[@]}"; do
      printf '  %s\n' "$source"
    done
  } >"$MANIFEST_FILE"
}

main() {
  # shellcheck disable=SC2034
  local -a mounted_devices=()

  # This script is designed to run without positional arguments.
  if (($# > 0)); then
    usage >&2
    exit 64
  fi

  # Check dependencies, prevent concurrent runs, and collect the backup plan.
  require_command rsync find mountpoint df date hostname tee
  acquire_lock
  prompt_for_compression
  if ((CREATE_COMPRESSED_BACKUP == 1)); then
    require_command tar pigz
  fi

  build_sources

  # Select the destination device and prepare the timestamped backup folder.
  # shellcheck disable=SC2034
  mapfile -t mounted_devices < <(get_mounted_devices)
  select_destination mounted_devices
  validate_destination_mount
  check_free_space "$SELECTED_DESTINATION"

  prepare_backup_destination
  initialize_logging
  log "Backup destination ready: $BACKUP_DIR"

  # Run the raw backup first, then optionally create the compressed archive.
  run_backup

  if ((CREATE_COMPRESSED_BACKUP == 1)); then
    create_compressed_backup
  fi

  write_partial_summary
  write_manifest

  log "Backup completed."
  log "Latest backup path: $BACKUP_DIR"
}

main "$@"
