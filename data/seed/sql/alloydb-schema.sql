DROP TABLE IF EXISTS stock_movements;
DROP TABLE IF EXISTS inventory;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS stores;

CREATE TABLE stores (
  store_id     TEXT PRIMARY KEY,
  store_name   TEXT NOT NULL,
  zip_code     TEXT NOT NULL,
  address      TEXT NOT NULL,
  latitude     DOUBLE PRECISION NOT NULL,
  longitude    DOUBLE PRECISION NOT NULL,
  opened_date  DATE NOT NULL,
  square_feet  INTEGER NOT NULL CHECK (square_feet > 0),
  status       TEXT NOT NULL CHECK (status IN ('OPEN', 'CLOSED', 'PLANNED'))
);

CREATE TABLE products (
  sku               TEXT PRIMARY KEY,
  item_name         TEXT NOT NULL,
  category          TEXT NOT NULL CHECK (category IN (
                      'Espresso Drinks', 'Filter Coffee', 'Cold Beverages',
                      'Tea & Matcha', 'Food & Snacks', 'Retail Beans', 'Merchandise')),
  unit_price        NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  reorder_threshold INTEGER NOT NULL CHECK (reorder_threshold >= 0),
  is_seasonal       BOOLEAN NOT NULL
);

CREATE TABLE inventory (
  store_id        TEXT NOT NULL REFERENCES stores(store_id),
  sku             TEXT NOT NULL REFERENCES products(sku),
  opening_stock   INTEGER NOT NULL CHECK (opening_stock >= 0),
  stock_count     INTEGER NOT NULL CHECK (stock_count >= 0),
  last_counted_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (store_id, sku)
);

CREATE TABLE stock_movements (
  movement_id    TEXT PRIMARY KEY,
  store_id       TEXT NOT NULL REFERENCES stores(store_id),
  sku            TEXT NOT NULL REFERENCES products(sku),
  movement_type  TEXT NOT NULL CHECK (movement_type IN ('SALE', 'DELIVERY', 'WASTE', 'ADJUSTMENT')),
  quantity_delta INTEGER NOT NULL CHECK (quantity_delta <> 0),
  occurred_at    TIMESTAMPTZ NOT NULL
);

CREATE INDEX inventory_store_idx ON inventory (store_id);
CREATE INDEX movements_store_sku_idx ON stock_movements (store_id, sku);
CREATE INDEX movements_occurred_idx ON stock_movements (occurred_at);
