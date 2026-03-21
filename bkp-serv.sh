#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_NAME
readonly MIN_FREE_GB=20
readonly TIMESTAMP_FORMAT='+%j-%d-%m-%H-%M-%S'
readonly RUN_AS_USER="${SUDO_USER:-$USER}"
readonly MEDIA_ROOT="/run/media/${RUN_AS_USER}"
readonly DESTINATION_PARENT_NAME="SERV"
readonly BACKUP_PREFIX="SERV"
readonly RESTORE_SCRIPT_SOURCE="/home/ralexander/Code/BKP/restore-serv.sh"
readonly LOCK_DIR="/tmp/bkp-serv.lock"
readonly BACKUP_SOURCES=(
  /etc/ssh/sshd_config
  "/home/${RUN_AS_USER}/.ssh"
  /boot/grub/themes/lateralus
  /etc/default/grub
  /etc/samba/smb.conf
  /etc/fstab
  /etc/mkinitcpio.conf
  /usr/share/plymouth/plymouthd.defaults
  /usr/lib/sddm/sddm.conf.d/default.conf
)
readonly OPTIONAL_GLOBS=(
  /etc/samba/creds-*
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

SELECTED_DESTINATION=
BACKUP_TIMESTAMP=
BACKUP_DIR=
LOG_FILE=
LOCK_ACQUIRED=0
ERROR_REPORTED=0
declare -a SOURCES=()
declare -a PARTIAL_WARNINGS=()

usage() {
  cat <<'EOF'
Usage:
  sudo ./bkp-serv.sh

Description:
  Detects mounted external devices under /run/media/<user>, selects a
  destination, creates SERV/SERV-<timestamp>, checks for at least 20 GB free
  space, and copies the configured root-owned source paths with rsync while preserving
  ownership, permissions, ACLs, and extended attributes.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

report_failure() {
  local message

  message=$1

  if ((ERROR_REPORTED == 1)); then
    return 0
  fi

  ERROR_REPORTED=1

  if [[ -n "$LOG_FILE" ]]; then
    {
      printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$message"
      [[ -n "$SELECTED_DESTINATION" ]] && printf 'destination=%s\n' "$SELECTED_DESTINATION"
      [[ -n "$BACKUP_DIR" ]] && printf 'backup_directory=%s\n' "$BACKUP_DIR"
      printf 'run_as_user=%s\n' "$RUN_AS_USER"
      printf 'next_checks=verify mount, free space, source paths, rsync output, and write permissions\n'
    } >>"$LOG_FILE"
  fi

  printf 'Error: %s\n' "$message" >&2
  [[ -n "$SELECTED_DESTINATION" ]] && printf 'Destination: %s\n' "$SELECTED_DESTINATION" >&2
  [[ -n "$BACKUP_DIR" ]] && printf 'Backup directory: %s\n' "$BACKUP_DIR" >&2
  [[ -n "$LOG_FILE" ]] && printf 'Error log: %s\n' "$LOG_FILE" >&2
  printf 'Useful checks: mounted device, free space, source paths, rsync output, and write permissions.\n' >&2
}

die() {
  report_failure "$*"
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
  local message

  line_no=$1
  exit_code=$2
  message="${SCRIPT_NAME} failed at line ${line_no} with exit code ${exit_code}"
  report_failure "$message"
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

require_root() {
  # Prompt for sudo and relaunch the script as root when needed.
  if ((EUID == 0)); then
    return 0
  fi

  log "Root privileges are required. Requesting sudo access."
  exec sudo --preserve-env=PATH "$0" "$@"
}

check_sources() {
  local source
  local matches_found
  local optional_path
  local optional_glob

  # Build the list of configured root-owned source paths.
  SOURCES=()
  for source in "${BACKUP_SOURCES[@]}"; do
    [[ -e "$source" ]] || die "Source path does not exist: $source"
    SOURCES+=("$source")
  done

  # Add optional Samba credential files when they exist.
  for optional_glob in "${OPTIONAL_GLOBS[@]}"; do
    matches_found=0
    for optional_path in $optional_glob; do
      if [[ -e "$optional_path" ]]; then
        SOURCES+=("$optional_path")
        matches_found=1
      fi
    done

    if ((matches_found == 0)); then
      warn "Optional source not found for pattern: $optional_glob"
    fi
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
  local mount_point

  # Find mounted external devices under the original user's media directory.
  [[ -d "$MEDIA_ROOT" ]] || return 0

  while IFS= read -r mount_point; do
    [[ -n "$mount_point" ]] || continue
    if mountpoint -q "$mount_point"; then
      printf '%s\n' "$mount_point"
    fi
  done < <(find "$MEDIA_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
}

get_luks_nvme_devices() {
  # Find NVMe partitions that use the crypto_LUKS filesystem type.
  lsblk -rno PATH,FSTYPE |
    while read -r device_path fs_type; do
      [[ "$device_path" == /dev/nvme* ]] || continue
      [[ "$fs_type" == "crypto_LUKS" ]] || continue
      printf '%s\n' "$device_path"
    done
}

select_destination() {
  local -n device_list_ref=$1
  local device_count
  local selection
  local index

  # Show available destinations and auto-select when only one is mounted.
  device_count=${#device_list_ref[@]}
  ((device_count > 0)) || die "No mounted external devices found under ${MEDIA_ROOT}"

  printf 'Mounted destinations:\n'
  for index in "${!device_list_ref[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${device_list_ref[index]}"
  done

  if ((device_count == 1)); then
    SELECTED_DESTINATION=${device_list_ref[0]}
    log "One mounted destination found: $SELECTED_DESTINATION"
    log "Destination auto-selected and auto-confirmed."
    return 0
  fi

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
  [[ "$SELECTED_DESTINATION" == "${MEDIA_ROOT}/"* ]] ||
    die "Destination is outside ${MEDIA_ROOT}: $SELECTED_DESTINATION"
  [[ -d "$SELECTED_DESTINATION" ]] ||
    die "Destination directory does not exist: $SELECTED_DESTINATION"
  mountpoint -q "$SELECTED_DESTINATION" ||
    die "Destination is not a mounted filesystem: $SELECTED_DESTINATION"
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
  local parent_dir

  # Create the SERV/SERV-<timestamp> destination directory for this run.
  BACKUP_TIMESTAMP=$(date "$TIMESTAMP_FORMAT")
  parent_dir="${SELECTED_DESTINATION}/${DESTINATION_PARENT_NAME}"
  BACKUP_DIR="${parent_dir}/${BACKUP_PREFIX}-${BACKUP_TIMESTAMP}"
  mkdir -p "$BACKUP_DIR"
}

initialize_logging() {
  # Prepare the error log path inside the backup directory.
  LOG_FILE="${BACKUP_DIR}/backup.log"
}

backup_luks_headers() {
  local luks_device
  local header_file
  local header_dir
  local found_luks

  # Back up detected NVMe LUKS headers into the current SERV backup.
  found_luks=0
  header_dir="${BACKUP_DIR}/luks-headers"

  while IFS= read -r luks_device; do
    [[ -n "$luks_device" ]] || continue
    found_luks=1
    mkdir -p "$header_dir"
    header_file="${header_dir}/$(basename "$luks_device")-luks-header.img"
    log "Backing up LUKS header for $luks_device -> $header_file"
    cryptsetup luksHeaderBackup "$luks_device" --header-backup-file "$header_file"
  done < <(get_luks_nvme_devices)

  if ((found_luks == 0)); then
    warn "No LUKS-encrypted NVMe device found. Skipping LUKS header backup."
  fi
}

rsync_for_source() {
  local source
  local rsync_exit
  local warning_message
  local -a extra_opts=()

  # Copy one source path into the SERV backup directory.
  source=$1

  case "$source" in
    "/home/${RUN_AS_USER}/.ssh")
      extra_opts+=(--exclude=agent/)
      ;;
  esac

  log "Backing up $source -> $BACKUP_DIR"

  set +e
  rsync "${RSYNC_OPTS[@]}" "${extra_opts[@]}" "$source" "$BACKUP_DIR/"
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

  # Copy each provided source path into the backup directory.
  for source in "${SOURCES[@]}"; do
    rsync_for_source "$source"
  done
}

copy_restore_script() {
  local restore_target

  # Copy the restore helper into the same backup directory.
  [[ -f "$RESTORE_SCRIPT_SOURCE" ]] ||
    die "Restore script not found: $RESTORE_SCRIPT_SOURCE"

  restore_target="${BACKUP_DIR}/$(basename "$RESTORE_SCRIPT_SOURCE")"
  cp -a "$RESTORE_SCRIPT_SOURCE" "$restore_target"
  log "Copied restore script -> $restore_target"
}

main() {
  # shellcheck disable=SC2034
  local -a mounted_devices=()

  if (($# > 0)); then
    usage >&2
    exit 64
  fi

  require_command rsync find mountpoint df date lsblk cryptsetup
  require_root "$@"
  check_sources
  acquire_lock

  # Select the destination device and prepare the timestamped backup folder.
  # shellcheck disable=SC2034
  mapfile -t mounted_devices < <(get_mounted_devices)
  select_destination mounted_devices
  validate_destination_mount
  check_free_space "$SELECTED_DESTINATION"

  prepare_backup_destination
  initialize_logging
  log "Backup destination ready: $BACKUP_DIR"

  # Run the backup using rsync with metadata-preserving options.
  backup_luks_headers
  run_backup
  copy_restore_script

  log "Backup completed."
  log "Latest backup path: $BACKUP_DIR"
}

main "$@"
