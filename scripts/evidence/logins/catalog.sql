-- The roles that can log in, with every role they are a member of (for
-- +role and samerole in pg_hba), and every database with the grantees of its
-- CONNECT privilege. PUBLIC holds CONNECT on a new database by default.
BEGIN READ ONLY;

-- Membership as pg_hba sees it: granted, directly or through other roles.
-- pg_has_role would also count a superuser as a member of every role.
WITH RECURSIVE membership(member, role) AS (
  SELECT oid, oid FROM pg_roles
  UNION
  SELECT membership.member, pg_auth_members.roleid
  FROM membership
  JOIN pg_auth_members ON pg_auth_members.member = membership.role
)

SELECT json_build_object(
  'roles', (
    SELECT coalesce(json_agg(json_build_object(
        'name', member.rolname,
        'member_of', (
          SELECT json_agg(target.rolname ORDER BY target.rolname)
          FROM membership
          JOIN pg_roles target ON target.oid = membership.role
          WHERE membership.member = member.oid
        )
      ) ORDER BY member.rolname), '[]')
    FROM pg_roles member
    WHERE member.rolcanlogin
  ),
  'databases', (
    SELECT coalesce(json_agg(json_build_object(
        'name', datname,
        'owner', pg_get_userbyid(datdba),
        'allows_connections', datallowconn,
        'connect', (
          SELECT coalesce(json_agg(DISTINCT CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(acl.grantee) END), '[]')
          FROM aclexplode(coalesce(datacl, acldefault('d', datdba))) acl
          WHERE acl.privilege_type = 'CONNECT'
        )
      ) ORDER BY datname), '[]')
    FROM pg_database
  )
);

ROLLBACK;
