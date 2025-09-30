#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: build-tile-image.sh [options] /path/to/map.osm.pbf /path/to/db-dir /path/to/rendered-dir

Options:
  --stage STAGE            Stage to run inside the container (import|render|all, default: all)
  --min-zoom VALUE         Override MIN_ZOOM for tile rendering
  --max-zoom VALUE         Override MAX_ZOOM for tile rendering
  --render-threads VALUE   Override RENDER_THREADS used by renderd
  --osm-cache VALUE        Override OSM2PGSQL_CACHE (in MiB)
  --osm-procs VALUE        Override OSM2PGSQL_NUM_PROCESSES
  --reset-database         Force database reset before import
  --no-reset-database      Skip resetting the database before import
  --image-tag TAG          Use a custom container image tag (default env IMAGE_TAG or maprender-renderrer:latest)
  --shm-size SIZE          Set Podman shared memory size (default env PODMAN_SHM_SIZE or 4g)
  -h, --help               Show this help and exit
USAGE
}

STAGE=""
MIN_ZOOM_OVERRIDE=""
MAX_ZOOM_OVERRIDE=""
RENDER_THREADS_OVERRIDE=""
OSM_CACHE_OVERRIDE=""
OSM_PROCS_OVERRIDE=""
RESET_DATABASE_OVERRIDE=""
IMAGE_TAG_OVERRIDE=""
SHM_SIZE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --stage)
      if [[ $# -lt 2 ]]; then
        echo '--stage requires a value (import|render|all).' >&2
        usage >&2
        exit 1
      fi
      STAGE=$2
      shift 2
      continue
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

if [[ $# -ne 3 ]]; then
  usage >&2
  exit 1
fi

if [[ -n "${STAGE}" ]]; then
  case "${STAGE}" in
    import|render|all)
      ;;
    *)
      echo "Invalid stage '${STAGE}'. Expected import, render, or all." >&2
      usage >&2
      exit 1
      ;;
  esac
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
if [[ -n "${RESET_DATABASE_OVERRIDE}" ]]; then
  ENV_ARGS+=(-e RESET_DATABASE="${RESET_DATABASE_OVERRIDE}")
fi

ENTRYPOINT_STAGE_ARGS=()
if [[ -n "${STAGE}" ]]; then
  ENTRYPOINT_STAGE_ARGS+=("${STAGE}")
fi

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
  "${ENV_ARGS[@]}" \
  "${IMAGE_TAG}" \
  "${ENTRYPOINT_STAGE_ARGS[@]}"

printf 'Tiles stored under %s\n' "${TILES_ABS}"
printf 'PostgreSQL data persisted under %s\n' "${DB_ABS}"
