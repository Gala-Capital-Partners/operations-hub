-- Provision the backend's PostgreSQL login.
-- Run as an authorized database administrator after the migrations.
-- Set the password separately; never commit actual credentials.

BEGIN;

CREATE ROLE operations_hub_api
    LOGIN
    NOINHERIT
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION
    NOBYPASSRLS;

GRANT CONNECT ON DATABASE postgres
    TO operations_hub_api;

GRANT operations_hub_runtime
    TO operations_hub_api
    WITH INHERIT FALSE, SET TRUE, ADMIN FALSE;

COMMIT;