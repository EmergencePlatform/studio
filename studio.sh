#!/bin/bash


echo
echo "--> Populating common commands"
hab pkg binlink core/git
hab pkg binlink jarvus/watchman
hab pkg binlink emergence/php-runtime
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


# check ownership of mounted site-data
if [ -d /hab/svc/php-runtime/var ]; then
    chown hab:hab \
        "/hab/svc/php-runtime/var" \
        "/hab/svc/php-runtime/var/site-data"
fi


# use /src/hologit as hologit client if it exists
if [ -f /src/hologit/bin/cli.js ]; then
    echo
    echo "--> Activating /src/hologit to provide git-holo"

  cat > "${HAB_BINLINK_DIR:-/bin}/git-holo" <<- END_OF_SCRIPT
#!/bin/bash

ENVPATH="\${PATH}"
set -a
. $(hab pkg path jarvus/hologit)/RUNTIME_ENVIRONMENT
set +a
PATH="\${ENVPATH}:\${PATH}"

exec $(hab pkg path core/node)/bin/node "--\${NODE_INSPECT:-inspect}=0.0.0.0:9229" /src/hologit/bin/cli.js \$@

END_OF_SCRIPT
  chmod +x "${HAB_BINLINK_DIR:-/bin}/git-holo"
  echo "    Linked ${HAB_BINLINK_DIR:-/bin}/git-holo to /src/hologit/bin/cli.js"
else
  hab pkg binlink jarvus/hologit
fi


echo
echo "--> Optimizing git performance"
git config --global core.untrackedCache true
git config --global core.fsmonitor "$(hab pkg path jarvus/rs-git-fsmonitor)/bin/rs-git-fsmonitor"


echo
echo "--> Configuring PsySH for application shell..."
mkdir -p /root/.config/psysh
cat > /root/.config/psysh/config.php <<- END_OF_SCRIPT
<?php

date_default_timezone_set('America/New_York');

return [
    'commands' => [
        new \Psy\Command\ParseCommand,
    ],

    'defaultIncludes' => [
        '/hab/svc/php-runtime/config/initialize.php',
    ]
];

END_OF_SCRIPT


echo
echo "--> Configuring services for local development..."

init-user-config() {
    if [ "$1" == "--force" ]; then
        shift
        config_force=true
    else
        config_force=false
    fi

    config_pkg_name="$1"
    config_default="$2"
    [ -z "$config_pkg_name" -o -z "$config_default" ] && { echo >&2 'Usage: init-user-config pkg_name "[default]\nconfig = value"'; return 1; }

    config_toml_path="/hab/user/${config_pkg_name}/config/user.toml"

    if $config_force || [ ! -f "$config_toml_path" ]; then
        echo "    Initializing: $config_toml_path"
        mkdir -p "/hab/user/${config_pkg_name}/config"
        echo -e "$config_default" > "$config_toml_path"
    fi
}

init-user-config nginx '
    [http.listen]
    port = 7080
'

init-user-config mysql '
    app_username = "emergence-php-runtime"
    app_password = "emergence-php-runtime"
    bind = "0.0.0.0"
'

init-user-config mysql-remote '
    app_username = "emergence-php-runtime"
    app_password = "emergence-php-runtime"
    host = "127.0.0.1"
    port = 3306
'

-write-php-runtime-config() {
    init-user-config --force php-runtime "
        [core]
        root = \"${EMERGENCE_CORE}\"

        [sites.default.holo]
        gitDir = \"${EMERGENCE_REPO}/.git\"
    "
}
"-write-php-runtime-config"


echo

echo "    * Use 'start-mysql' to start local mysql service"
start-mysql() {
    stop-mysql
    hab svc load core/mysql \
        --strategy at-once
}
start-mysql-local() {
    >&2 echo "warning: start-mysql-local has been shortened to start-mysql"
    >&2 echo
    start-mysql "$@"
}

echo "    * Use 'start-mysql-remote' to start remote mysql service"
start-mysql-remote() {
    stop-mysql
    hab svc load jarvus/mysql-remote \
        --strategy at-once
}

echo "    * Use 'start-runtime' to start runtime service bound to local mysql"
start-runtime() {
    hab svc load "emergence/php-runtime" \
        --bind=database:mysql.default \
        --strategy at-once
}
start-runtime-local() {
    >&2 echo "warning: start-runtime-local has been shortened to start-runtime"
    >&2 echo
    start-runtime "$@"
}

echo "    * Use 'start-runtime-remote' to start runtime service bound to remote mysql"
start-runtime-remote() {
    hab svc load "emergence/php-runtime" \
        --bind=database:mysql-remote.default \
        --strategy at-once
}

echo "    * Use 'start-http' to start http service"
start-http() {
    hab svc load emergence/nginx \
        --bind=runtime:php-runtime.default \
        --strategy at-once
}

echo "    * Use 'start-all' to start all services individually with local mysql"
start-all() {
    start-mysql && start-runtime && start-http
}
start-all-local() {
    >&2 echo "warning: start-all-local has been shortened to start-all"
    >&2 echo
    start-all "$@"
}

echo "    * Use 'start-all-remote' to start all services individually with remote mysql"
start-all-remote() {
    start-mysql-remote && start-runtime-remote && start-http
}


echo
echo "    * Use 'stop-mysql' to stop just mysql service"
stop-mysql() {
    hab svc unload core/mysql
    hab svc unload jarvus/mysql-remote
}

echo "    * Use 'stop-runtime' to stop just runtime service"
stop-runtime() {
    hab svc unload emergence/php-runtime
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
    hab pkg exec core/mysql mysql -u root -h 127.0.0.1 "${1:-default}"
}
shell-mysql-local() {
    >&2 echo "warning: shell-mysql-local has been shortened to shell-mysql"
    >&2 echo
    shell-mysql "$@"
}

echo "    * Use 'shell-mysql-remote' to open a mysql shell for the remote mysql service"
shell-mysql-remote() {
    hab pkg exec core/mysql mysql --defaults-extra-file=/hab/svc/mysql-remote/config/client.cnf "${1:-default}"
}

echo "    * Use 'shell-runtime' to open a php shell for the studio runtime service"
shell-runtime() {
    hab pkg exec emergence/studio psysh
}


echo "    * Use 'load-sql [file...|URL|site]' to load one or more .sql files into the local mysql service"
load-sql() {
    LOAD_SQL_MYSQL="hab pkg exec core/mysql mysql -u root -h 127.0.0.1"

    DATABASE_NAME="${2:-default}"
    echo "CREATE DATABASE IF NOT EXISTS \`${DATABASE_NAME}\`;" | $LOAD_SQL_MYSQL;
    LOAD_SQL_MYSQL="${LOAD_SQL_MYSQL} ${DATABASE_NAME}"

    if [[ "${1}" =~ ^https?://[^/]+/?$ ]]; then
        printf "Developer username: "
        read LOAD_SQL_USER
        wget --user="${LOAD_SQL_USER}" --ask-password "${1%/}/site-admin/database/dump.sql" -O - | $LOAD_SQL_MYSQL
    elif [[ "${1}" =~ ^https?://[^/]+/.+ ]]; then
        wget "${1}" -O - | $LOAD_SQL_MYSQL
    else
        cat "${1:-/hab/svc/php-runtime/var/site-data/seed.sql}" | $LOAD_SQL_MYSQL
    fi
}
load-sql-local() {
    >&2 echo "warning: load-sql-local has been shortened to load-sql"
    >&2 echo
    load-sql "$@"
}


echo "    * Use 'promote-user <username> [account_level]' to promote a user in the database"
promote-user() {
    echo "UPDATE people SET AccountLevel = '${2:-Developer}' WHERE Username = '${1}'" | hab pkg exec core/mysql mysql -u root -h 127.0.0.1 "${3:-default}"
}

echo "    * Use 'reset-database [database_name]' to drop and recreate the MySQL database"
reset-mysql() {
    echo "DROP DATABASE IF EXISTS \`"${1:-default}"\`; CREATE DATABASE \`"${1:-default}"\`;" | hab pkg exec core/mysql mysql -u root -h 127.0.0.1
}


echo
echo "--> Setting up development commands..."

echo "    * Use 'switch-site <repo_path>' to switch environment to running a different site repository"
switch-site() {
    if [ -d "$1" ]; then
        export EMERGENCE_REPO="$( cd "$1" && pwd)"
        "-write-php-runtime-config"
    else
        >&2 echo "error: $1 does not exist"
    fi
}

echo "    * Use 'update-site' to update the running site from ${EMERGENCE_REPO}#${EMERGENCE_HOLOBRANCH}"
update-site() {
    pushd "${EMERGENCE_REPO}" > /dev/null
    git holo project "${EMERGENCE_HOLOBRANCH}" --working ${EMERGENCE_FETCH:+--fetch} | emergence-php-load --stdin
    popd > /dev/null
}

echo "    * Use 'watch-site' to watch the running site in ${EMERGENCE_REPO}#${EMERGENCE_HOLOBRANCH}"
watch-site() {
    pushd "${EMERGENCE_REPO}" > /dev/null
    git holo project "${EMERGENCE_HOLOBRANCH}" --working --watch ${EMERGENCE_FETCH:+--fetch} | xargs -n 1 emergence-php-load
    popd > /dev/null
}


# overall instructions
echo
echo "    For a complete studio debug environment:"
echo "      start-all # wait a moment for services to start up"
echo "      update-site # or watch-site"


# final blank line
export EMERGENCE_STUDIO="loaded"
echo
