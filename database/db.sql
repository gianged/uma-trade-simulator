CREATE SCHEMA IF NOT EXISTS market;
CREATE SCHEMA IF NOT EXISTS trading;

-- shared updated_at trigger fn
CREATE OR REPLACE FUNCTION public.fn_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- market.umas
CREATE TABLE market.umas (
    id          SMALLINT NOT NULL,
    slug        TEXT NOT NULL,
    name_en     TEXT NOT NULL,
    name_jp     TEXT NOT NULL,
    category    TEXT NOT NULL,
    color       TEXT NOT NULL,
    image       BYTEA NOT NULL,
    image_mime  TEXT NOT NULL DEFAULT 'image/png',

    CONSTRAINT pk_umas PRIMARY KEY (id),
    CONSTRAINT uq_umas_slug UNIQUE (slug),
    CONSTRAINT chk_umas_category CHECK (category IN ('uma', 'staff'))
);

-- trading.users
CREATE TABLE trading.users (
    id          INTEGER NOT NULL,
    name        TEXT NOT NULL,
    bot_type    SMALLINT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_users PRIMARY KEY (id),
    CONSTRAINT chk_users_bot_type CHECK (bot_type BETWEEN 0 AND 3)
);

-- trading.accounts
CREATE TABLE trading.accounts (
    user_id     INTEGER NOT NULL,
    cash        BIGINT NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_accounts PRIMARY KEY (user_id),
    CONSTRAINT chk_accounts_cash_nonneg CHECK (cash >= 0)
);

-- trading.positions
CREATE TABLE trading.positions (
    user_id  INTEGER NOT NULL,
    uma_id   SMALLINT NOT NULL,
    qty      BIGINT NOT NULL,

    CONSTRAINT pk_positions PRIMARY KEY (user_id, uma_id),
    CONSTRAINT chk_positions_qty_nonneg CHECK (qty >= 0)
);

-- trading.user_sessions
CREATE TABLE trading.user_sessions (
    id         BIGINT GENERATED ALWAYS AS IDENTITY,
    user_id    INTEGER NOT NULL,
    login_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    logout_at  TIMESTAMPTZ,

    CONSTRAINT pk_user_sessions PRIMARY KEY (id)
);

-- market.candles
CREATE TABLE market.candles (
    uma_id  SMALLINT NOT NULL,
    ts      TIMESTAMPTZ NOT NULL,
    open    BIGINT NOT NULL,
    high    BIGINT NOT NULL,
    low     BIGINT NOT NULL,
    close   BIGINT NOT NULL,
    volume  BIGINT NOT NULL,
    trades  INTEGER NOT NULL,

    CONSTRAINT pk_candles PRIMARY KEY (uma_id, ts)
) PARTITION BY RANGE (ts);

CREATE TABLE market.candles_default PARTITION OF market.candles DEFAULT;

-- market.trades
CREATE TABLE market.trades (
    id         BIGINT GENERATED ALWAYS AS IDENTITY,
    buyer_id   INTEGER NOT NULL,
    seller_id  INTEGER NOT NULL,
    uma_id     SMALLINT NOT NULL,
    ts         TIMESTAMPTZ NOT NULL,
    price      BIGINT NOT NULL,
    qty        BIGINT NOT NULL,

    CONSTRAINT pk_trades PRIMARY KEY (id)
);

-- market.book_snapshots
CREATE TABLE market.book_snapshots (
    ts      TIMESTAMPTZ NOT NULL,
    uma_id  SMALLINT NOT NULL,
    side    SMALLINT NOT NULL,
    level   SMALLINT NOT NULL,
    price   BIGINT NOT NULL,
    qty     BIGINT NOT NULL,

    CONSTRAINT pk_book_snapshots PRIMARY KEY (ts, uma_id, side, level),
    CONSTRAINT chk_book_snapshots_side CHECK (side IN (0, 1))
);

-- trading.leaderboard_entries
CREATE TABLE trading.leaderboard_entries (
    ts       TIMESTAMPTZ NOT NULL,
    rank     INTEGER NOT NULL,
    user_id  INTEGER NOT NULL,
    equity   BIGINT NOT NULL,

    CONSTRAINT pk_leaderboard_entries PRIMARY KEY (ts, rank)
);

-- trading.api_orders
CREATE TABLE trading.api_orders (
    id          BIGINT GENERATED ALWAYS AS IDENTITY,
    uma_id      SMALLINT NOT NULL,
    user_id     INTEGER NOT NULL,
    side        SMALLINT NOT NULL,
    kind        SMALLINT NOT NULL,
    price       BIGINT,
    qty         BIGINT NOT NULL,
    status      SMALLINT NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_api_orders PRIMARY KEY (id),
    CONSTRAINT chk_api_orders_side CHECK (side IN (0, 1)),
    CONSTRAINT chk_api_orders_kind CHECK (kind IN (0, 1)),
    CONSTRAINT chk_api_orders_status CHECK (status BETWEEN 0 AND 3),
    CONSTRAINT chk_api_orders_limit_price CHECK (kind = 1 OR price IS NOT NULL)
);

ALTER TABLE trading.accounts
    ADD CONSTRAINT fk_accounts_user_id FOREIGN KEY (user_id) REFERENCES trading.users (id) ON DELETE RESTRICT;

ALTER TABLE trading.positions
    ADD CONSTRAINT fk_positions_user_id FOREIGN KEY (user_id) REFERENCES trading.users (id) ON DELETE RESTRICT;

ALTER TABLE trading.positions
    ADD CONSTRAINT fk_positions_uma_id FOREIGN KEY (uma_id) REFERENCES market.umas (id) ON DELETE RESTRICT;

ALTER TABLE trading.user_sessions
    ADD CONSTRAINT fk_user_sessions_user_id FOREIGN KEY (user_id) REFERENCES trading.users (id) ON DELETE RESTRICT;

ALTER TABLE trading.leaderboard_entries
    ADD CONSTRAINT fk_leaderboard_entries_user_id FOREIGN KEY (user_id) REFERENCES trading.users (id) ON DELETE RESTRICT;

ALTER TABLE trading.api_orders
    ADD CONSTRAINT fk_api_orders_user_id FOREIGN KEY (user_id) REFERENCES trading.users (id) ON DELETE RESTRICT;

ALTER TABLE trading.api_orders
    ADD CONSTRAINT fk_api_orders_uma_id FOREIGN KEY (uma_id) REFERENCES market.umas (id) ON DELETE RESTRICT;

ALTER TABLE market.candles
    ADD CONSTRAINT fk_candles_uma_id FOREIGN KEY (uma_id) REFERENCES market.umas (id) ON DELETE RESTRICT;

ALTER TABLE market.trades
    ADD CONSTRAINT fk_trades_uma_id FOREIGN KEY (uma_id) REFERENCES market.umas (id) ON DELETE RESTRICT;

ALTER TABLE market.trades
    ADD CONSTRAINT fk_trades_buyer_id FOREIGN KEY (buyer_id) REFERENCES trading.users (id) ON DELETE RESTRICT;

ALTER TABLE market.trades
    ADD CONSTRAINT fk_trades_seller_id FOREIGN KEY (seller_id) REFERENCES trading.users (id) ON DELETE RESTRICT;

ALTER TABLE market.book_snapshots
    ADD CONSTRAINT fk_book_snapshots_uma_id FOREIGN KEY (uma_id) REFERENCES market.umas (id) ON DELETE RESTRICT;

CREATE INDEX idx_positions_uma_id ON trading.positions (uma_id);
CREATE INDEX idx_user_sessions_user_id ON trading.user_sessions (user_id);
CREATE INDEX idx_leaderboard_entries_user_id ON trading.leaderboard_entries (user_id);
CREATE INDEX idx_api_orders_user_id ON trading.api_orders (user_id);
CREATE INDEX idx_api_orders_uma_id ON trading.api_orders (uma_id);
CREATE INDEX idx_trades_uma_id_ts ON market.trades (uma_id, ts);
CREATE INDEX idx_trades_buyer_id ON market.trades (buyer_id);
CREATE INDEX idx_trades_seller_id ON market.trades (seller_id);
CREATE INDEX idx_book_snapshots_uma_id ON market.book_snapshots (uma_id);

CREATE TRIGGER trg_accounts_set_updated_at
    BEFORE UPDATE ON trading.accounts
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_set_updated_at();

