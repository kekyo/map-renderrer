#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 /path/to/map.osm.pbf /path/to/db-dir /path/to/rendered-dir" >&2
  exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "podman command not found. Please install Podman to continue." >&2
  exit 1
fi

resolve_path() {
  local target=$1
  if command -v readlink >/dev/null 2>&1; then
    if readlink -f "${target}" >/dev/null 2>&1; then
      readlink -f "${target}"
      return
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$target" <<'PY'
import os, sys
print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
    return
  fi
  case ${target} in
    /*) printf '%s\n' "${target}" ;;
    *) printf '%s/%s\n' "$(pwd)" "${target}" ;;
  esac
}

PBF_SOURCE=$1
DB_DIR=$2
TILES_DIR=$3

if [[ ! -f "${PBF_SOURCE}" ]]; then
  echo "PBF file not found: ${PBF_SOURCE}" >&2
  exit 1
fi

PBF_ABS=$(resolve_path "${PBF_SOURCE}")
mkdir -p "${DB_DIR}" "${TILES_DIR}"
DB_ABS=$(resolve_path "${DB_DIR}")
TILES_ABS=$(resolve_path "${TILES_DIR}")

STATE_DIR=${STATE_DIR:-"${DB_ABS}/state"}
mkdir -p "${STATE_DIR}"

IMAGE_TAG=${IMAGE_TAG:-maprender-renderrer:latest}
PODMAN_SHM_SIZE=${PODMAN_SHM_SIZE:-4g}
IMAGE_STATE_FILE="${STATE_DIR}/image.sha256"
CURRENT_IMAGE_SIG=$(cat renderrer/Dockerfile renderrer/docker-entrypoint.sh | sha256sum | awk '{print $1}')

need_build=1
if [[ -f "${IMAGE_STATE_FILE}" ]]; then
  read -r RECORDED_SIG <"${IMAGE_STATE_FILE}"
  if [[ "${RECORDED_SIG}" == "${CURRENT_IMAGE_SIG}" ]] && podman image exists "${IMAGE_TAG}" >/dev/null 2>&1; then
    need_build=0
    printf 'Reusing existing container image %s\n' "${IMAGE_TAG}"
  fi
fi

if (( need_build )); then
  printf 'Building container image %s\n' "${IMAGE_TAG}"
  podman build -t "${IMAGE_TAG}" renderrer
  printf '%s\n' "${CURRENT_IMAGE_SIG}" >"${IMAGE_STATE_FILE}"
fi

podman run --rm \
  --shm-size "${PODMAN_SHM_SIZE}" \
  -v "${PBF_ABS}:/data/map.osm.pbf:ro" \
  -v "${DB_ABS}:/data/db" \
  -v "${TILES_ABS}:/data/rendered" \
  -v "${STATE_DIR}:/data/state" \
  -e STEP_STATE_DIR=/data/state \
  "${IMAGE_TAG}"

printf 'Tiles stored under %s\n' "${TILES_ABS}"
printf 'PostgreSQL data persisted under %s\n' "${DB_ABS}"
