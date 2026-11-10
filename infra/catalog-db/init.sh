#!/bin/sh
# Provisions the catalog's own database and role on the shared PostgreSQL server. Idempotent.
#
# The catalog gets a dedicated non-superuser role that owns only its database and cannot connect to
# the backend's (ADR 0011: no personal data reachable from the catalog). pg_trgm and unaccent are
# trusted extensions, so the owner can create them. Statement logging is switched off for the
# catalog database: bound parameters would carry what people searched for.
#
# Environment: POSTGRES_USER, PGPASSWORD (admin), POSTGRES_HOST (default postgres), POSTGRES_DB
# (the backend database), CATALOG_POSTGRES_DB (default pillpal_catalog), CATALOG_DB_USER (default
# catalog), CATALOG_DB_PASSWORD (required). Optional: CATALOG_READER_PASSWORD (and
# CATALOG_READER_USER, default catalog_reader) also creates a read-only role for the public
# service: LOGIN, no inheritance, SELECT only, on the tables the owner creates now and later.
# Without the password no reader is created (local development).
set -eu

: "${POSTGRES_HOST:=postgres}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=pillpal}"
: "${CATALOG_POSTGRES_DB:=pillpal_catalog}"
: "${CATALOG_DB_USER:=catalog}"
: "${CATALOG_DB_PASSWORD:?CATALOG_DB_PASSWORD must be set}"
: "${CATALOG_READER_USER:=catalog_reader}"
export POSTGRES_DB CATALOG_POSTGRES_DB CATALOG_DB_USER CATALOG_DB_PASSWORD CATALOG_READER_USER
# \getenv leaves a psql variable unset only when the environment variable is unset, not when empty.
if [ -n "${CATALOG_READER_PASSWORD:-}" ]; then
    export CATALOG_READER_PASSWORD
else
    unset CATALOG_READER_PASSWORD
fi

# \getenv keeps the password off the command line (visible in the process list).
psql -v ON_ERROR_STOP=1 -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d postgres <<'SQL'
\getenv role CATALOG_DB_USER
\getenv pw CATALOG_DB_PASSWORD
\getenv db CATALOG_POSTGRES_DB
\getenv backend_db POSTGRES_DB
\getenv reader CATALOG_READER_USER
\getenv reader_pw CATALOG_READER_PASSWORD

SELECT format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE', :'role')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'role', :'pw') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SELECT format('ALTER DATABASE %I OWNER TO %I', :'db', :'role') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db') \gexec
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'backend_db')
  WHERE EXISTS (SELECT FROM pg_database WHERE datname = :'backend_db') \gexec
-- The maintenance database is not for application roles.
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
\if :{?reader_pw}
  SELECT format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT', :'reader')
    WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'reader') \gexec
  SELECT format('ALTER ROLE %I PASSWORD %L', :'reader', :'reader_pw') \gexec
  SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db', :'reader') \gexec
\endif
SELECT format('ALTER DATABASE %I SET log_statement = %L', :'db', 'none') \gexec
SELECT format('ALTER DATABASE %I SET log_min_duration_statement = -1', :'db') \gexec
SELECT format('ALTER DATABASE %I SET log_parameter_max_length_on_error = 0', :'db') \gexec
SQL

# Privileges of the reader live inside the catalog database. The schema `catalog` does not exist
# before the first migration, so the rules are default privileges for what the owner creates (all
# schemas of this database) plus a grant on what already exists.
if [ -n "${CATALOG_READER_PASSWORD:-}" ]; then
psql -v ON_ERROR_STOP=1 -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$CATALOG_POSTGRES_DB" <<'SQL'
\getenv role CATALOG_DB_USER
\getenv reader CATALOG_READER_USER

ALTER DEFAULT PRIVILEGES FOR ROLE :"role" GRANT SELECT ON TABLES TO :"reader";
ALTER DEFAULT PRIVILEGES FOR ROLE :"role" GRANT USAGE ON SCHEMAS TO :"reader";
SELECT format('GRANT USAGE ON SCHEMA %I TO %I', nspname, :'reader')
  FROM pg_namespace WHERE nspname IN ('public', 'catalog') \gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', nspname, :'reader')
  FROM pg_namespace WHERE nspname IN ('public', 'catalog') \gexec
SQL
fi
