# DB schema sketch

Tables and properties only. Money and price are `bigint` fixed-point ticks (same as the engine).
Enum-like columns are `smallint` with a CHECK.

## Seeded once (seed.sql)

### uma

| Column | Type | Note |
|---|---|---|
| id | smallint PK | 1..=173, site order |
| slug | text UNIQUE | file name of the image |
| name_en | text | |
| name_jp | text | |
| category | text | CHECK in (uma, staff) |
| color | text | |
| image | bytea | PNG bytes |
| image_mime | text | image/png |

### app_user

| Column | Type | Note |
|---|---|---|
| id | integer PK | 1..=1_000_000 |
| name | text | generated |
| bot_type | smallint | 0 maker, 1 taker, 2 contrarian, 3 noise |
| created_at | timestamptz | default now() |

## Account state (session + persister write)

### account

| Column | Type | Note |
|---|---|---|
| user_id | integer PK | FK app_user.id |
| cash | bigint | ticks, settled only (reserves reset on restart) |
| updated_at | timestamptz | last checkpoint or logout |

### position

| Column | Type | Note |
|---|---|---|
| user_id | integer | FK app_user.id |
| uma_id | smallint | FK uma.id |
| qty | bigint | settled only |
| | | PK (user_id, uma_id) |

### user_session

| Column | Type | Note |
|---|---|---|
| id | bigint PK | identity |
| user_id | integer | FK app_user.id, indexed |
| login_at | timestamptz | |
| logout_at | timestamptz | NULL while trading |

## Aggregates (persister writes)

### candle

| Column | Type | Note |
|---|---|---|
| uma_id | smallint | FK uma.id |
| ts | timestamptz | 1 s bucket |
| open, high, low, close | bigint | ticks |
| volume | bigint | qty |
| trades | integer | count |
| | | PK (uma_id, ts), partitioned by day on ts |

### trade

| Column | Type | Note |
|---|---|---|
| id | bigint PK | identity |
| ts | timestamptz | |
| uma_id | smallint | FK uma.id |
| price | bigint | ticks |
| qty | bigint | |
| buyer_id | integer | FK app_user.id |
| seller_id | integer | FK app_user.id |

### book_snapshot

| Column | Type | Note |
|---|---|---|
| ts | timestamptz | |
| uma_id | smallint | FK uma.id |
| side | smallint | 0 bid, 1 ask |
| level | smallint | 0 = best |
| price | bigint | ticks |
| qty | bigint | |
| | | PK (ts, uma_id, side, level) |

### leaderboard

| Column | Type | Note |
|---|---|---|
| ts | timestamptz | snapshot time |
| rank | integer | 1 = top |
| user_id | integer | FK app_user.id |
| equity | bigint | cash + holdings at last prices |
| | | PK (ts, rank) |

## Gateway writes

### api_order

| Column | Type | Note |
|---|---|---|
| id | bigint PK | identity |
| user_id | integer | FK app_user.id |
| uma_id | smallint | FK uma.id |
| side | smallint | 0 buy, 1 sell |
| kind | smallint | 0 limit, 1 market |
| price | bigint | NULL for market |
| qty | bigint | |
| status | smallint | 0 sent, 1 filled, 2 cancelled, 3 rejected |
| created_at | timestamptz | |
