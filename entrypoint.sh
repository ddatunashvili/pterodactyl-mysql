#!/bin/bash
cd /home/container || exit 1

DATADIR=/home/container/mysql
RUNDIR=/tmp/mysqld
SOCKET=${RUNDIR}/mysqld.sock
PIDFILE=${RUNDIR}/mysqld.pid
CNF=/tmp/renode.cnf
INIT=/tmp/renode-init.sql
PORT="${SERVER_PORT:-3306}"

say() { echo "Renode: $*"; }

# Values that go into SQL. Names are checked against a strict shape rather than
# quoted; passwords have their quotes and backslashes escaped.
NAME_RE='^[A-Za-z][A-Za-z0-9_]{0,63}$'
sql_string() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"; }

if [ -z "${MYSQL_ROOT_PASSWORD:-}" ]; then
    say "MYSQL_ROOT_PASSWORD is empty; refusing to start a server without a root password."
    exit 1
fi
if [ -n "${MYSQL_DATABASE:-}" ] && ! [[ "$MYSQL_DATABASE" =~ $NAME_RE ]]; then
    say "MYSQL_DATABASE '${MYSQL_DATABASE}' is not a plain name (letters, digits, _)."
    exit 1
fi
if [ -n "${MYSQL_USER:-}" ] && ! [[ "$MYSQL_USER" =~ ^[A-Za-z][A-Za-z0-9_]{0,31}$ ]]; then
    say "MYSQL_USER '${MYSQL_USER}' is not a plain name (letters, digits, _)."
    exit 1
fi

# Size InnoDB to the container rather than to the host: a 1 GB server given
# MySQL's defaults plus performance_schema is an out-of-memory kill waiting.
LIMIT=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo max)
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -gt $((64 * 1024 * 1024 * 1024)) ]; then
    LIMIT=$((1024 * 1024 * 1024))
fi
MB=$((LIMIT / 1024 / 1024))
POOL=$(( (MB * 45 / 100) / 128 * 128 ))
[ "$POOL" -lt 128 ] && POOL=128
PERF=OFF
[ "$MB" -gt 2048 ] && PERF=ON

{
    echo "[mysqld]"
    echo "datadir=${DATADIR}"
    echo "socket=${SOCKET}"
    echo "pid-file=${PIDFILE}"
    echo "port=${PORT}"
    echo "bind-address=0.0.0.0"
    echo "mysqlx=OFF"
    echo "skip-name-resolve"
    echo "innodb_buffer_pool_size=${POOL}M"
    echo "performance_schema=${PERF}"
    echo "max_connections=$([ "$MB" -le 1024 ] && echo 60 || echo 151)"
    echo "log-error-verbosity=2"
    # Statements run once as the server starts, before it takes connections.
    echo "init-file=${INIT}"
    echo "[client]"
    echo "socket=${SOCKET}"
    # Anything the owner wants on top, in their own file.
    [ -f /home/container/my.cnf ] && echo "!include /home/container/my.cnf"
} > "$CNF"

mkdir -p -m 700 "$RUNDIR"
umask 077
: > "$INIT"

if [ ! -d "${DATADIR}/mysql" ]; then
    say "First start: initialising the data directory (${POOL} MB buffer pool, performance_schema ${PERF})."
    mkdir -p "$DATADIR"
    if ! mysqld --defaults-file="$CNF" --initialize-insecure >/tmp/renode-initialize.log 2>&1; then
        cat /tmp/renode-initialize.log
        say "Initialising the data directory failed."
        exit 1
    fi

    ROOT_PW=$(sql_string "$MYSQL_ROOT_PASSWORD")
    {
        echo "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PW}';"
        echo "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${ROOT_PW}';"
        echo "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
        if [ -n "${MYSQL_DATABASE:-}" ]; then
            echo "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;"
        fi
        if [ -n "${MYSQL_USER:-}" ] && [ -n "${MYSQL_PASSWORD:-}" ]; then
            echo "CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '$(sql_string "$MYSQL_PASSWORD")';"
            [ -n "${MYSQL_DATABASE:-}" ] && echo "GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';"
        fi
        echo "FLUSH PRIVILEGES;"
    } >> "$INIT"
    say "Root, ${MYSQL_USER:-no app user} and ${MYSQL_DATABASE:-no database} are created as the server starts."
elif [ -n "${MYSQL_DATABASE:-}" ]; then
    # Later starts never touch a password: it may have been changed with
    # ALTER USER, and resetting it here would lock out whoever changed it.
    echo "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;" >> "$INIT"
fi
umask 022

# Pterodactyl startup: {{VAR}} -> ${VAR}, run as a script (the panel may prefix
# it with a console banner, which `eval echo` would execute and swallow).
MODIFIED_STARTUP=$(printf '%s' "${STARTUP:-mysqld --defaults-file=${CNF}}" | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo ":/home/container$ ${MODIFIED_STARTUP}"

if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "${MODIFIED_STARTUP}" </dev/null &
else
    bash -c "${MODIFIED_STARTUP}" </dev/null &
fi
PID=$!

shutdown() {
    echo "Stopping MySQL..."
    # mysqld itself, by its pid file: it may be a child of the startup shell
    # rather than the process this script started.
    if [ -s "$PIDFILE" ]; then
        kill -TERM "$(cat "$PIDFILE")" 2>/dev/null
    fi
    kill -TERM -- "-$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null
    wait "$PID"
    exit $?
}
trap shutdown INT TERM

# The init file holds passwords on first start; it is only read at startup.
(
    for _ in $(seq 1 120); do
        [ -S "$SOCKET" ] && break
        kill -0 "$PID" 2>/dev/null || exit 0
        sleep 1
    done
    sleep 2
    rm -f "$INIT"
) &

# Panel console lines run as SQL, as root over the local socket. In the
# background, so the container lives exactly as long as mysqld does.
exec 3<&0
while IFS= read -r line <&3; do
    [ -z "$line" ] && continue
    MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --defaults-file="$CNF" -uroot -t -e "$line" || true
done &

wait "$PID"
exit $?
