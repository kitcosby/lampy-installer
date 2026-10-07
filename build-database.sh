#!/bin/bash
# build-database.sh — Client-side from-source database build for Lampy.
#
# This script compiles and installs the full database stack from the
# sources staged in /opt/stage/, with NO network access, NO apt, and
# NO Docker required on the client machine.
#
# Sources (in the image):
#   /opt/stage/postgresql-16.10/  — PostgreSQL 16.10 source
#   /opt/stage/timescaledb-2.17.2/ — TimescaleDB source
#   /opt/extensions/pgvectorscale/ — pgvectorscale source
#   /opt/stage/pgai/              — pgai 0.12.1 source
#
# Installs to:
#   /usr/local/pgsql/             — PostgreSQL binaries
#   /var/lib/postgresql/data/     — PGDATA (initialized by this script)
#
# Usage: sudo ./build-database.sh
# Must run as root (needs to create postgres user, write to /usr/local).

set -euo pipefail

PG_VERSION="16.10"
TSDB_VERSION="2.17.2"
PG_PREFIX="/usr/local/pgsql"
PGDATA="/var/lib/postgresql/data"
STAGE="/opt/stage"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { log "FATAL: $*"; exit 1; }

# Must run as root
[ "$(id -u)" -eq 0 ] || fail "Must run as root (sudo)."

log "=== Lampy database from-source build starting ==="

# 1. Verify sources are present
for src in "postgresql-${PG_VERSION}" "timescaledb-${TSDB_VERSION}"; do
    [ -d "${STAGE}/${src}" ] || fail "Source not found: ${STAGE}/${src}"
    log "Source verified: ${STAGE}/${src}"
done
[ -d "/opt/extensions/pgvectorscale" ] || fail "pgvectorscale source not found"
[ -d "${STAGE}/pgai" ] || fail "pgai source not found"

# 2. Create postgres user if it doesn't exist
if ! id postgres &>/dev/null; then
    log "Creating postgres user..."
    useradd -r -m -s /bin/bash postgres
fi

# 3. Build and install PostgreSQL
log "=== Building PostgreSQL ${PG_VERSION} ==="
cd "${STAGE}/postgresql-${PG_VERSION}"
# Clean any previous build artifacts (ignore failure on fresh tree)
make distclean >/dev/null 2>&1 || true
# --without-icu: ICU dev libraries are not in the offline image; the
# client has no apt/network to fetch them. ICU provides localized
# collation; without it PostgreSQL uses the C library collation.
./configure --prefix="${PG_PREFIX}" --with-openssl --without-icu > /tmp/pg-configure.log 2>&1 \
    || fail "PostgreSQL configure failed (see /tmp/pg-configure.log)"
log "PostgreSQL configured. Building (this takes several minutes)..."
make -j"$(nproc)" > /tmp/pg-build.log 2>&1 \
    || fail "PostgreSQL build failed (see /tmp/pg-build.log)"
log "PostgreSQL built. Installing to ${PG_PREFIX}..."
make install > /tmp/pg-install.log 2>&1 \
    || fail "PostgreSQL install failed (see /tmp/pg-install.log)"

export PATH="${PG_PREFIX}/bin:${PATH}"
pg_config --version || fail "pg_config not working after install"

# 4. Build and install TimescaleDB
log "=== Building TimescaleDB ${TSDB_VERSION} ==="
cd "${STAGE}/timescaledb-${TSDB_VERSION}"
rm -rf build && mkdir -p build && cd build
cmake -DREGRESS_CHECKS=OFF \
      -DPG_CONFIG="${PG_PREFIX}/bin/pg_config" \
      .. > /tmp/tsdb-cmake.log 2>&1 \
    || fail "TimescaleDB cmake failed (see /tmp/tsdb-cmake.log)"
log "TimescaleDB configured. Building..."
make -j"$(nproc)" > /tmp/tsdb-build.log 2>&1 \
    || fail "TimescaleDB build failed (see /tmp/tsdb-build.log)"
log "TimescaleDB built. Installing..."
make install > /tmp/tsdb-install.log 2>&1 \
    || fail "TimescaleDB install failed (see /tmp/tsdb-install.log)"

# 5. Build and install pgvector (required by pgvectorscale)
log "=== Building pgvector ==="
cd "${STAGE}/pgvector-0.8.0"
make PG_CONFIG="${PG_PREFIX}/bin/pg_config" -j"$(nproc)" > /tmp/pgvector-build.log 2>&1 \
    || fail "pgvector build failed (see /tmp/pgvector-build.log)"
make PG_CONFIG="${PG_PREFIX}/bin/pg_config" install > /tmp/pgvector-install.log 2>&1 \
    || fail "pgvector install failed (see /tmp/pgvector-install.log)"

# 6. Build and install pgvectorscale via cargo-pgrx
log "=== Building pgvectorscale ==="
export PATH="$HOME/.cargo/bin:${PATH}"
command -v cargo-pgrx >/dev/null || fail "cargo-pgrx not found in PATH"
# Initialize pgrx for our compiled postgres
cargo pgrx init --pg16="${PG_PREFIX}/bin/pg_config" > /tmp/pgrx-init.log 2>&1 \
    || fail "cargo pgrx init failed (see /tmp/pgrx-init.log)"
# The Cargo.toml is in the pgvectorscale/ subdirectory
cd /opt/extensions/pgvectorscale/pgvectorscale
cargo pgrx install --release --pg-config="${PG_PREFIX}/bin/pg_config" \
    > /tmp/pgvectorscale-build.log 2>&1 \
    || fail "pgvectorscale build failed (see /tmp/pgvectorscale-build.log)"

# 6. Install pgai (PostgreSQL extension part)
log "=== Installing pgai ==="
cd "${STAGE}/pgai"
# pgai has both a Python package and a PostgreSQL extension
# Install the PostgreSQL extension
if [ -f "Makefile" ]; then
    make PG_CONFIG="${PG_PREFIX}/bin/pg_config" install \
        > /tmp/pgai-build.log 2>&1 \
        || log "WARNING: pgai make install had issues (see /tmp/pgai-build.log)"
fi
# Install the Python package (for the workers)
pip3 install --no-index --find-links=/opt/wheelhouse . \
    > /tmp/pgai-pip.log 2>&1 \
    || log "WARNING: pgai pip install had issues (see /tmp/pgai-pip.log)"

# 7. Initialize the database cluster
log "=== Initializing PostgreSQL data directory ==="
mkdir -p "${PGDATA}"
chown postgres:postgres "${PGDATA}"
chmod 700 "${PGDATA}"
# initdb must run as postgres user, not root, with C locale
# (initdb fails on invalid locale settings without this)
su postgres -c "LANG=C LC_ALL=C ${PG_PREFIX}/bin/initdb -D ${PGDATA} -E UTF8" \
    > /tmp/pg-initdb.log 2>&1 \
    || fail "initdb failed (see /tmp/pg-initdb.log)"

# 8. Configure postgresql.conf for TimescaleDB
log "Configuring postgresql.conf..."
echo "shared_preload_libraries = 'timescaledb'" >> "${PGDATA}/postgresql.conf"
echo "timescaledb.telemetry_level = off" >> "${PGDATA}/postgresql.conf"

# 9. Start PostgreSQL and create extensions
log "Starting PostgreSQL..."
su postgres -c "${PG_PREFIX}/bin/pg_ctl -D ${PGDATA} -l /tmp/pg-server.log start" \
    || fail "Failed to start PostgreSQL"
# Wait for it to be ready
for i in $(seq 1 30); do
    su postgres -c "${PG_PREFIX}/bin/pg_isready" 2>/dev/null && break
    sleep 1
    [ "$i" -eq 30 ] && fail "PostgreSQL did not become ready in 30s"
done

log "Creating forum database and extensions..."
su postgres -c "${PG_PREFIX}/bin/createdb forum" \
    || fail "Failed to create forum database"
su postgres -c "${PG_PREFIX}/bin/psql -d forum -c \"CREATE EXTENSION IF NOT EXISTS timescaledb;\"" \
    || fail "Failed to create timescaledb extension"
su postgres -c "${PG_PREFIX}/bin/psql -d forum -c \"CREATE EXTENSION IF NOT EXISTS vector;\"" \
    || fail "Failed to create vector extension"
su postgres -c "${PG_PREFIX}/bin/psql -d forum -c \"CREATE EXTENSION IF NOT EXISTS vectorscale;\"" \
    || log "WARNING: vectorscale extension creation had issues"
su postgres -c "${PG_PREFIX}/bin/psql -d forum -c \"CREATE EXTENSION IF NOT EXISTS ai;\"" \
    || log "WARNING: ai extension creation had issues"

# Verify extensions
log "Verifying installed extensions..."
su postgres -c "${PG_PREFIX}/bin/psql -d forum -c '\dx'" | tee /tmp/pg-extensions.log

log "=== Database build complete ==="
log "PostgreSQL ${PG_VERSION} installed at ${PG_PREFIX}"
log "Data directory: ${PGDATA}"
log "Extensions verified. See /tmp/pg-extensions.log for details."
log "DATABASE BUILD COMPLETE"
