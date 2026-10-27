-- The TLS settings PostgreSQL runs with on one instance.
BEGIN READ ONLY;

SELECT json_build_object(
  'ssl', current_setting('ssl'),
  'min_protocol_version', current_setting('ssl_min_protocol_version')
);

ROLLBACK;
