--------------------------------------------------------------------------------
-- 00_types.sql
--
-- Schema-level composite type used by pkg_data_quality's SETOF-returning
-- functions. This is PostgreSQL's equivalent of the Oracle SQL object type
-- (DQ_FINDING_OBJ) the original Oracle version of this project used for its
-- PIPELINED table functions: a named row shape that both PL/pgSQL and plain
-- SQL (`SELECT * FROM pkg_data_quality.run_all_checks()`) can consume
-- directly, with no OUT parameters or cursor loops required for the
-- common case.
--------------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS pkg_data_quality;

CREATE TYPE pkg_data_quality.dq_finding AS (
    rule_name           VARCHAR(60),   -- e.g. 'DUPLICATE_DIAGNOSIS'
    severity            VARCHAR(10),   -- 'ERROR' (blocks downstream use) or 'WARNING' (needs review)
    entity_type         VARCHAR(30),   -- e.g. 'APPOINTMENT', 'LAB_RESULT', 'STAGING_ROW'
    entity_id           VARCHAR(30),   -- the relevant record identifier, as text
    finding_description VARCHAR(300),
    recommended_action  VARCHAR(300)
);
