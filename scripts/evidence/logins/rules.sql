-- The pg_hba and pg_ident rows of one instance, in the order PostgreSQL
-- matches them. Rows with an error have no rule number and come first.
BEGIN READ ONLY;

SELECT json_build_object(
  'pg_hba', (
    SELECT coalesce(json_agg(json_build_object(
        'line', concat_ws(' ', type, array_to_string(database, ','), array_to_string(user_name, ','),
                          address, netmask, auth_method, array_to_string(options, ' '), 'error: ' || error),
        'type', type,
        'databases', coalesce(database, '{}'),
        'users', coalesce(user_name, '{}'),
        'address', address,
        'method', auth_method,
        'options', coalesce(options, '{}'),
        'error', error
      ) ORDER BY rule_number NULLS FIRST, file_name, line_number), '[]')
    FROM pg_hba_file_rules
  ),
  'pg_ident', (
    SELECT coalesce(json_agg(json_build_object(
        'line', concat_ws(' ', map_name, sys_name, pg_username, 'error: ' || error),
        'map', map_name,
        'system_user', sys_name,
        'role', pg_username,
        'error', error
      ) ORDER BY map_number NULLS FIRST, file_name, line_number), '[]')
    FROM pg_ident_file_mappings
  )
);

ROLLBACK;
