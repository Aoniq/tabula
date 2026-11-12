#!/bin/bash
# Start throwaway databases used by `Tabula --selftest` and for manual testing.
set -e
docker start tabula-pg 2>/dev/null || docker run -d --name tabula-pg -e POSTGRES_PASSWORD=secret -p 55432:5432 postgres:17
docker start tabula-mysql 2>/dev/null || docker run -d --name tabula-mysql -e MYSQL_ROOT_PASSWORD=secret -e MYSQL_DATABASE=shop -p 53306:3306 mysql:8.4
docker start tabula-redis 2>/dev/null || docker run -d --name tabula-redis -p 56379:6379 redis:7
echo "Waiting for databases..."
until docker exec tabula-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
until docker exec tabula-mysql mysqladmin ping -uroot -psecret --silent >/dev/null 2>&1; do sleep 1; done
DIR="$(cd "$(dirname "$0")" && pwd)"
docker exec -i tabula-pg psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='shop'" | grep -q 1 || docker exec -i tabula-pg createdb -U postgres shop
docker exec -i tabula-pg psql -q -U postgres -d shop -v ON_ERROR_STOP=1 < "$DIR/seed-postgres.sql"
docker exec -i tabula-mysql mysql -uroot -psecret shop < "$DIR/seed-mysql.sql" 2>/dev/null
echo "Ready: postgres://postgres:secret@127.0.0.1:55432/shop  mysql://root:secret@127.0.0.1:53306/shop  redis://127.0.0.1:56379"
