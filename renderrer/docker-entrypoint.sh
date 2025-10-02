#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"
}

SCRIPT_NAME=${0##*/}

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [options] [import|render|all]

Options:
  --pbf PATH              Set the input PBF file path (default: ${PBF_PATH})
  --render-output DIR     Set the render output directory (default: ${RENDER_OUTPUT_ROOT})
  --pgdata-root DIR       Set the PostgreSQL data root (default: ${PGDATA_ROOT})
  --db-name NAME          Override the database name (default: ${POSTGRES_DB})
  --min-zoom VALUE        Minimum zoom level to render (default: ${MIN_ZOOM})
  --max-zoom VALUE        Maximum zoom level to render (default: ${MAX_ZOOM})
  --flat-nodes PATH       Path to osm2pgsql flat nodes file
  --progress-mode MODE    Progress reporting mode: interval|zoom (default: ${RENDER_PROGRESS_MODE})
  --render-progress VALUE Report progress every N tiles when using interval mode (default: ${RENDER_PROGRESS_INTERVAL})
  --reset-database        Force database drop before import
  --no-reset-database     Skip database reset even if RESET_DATABASE=true
  --stage STAGE           Explicitly choose stage: import|render|all
  -h, --help              Show this help and exit

Stages (positional argument):
  import    Import the PBF into PostGIS and refresh indexes/statistics.
  render    Render tiles from the existing PostGIS database.
  all       Run both stages sequentially (default).
USAGE
}

PBF_PATH=${PBF_PATH:-/data/map.osm.pbf}
RENDER_OUTPUT_ROOT=${RENDER_OUTPUT_ROOT:-/data/rendered}
POSTGRES_DB=${POSTGRES_DB:-gis}
MIN_ZOOM=${MIN_ZOOM:-0}
MAX_ZOOM=${MAX_ZOOM:-5}
OSM2PGSQL_CACHE=${OSM2PGSQL_CACHE:-4096}
OSM2PGSQL_NUM_PROCESSES=${OSM2PGSQL_NUM_PROCESSES:-8}
RENDER_THREADS=${RENDER_THREADS:-8}
MAPNIK_XML=${MAPNIK_XML:-/tmp/basic-style.xml}
RESET_DATABASE=${RESET_DATABASE:-true}
FLAT_NODES_PATH=${FLAT_NODES_PATH:-}
OSM2PGSQL_EXTRA_ARGS=${OSM2PGSQL_EXTRA_ARGS:-}
PGDATA_ROOT=${PGDATA_ROOT:-/data/db}
LAYER_SRS=${MAPNIK_LAYER_SRS:-EPSG:3857}
RENDER_PROGRESS_INTERVAL=${RENDER_PROGRESS_INTERVAL:-500}
RENDER_PROGRESS_MODE=${RENDER_PROGRESS_MODE:-zoom}
RENDER_LOG_DIR=${RENDER_LOG_DIR:-/tmp/map-renderer}
RENDER_LOG_PATH=${RENDER_LOG_PATH:-}

PIPELINE_STAGE="all"

RENDERD_PID=""
RENDERD_WRAPPER_PID=""
RENDER_SESSION_LOG=""

while (( $# )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --pbf)
      if [[ $# -lt 2 ]]; then
        log "--pbf requires a path argument."
        usage
        exit 1
      fi
      PBF_PATH=$2
      shift 2
      continue
      ;;
    --render-output)
      if [[ $# -lt 2 ]]; then
        log "--render-output requires a directory argument."
        usage
        exit 1
      fi
      RENDER_OUTPUT_ROOT=$2
      shift 2
      continue
      ;;
    --pgdata-root)
      if [[ $# -lt 2 ]]; then
        log "--pgdata-root requires a directory argument."
        usage
        exit 1
      fi
      PGDATA_ROOT=$2
      shift 2
      continue
      ;;
    --db-name)
      if [[ $# -lt 2 ]]; then
        log "--db-name requires a value."
        usage
        exit 1
      fi
      POSTGRES_DB=$2
      shift 2
      continue
      ;;
    --min-zoom)
      if [[ $# -lt 2 ]]; then
        log "--min-zoom requires a value."
        usage
        exit 1
      fi
      MIN_ZOOM=$2
      shift 2
      continue
      ;;
    --max-zoom)
      if [[ $# -lt 2 ]]; then
        log "--max-zoom requires a value."
        usage
        exit 1
      fi
      MAX_ZOOM=$2
      shift 2
      continue
      ;;
    --flat-nodes)
      if [[ $# -lt 2 ]]; then
        log "--flat-nodes requires a path argument."
        usage
        exit 1
      fi
      FLAT_NODES_PATH=$2
      shift 2
      continue
      ;;
    --progress-mode)
      if [[ $# -lt 2 ]]; then
        log "--progress-mode requires a value (interval|zoom)."
        usage
        exit 1
      fi
      case "$2" in
        interval|zoom)
          RENDER_PROGRESS_MODE=$2
          ;;
        *)
          log "Unknown progress mode '$2'."
          usage
          exit 1
          ;;
      esac
      shift 2
      continue
      ;;
    --render-progress)
      if [[ $# -lt 2 ]]; then
        log "--render-progress requires a numeric value."
        usage
        exit 1
      fi
      RENDER_PROGRESS_INTERVAL=$2
      shift 2
      continue
      ;;
    --reset-database)
      RESET_DATABASE=true
      shift
      continue
      ;;
    --no-reset-database)
      RESET_DATABASE=false
      shift
      continue
      ;;
    --stage)
      if [[ $# -lt 2 ]]; then
        log "--stage requires a value (import|render|all)."
        usage
        exit 1
      fi
      case "$2" in
        import|render|all)
          PIPELINE_STAGE=$2
          ;;
        *)
          log "Unknown stage '$2'."
          usage
          exit 1
          ;;
      esac
      shift 2
      continue
      ;;
    --)
      shift
      break
      ;;
    import|render|all)
      PIPELINE_STAGE=$1
      shift
      continue
      ;;
    -* )
      log "Unknown option '$1'."
      usage
      exit 1
      ;;
    *)
      log "Unexpected argument '$1'."
      usage
      exit 1
      ;;
  esac
done

if (( $# )); then
  if (( $# == 1 )); then
    case "$1" in
      import|render|all)
        PIPELINE_STAGE=$1
        shift
        ;;
      *)
        log "Unexpected argument '$1'."
        usage
        exit 1
        ;;
    esac
  else
    log "Too many arguments: $*"
    usage
    exit 1
  fi
fi

discover_first_existing_dir() {
  local pattern candidate
  shopt -s nullglob
  for pattern in "$@"; do
    [[ -z "${pattern}" ]] && continue
    if [[ -d "${pattern}" ]]; then
      printf '%s\n' "${pattern}"
      shopt -u nullglob
      return 0
    fi
    for candidate in ${pattern}; do
      if [[ -d "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        shopt -u nullglob
        return 0
      fi
    done
  done
  shopt -u nullglob
  return 1
}

prepare_render_log() {
  if [[ -n "${RENDER_SESSION_LOG:-}" ]]; then
    return
  fi

  local ts
  ts=$(date '+%Y%m%dT%H%M%S')
  local target_path
  if [[ -n "${RENDER_LOG_PATH:-}" ]]; then
    target_path=${RENDER_LOG_PATH}
  else
    local dir=${RENDER_LOG_DIR%/}
    target_path="${dir}/render-list-${ts}.log"
  fi

  mkdir -p "$(dirname "${target_path}")"
  : >"${target_path}"
  RENDER_SESSION_LOG=${target_path}
  log "Logging render_list output to ${RENDER_SESSION_LOG}."
}

append_render_log() {
  if [[ -z "${RENDER_SESSION_LOG:-}" ]]; then
    return
  fi
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"${RENDER_SESSION_LOG}"
}

mkdir -p "${RENDER_OUTPUT_ROOT}" /var/run/renderd "${PGDATA_ROOT}"
chown -R postgres:postgres /var/run/renderd
chmod 775 /var/run/renderd 2>/dev/null || true

cluster_info=$(pg_lsclusters | awk 'NR==2 {print $1" "$2" "$6}')
if [[ -z "${cluster_info}" ]]; then
  log "Unable to determine PostgreSQL cluster metadata."
  exit 1
fi
read -r PG_VERSION PG_CLUSTER DEFAULT_PGDATA <<<"${cluster_info}"
DESIRED_PGDATA="${PGDATA_ROOT}/${PG_VERSION}/${PG_CLUSTER}"

ensure_persistent_pgdata() {
  local default_path=$1
  local desired_path=$2

  mkdir -p "${desired_path}"
  if [[ ! -f "${desired_path}/PG_VERSION" ]]; then
    log "Seeding PostgreSQL data into ${desired_path}."
    if [[ -d "${default_path}" ]]; then
      cp -a "${default_path}/." "${desired_path}/"
    fi
  fi

  chown -R postgres:postgres "${PGDATA_ROOT}"

  local resolved_default=""
  local resolved_desired=""
  if [[ -e "${desired_path}" ]]; then
    resolved_desired=$(readlink -f "${desired_path}")
  fi
  if [[ -e "${default_path}" ]]; then
    resolved_default=$(readlink -f "${default_path}")
  fi

  if [[ "${resolved_default}" != "${resolved_desired}" ]]; then
    log "Linking PostgreSQL data directory ${default_path} -> ${desired_path}."
    rm -rf "${default_path}"
    ln -s "${desired_path}" "${default_path}"
  fi
}

ensure_persistent_pgdata "${DEFAULT_PGDATA}" "${DESIRED_PGDATA}"

log "Starting PostgreSQL cluster ${PG_VERSION}/${PG_CLUSTER}."
pg_ctlcluster "${PG_VERSION}" "${PG_CLUSTER}" start

cleanup() {
  if [[ -n "${RENDERD_PID:-}" ]]; then
    log "Stopping renderd (pid=${RENDERD_PID})."
    kill "${RENDERD_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${RENDERD_WRAPPER_PID:-}" ]]; then
    wait "${RENDERD_WRAPPER_PID}" 2>/dev/null || true
  fi
  log "Stopping PostgreSQL cluster ${PG_VERSION}/${PG_CLUSTER}."
  pg_ctlcluster "${PG_VERSION}" "${PG_CLUSTER}" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Waiting for PostgreSQL to accept connections."
ready=false
for _ in $(seq 1 60); do
  if runuser -u postgres -- psql -d "postgres" -Atqc "SELECT 1" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "${ready}" != "true" ]]; then
  log "PostgreSQL did not become ready in time."
  exit 1
fi

ensure_database() {
  local db_name=$1
  local reset=$2

  if [[ "${reset}" == "true" ]]; then
    if runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_database WHERE datname='${db_name}'" | grep -q 1; then
      log "Dropping existing database ${db_name}."
      runuser -u postgres -- dropdb "${db_name}"
    fi
  fi

  if ! runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_database WHERE datname='${db_name}'" | grep -q 1; then
    log "Creating database ${db_name}."
    runuser -u postgres -- createdb -E UTF8 "${db_name}"
  fi

  log "Ensuring PostGIS and hstore extensions exist on ${db_name}."
  runuser -u postgres -- psql -d "${db_name}" -c "CREATE EXTENSION IF NOT EXISTS postgis"
  runuser -u postgres -- psql -d "${db_name}" -c "CREATE EXTENSION IF NOT EXISTS hstore"
}

import_data() {
  local db_name=$1

  local flat_nodes_args=()
  if [[ -n "${FLAT_NODES_PATH}" ]]; then
    mkdir -p "$(dirname "${FLAT_NODES_PATH}")"
    flat_nodes_args=("--flat-nodes" "${FLAT_NODES_PATH}")
  fi

  local extra_args=()
  if [[ -n "${OSM2PGSQL_EXTRA_ARGS}" ]]; then
    # shellcheck disable=SC2206
    extra_args=( ${OSM2PGSQL_EXTRA_ARGS} )
  fi

  log "Importing ${PBF_PATH} into ${db_name} using osm2pgsql."
  runuser -u postgres -- osm2pgsql \
    --create \
    --slim \
    --cache "${OSM2PGSQL_CACHE}" \
    --number-processes "${OSM2PGSQL_NUM_PROCESSES}" \
    --database "${db_name}" \
    --multi-geometry \
    --hstore \
    "${flat_nodes_args[@]}" \
    "${extra_args[@]}" \
    "${PBF_PATH}"
}


refresh_database_statistics() {
  local db_name=$1

  log "Running VACUUM ANALYZE to refresh planner statistics."
  runuser -u postgres -- psql -d "${db_name}" -c "VACUUM ANALYZE"
}


configure_mapnik_paths() {
  PLUGIN_DIR=${MAPNIK_PLUGIN_DIR:-}
  FONT_DIR=${MAPNIK_FONT_DIR:-}

  if command -v mapnik-config >/dev/null 2>&1; then
    if [[ -z "${PLUGIN_DIR}" ]]; then
      PLUGIN_DIR=$(mapnik-config --input-plugins 2>/dev/null || true)
    fi
    if [[ -z "${FONT_DIR}" ]]; then
      FONT_DIR=$(mapnik-config --fonts 2>/dev/null || true)
    fi
  else
    log "mapnik-config not found; attempting to locate Mapnik resources manually."
  fi

  if [[ -z "${PLUGIN_DIR}" ]]; then
    PLUGIN_DIR=$(discover_first_existing_dir \
      "/usr/lib/mapnik/*/input" \
      "/usr/lib/*/mapnik/*/input" \
      "/usr/lib/*/mapnik/input" \
      "/usr/lib/mapnik/input") || true
  fi

  if [[ -z "${FONT_DIR}" ]]; then
    FONT_DIR=$(discover_first_existing_dir \
      "/usr/share/fonts/truetype" \
      "/usr/share/fonts") || true
  fi

  if [[ -z "${PLUGIN_DIR}" ]]; then
    log "Unable to determine Mapnik input plugin directory. Set MAPNIK_PLUGIN_DIR."
    exit 1
  fi

  if [[ -z "${FONT_DIR}" ]]; then
    log "Unable to determine Mapnik font directory. Set MAPNIK_FONT_DIR."
    exit 1
  fi
}

render_tiles() {
  configure_mapnik_paths

  prepare_render_log
  append_render_log "BEGIN render stage min=${MIN_ZOOM} max=${MAX_ZOOM} mode=${RENDER_PROGRESS_MODE} threads=${RENDER_THREADS}"

  log "Generating Mapnik stylesheet at ${MAPNIK_XML}."
  cat >"${MAPNIK_XML}" <<MAPNIK
<Map background-color="#f2efe9" srs="+proj=merc +a=6378137 +b=6378137 +lat_ts=0.0 +lon_0=0.0 +x_0=0.0 +y_0=0 +units=m +nadgrids=@null +wktext +no_defs">
  <Parameters>
    <Parameter name="buffer-size">128</Parameter>
  </Parameters>

  <Style name="water">
    <Rule>
      <PolygonSymbolizer fill="#a0c8f0" />
    </Rule>
  </Style>

  <Style name="parks">
    <Rule>
      <PolygonSymbolizer fill="#bde1a5" />
    </Rule>
  </Style>

  <Style name="roads">
    <Rule>
      <Filter>[highway] = 'motorway'</Filter>
      <LineSymbolizer stroke="#f38f6d" stroke-width="3" stroke-linecap="round" />
    </Rule>
    <Rule>
      <Filter>[highway] = 'primary'</Filter>
      <LineSymbolizer stroke="#f6b26b" stroke-width="2.2" stroke-linecap="round" />
    </Rule>
    <Rule>
      <ElseFilter />
      <LineSymbolizer stroke="#ffffff" stroke-width="1.2" stroke-linecap="round" />
    </Rule>
  </Style>

  <Layer name="water" srs="${LAYER_SRS}">
    <StyleName>water</StyleName>
    <Datasource>
      <Parameter name="type">postgis</Parameter>
      <Parameter name="host">${PGHOST:-/var/run/postgresql}</Parameter>
      <Parameter name="dbname">${POSTGRES_DB}</Parameter>
      <Parameter name="user">postgres</Parameter>
      <Parameter name="geometry_field">way</Parameter>
      <Parameter name="srid">3857</Parameter>
      <Parameter name="table">(SELECT way FROM planet_osm_polygon WHERE "natural" = 'water' OR waterway IN ('river','canal') OR landuse IN ('reservoir','basin')) AS data</Parameter>
    </Datasource>
  </Layer>

  <Layer name="parks" srs="${LAYER_SRS}">
    <StyleName>parks</StyleName>
    <Datasource>
      <Parameter name="type">postgis</Parameter>
      <Parameter name="host">${PGHOST:-/var/run/postgresql}</Parameter>
      <Parameter name="dbname">${POSTGRES_DB}</Parameter>
      <Parameter name="user">postgres</Parameter>
      <Parameter name="geometry_field">way</Parameter>
      <Parameter name="srid">3857</Parameter>
      <Parameter name="table">(SELECT way FROM planet_osm_polygon WHERE leisure = 'park' OR landuse IN ('grass','forest')) AS data</Parameter>
    </Datasource>
  </Layer>

  <Layer name="roads" srs="${LAYER_SRS}">
    <StyleName>roads</StyleName>
    <Datasource>
      <Parameter name="type">postgis</Parameter>
      <Parameter name="host">${PGHOST:-/var/run/postgresql}</Parameter>
      <Parameter name="dbname">${POSTGRES_DB}</Parameter>
      <Parameter name="user">postgres</Parameter>
      <Parameter name="geometry_field">way</Parameter>
      <Parameter name="srid">3857</Parameter>
      <Parameter name="table">(SELECT way, highway FROM planet_osm_line WHERE highway IS NOT NULL) AS data</Parameter>
    </Datasource>
  </Layer>
</Map>
MAPNIK

  log "Writing renderd configuration."
  cat >/etc/renderd.conf <<RENDERD_CONF
[renderd]
num_threads=${RENDER_THREADS}
tile_dir=${RENDER_OUTPUT_ROOT}
stats_file=/var/run/renderd/renderd.stats
socketname=/var/run/renderd/renderd.sock

[mapnik]
plugins_dir=${PLUGIN_DIR}
font_dir=${FONT_DIR}
font_dir_recurse=true

[default]
URI=/tiles/
TILEDIR=${RENDER_OUTPUT_ROOT}
XML=${MAPNIK_XML}
HOST=localhost
TILESIZE=256
MAXZOOM=${MAX_ZOOM}
RENDERD_CONF

  rm -f /var/run/renderd/renderd.sock

  log "Starting renderd as postgres user."
  runuser -u postgres -- renderd -f -c /etc/renderd.conf &
  RENDERD_WRAPPER_PID=$!

  ready=false
  for _ in $(seq 1 30); do
    if [[ -S /var/run/renderd/renderd.sock ]]; then
      ready=true
      break
    fi
    sleep 1
  done
  if [[ "${ready}" != "true" ]]; then
    log "renderd socket was not created."
    exit 1
  fi

  if [[ -z "${RENDERD_PID}" ]]; then
    if pids=$(pgrep -u postgres -f 'renderd -f -c /etc/renderd.conf' 2>/dev/null); then
      RENDERD_PID=$(printf '%s\n' "${pids}" | head -n1)
    fi
  fi
  if [[ -z "${RENDERD_PID}" ]]; then
    RENDERD_PID=${RENDERD_WRAPPER_PID}
  fi

  log "Rendering tiles from zoom ${MIN_ZOOM} to ${MAX_ZOOM} (progress mode: ${RENDER_PROGRESS_MODE})."
  local render_status=0
  case "${RENDER_PROGRESS_MODE}" in
    interval)
      if ! render_tiles_with_interval; then
        render_status=$?
      fi
      ;;
    zoom|*)
      if ! render_tiles_by_zoom; then
        render_status=$?
      fi
      ;;
  esac

  if (( render_status != 0 )); then
    append_render_log "Render stage failed exit=${render_status}"
    log "Tile rendering failed. See ${RENDER_SESSION_LOG} for details."
  else
    append_render_log "Render stage completed successfully"
    log "Tile rendering complete. Output stored in ${RENDER_OUTPUT_ROOT}."
  fi
  if [[ -n "${RENDERD_PID:-}" ]]; then
    log "Stopping renderd (pid=${RENDERD_PID})."
    kill "${RENDERD_PID}" >/dev/null 2>&1 || true
    unset RENDERD_PID
  fi
  if [[ -n "${RENDERD_WRAPPER_PID:-}" ]]; then
    wait "${RENDERD_WRAPPER_PID}" 2>/dev/null || true
    unset RENDERD_WRAPPER_PID
  fi
  if (( render_status != 0 )); then
    return "${render_status}"
  fi
}

render_tiles_with_interval() {
  local progress_interval=${RENDER_PROGRESS_INTERVAL}
  if [[ "${progress_interval}" =~ ^[0-9]+$ ]] && (( progress_interval > 0 )); then
    if ! run_render_list_range "${MIN_ZOOM}" "${MAX_ZOOM}" "interval" "${progress_interval}"; then
      local status=$?
      append_render_log "render_list failed for range ${MIN_ZOOM}-${MAX_ZOOM} exit=${status}"
      log "render_list failed while rendering zoom range ${MIN_ZOOM}-${MAX_ZOOM}. See ${RENDER_SESSION_LOG}."
      return "${status}"
    fi
  else
    log "Progress interval disabled; streaming render_list output without aggregation."
    if ! run_render_list_range "${MIN_ZOOM}" "${MAX_ZOOM}" "plain"; then
      local status=$?
      append_render_log "render_list failed for range ${MIN_ZOOM}-${MAX_ZOOM} exit=${status}"
      log "render_list failed while rendering zoom range ${MIN_ZOOM}-${MAX_ZOOM}. See ${RENDER_SESSION_LOG}."
      return "${status}"
    fi
  fi
  return 0
}

render_tiles_by_zoom() {
  local total_levels=$(( MAX_ZOOM - MIN_ZOOM + 1 ))
  local completed=0
  local zoom

  for (( zoom=MIN_ZOOM; zoom<=MAX_ZOOM; zoom++ )); do
    ((completed++))
    local tiles_estimate=$(( (1 << zoom) * (1 << zoom) ))
    log "Rendering zoom ${zoom} (${completed}/${total_levels}); ~${tiles_estimate} tiles (global)."
    append_render_log "BEGIN zoom ${zoom} (${completed}/${total_levels})"
    if ! run_render_list_range "${zoom}" "${zoom}" "plain"; then
      local status=$?
      append_render_log "FAILED zoom ${zoom} exit=${status}"
      log "render_list failed at zoom ${zoom}; see ${RENDER_SESSION_LOG}."
      return "${status}"
    fi
    append_render_log "COMPLETED zoom ${zoom}"
    log "Completed zoom ${zoom} (${completed}/${total_levels})."
  done

  return 0
}

run_render_list_range() {
  local min_zoom=$1
  local max_zoom=$2
  local mode=${3:-plain}
  local progress_interval=${4:-0}

  local log_path=${RENDER_SESSION_LOG:-}
  local cmd_desc="render_list -z ${min_zoom} -Z ${max_zoom}"
  local cmd=(runuser -u postgres -- render_list -a -f -s /var/run/renderd/renderd.sock -n "${RENDER_THREADS}" -m default -z "${min_zoom}" -Z "${max_zoom}")

  append_render_log "COMMAND ${cmd_desc}"

  local status=0
  if [[ "${mode}" == "interval" ]]; then
    if [[ -n "${log_path}" ]]; then
      "${cmd[@]}" 2> >(tee -a "${log_path}" >&2) | tee -a "${log_path}" | monitor_render_progress "${progress_interval}"
      local -a pipeline_status=( "${PIPESTATUS[@]}" )
      status=${pipeline_status[0]}
      append_render_log "STATUS render_list=${pipeline_status[0]} tee=${pipeline_status[1]:-0} monitor=${pipeline_status[2]:-0}"
    else
      "${cmd[@]}" | monitor_render_progress "${progress_interval}"
      local -a pipeline_status=( "${PIPESTATUS[@]}" )
      status=${pipeline_status[0]}
      append_render_log "STATUS render_list=${pipeline_status[0]} monitor=${pipeline_status[1]:-0}"
    fi
  else
    if [[ -n "${log_path}" ]]; then
      "${cmd[@]}" 2> >(tee -a "${log_path}" >&2) | tee -a "${log_path}"
      local -a pipeline_status=( "${PIPESTATUS[@]}" )
      status=${pipeline_status[0]}
      append_render_log "STATUS render_list=${pipeline_status[0]} tee=${pipeline_status[1]:-0}"
    else
      "${cmd[@]}"
      status=$?
      append_render_log "STATUS render_list=${status}"
    fi
  fi

  append_render_log "END ${cmd_desc} exit=${status}"
  return "${status}"
}

monitor_render_progress() {
  local interval=$1
  local count=0
  local next_log=${interval}

  while IFS= read -r _; do
    (( count++ ))
    if (( count >= next_log )); then
      log "Rendered ${count} tiles so far."
      next_log=$((next_log + interval))
    fi
  done

  if (( count > 0 )) && (( interval > 0 )) && (( count % interval != 0 )); then
    log "Rendered ${count} tiles so far."
  fi
}

run_import_stage() {
  if [[ ! -f "${PBF_PATH}" ]]; then
    log "Missing PBF file at ${PBF_PATH}. Mount the file into the container."
    exit 1
  fi

  log "Running import stage (osm2pgsql + VACUUM)."

  if [[ "${RESET_DATABASE}" == "true" ]]; then
    log "RESET_DATABASE requested; dropping and recreating ${POSTGRES_DB}."
  fi

  ensure_database "${POSTGRES_DB}" "${RESET_DATABASE}"
  import_data "${POSTGRES_DB}"
  refresh_database_statistics "${POSTGRES_DB}"
}

run_render_stage() {
  log "Running render stage (renderd + render_list)."

  ensure_database "${POSTGRES_DB}" "false"
  render_tiles
}

case "${PIPELINE_STAGE}" in
  import)
    run_import_stage
    ;;
  render)
    run_render_stage
    ;;
  all)
    run_import_stage
    run_render_stage
    ;;
  *)
    log "Unknown stage '${PIPELINE_STAGE}'. Expected import, render, or all."
    usage
    exit 1
    ;;
esac
