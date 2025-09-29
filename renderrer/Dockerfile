FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    fonts-dejavu-core \
    gdal-bin \
    mapnik-utils \
    osm2pgsql \
    postgis \
    postgresql \
    postgresql-contrib \
    postgresql-15-postgis-3 \
    postgresql-15-postgis-3-scripts \
    renderd \
 && rm -rf /var/lib/apt/lists/*

ENV PBF_PATH=/data/map.osm.pbf \
    RENDER_OUTPUT_ROOT=/data/rendered \
    POSTGRES_DB=gis \
    MIN_ZOOM=0 \
    MAX_ZOOM=5 \
    OSM2PGSQL_CACHE=1024 \
    OSM2PGSQL_NUM_PROCESSES=2 \
    FLAT_NODES_PATH= \
    MAPNIK_XML=/tmp/basic-style.xml \
    RENDER_THREADS=2 \
    PGDATA_ROOT=/data/db

VOLUME ["/data"]

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
