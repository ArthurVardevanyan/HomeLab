-- PSQL 15 Public Scheme Tweak
\c
'quay'
GRANT CREATE ON SCHEMA public TO quay;
CREATE EXTENSION pg_trgm;
