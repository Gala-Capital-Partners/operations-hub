-- Provision the nightly task-generation job's PostgreSQL login.
-- Run once as an authorized database administrator, after the migration
-- 20261118000000_create_task_instance_generator.sql has been applied.
-- Set the password separately; never commit actual credentials.
--
-- The login has no privileges of its own. The job must run
-- `SET LOCAL ROLE operations_hub_scheduler` inside each transaction, which
-- allows only:
--   public.scheduler_active_task_definitions()
--   public.scheduler_generate_task_instances(uuid, date[], text, text)

BEGIN;

CREATE ROLE operations_hub_scheduler_login
    LOGIN
    NOINHERIT
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION
    NOBYPASSRLS;

GRANT CONNECT ON DATABASE postgres
    TO operations_hub_scheduler_login;

GRANT operations_hub_scheduler
    TO operations_hub_scheduler_login
    WITH INHERIT FALSE, SET TRUE, ADMIN FALSE;

COMMIT;

-- Then, in a separate session (the password is not stored in this file):
--   \password operations_hub_scheduler_login
-- and save the Session pooler connection URL for this login as the
-- TASK_SCHEDULER_DATABASE_URL secret in the GitHub `supabase-shared` environment.
