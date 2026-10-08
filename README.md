# pterodactyl-mysql

MySQL 8.4 LTS as a Pterodactyl egg. Image: `ghcr.io/ddatunashvili/pterodactyl-mysql:8.4`, built and boot-tested by GitHub Actions on every push to `main` (run as Wings runs it: uid 988, Wings' dropped capabilities, no-new-privileges, 1 GB limit).

## What a server gets

- `root` (local and remote) with `MYSQL_ROOT_PASSWORD`.
- `MYSQL_DATABASE`, and `MYSQL_USER` with `MYSQL_PASSWORD` and full rights on that database only.
- All created on first start. Later starts never reset a password, so `ALTER USER` sticks; a missing database is re-created.
- Data in `/home/container/mysql`. Your own settings go in `/home/container/my.cnf` (a `[mysqld]` section); it is included last.
- Console lines run as SQL as root.

## Memory

The buffer pool is 45% of the container's memory limit (min 128 MB). `performance_schema` is off at 2 GB and below, and `max_connections` is 60 at 1 GB. Override in `my.cnf`.

## Import

Admin → Nests → Import Egg → `egg-mysql.json`. Every variable is required; the Renode shop generates the passwords and database name per server.
