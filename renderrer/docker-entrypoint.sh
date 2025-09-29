#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"
}

PBF_PATH=${PBF_PATH:-/data/map.osm.pbf}
RENDER_OUTPUT_ROOT=${RENDER_OUTPUT_ROOT:-/data/rendered}
POSTGRES_DB=${POSTGRES_DB:-gis}
MIN_ZOOM=${MIN_ZOOM:-0}
MAX_ZOOM=${MAX_ZOOM:-5}
OSM2PGSQL_CACHE=${OSM2PGSQL_CACHE:-1024}
OSM2PGSQL_NUM_PROCESSES=${OSM2PGSQL_NUM_PROCESSES:-2}
RENDER_THREADS=${RENDER_THREADS:-2}
MAPNIK_XML=${MAPNIK_XML:-/tmp/basic-style.xml}
RESET_DATABASE=${RESET_DATABASE:-true}
FLAT_NODES_PATH=${FLAT_NODES_PATH:-}
OSM2PGSQL_EXTRA_ARGS=${OSM2PGSQL_EXTRA_ARGS:-}
PGDATA_ROOT=${PGDATA_ROOT:-/data/db}
STATE_DIR=${STEP_STATE_DIR:-${PGDATA_ROOT}/state}
STYLE_VERSION=2
LAYER_SRS=${MAPNIK_LAYER_SRS:-EPSG:3857}

RENDERD_PID=""
RENDERD_WRAPPER_PID=""

if command -v readlink >/dev/null 2>&1; then
  STATE_DIR=$(readlink -f "${STATE_DIR}" 2>/dev/null || printf '%s' "${STATE_DIR}")
fi

mkdir -p "${STATE_DIR}"
chown -R postgres:postgres "${STATE_DIR}"

state_file() {
  printf '%s/%s.state' "${STATE_DIR}" "$1"
}

state_mark() {
  local step=$1 token=$2
  printf '%s\n' "${token}" >"$(state_file "${step}")"
}

state_clear() {
  rm -f "$(state_file "$1")"
}

state_matches() {
  local step=$1 token=$2 file
  file=$(state_file "${step}")
  [[ -f "${file}" ]] && [[ "$(<"${file}")" == "${token}" ]]
}

hash_payload() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

clear_processing_state() {
  local step
  for step in osm-import vacuum render-tiles; do
    state_clear "${step}"
  done
}

clear_downstream_steps() {
  state_clear "vacuum"
  state_clear "render-tiles"
}

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

if [[ ! -f "${PBF_PATH}" ]]; then
  log "Missing PBF file at ${PBF_PATH}. Mount the file into the container."
  exit 1
fi

PBF_FINGERPRINT=$(stat -c '%s:%Y:%n' "${PBF_PATH}")
IMPORT_TOKEN=$(hash_payload "import-v1|${PBF_FINGERPRINT}|cache=${OSM2PGSQL_CACHE}|procs=${OSM2PGSQL_NUM_PROCESSES}|flat=${FLAT_NODES_PATH}|extra=${OSM2PGSQL_EXTRA_ARGS}")
RENDER_TOKEN=$(hash_payload "render-v${STYLE_VERSION}|${IMPORT_TOKEN}|min=${MIN_ZOOM}|max=${MAX_ZOOM}|threads=${RENDER_THREADS}|xml=${MAPNIK_XML}")

mkdir -p "${RENDER_OUTPUT_ROOT}" /var/run/renderd "${PGDATA_ROOT}"
chown -R postgres:postgres /var/run/renderd
chmod 775 /var/run/renderd 2>/dev/null || true

if [[ "${RESET_DATABASE}" == "true" ]]; then
  log "RESET_DATABASE requested; clearing cached step markers."
  clear_processing_state
  rm -f "${RENDER_OUTPUT_ROOT}/planet-import-complete"
fi

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

ensure_database "${POSTGRES_DB}" "${RESET_DATABASE}"

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

  touch "${RENDER_OUTPUT_ROOT}/planet-import-complete"

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

  log "Rendering tiles from zoom ${MIN_ZOOM} to ${MAX_ZOOM}."
  runuser -u postgres -- render_list -a -f -s /var/run/renderd/renderd.sock -n "${RENDER_THREADS}" -m default -z "${MIN_ZOOM}" -Z "${MAX_ZOOM}"

  log "Tile rendering complete. Output stored in ${RENDER_OUTPUT_ROOT}."
  if [[ -n "${RENDERD_PID:-}" ]]; then
    log "Stopping renderd (pid=${RENDERD_PID})."
    kill "${RENDERD_PID}" >/dev/null 2>&1 || true
    unset RENDERD_PID
  fi
  if [[ -n "${RENDERD_WRAPPER_PID:-}" ]]; then
    wait "${RENDERD_WRAPPER_PID}" 2>/dev/null || true
    unset RENDERD_WRAPPER_PID
  fi
}

if state_matches "osm-import" "${IMPORT_TOKEN}"; then
  log "Skipping osm2pgsql import; checkpoint detected."
else
  state_clear "osm-import"
  clear_downstream_steps
  import_data "${POSTGRES_DB}"
  state_mark "osm-import" "${IMPORT_TOKEN}"
fi

touch "${RENDER_OUTPUT_ROOT}/planet-import-complete"

if state_matches "vacuum" "${IMPORT_TOKEN}"; then
  log "Skipping VACUUM ANALYZE; checkpoint detected."
else
  log "Running VACUUM ANALYZE to refresh planner statistics."
  runuser -u postgres -- psql -d "${POSTGRES_DB}" -c "VACUUM ANALYZE"
  state_mark "vacuum" "${IMPORT_TOKEN}"
fi

render_required=1
if state_matches "render-tiles" "${RENDER_TOKEN}"; then
  if [[ -d "${RENDER_OUTPUT_ROOT}" ]]; then
    log "Skipping tile rendering; checkpoint detected."
    render_required=0
  else
    log "Render checkpoint present but ${RENDER_OUTPUT_ROOT} missing; rerunning pipeline."
  fi
fi

if (( render_required )); then
  state_clear "render-tiles"
  render_tiles
  state_mark "render-tiles" "${RENDER_TOKEN}"
else
  log "Tile rendering already up to date; skipping render step."
fi
