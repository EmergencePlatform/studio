#!/bin/bash


echo
echo "--> Populating common commands"
hab pkg binlink core/git
hab pkg binlink jarvus/watchman
hab pkg binlink core/mysql-client mysql
mkdir -m 777 -p /hab/svc/watchman/var


echo
echo "--> Populating /bin/{chmod,stat} commands for Docker for Windows watch workaround"
echo "    See: https://gist.github.com/themightychris/8a016e655160598ede29b2cac7c04668"
hab pkg binlink core/coreutils -d /bin chmod
hab pkg binlink core/coreutils -d /bin stat


echo
echo "--> Welcome to Emergence Studio! Detecting environment..."

export EMERGENCE_STUDIO="loading"
export EMERGENCE_HOLOBRANCH="${EMERGENCE_HOLOBRANCH:-emergence-site}"

if [ -z "${EMERGENCE_REPO}" ]; then
    EMERGENCE_REPO="$( cd "$( dirname "${BASH_SOURCE[1]}" )" && pwd)"
    EMERGENCE_REPO="${EMERGENCE_REPO:-/src}"
fi
echo "    EMERGENCE_REPO=${EMERGENCE_REPO}"
export EMERGENCE_REPO

if [ -z "${EMERGENCE_CORE}" ]; then
    if [ -f /src/emergence-php-core/composer.json ]; then
        EMERGENCE_CORE="/src/emergence-php-core"

        pushd "${EMERGENCE_CORE}" > /dev/null
        COMPOSER_ALLOW_SUPERUSER=1 hab pkg exec core/composer composer install
        popd > /dev/null
    else
        EMERGENCE_CORE="$(hab pkg path emergence/php-core)"
    fi
fi
echo "    EMERGENCE_CORE=${EMERGENCE_CORE}"
export EMERGENCE_CORE


# use /src/hologit as hologit client if it exists
if [ -f /src/hologit/bin/cli.js ]; then
    echo
    echo "--> Activating /src/hologit to provide git-holo and git-holo-debug"

  cat > "${HAB_BINLINK_DIR:-/bin}/git-holo" <<- END_OF_SCRIPT
#!/bin/bash

ENVPATH="\${PATH}"
set -a
. $(hab pkg path jarvus/hologit)/RUNTIME_ENVIRONMENT
set +a
PATH="\${ENVPATH}:\${PATH}"

END_OF_SCRIPT
  cp "${HAB_BINLINK_DIR:-/bin}/git-holo"{,-debug}
  echo "exec $(hab pkg path core/node)/bin/node /src/hologit/bin/cli.js \$@" >> "${HAB_BINLINK_DIR:-/bin}/git-holo"
  echo "exec $(hab pkg path core/node)/bin/node --inspect-brk=0.0.0.0:9229 /src/hologit/bin/cli.js \$@" >> "${HAB_BINLINK_DIR:-/bin}/git-holo-debug"
  chmod +x "${HAB_BINLINK_DIR:-/bin}/git-holo"{,-debug}
  echo "    Linked ${HAB_BINLINK_DIR:-/bin}/git-holo to /src/hologit/bin/cli.js"
  echo "    Linked ${HAB_BINLINK_DIR:-/bin}/git-holo-debug to /src/hologit/bin/cli.js --inspect-brk=0.0.0.0:9229"
else
  hab pkg binlink jarvus/hologit
fi


echo
echo "--> Optimizing git performance"
git config --global core.untrackedCache true
git config --global core.fsmonitor "$(hab pkg path jarvus/rs-git-fsmonitor)/bin/rs-git-fsmonitor"


echo
echo "--> Configuring services for local development..."

init-user-config() {
    local config_force
    if [ "$1" == "--force" ]; then
        shift
        config_force=true
    else
        config_force=false
    fi

    local config_pkg_name="$1"
    local config_default="$2"
    [ -z "$config_pkg_name" -o -z "$config_default" ] && { echo >&2 'Usage: init-user-config pkg_name "[default]\nconfig = value"'; return 1; }

    local config_toml_path="/hab/user/${config_pkg_name}/config/user.toml"

    if $config_force || [ ! -f "$config_toml_path" ]; then
        echo "    Initializing: $config_toml_path"
        mkdir -p "/hab/user/${config_pkg_name}/config"
        echo -e "$config_default" | awk '{$1=$1};1NF' | awk 'NF' > "$config_toml_path"
    fi
}

init-user-config nginx '
    [http.listen]
    port = 80
'

init-user-config mysql '
    app_username = "admin"
    app_password = "admin"
    bind = "0.0.0.0"
'

init-user-config mysql-remote '
    username = "admin"
    password = "admin"
    host = "127.0.0.1"
    port = 3306
'

-write-runtime-config() {
    local runtime_config="
        [core]
        root = \"${EMERGENCE_CORE}\"

        [sites.default]
        database = \"${DB_DATABASE:-default}\"
    "

    if [ "${EMERGENCE_RUNTIME}" == "emergence/php-runtime" ] || [ -n "${EMERGENCE_SITE_GIT_DIR}" ]; then
        runtime_config="${runtime_config}

            [sites.default.holo]
            gitDir = \"${EMERGENCE_SITE_GIT_DIR:-${EMERGENCE_REPO}/.git}\"

            [extensions.opcache.config]
            validate_timestamps = true
        "
    fi

    if [ -n "${XDEBUG_HOST}" ]; then
        mkdir -p "/hab/svc/${EMERGENCE_RUNTIME#*/}/var/profiles"
        chown hab:hab "/hab/svc/${EMERGENCE_RUNTIME#*/}/var/profiles"

        runtime_config="${runtime_config}

            [extensions.xdebug]
            enabled=true
            [extensions.xdebug.config]
            remote_connect_back = 0
            remote_host = '${XDEBUG_HOST}'
            profiler_enable_trigger = 1
            profiler_output_dir = '/hab/svc/${EMERGENCE_RUNTIME#*/}/var/profiles'
        "
    fi

    if [ -n "${MAIL_SERVICE}" ] && hab svc status "${MAIL_SERVICE}" > /dev/null 2>&1; then
        runtime_config="${runtime_config}

            [sendmail]
            path = 'hab pkg exec ${MAIL_SERVICE} sendmail -t -i'
        "
    fi

    init-user-config --force ${EMERGENCE_RUNTIME#*/} "${runtime_config}"

    mkdir -p /root/.config/psysh
    cat > /root/.config/psysh/config.php <<- END_OF_SCRIPT
<?php

    date_default_timezone_set('America/New_York');

    return [
        'commands' => [
            new \Psy\Command\ParseCommand,
        ],

        'defaultIncludes' => [
            '/hab/svc/${EMERGENCE_RUNTIME#*/}/config/initialize.php',
        ]
    ];
END_OF_SCRIPT
}
"-write-runtime-config"


echo

echo "    * Use 'start-mysql [pkg] [db]' to load a MySQL database service"
start-mysql() {
    if [ -n "${DB_SERVICE}" ] && hab svc status "${DB_SERVICE}" > /dev/null 2>&1; then
        hab svc unload "${DB_SERVICE}"
    fi

    export DB_SERVICE="${1:-${DB_SERVICE:-core/mysql}}"
    export DB_DATABASE="${2:-${DB_DATABASE:-default}}"
    ln -sf "/hab/svc/${DB_SERVICE#*/}/config/client.cnf" ~/.my.cnf

    if [ -d "/hab/svc/${DB_SERVICE#*/}/data" ]; then
        chown -v hab:hab "/hab/svc/${DB_SERVICE#*/}/data"
    fi

    hab svc load "${DB_SERVICE}" \
        --strategy at-once \
        --force
}

echo "    * Use 'start-mysql-remote [db]' to login to a remote MySQL database"
start-mysql-remote() {
    "${EDITOR:-vim}" "/hab/user/mysql-remote/config/user.toml"
    start-mysql "jarvus/mysql-remote" "${1}"
}

echo "    * Use 'start-runtime [pkg]' to start runtime"
start-runtime() {
    if [ -n "${EMERGENCE_RUNTIME}" ] && hab svc status "${EMERGENCE_RUNTIME}" > /dev/null 2>&1; then
        hab svc unload "${EMERGENCE_RUNTIME}"
    fi

    export EMERGENCE_RUNTIME="${1:-${EMERGENCE_RUNTIME:-emergence/php-runtime}}"

    hab svc load "${1:-$EMERGENCE_RUNTIME}" \
        --bind="database:${2:-${DB_SERVICE#*/}.default}" \
        --strategy at-once \
        --force

    "-write-runtime-config"
}

echo "    * Use 'start-http' to start http service"
start-http() {
    if [ -z "${EMERGENCE_RUNTIME}" ]; then
        echo "Cannot start-http, EMERGENCE_RUNTIME is not initialized, start-runtime first"
        return 1
    fi

    hab svc load emergence/nginx \
        --bind="backend:${1:-${EMERGENCE_RUNTIME#*/}.default}" \
        --strategy at-once \
        --force
}

echo "    * Use 'start-all' to start all services"
start-all() {
    start-mysql && start-runtime && start-http
}


echo
echo "    * Use 'stop-mysql' to stop just mysql service"
stop-mysql() {
    hab svc unload "${DB_SERVICE}"
}

echo "    * Use 'stop-runtime' to stop just runtime service"
stop-runtime() {
    hab svc unload "${EMERGENCE_RUNTIME}"
}

echo "    * Use 'stop-http' to stop just http service"
stop-http() {
    hab svc unload emergence/nginx
}

echo "    * Use 'stop-all' to stop everything"
stop-all() {
    stop-http
    stop-runtime
    stop-mysql
}


echo

echo "    * Use 'shell-mysql' to open a mysql shell for the local mysql service"
shell-mysql() {
    hab pkg exec "${DB_SERVICE}" mysql "${1:-$DB_DATABASE}" "$@"
}

echo "    * Use 'shell-runtime' to open a php shell for the studio runtime service"
shell-runtime() {
    hab pkg exec emergence/studio psysh "$@"
}


echo "    * Use 'load-sql [-|file...|URL|site] [database]' to load one or more .sql files into the local mysql service"
load-sql() {
    local load_sql_mysql="hab pkg exec ${DB_SERVICE} mysql --default-character-set=utf8"

    DATABASE_NAME="${2:-$DB_DATABASE}"
    echo "CREATE DATABASE IF NOT EXISTS \`${DATABASE_NAME}\`;" | $load_sql_mysql;
    load_sql_mysql="${load_sql_mysql} ${DATABASE_NAME}"

    if [[ "${1}" =~ ^https?://[^/]+/?$ ]]; then
        printf "Developer username: "
        read LOAD_SQL_USER
        wget --user="${LOAD_SQL_USER}" --ask-password "${1%/}/site-admin/database/dump.sql" -O - | $load_sql_mysql
    elif [[ "${1}" =~ ^https?://[^/]+/.+ ]]; then
        wget "${1}" -O - | $load_sql_mysql
    elif [ -n "${EMERGENCE_RUNTIME}" ]; then
        cat "${1:-/hab/svc/${EMERGENCE_RUNTIME#*/}/var/site-data/seed.sql}" | $load_sql_mysql
    fi
}

echo "    * Use 'dump-sql [database] > file.sql' to dump database to SQL"
dump-sql() {
    hab pkg exec "${DB_SERVICE}" mysqldump \
        --force \
        --skip-opt \
        --skip-comments \
        --skip-dump-date \
        --create-options \
        --order-by-primary \
        --single-transaction \
        --compact \
        --quick \
        "${1:-$DB_DATABASE}"
}


echo "    * Use 'promote-user <username> [account_level]' to promote a user in the database"
promote-user() {
    echo "UPDATE people SET AccountLevel = '${2:-Developer}' WHERE Username = '${1}'" | hab pkg exec "${DB_SERVICE}" mysql "${3:-$DB_DATABASE}"
}

echo "    * Use 'reset-database [database_name]' to drop and recreate the MySQL database"
reset-mysql() {
    echo "DROP DATABASE IF EXISTS \`"${1:-$DB_DATABASE}"\`; CREATE DATABASE \`"${1:-$DB_DATABASE}"\`;" | hab pkg exec "${DB_SERVICE}" mysql
}


echo
echo "--> Setting up development commands..."

echo "    * Use 'switch-site <repo_path>' to switch environment to running a different site repository"
switch-site() {
    if [ -d "$1" ]; then
        export EMERGENCE_REPO="$( cd "$1" && pwd)"
        "-write-runtime-config"
    else
        >&2 echo "error: $1 does not exist"
    fi
}

echo "    * Use 'update-site' to update the running site from ${EMERGENCE_REPO}#${EMERGENCE_HOLOBRANCH}"
update-site() {
    pushd "${EMERGENCE_REPO}" > /dev/null

    local previous_tree="${EMERGENCE_LOADED_TREE}"
    export EMERGENCE_LOADED_TREE=$(git holo project "${EMERGENCE_HOLOBRANCH}" --working ${EMERGENCE_FETCH:+--fetch})

    hab pkg exec "${EMERGENCE_RUNTIME}" emergence-php-load "${EMERGENCE_LOADED_TREE}"

    if [ -n "${previous_tree}" ]; then
        git diff --stat "${previous_tree}" "${EMERGENCE_LOADED_TREE}"
    fi

    popd > /dev/null
}

echo "    * Use 'watch-site' to watch the running site in ${EMERGENCE_REPO}#${EMERGENCE_HOLOBRANCH}"
watch-site() {
    pushd "${EMERGENCE_REPO}" > /dev/null
    git holo project "${EMERGENCE_HOLOBRANCH}" --working --watch ${EMERGENCE_FETCH:+--fetch} | xargs -n 1 hab pkg exec "${EMERGENCE_RUNTIME}" emergence-php-load
    popd > /dev/null
}

echo "    * Use 'enable-xdebug <debugger_host>' to configure xdebug via a host"
enable-xdebug() {
    export XDEBUG_HOST="${1:-127.0.0.1}"
    "-write-runtime-config"
    echo "enabled Xdebug with remote debugger: ${XDEBUG_HOST}"
}

echo "    * Use 'enable-runtime-update' to enable updating site-specific runtime builds with new site code via \`update-site\` and \`watch-site\`"
enable-runtime-update() {
    export EMERGENCE_SITE_GIT_DIR="${EMERGENCE_REPO}/.git"
    "-write-runtime-config"
    echo "enabled updating ${EMERGENCE_RUNTIME} from ${EMERGENCE_SITE_GIT_DIR}"
}

echo "    * Use 'enable-email [pkg=jarvus/postfix]' to install a local MTA for queuing/relaying/delivering email and configure the current runtime to use it"
enable-email() {
    if [ -z "${SYSLOG_PID}" ]; then
        hab pkg exec core/busybox-static syslogd -n -O /hab/cache/sys.log &
        SYSLOG_PID=$!
        echo "syslog started, to follow use: tail -f /hab/cache/sys.log"
    fi

    export MAIL_SERVICE="${1:-${MAIL_SERVICE:-jarvus/postfix}}"
    hab svc load --force "${MAIL_SERVICE}"
    "-write-runtime-config"
    echo "${MAIL_SERVICE} loaded and runtime configured to use it"
}

echo "    * Use 'enable-email-relay <host> <port> <username> [password]' to configure MTA to relay"
enable-email-relay() {
    if [ -z "${1}" ] || [ -z "${2}" ] || [ -z "${3}" ]; then
        echo >&2 'Usage: enable-email-relay <host> <port> <username> [password]'
        return 1
    fi

    init-user-config --force postfix "
        relayhost = '[${1}]:${2}'

        [smtp.sasl]
        password_maps = 'static:${3}:${4}'
    "
}

echo "    * Use 'console-run <command> [args...]' to execute a console command within the current runtime instance"
console-run() {
    local console_command="${1}"
    shift
    [ -z "$console_command" ] && { echo >&2 'Usage: console-run <command> [args...]'; return 1; }

    hab pkg exec "${EMERGENCE_RUNTIME}" emergence-console-run "${console_command}" "$@"
}


# overall instructions
echo
echo "    For a complete studio debug environment:"
echo "      start-all # wait a moment for services to start up"
echo "      update-site # or watch-site"


# final blank line
export EMERGENCE_STUDIO="loaded"
echo
