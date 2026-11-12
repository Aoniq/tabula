SET SESSION cte_max_recursion_depth = 10000;
DROP TABLE IF EXISTS order_items, orders, products, customers, audit_log;
DROP VIEW IF EXISTS active_customers;
CREATE TABLE customers (
  id int AUTO_INCREMENT PRIMARY KEY,
  name varchar(100) NOT NULL,
  email varchar(255) UNIQUE COMMENT 'Primary contact email',
  country char(2) DEFAULT 'NL',
  is_active tinyint(1) NOT NULL DEFAULT 1,
  metadata json,
  avatar blob,
  created_at datetime NOT NULL DEFAULT CURRENT_TIMESTAMP
) COMMENT='People who buy things';
CREATE TABLE products (
  id int AUTO_INCREMENT PRIMARY KEY,
  sku varchar(32) NOT NULL UNIQUE,
  title varchar(200) NOT NULL,
  price decimal(10,2) NOT NULL,
  stock int NOT NULL DEFAULT 0
);
CREATE TABLE orders (
  id bigint AUTO_INCREMENT PRIMARY KEY,
  customer_id int NOT NULL,
  status enum('pending','paid','shipped','cancelled') NOT NULL DEFAULT 'pending',
  total decimal(12,2),
  ordered_at timestamp DEFAULT CURRENT_TIMESTAMP,
  KEY idx_orders_status (status, ordered_at),
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE
);
CREATE TABLE order_items (
  order_id bigint NOT NULL,
  product_id int NOT NULL,
  quantity int NOT NULL DEFAULT 1,
  PRIMARY KEY (order_id, product_id),
  FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
  FOREIGN KEY (product_id) REFERENCES products(id)
);
CREATE TABLE audit_log (event varchar(50), payload text);
INSERT INTO customers (name, email, country, is_active, metadata, avatar)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 800)
SELECT CONCAT('Customer ', n), CONCAT('customer', n, '@example.com'), ELT(1 + n % 5, 'NL','DE','US','GB','FR'), n % 7 <> 0,
       JSON_OBJECT('tier', ELT(1 + n % 3, 'gold','silver','bronze')), IF(n % 10 = 0, UNHEX('DEADBEEF'), NULL) FROM seq;
INSERT INTO products (sku, title, price, stock)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 120)
SELECT CONCAT('SKU-', LPAD(n, 5, '0')), CONCAT('Product ', n), ROUND(RAND() * 200, 2), n % 50 FROM seq;
INSERT INTO orders (customer_id, status, total)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 2000)
SELECT 1 + n % 800, ELT(1 + n % 4, 'pending','paid','shipped','cancelled'), ROUND(RAND() * 500, 2) FROM seq;
INSERT INTO order_items SELECT id, 1 + id % 120, 1 + id % 3 FROM orders;
INSERT INTO audit_log VALUES ('login', 'user 1'), ('logout', NULL);
CREATE VIEW active_customers AS SELECT id, name, email FROM customers WHERE is_active = 1;
