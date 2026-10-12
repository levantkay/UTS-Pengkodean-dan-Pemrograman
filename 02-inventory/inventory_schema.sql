-- Studi kasus 2: skema dasar yang diberikan pada soal.

CREATE TABLE inventory_items (
    item_id VARCHAR(10) PRIMARY KEY,
    item_name VARCHAR(100),
    stock_qty INT NOT NULL DEFAULT 0,
    unit_cost NUMERIC(15, 2) NOT NULL CHECK (unit_cost >= 0)
);

CREATE TABLE inventory_transactions (
    trx_id SERIAL PRIMARY KEY,
    item_id VARCHAR(10) NOT NULL
        REFERENCES inventory_items(item_id) ON DELETE RESTRICT,
    trx_type VARCHAR(10) NOT NULL
        CHECK (trx_type IN ('PURCHASE', 'SALE', 'ADJUSTMENT')),
    qty INT NOT NULL,
    trx_date TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
