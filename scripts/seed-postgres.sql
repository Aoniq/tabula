DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
DROP SCHEMA IF EXISTS analytics CASCADE;
CREATE SCHEMA analytics;
CREATE TABLE customers (
  id serial PRIMARY KEY,
  name text NOT NULL,
  email varchar(255) UNIQUE,
  country char(2) DEFAULT 'NL',
  is_active boolean NOT NULL DEFAULT true,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE customers IS 'People who buy things';
COMMENT ON COLUMN customers.email IS 'Primary contact email';
CREATE TABLE products (
  id serial PRIMARY KEY,
  sku varchar(32) NOT NULL UNIQUE,
  title text NOT NULL,
  price numeric(10,2) NOT NULL CHECK (price >= 0),
  tags text[],
  stock integer NOT NULL DEFAULT 0
);
CREATE TABLE orders (
  id bigserial PRIMARY KEY,
  customer_id integer NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  status varchar(20) NOT NULL DEFAULT 'pending',
  total numeric(12,2),
  ordered_at timestamp DEFAULT now()
);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_status_date ON orders(status, ordered_at DESC);
CREATE TABLE order_items (
  order_id bigint REFERENCES orders(id) ON DELETE CASCADE,
  product_id integer REFERENCES products(id),
  quantity integer NOT NULL DEFAULT 1,
  unit_price numeric(10,2) NOT NULL,
  PRIMARY KEY (order_id, product_id)
);
CREATE TABLE audit_log (event text, payload text, at timestamp DEFAULT now());
INSERT INTO customers (name, email, country, is_active, metadata)
SELECT 'Customer ' || g, 'customer' || g || '@example.com', (ARRAY['NL','DE','US','GB','FR'])[1 + g % 5], g % 7 <> 0,
       jsonb_build_object('tier', (ARRAY['gold','silver','bronze'])[1 + g % 3], 'score', g * 3)
FROM generate_series(1, 1200) g;
INSERT INTO customers (name, email, country) VALUES ('Ada Lovelace', 'ada@example.com', 'GB'), ('Alan Turing', NULL, 'GB');
INSERT INTO products (sku, title, price, tags, stock)
SELECT 'SKU-' || lpad(g::text, 5, '0'), 'Product ' || g, round((random() * 200)::numeric, 2), ARRAY['tag' || (g % 4), 'new'], g % 50
FROM generate_series(1, 250) g;
INSERT INTO orders (customer_id, status, total, ordered_at)
SELECT 1 + (g % 1200), (ARRAY['pending','paid','shipped','cancelled'])[1 + g % 4], round((random() * 500)::numeric, 2), now() - (g || ' hours')::interval
FROM generate_series(1, 5000) g;
INSERT INTO order_items SELECT o.id, 1 + (o.id % 250), 1 + (o.id % 3), 9.99 FROM orders o;
INSERT INTO audit_log (event, payload) VALUES ('login', 'user 1'), ('login', 'user 2'), ('logout', NULL);
CREATE VIEW active_customers AS SELECT id, name, email FROM customers WHERE is_active;
CREATE MATERIALIZED VIEW order_totals AS SELECT customer_id, count(*) AS orders, sum(total) AS revenue FROM orders GROUP BY customer_id;
CREATE FUNCTION customer_revenue(cid integer) RETURNS numeric LANGUAGE sql AS $$ SELECT COALESCE(sum(total),0) FROM orders WHERE customer_id = cid $$;
CREATE TABLE analytics.daily_stats (day date PRIMARY KEY, visits integer, signups integer);
INSERT INTO analytics.daily_stats SELECT d::date, (random()*1000)::int, (random()*50)::int FROM generate_series(now() - interval '60 days', now(), interval '1 day') d;
