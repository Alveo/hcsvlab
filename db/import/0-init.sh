#!/bin/bash
# set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER hcsvlab;
    ALTER USER hcsvlab WITH PASSWORD 'hcsvlab';
    CREATE DATABASE hcsvlab;
    GRANT ALL PRIVILEGES ON DATABASE hcsvlab TO hcsvlab;
EOSQL