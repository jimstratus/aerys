-- Runs first (alphabetically) in /docker-entrypoint-initdb.d/
-- Connected to default 'n8n' database as superuser at this point

-- Enable vector in n8n database (in case n8n ever needs it)
CREATE EXTENSION IF NOT EXISTS vector;

-- Create Aerys application database
CREATE DATABASE aerys;

-- Switch to aerys database and enable extensions
\c aerys

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Grant schema permissions for future use
GRANT ALL ON SCHEMA public TO PUBLIC;
