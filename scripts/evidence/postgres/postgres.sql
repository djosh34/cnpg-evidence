-- Who can do what, as lists of role names, and every role. The built-in pg_*
-- roles cannot log in, so only the roles that reach them count.
--
-- A role attribute such as SUPERUSER is never inherited: a role has it only
-- after SET ROLE to a role that holds it. A privilege, including those of the
-- built-in pg_* roles and EXECUTE on a function, also comes by inheritance
-- from a role granted WITH INHERIT, without any SET ROLE.
BEGIN READ ONLY;

WITH by_set AS (
  SELECT member.rolname AS name, target.*
  FROM pg_roles member
  JOIN pg_roles target ON pg_has_role(member.oid, target.oid, 'SET')
  WHERE member.rolname !~ '^pg_'
),

by_set_or_inheritance AS (
  SELECT member.rolname AS name, target.*
  FROM pg_roles member
  JOIN pg_roles target ON pg_has_role(member.oid, target.oid, 'SET') OR pg_has_role(member.oid, target.oid, 'USAGE')
  WHERE member.rolname !~ '^pg_'
),

-- The roles that can run one of these functions.
runs AS (
  SELECT DISTINCT by_set_or_inheritance.name, pg_proc.proname
  FROM by_set_or_inheritance
  JOIN pg_proc ON has_function_privilege(by_set_or_inheritance.oid, pg_proc.oid, 'EXECUTE')
  WHERE pg_proc.proname IN ('pg_read_file', 'pg_read_binary_file', 'lo_import', 'lo_export')
),

-- pg_rewind reads files through pg_read_binary_file, without pg_read_server_files.
-- The server-side lo_import and lo_export read and write any file as the server.
file_readers AS (
  SELECT name FROM by_set_or_inheritance WHERE rolname = 'pg_read_server_files'
  UNION
  SELECT name FROM runs WHERE proname IN ('pg_read_file', 'pg_read_binary_file', 'lo_import')
),

file_writers AS (
  SELECT name FROM by_set_or_inheritance WHERE rolname = 'pg_write_server_files'
  UNION
  SELECT name FROM runs WHERE proname = 'lo_export'
),

own_roles AS (
  SELECT * FROM pg_authid WHERE rolname !~ '^pg_'
)

SELECT json_build_object(
  'superusers',
    (SELECT coalesce(json_agg(DISTINCT name ORDER BY name), '[]') FROM by_set WHERE rolsuper),
  'can_create_roles',
    (SELECT coalesce(json_agg(DISTINCT name ORDER BY name), '[]') FROM by_set WHERE rolcreaterole),
  'can_create_databases',
    (SELECT coalesce(json_agg(DISTINCT name ORDER BY name), '[]') FROM by_set WHERE rolcreatedb),
  'can_replicate',
    (SELECT coalesce(json_agg(DISTINCT name ORDER BY name), '[]') FROM by_set WHERE rolreplication),
  'can_bypass_row_security',
    (SELECT coalesce(json_agg(DISTINCT name ORDER BY name), '[]') FROM by_set WHERE rolbypassrls),
  'can_run_server_programs',
    (SELECT coalesce(json_agg(DISTINCT name ORDER BY name), '[]') FROM by_set_or_inheritance WHERE rolname = 'pg_execute_server_program'),
  'can_read_server_files',
    (SELECT coalesce(json_agg(DISTINCT name ORDER BY name), '[]') FROM file_readers),
  'can_write_server_files',
    (SELECT coalesce(json_agg(DISTINCT name ORDER BY name), '[]') FROM file_writers),
  'can_read_all_data',
    (SELECT coalesce(json_agg(DISTINCT name ORDER BY name), '[]') FROM by_set_or_inheritance WHERE rolname = 'pg_read_all_data'),
  'can_write_all_data',
    (SELECT coalesce(json_agg(DISTINCT name ORDER BY name), '[]') FROM by_set_or_inheritance WHERE rolname = 'pg_write_all_data'),
  'have_password',
    (SELECT coalesce(json_agg(rolname ORDER BY rolname), '[]') FROM own_roles WHERE rolpassword IS NOT NULL),
  'can_log_in',
    (SELECT coalesce(json_agg(rolname ORDER BY rolname), '[]') FROM own_roles WHERE rolcanlogin),
  'roles',
    (SELECT coalesce(json_agg(rolname ORDER BY rolname), '[]') FROM own_roles),
  'databases',
    (SELECT coalesce(json_agg(datname ORDER BY datname), '[]') FROM pg_database)
);

ROLLBACK;
