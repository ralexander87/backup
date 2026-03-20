#!/usr/bin/env bash

set -euo pipefail

readonly MIN_FREE_GB=20
readonly TIMESTAMP_FORMAT='+%j-%d-%m-%H-%M-%S'
readonly BACKUP_ROOT="/home/$USER"
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
  .ssh
  .icons
  .themes
  .mydotfiles
  .local
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
declare -a SOURCES=()

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

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

require_command() {
  local cmd

  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

get_mounted_devices() {
  local media_root mount_point

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
  local device_count selection index

  device_count=${#device_list_ref[@]}
  (( device_count > 0 )) || die "No mounted external devices found under /run/media/$USER"

  if (( device_count == 1 )); then
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

    if (( selection < 1 || selection > device_count )); then
      printf 'Please choose a number between 1 and %d.\n' "$device_count" >&2
      continue
    fi

    SELECTED_DESTINATION=${device_list_ref[selection - 1]}
    break
  done

  printf 'Selected destination: %s\n' "$SELECTED_DESTINATION"
  read -r -p 'Press Enter to confirm...' _
}

prompt_for_compression() {
  local reply

  read -r -p 'Create compressed version with pigz? [Y/n]: ' reply
  reply=${reply:-Y}

  case "$reply" in
    Y|y)
      CREATE_COMPRESSED_BACKUP=1
      log "Compressed backup enabled."
      ;;
    N|n)
      CREATE_COMPRESSED_BACKUP=0
      log "Compressed backup disabled."
      ;;
    *)
      die "Invalid answer. Please enter Y, y, N, n, or press Enter for default Y."
      ;;
  esac
}

build_sources() {
  local name source_path

  SOURCES=()

  for name in "${BACKUP_NAMES[@]}"; do
    source_path="${BACKUP_ROOT}/${name}"
    if [[ -e "$source_path" ]]; then
      SOURCES+=("$source_path")
    else
      warn "Skipping missing source: $source_path"
    fi
  done

  (( ${#SOURCES[@]} > 0 )) || die "No configured source directories found under $BACKUP_ROOT"
}

check_free_space() {
  local destination_path available_gb

  destination_path=$1
  available_gb=$(df -BG --output=avail "$destination_path" | tail -n 1 | tr -dc '0-9')
  [[ -n "$available_gb" ]] || die "Unable to determine free space for: $destination_path"

  if (( available_gb < MIN_FREE_GB )); then
    die "Destination has ${available_gb} GB free. Minimum required is ${MIN_FREE_GB} GB."
  fi

  log "Free space check passed: ${available_gb} GB available."
}

prepare_backup_destination() {
  local timestamp main_dir backup_dir

  BACKUP_TIMESTAMP=$(date "$TIMESTAMP_FORMAT")
  main_dir="${SELECTED_DESTINATION}/MAIN"
  backup_dir="${main_dir}/BKP-${BACKUP_TIMESTAMP}"

  mkdir -p "$backup_dir"
  printf '%s\n' "$backup_dir"
}

rsync_for_source() {
  local source target_dir rsync_exit
  local -a extra_opts=()

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
    .local)
      extra_opts+=(
        '--exclude=share/fonts/'
        '--exclude=share/fonts/NerdFonts/'
      )
      ;;
    .var)
      extra_opts+=(--exclude=app/)
      ;;
    .ssh)
      extra_opts+=(--exclude=agent/)
      ;;
  esac

  mkdir -p "$target_dir"
  log "Backing up $source -> $target_dir"

  set +e
  rsync "${RSYNC_OPTS[@]}" "${extra_opts[@]}" "$source/" "$target_dir/"
  rsync_exit=$?
  set -e

  case "$rsync_exit" in
    0)
      ;;
    23|24)
      log "rsync returned partial-transfer code ${rsync_exit} for $source; continuing."
      ;;
    *)
      die "rsync failed with exit code ${rsync_exit} for source: $source"
      ;;
  esac
}

run_backup() {
  local destination_dir source target_dir

  destination_dir=$1

  for source in "${SOURCES[@]}"; do
    target_dir="${destination_dir}/$(basename "$source")"
    rsync_for_source "$source" "$target_dir"
  done
}

create_compressed_backup() {
  local destination_dir archive_name temp_archive archive_path

  destination_dir=$1
  archive_name="BKP-${BACKUP_TIMESTAMP}.tar.gz"
  temp_archive="${SELECTED_DESTINATION}/MAIN/.${archive_name}.tmp"
  archive_path="${destination_dir}/${archive_name}"

  log "Creating compressed archive with pigz: $archive_path"

  tar \
    --create \
    --acls \
    --xattrs \
    --numeric-owner \
    --use-compress-program=pigz \
    --file "$temp_archive" \
    --directory "$destination_dir" \
    .

  mv -f "$temp_archive" "$archive_path"
  log "Compressed archive created: $archive_path"
}

main() {
  local -a mounted_devices=()
  local destination_dir

  if (( $# > 0 )); then
    usage >&2
    exit 64
  fi

  require_command rsync find mountpoint df date
  prompt_for_compression
  if (( CREATE_COMPRESSED_BACKUP == 1 )); then
    require_command tar pigz
  fi

  build_sources

  mapfile -t mounted_devices < <(get_mounted_devices)
  select_destination mounted_devices
  check_free_space "$SELECTED_DESTINATION"

  destination_dir=$(prepare_backup_destination)
  log "Backup destination ready: $destination_dir"

  run_backup "$destination_dir"

  if (( CREATE_COMPRESSED_BACKUP == 1 )); then
    create_compressed_backup "$destination_dir"
  fi

  log "Backup completed."
  log "Latest backup path: $destination_dir"
}

main "$@"
