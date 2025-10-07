#!/usr/bin/env bash
# -------------------------------------------------------------------
# mailcow cold standby merge script
# Merged to preserve upstream behavior while adding hardened checks,
# reproducible artifacts, and explicit stewardship logic.
#
# Notes:
# - Honors REMOTE_SSH_USER defaulting to local $(whoami)
# - Validates SSH key existence and strict permissions (600)
# - Explicitly rejects BusyBox grep (local and remote)
# - Validates REMOTE_SSH_PORT numeric bounds
# - Detects remote Docker Compose flavor (native vs standalone v2)
# - Handles architecture mismatch gracefully (skips incompatible volumes)
# - Creates consistent MariaDB backups via mariabackup (backup+prepare)
# - Supports tar+scp or rsync path for volume transfer
# - Retries remote actions with sudo fallback where necessary
# - Forces image cleanup via update.sh -f --gc on remote
#
# Environment variables:
#   REMOTE_SSH_KEY      (required) path to private key
#   REMOTE_SSH_HOST     (required) remote hostname
#   REMOTE_SSH_PORT     (optional) default depends on ssh config
#   REMOTE_SSH_USER     (optional) defaults to $(whoami)
#   USE_TAR_FOR_VOLUMES (optional) defaults to "true"
#
# -------------------------------------------------------------------

# Optional strict mode (enable by exporting STRICT_MODE=1 before running)
if [[ "${STRICT_MODE:-0}" == "1" ]]; then
  set -euo pipefail
fi

PATH=${PATH}:/opt/bin
DATE=$(date +%Y-%m-%d_%H_%M_%S)
LOCAL_ARCH=$(uname -m)
export LC_ALL=C

REMOTE_SSH_USER="${REMOTE_SSH_USER:-$(whoami)}"
USE_TAR_FOR_VOLUMES="${USE_TAR_FOR_VOLUMES:-true}"

echo
echo "If this script is run automatically by cron or a timer AND you are using block-level snapshots on your backup destination, make sure both do not run at the same time."
echo "The snapshots of your backup destination should run AFTER the cold standby script finished to ensure consistent snapshots."
echo

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

function die() {
  # **Msg:** print error and exit with non-zero code
  local msg="$1"
  >&2 echo -e "\e[31m${msg}\e[0m"
  exit 1
}

function info() {
  # **Msg:** print informational message (bold)
  local msg="$1"
  echo -e "\033[1m${msg}\033[0m"
}

function warn() {
  # **Msg:** print warning message (yellow)
  local msg="$1"
  echo -e "\e[1;33m${msg}\e[0m"
}

function ok() {
  # **Msg:** print OK status
  local msg="${1:-OK}"
  echo "${msg}"
}

# -------------------------------------------------------------------
# Preflight checks (local)
# -------------------------------------------------------------------

function preflight_local_checks() {
  if [[ -z "${REMOTE_SSH_KEY}" ]]; then
    die "REMOTE_SSH_KEY is not set"
  fi

  if [[ ! -s "${REMOTE_SSH_KEY}" ]]; then
    die "Keyfile ${REMOTE_SSH_KEY} is empty"
  fi

  # Enforce 600 permissions on SSH keyfile
  local key_mode
  key_mode="$(stat -c "%a" "${REMOTE_SSH_KEY}")"
  if [[ "${key_mode}" -ne 600 ]]; then
    die "Keyfile ${REMOTE_SSH_KEY} has insecure permissions (mode=${key_mode}, expected=600)"
  fi

  # Validate REMOTE_SSH_PORT if provided
  if [[ -n "${REMOTE_SSH_PORT:-}" ]]; then
    if [[ ${REMOTE_SSH_PORT} != ?(-)+([0-9]) ]] || [[ ${REMOTE_SSH_PORT} -gt 65535 ]]; then
      die "REMOTE_SSH_PORT is set but not an integer < 65535"
    fi
  fi

  # REMOTE_SSH_HOST must be set
  if [[ -z "${REMOTE_SSH_HOST:-}" ]]; then
    die "REMOTE_SSH_HOST cannot be empty"
  fi

  # Required binaries on local
  for bin in rsync docker grep cut tar scp ssh; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
      die "Cannot find ${bin} in local PATH, exiting..."
    fi
  done

  # Reject BusyBox grep locally
  if grep --help 2>&1 | head -n 1 | grep -q -i "busybox"; then
    die "BusyBox grep detected on local system, please install GNU grep"
  fi
}

# -------------------------------------------------------------------
# Preflight checks (remote)
# -------------------------------------------------------------------

function preflight_remote_checks() {
  # Verify remote connectivity and rsync presence
  if ! ssh -o StrictHostKeyChecking=no \
    -i "${REMOTE_SSH_KEY}" \
    -p "${REMOTE_SSH_PORT}" \
    "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
    rsync --version >/dev/null 2>&1; then
      >&2 echo -e "\e[31mCould not verify connection to ${REMOTE_SSH_HOST}\e[0m"
      >&2 echo -e "\e[31mPlease check the output above (is rsync >= 3.1.0 installed on the remote system?)\e[0m"
      exit 1
  fi

  # Reject BusyBox grep remotely
  if ssh -o StrictHostKeyChecking=no \
    -i "${REMOTE_SSH_KEY}" \
    -p "${REMOTE_SSH_PORT}" \
    "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
    grep --help 2>&1 | head -n 1 | grep -q -i "busybox" ; then
      die "BusyBox grep detected on remote system ${REMOTE_SSH_HOST}, please install GNU grep"
  fi

  # Required binaries on remote
  for bin in rsync docker tar scp ssh; do
    if ! ssh -o StrictHostKeyChecking=no \
      -i "${REMOTE_SSH_KEY}" \
      -p "${REMOTE_SSH_PORT}" \
      "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
      which "${bin}" >/dev/null 2>&1; then
        die "Cannot find ${bin} in remote PATH, exiting..."
    fi
  done

  # Detect Docker Compose flavor on remote
  ssh -o StrictHostKeyChecking=no \
      -i "${REMOTE_SSH_KEY}" \
      -p "${REMOTE_SSH_PORT}" \
      "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
      "bash -s" << "EOF"
if docker compose > /dev/null 2>&1; then
  exit 0
elif docker-compose version --short | grep "^2." > /dev/null 2>&1; then
  exit 1
else
  exit 2
fi
EOF

  local ret=$?
  if [[ ${ret} -eq 0 ]]; then
    COMPOSE_COMMAND="docker compose"
    echo "INFO: Using native docker compose on remote"
  elif [[ ${ret} -eq 1 ]]; then
    COMPOSE_COMMAND="docker-compose"
    echo "INFO: Using standalone docker compose on remote"
  else
    die "Cannot find any Docker Compose on remote, exiting..."
  fi

  # Remote architecture
  REMOTE_ARCH="$(ssh -o StrictHostKeyChecking=no -i "${REMOTE_SSH_KEY}" -p "${REMOTE_SSH_PORT}" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" "uname -m")"
}

# -------------------------------------------------------------------
# Context
# -------------------------------------------------------------------

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../mailcow.conf"
COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.yml"
CMPS_PRJ="$(echo "${COMPOSE_PROJECT_NAME}" | tr -cd 'A-Za-z-_')"
SQLIMAGE="$(grep -iEo '(mysql|mariadb)\:.+' "${COMPOSE_FILE}")"

preflight_local_checks
preflight_remote_checks

echo
info "Found compose project name ${CMPS_PRJ} for ${MAILCOW_HOSTNAME}"
info "Found SQL ${SQLIMAGE}"
echo

# Architecture mismatch notice
if [[ "${LOCAL_ARCH}" != "${REMOTE_ARCH}" ]]; then
  echo
  warn "!!!!!!!!!!!!!!!!!!!!!!!!!! CAUTION !!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo -e "\e[3;33mDetected Architecture mismatch from source to destination...\e[0m"
  echo -e "\e[3;33mYour backup is transferred but some volumes might be skipped!\e[0m"
  warn "!!!!!!!!!!!!!!!!!!!!!!!!!! CAUTION !!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo
  sleep 2
fi

# -------------------------------------------------------------------
# Remote preparation (create base directory)
# -------------------------------------------------------------------

info "Preparing remote..."
if ! ssh -o StrictHostKeyChecking=no \
  -i "${REMOTE_SSH_KEY}" \
  -p "${REMOTE_SSH_PORT}" \
  "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
  mkdir -p "${SCRIPT_DIR}/../" ; then
    info "Trying with sudo on remote..."
    if ! ssh -o StrictHostKeyChecking=no \
      -i "${REMOTE_SSH_KEY}" \
      -p "${REMOTE_SSH_PORT}" \
      "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
      sudo mkdir -p "${SCRIPT_DIR}/../" ; then
        die "[ERR] - Could not prepare remote for mailcow base directory transfer"
    fi
fi

# -------------------------------------------------------------------
# Sync base directory (rsync)
# -------------------------------------------------------------------

info "Synchronizing mailcow base directory..."
rsync --delete -aH -e "ssh -o StrictHostKeyChecking=no -i \"${REMOTE_SSH_KEY}\" -p ${REMOTE_SSH_PORT}" \
  "${SCRIPT_DIR}/../" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:${SCRIPT_DIR}/../"
ec=$?
if [[ ${ec} -ne 0 && ${ec} -ne 24 ]]; then
  die "[ERR] - Could not transfer mailcow base directory to remote"
fi

# -------------------------------------------------------------------
# Prepare remote containers (create networks, volumes, containers)
# -------------------------------------------------------------------

echo -e "\e[33mCreating networks, volumes and containers on remote...\e[0m"
if ! ssh -o StrictHostKeyChecking=no \
  -i "${REMOTE_SSH_KEY}" \
  -p "${REMOTE_SSH_PORT}" \
  "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
  ${COMPOSE_COMMAND} -f "${SCRIPT_DIR}/../docker-compose.yml" create 2>&1 ; then
    >&2 echo -e "\e[31m[ERR]\e[0m - Could not create networks, volumes and containers on remote"
fi

# -------------------------------------------------------------------
# Consistent Redis dump
# -------------------------------------------------------------------

echo -ne "\033[1mRunning redis-cli save... \033[0m"
docker exec "$(docker ps -qf name=redis-mailcow)" redis-cli -a "${REDISPASS}" --no-auth-warning save

# -------------------------------------------------------------------
# Volume transfer
# -------------------------------------------------------------------

for vol in $(docker volume ls -qf name="${CMPS_PRJ}"); do
  # Determine local mountpoint of volume
  mountpoint="$(docker inspect "${vol}" | grep Mountpoint | cut -d '"' -f4)"

  info "Creating remote mountpoint ${mountpoint} for ${vol}..."

  # Create mountpoint on remote with sudo fallback
  if ! ssh -o StrictHostKeyChecking=no \
    -i "${REMOTE_SSH_KEY}" \
    -p "${REMOTE_SSH_PORT}" \
    "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
    mkdir -p "${mountpoint}"; then
      info "Trying with sudo on remote..."
      ssh -o StrictHostKeyChecking=no \
        -i "${REMOTE_SSH_KEY}" \
        -p "${REMOTE_SSH_PORT}" \
        "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
        sudo mkdir -p "${mountpoint}"
  fi

  # -----------------------------------------------------------------
  # MariaDB: use mariabackup for consistent backup
  # -----------------------------------------------------------------
  if [[ "${vol}" =~ "mysql-vol-1" ]]; then
    rm -rf "${SCRIPT_DIR}/../_tmp_mariabackup/"
    info "Creating consistent backup of MariaDB volume..."

    # Backup phase
    if ! docker run --rm \
      --network "$(docker network ls -qf name=${CMPS_PRJ}_) " \
      -v "$(docker volume ls -qf name=${CMPS_PRJ}_mysql-vol-1)":/var/lib/mysql/:ro \
      --entrypoint= \
      -v "${SCRIPT_DIR}/../_tmp_mariabackup":/backup \
      "${SQLIMAGE}" mariabackup --host mysql --user root --password "${DBROOT}" --backup --target-dir=/backup 2>/dev/null ; then
        >&2 echo -e "\e[31m[ERR]\e[0m - Could not create MariaDB backup on source"
        rm -rf "${SCRIPT_DIR}/../_tmp_mariabackup/"
        exit 1
    fi

    # Prepare phase
    if ! docker run --rm \
      --network "$(docker network ls -qf name=${CMPS_PRJ}_) " \
      --entrypoint= \
      -v "${SCRIPT_DIR}/../_tmp_mariabackup":/backup \
      "${SQLIMAGE}" mariabackup --prepare --target-dir=/backup 2>/dev/null ; then
        >&2 echo -e "\e[31m[ERR]\e[0m - Could not transfer MariaDB backup to remote"
        rm -rf "${SCRIPT_DIR}/../_tmp_mariabackup/"
        exit 1
    fi

    chown -R 999:999 "${SCRIPT_DIR}/../_tmp_mariabackup"

    if [[ "${USE_TAR_FOR_VOLUMES}" == "true" ]]; then
      info "Archiving MariaDB backup for transfer..."
      MARIABACKUP_ARCHIVE="${SCRIPT_DIR}/../_tmp_mariabackup_${DATE}.tar.gz"
      if ! tar -czf "${MARIABACKUP_ARCHIVE}" -C "${SCRIPT_DIR}/../_tmp_mariabackup" . ; then
        >&2 echo -e "\e[31m[ERR]\e[0m - Could not create MariaDB backup archive"
        rm -rf "${SCRIPT_DIR}/../_tmp_mariabackup/"
        exit 1
      fi

      info "Transferring MariaDB backup archive to remote..."
      if ! scp -i "${REMOTE_SSH_KEY}" -P "${REMOTE_SSH_PORT}" "${MARIABACKUP_ARCHIVE}" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:/tmp/" ; then
        >&2 echo -e "\e[31m[ERR]\e[0m - Could not transfer MariaDB backup archive to remote"
        rm -f "${MARIABACKUP_ARCHIVE}"
        rm -rf "${SCRIPT_DIR}/../_tmp_mariabackup/"
        exit 1
      fi

      info "Extracting MariaDB backup on remote..."
      if ! ssh -o StrictHostKeyChecking=no \
        -i "${REMOTE_SSH_KEY}" \
        -p "${REMOTE_SSH_PORT}" \
        "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
        "sudo tar -xzf /tmp/$(basename "${MARIABACKUP_ARCHIVE}") -C \"${mountpoint}\" && sudo rm -f /tmp/$(basename "${MARIABACKUP_ARCHIVE}")" ; then
          >&2 echo -e "\e[31m[ERR]\e[0m - Could not extract MariaDB backup on remote"
          rm -f "${MARIABACKUP_ARCHIVE}"
          rm -rf "${SCRIPT_DIR}/../_tmp_mariabackup/"
          exit 1
      fi

      rm -f "${MARIABACKUP_ARCHIVE}"
      rm -rf "${SCRIPT_DIR}/../_tmp_mariabackup/"

    else
      info "Synchronizing MariaDB backup..."
      rsync --delete --info=progress2 -aH -e "ssh -o StrictHostKeyChecking=no -i \"${REMOTE_SSH_KEY}\" -p ${REMOTE_SSH_PORT}" \
        "${SCRIPT_DIR}/../_tmp_mariabackup/" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:${mountpoint}"
      ec=$?
      if [[ ${ec} -ne 0 && ${ec} -ne 24 ]]; then
        >&2 echo -e "\e[31m[ERR]\\e[0m - Could not transfer MariaDB backup to remote"
        rm -rf "${SCRIPT_DIR}/../_tmp_mariabackup/"
        exit 1
      fi

      rm -rf "${SCRIPT_DIR}/../_tmp_mariabackup/"
    fi

  # -----------------------------------------------------------------
  # Rspamd: only transfer if architectures match
  # -----------------------------------------------------------------
  elif [[ "${vol}" =~ "rspamd-vol-1" ]]; then
    if [[ "${LOCAL_ARCH}" == "${REMOTE_ARCH}" ]]; then
      if [[ "${USE_TAR_FOR_VOLUMES}" == "true" ]]; then
        info "Archiving and transferring ${vol} from local ${mountpoint}..."
        ARCHIVE="/tmp/${vol}_${DATE}.tar.gz"
        if ! tar -czf "${ARCHIVE}" -C "${mountpoint}" . ; then
          >&2 echo -e "\e[31m[ERR]\\e[0m - Could not create archive for ${vol}"
          rm -f "${ARCHIVE}"
          exit 1
        fi
        if ! scp -i "${REMOTE_SSH_KEY}" -P "${REMOTE_SSH_PORT}" "${ARCHIVE}" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:/tmp/" ; then
          >&2 echo -e "\e[31m[ERR]\\e[0m - Could not transfer ${vol} archive to remote"
          rm -f "${ARCHIVE}"
          exit 1
        fi
        if ! ssh -o StrictHostKeyChecking=no \
          -i "${REMOTE_SSH_KEY}" \
          -p "${REMOTE_SSH_PORT}" \
          "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
          "sudo tar -xzf /tmp/$(basename "${ARCHIVE}") -C \"${mountpoint}\" && sudo rm -f /tmp/$(basename "${ARCHIVE}")" ; then
            >&2 echo -e "\e[31m[ERR]\\e[0m - Could not extract ${vol} on remote"
            rm -f "${ARCHIVE}"
            exit 1
        fi
        rm -f "${ARCHIVE}"
      else
        info "Synchronizing ${vol} from local ${mountpoint}..."
        rsync --delete --info=progress2 -aH -e "ssh -o StrictHostKeyChecking=no -i \"${REMOTE_SSH_KEY}\" -p ${REMOTE_SSH_PORT}" \
          "${mountpoint}/" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:${mountpoint}"
        ec=$?
        if [[ ${ec} -ne 0 && ${ec} -ne 24 ]]; then
          >&2 echo -e "\e[31m[ERR]\\e[0m - Could not transfer ${vol} from local ${mountpoint} to remote"
          exit 1
        fi
      fi
    else
      echo -e "\e[1;31mSkipping ${vol} from local machine due to incompatibility between different architectures...\e[0m"
      sleep 2
      continue
    fi

  # -----------------------------------------------------------------
  # Other volumes
  # -----------------------------------------------------------------
  else
    if [[ "${USE_TAR_FOR_VOLUMES}" == "true" ]]; then
      info "Archiving and transferring ${vol} from local ${mountpoint}..."
      ARCHIVE="/tmp/${vol}_${DATE}.tar.gz"
      if ! tar -czf "${ARCHIVE}" -C "${mountpoint}" . ; then
        >&2 echo -e "\e[31m[ERR]\\e[0m - Could not create archive for ${vol}"
        rm -f "${ARCHIVE}"
        exit 1
      fi
      if ! scp -i "${REMOTE_SSH_KEY}" -P "${REMOTE_SSH_PORT}" "${ARCHIVE}" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:/tmp/" ; then
        >&2 echo -e "\e[31m[ERR]\\e[0m - Could not transfer ${vol} archive to remote"
        rm -f "${ARCHIVE}"
        exit 1
      fi
      if ! ssh -o StrictHostKeyChecking=no \
        -i "${REMOTE_SSH_KEY}" \
        -p "${REMOTE_SSH_PORT}" \
        "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
        "sudo tar -xzf /tmp/$(basename "${ARCHIVE}") -C \"${mountpoint}\" && sudo rm -f /tmp/$(basename "${ARCHIVE}")" ; then
          >&2 echo -e "\e[31m[ERR]\\e[0m - Could not extract ${vol} on remote"
          rm -f "${ARCHIVE}"
          exit 1
      fi
      rm -f "${ARCHIVE}"
    else
      info "Synchronizing ${vol} from local ${mountpoint}..."
      rsync --delete --info=progress2 -aH -e "ssh -o StrictHostKeyChecking=no -i \"${REMOTE_SSH_KEY}\" -p ${REMOTE_SSH_PORT}" \
        "${mountpoint}/" "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}:${mountpoint}"
      ec=$?
      if [[ ${ec} -ne 0 && ${ec} -ne 24 ]]; then
        >&2 echo -e "\e[31m[ERR]\\e[0m - Could not transfer ${vol} from local ${mountpoint} to remote"
        exit 1
      fi
    fi
  fi

  echo -e "\e[32mCompleted\e[0m"
done

# -------------------------------------------------------------------
# Restart Docker daemon on remote (sudo fallback)
# -------------------------------------------------------------------

echo -ne "\033[1mRestarting Docker daemon on remote to detect new volumes... \033[0m"
if ! ssh -o StrictHostKeyChecking=no \
  -i "${REMOTE_SSH_KEY}" \
  -p "${REMOTE_SSH_PORT}" \
  "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
  systemctl restart docker ; then
    info "Trying with sudo on remote..."
    if ! ssh -o StrictHostKeyChecking=no \
      -i "${REMOTE_SSH_KEY}" \
      -p "${REMOTE_SSH_PORT}" \
      "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
      sudo systemctl restart docker ; then
        die "[ERR] - Could not restart Docker daemon on remote"
    fi
fi
ok "OK"

# -------------------------------------------------------------------
# Pull images on remote
# -------------------------------------------------------------------

echo -e "\e[33mPulling images on remote...\e[0m"
echo -e "\e[33mProcess is NOT stuck! Please wait...\e[0m"

if ! ssh -o StrictHostKeyChecking=no \
  -i "${REMOTE_SSH_KEY}" \
  -p "${REMOTE_SSH_PORT}" \
  "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
  ${COMPOSE_COMMAND} -f "${SCRIPT_DIR}/../docker-compose.yml" pull --quiet 2>&1 ; then
    >&2 echo -e "\e[31m[ERR]\e[0m - Could not pull images on remote"
fi

# -------------------------------------------------------------------
# Run update script and force garbage cleanup on remote
# -------------------------------------------------------------------

info "Executing update script and forcing garbage cleanup on remote..."
if ! ssh -o StrictHostKeyChecking=no \
  -i "${REMOTE_SSH_KEY}" \
  -p "${REMOTE_SSH_PORT}" \
  "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
  "cd \"${SCRIPT_DIR}/../\" && ./update.sh -f --gc" ; then
    info "Trying with sudo on remote..."
    if ! ssh -o StrictHostKeyChecking=no \
      -i "${REMOTE_SSH_KEY}" \
      -p "${REMOTE_SSH_PORT}" \
      "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" \
      "sudo bash -lc 'cd \"${SCRIPT_DIR}/../\" && ./update.sh -f --gc'" ; then
        >&2 echo -e "\e[31m[ERR]\e[0m - Could not cleanup old images on remote"
    fi
fi

echo -e "\e[32mDone\e[0m"

# -------------------------------------------------------------------
# End
# -------------------------------------------------------------------

