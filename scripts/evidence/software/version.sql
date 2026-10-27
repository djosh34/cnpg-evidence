-- server_version can carry the packager after a space: "17.1 (Debian ...)".
BEGIN READ ONLY;

SELECT json_build_object('postgresql', split_part(current_setting('server_version'), ' ', 1));

ROLLBACK;
