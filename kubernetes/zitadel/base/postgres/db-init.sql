-- PSQL 15 Public Scheme Tweak
\c 'zitadel'
GRANT CREATE ON SCHEMA public TO zitadel;
CREATE ROLE zitadel LOGIN;
CREATE DATABASE zitadel;
GRANT CONNECT, CREATE ON DATABASE zitadel TO zitadel;
