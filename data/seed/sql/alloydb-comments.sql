COMMENT ON TABLE stores IS
  'Store dimension. Grain: one row per physical store the brand operates, 6 rows. A store that has not opened yet lives in the BigQuery candidate_sites table, not here.';
COMMENT ON COLUMN stores.store_id IS 'Primary key. Also the business_id of this store in BigQuery customer_feedback.';
COMMENT ON COLUMN stores.store_name IS 'Display name, brand plus neighbourhood. Presentation only; join on store_id.';
COMMENT ON COLUMN stores.zip_code IS 'ZIP the store trades in. Joins to the BigQuery ZIP tables. Authoritative if it ever disagrees with the denormalised copy in historical_sales.';
COMMENT ON COLUMN stores.square_feet IS 'Trading floor area. The same measure as candidate_sites.available_sqft, so the two are directly comparable.';
COMMENT ON COLUMN stores.opened_date IS 'Date the store began trading.';
COMMENT ON COLUMN stores.status IS 'Lifecycle state: OPEN, CLOSED or PLANNED. All 6 stores are currently OPEN; no history of past states is kept.';

COMMENT ON TABLE products IS
  'Product dimension. Grain: one row per SKU, 25 rows. Current state only: there is no price history, so a historical revenue figure cannot be reproduced from unit_price.';
COMMENT ON COLUMN products.sku IS 'Primary key. Joins to inventory, stock_movements and BigQuery historical_sales.';
COMMENT ON COLUMN products.unit_price IS 'CURRENT list price in USD. Not the price at which past sales were rung up: historical_sales.net_revenue is net of discounts and comps and will not equal units_sold * unit_price.';
COMMENT ON COLUMN products.reorder_threshold IS 'Stock level at or below which the SKU should be reordered. The test for a shortage is inventory.stock_count <= reorder_threshold.';
COMMENT ON COLUMN products.is_seasonal IS 'True where demand swings with the season rather than holding steady year round.';

COMMENT ON TABLE inventory IS
  'Current-state snapshot. Grain: one row per store and SKU, 150 rows. Not a history: it holds the position as of last_counted_at only. Invariant: stock_count = opening_stock + the sum of every stock_movements.quantity_delta for the pair, and the balance never goes negative at any point in between.';
COMMENT ON COLUMN inventory.opening_stock IS 'Units on hand at the start of the stock_movements window, before its oldest movement. A real historical balance produced by simulating the ledger forward, not a back-calculation: it is non-negative, and replaying every movement from it never drives stock below zero. Read stock_count for the live position.';
COMMENT ON COLUMN inventory.stock_count IS 'Units on hand as of last_counted_at. This is the live figure a shortage question should read.';
COMMENT ON COLUMN inventory.last_counted_at IS 'As-of timestamp for stock_count. Every row shares one timestamp: this is a single stocktake, not a rolling count.';

COMMENT ON TABLE stock_movements IS
  'Operational ledger. Grain: one row per inventory event. Covers a trailing 9-week window only, not the full 104 weeks in BigQuery historical_sales. SALE rows are the same events as historical_sales.units_sold and reconcile to it exactly for every complete week.';
COMMENT ON COLUMN stock_movements.movement_type IS 'SALE and WASTE remove stock and are negative; DELIVERY adds stock and is positive; ADJUSTMENT is a stocktake correction of either sign.';
COMMENT ON COLUMN stock_movements.quantity_delta IS 'Signed change in units on hand. Negative removes stock. Never zero. Sum all rows for a store and SKU to move from opening_stock to stock_count.';
COMMENT ON COLUMN stock_movements.occurred_at IS 'When the event happened. The window ends at the stocktake timestamp, so the newest calendar week is partial.';

COMMENT ON COLUMN stores.address IS 'Illustrative street block for a fictional store, not an actual business address.';
COMMENT ON COLUMN stores.latitude IS 'Approximate retail-corridor latitude, WGS84; not a surveyed store point.';
COMMENT ON COLUMN stores.longitude IS 'Approximate retail-corridor longitude, WGS84.';
