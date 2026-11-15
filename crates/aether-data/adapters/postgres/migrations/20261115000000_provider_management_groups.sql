-- Display-only directory organization, kept outside provider/routing records.
-- A string document allows atomic compare-and-set saves by multiple administrators.
INSERT INTO system_configs (id, key, value, description, created_at, updated_at)
VALUES (
    '16aaf674-408c-43d0-93d1-316bb9a3c168',
    'provider_management_groups',
    to_json('{"version":0,"groups":[]}'::text),
    'Display-only provider management groups; does not affect scheduling',
    NOW(), NOW()
)
ON CONFLICT (key) DO NOTHING;
