#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: build-tile-image.sh [options] import /path/to/map.osm.pbf /path/to/db-dir
       build-tile-image.sh [options] render /path/to/db-dir /path/to/rendered-dir

Options:
  --min-zoom VALUE         Override MIN_ZOOM for tile rendering
  --max-zoom VALUE         Override MAX_ZOOM for tile rendering
  --render-threads VALUE   Override RENDER_THREADS used by renderd
  --osm-cache VALUE        Override OSM2PGSQL_CACHE (in MiB)
  --osm-procs VALUE        Override OSM2PGSQL_NUM_PROCESSES
  --render-progress VALUE  Report progress every N tiles (0 disables progress logs)
  --reset-database         Force database reset before import
  --no-reset-database      Skip resetting the database before import
  --image-tag TAG          Use a custom container image tag (default env IMAGE_TAG or maprender-renderrer:latest)
  --shm-size SIZE          Set Podman shared memory size (default env PODMAN_SHM_SIZE or 4g)
  -h, --help               Show this help and exit

Stages:
  import                   Runs the osm2pgsql import (requires PBF and database paths)
  render                   Renders tiles from an existing database (requires database and output paths)
USAGE
}

STAGE=""
MIN_ZOOM_OVERRIDE=""
MAX_ZOOM_OVERRIDE=""
RENDER_THREADS_OVERRIDE=""
OSM_CACHE_OVERRIDE=""
OSM_PROCS_OVERRIDE=""
RENDER_PROGRESS_OVERRIDE=""
RESET_DATABASE_OVERRIDE=""
IMAGE_TAG_OVERRIDE=""
SHM_SIZE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --min-zoom)
      if [[ $# -lt 2 ]]; then
        echo '--min-zoom requires a value.' >&2
        usage >&2
        exit 1
      fi
      MIN_ZOOM_OVERRIDE=$2
      shift 2
      continue
      ;;
    --max-zoom)
      if [[ $# -lt 2 ]]; then
        echo '--max-zoom requires a value.' >&2
        usage >&2
        exit 1
      fi
      MAX_ZOOM_OVERRIDE=$2
      shift 2
      continue
      ;;
    --render-threads)
      if [[ $# -lt 2 ]]; then
        echo '--render-threads requires a value.' >&2
        usage >&2
        exit 1
      fi
      RENDER_THREADS_OVERRIDE=$2
      shift 2
      continue
      ;;
    --osm-cache)
      if [[ $# -lt 2 ]]; then
        echo '--osm-cache requires a value.' >&2
        usage >&2
        exit 1
      fi
      OSM_CACHE_OVERRIDE=$2
      shift 2
      continue
      ;;
    --osm-procs)
      if [[ $# -lt 2 ]]; then
        echo '--osm-procs requires a value.' >&2
        usage >&2
        exit 1
      fi
      OSM_PROCS_OVERRIDE=$2
      shift 2
      continue
      ;;
    --render-progress)
      if [[ $# -lt 2 ]]; then
        echo '--render-progress requires a value.' >&2
        usage >&2
        exit 1
      fi
      RENDER_PROGRESS_OVERRIDE=$2
      shift 2
      continue
      ;;
    --reset-database)
      RESET_DATABASE_OVERRIDE=true
      shift
      continue
      ;;
    --no-reset-database)
      RESET_DATABASE_OVERRIDE=false
      shift
      continue
      ;;
    --image-tag)
      if [[ $# -lt 2 ]]; then
        echo '--image-tag requires a value.' >&2
        usage >&2
        exit 1
      fi
      IMAGE_TAG_OVERRIDE=$2
      shift 2
      continue
      ;;
    --shm-size)
      if [[ $# -lt 2 ]]; then
        echo '--shm-size requires a value.' >&2
        usage >&2
        exit 1
      fi
      SHM_SIZE_OVERRIDE=$2
      shift 2
      continue
      ;;
    --)
      shift
      break
      ;;
    import|render)
      STAGE=$1
      shift
      break
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ -z "${STAGE}" && $# -gt 0 ]]; then
  case "$1" in
    import|render)
      STAGE=$1
      shift
      ;;
  esac
fi

if [[ -z "${STAGE}" ]]; then
  echo 'Stage not specified. Provide either "import" or "render".' >&2
  usage >&2
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

case "${STAGE}" in
  import)
    if [[ $# -lt 2 ]]; then
      echo 'import stage requires: /path/to/map.osm.pbf /path/to/db-dir' >&2
      usage >&2
      exit 1
    fi
    PBF_SOURCE=$1
    DB_DIR=$2
    shift 2
    if [[ $# -gt 0 ]]; then
      echo "Unexpected extra arguments: $*" >&2
      usage >&2
      exit 1
    fi
    if [[ ! -f "${PBF_SOURCE}" ]]; then
      echo "PBF file not found: ${PBF_SOURCE}" >&2
      exit 1
    fi
    PBF_ABS=$(resolve_path "${PBF_SOURCE}")
    mkdir -p "${DB_DIR}"
    DB_ABS=$(resolve_path "${DB_DIR}")
    TILES_DIR=""
    TILES_ABS=""
    ;;
  render)
    if [[ $# -lt 2 ]]; then
      echo 'render stage requires: /path/to/db-dir /path/to/rendered-dir' >&2
      usage >&2
      exit 1
    fi
    DB_DIR=$1
    TILES_DIR=$2
    shift 2
    if [[ $# -gt 0 ]]; then
      echo "Unexpected extra arguments: $*" >&2
      usage >&2
      exit 1
    fi
    mkdir -p "${DB_DIR}" "${TILES_DIR}"
    DB_ABS=$(resolve_path "${DB_DIR}")
    TILES_ABS=$(resolve_path "${TILES_DIR}")
    PBF_SOURCE=""
    PBF_ABS=""
    ;;
esac

STATE_DIR=${STATE_DIR:-"${DB_ABS}/state"}
mkdir -p "${STATE_DIR}"

DEFAULT_IMAGE_TAG=${IMAGE_TAG:-maprender-renderrer:latest}
DEFAULT_PODMAN_SHM_SIZE=${PODMAN_SHM_SIZE:-4g}
IMAGE_TAG=${IMAGE_TAG_OVERRIDE:-${DEFAULT_IMAGE_TAG}}
PODMAN_SHM_SIZE=${SHM_SIZE_OVERRIDE:-${DEFAULT_PODMAN_SHM_SIZE}}

ENV_ARGS=(-e STEP_STATE_DIR=/data/state)
if [[ -n "${MIN_ZOOM_OVERRIDE}" ]]; then
  ENV_ARGS+=(-e MIN_ZOOM="${MIN_ZOOM_OVERRIDE}")
fi
if [[ -n "${MAX_ZOOM_OVERRIDE}" ]]; then
  ENV_ARGS+=(-e MAX_ZOOM="${MAX_ZOOM_OVERRIDE}")
fi
if [[ -n "${RENDER_THREADS_OVERRIDE}" ]]; then
  ENV_ARGS+=(-e RENDER_THREADS="${RENDER_THREADS_OVERRIDE}")
fi
if [[ -n "${OSM_CACHE_OVERRIDE}" ]]; then
  ENV_ARGS+=(-e OSM2PGSQL_CACHE="${OSM_CACHE_OVERRIDE}")
fi
if [[ -n "${OSM_PROCS_OVERRIDE}" ]]; then
  ENV_ARGS+=(-e OSM2PGSQL_NUM_PROCESSES="${OSM_PROCS_OVERRIDE}")
fi
if [[ -n "${RENDER_PROGRESS_OVERRIDE}" ]]; then
  ENV_ARGS+=(-e RENDER_PROGRESS_INTERVAL="${RENDER_PROGRESS_OVERRIDE}")
fi
if [[ -n "${RESET_DATABASE_OVERRIDE}" ]]; then
  ENV_ARGS+=(-e RESET_DATABASE="${RESET_DATABASE_OVERRIDE}")
fi

ENTRYPOINT_STAGE_ARGS=("${STAGE}")

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

case "${STAGE}" in
  import)
    VOLUME_ARGS=(
      -v "${PBF_ABS}:/data/map.osm.pbf:ro"
      -v "${DB_ABS}:/data/db"
      -v "${STATE_DIR}:/data/state"
    )
    ;;
  render)
    VOLUME_ARGS=(
      -v "${DB_ABS}:/data/db"
      -v "${TILES_ABS}:/data/rendered"
      -v "${STATE_DIR}:/data/state"
    )
    ;;
esac

podman run --rm \
  --shm-size "${PODMAN_SHM_SIZE}" \
  "${VOLUME_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  "${IMAGE_TAG}" \
  "${ENTRYPOINT_STAGE_ARGS[@]}"

case "${STAGE}" in
  import)
    printf 'PostgreSQL data persisted under %s\n' "${DB_ABS}"
    ;;
  render)
    printf 'Tiles stored under %s\n' "${TILES_ABS}"
    printf 'PostgreSQL data read from %s\n' "${DB_ABS}"
    ;;
esac
