-- Preserve existing rows: fail with a clear error before adding validated limits.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.task_definitions
        WHERE char_length(name) > 200
           OR char_length(description) > 2000
           OR char_length(numeric_unit) > 32
    ) THEN
        RAISE EXCEPTION
            'Existing task definitions exceed the 200/2000/32 character limits; review those rows before applying this migration'
            USING ERRCODE = '23514';
    END IF;
END;
$$;

-- Count Unicode code points, matching [...value].length in the API validator.
ALTER TABLE public.task_definitions
    ADD CONSTRAINT task_definitions_name_length_check
        CHECK (char_length(name) <= 200),
    ADD CONSTRAINT task_definitions_description_length_check
        CHECK (char_length(description) <= 2000),
    ADD CONSTRAINT task_definitions_numeric_unit_length_check
        CHECK (numeric_unit IS NULL OR char_length(numeric_unit) <= 32);

-- Backend entry points live in public; internal permission helpers stay private.
-- SET SCHEMA preserves the function's ownership and restricted execution grants.
GRANT CREATE ON SCHEMA public TO operations_hub_definition_writer;
GRANT operations_hub_definition_writer TO postgres WITH INHERIT FALSE, SET TRUE;
SET ROLE operations_hub_definition_writer;
ALTER FUNCTION identity_access.create_task_definition(
    uuid, uuid, text, text, text, text, date, date, text, time[], time, text, numeric, numeric
) SET SCHEMA public;
RESET ROLE;
REVOKE operations_hub_definition_writer FROM postgres;
REVOKE CREATE ON SCHEMA public FROM operations_hub_definition_writer;
