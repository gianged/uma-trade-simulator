-- apply after db.sql; idempotent

INSERT INTO market.umas (id, slug, name_en, name_jp, category, color, image, image_mime)
SELECT u.id, u.slug, u.name_en, u.name_jp, u.category, u.color,
       pg_read_binary_file('/data/umas/' || u.image), 'image/png'
FROM jsonb_to_recordset(pg_read_file('/data/umas/umas.json')::jsonb)
    AS u(id smallint, slug text, name_en text, name_jp text, category text, color text, image text)
ON CONFLICT (id) DO NOTHING;

INSERT INTO trading.users (id, name, bot_type)
SELECT g, 'user_' || g, (g % 4)::smallint
FROM generate_series(1, 1000000) AS g
ON CONFLICT (id) DO NOTHING;

INSERT INTO trading.accounts (user_id, cash)
SELECT id, 10000000 FROM trading.users
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO trading.positions (user_id, uma_id, qty)
SELECT u.id, (1 + (u.id * 7 + k * 31) % 173)::smallint, 1 + (u.id + k) % 100
FROM trading.users AS u CROSS JOIN generate_series(1, 5) AS k
ON CONFLICT (user_id, uma_id) DO NOTHING;

