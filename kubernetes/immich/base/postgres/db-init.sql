-- PSQL 15 Public Scheme Tweak
\c 'immich'
GRANT CREATE ON SCHEMA public TO immich;
CREATE ROLE immich LOGIN;
CREATE DATABASE immich;
GRANT CONNECT, CREATE ON DATABASE immich TO immich;
