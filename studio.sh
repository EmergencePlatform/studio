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


# load studio toolkit
source "$(hab pkg path jarvus/studio-toolkit)/studio.sh"


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
echo "--> Configuring git..."
export GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
git config --global core.untrackedCache true
git config --global core.fsmonitor "$(hab pkg path jarvus/rs-git-fsmonitor)/bin/rs-git-fsmonitor"
git config --global user.name "Chef Habitat Studio"
git config --global user.email "chef-habitat@studio"

echo
echo "--> Configuring services for local development..."

studio-svc-config nginx '
    [http.listen]
    port = 80
'

studio-svc-config mysql '
    app_username = "admin"
    app_password = "admin"
    bind = "0.0.0.0"
'

studio-svc-config mysql-remote '
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

    studio-svc-config --force ${EMERGENCE_RUNTIME#*/} "${runtime_config}"

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


##
## SERVICE TOOLS
##

STUDIO_HELP['start-mysql [pkg] [db]']="Load MySQL database service"
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

STUDIO_HELP['start-mysql-remote [db]']="Load connection to remote MySQL database service"
start-mysql-remote() {
    "${EDITOR:-vim}" "/hab/user/mysql-remote/config/user.toml"
    start-mysql "jarvus/mysql-remote" "${1}"
}

STUDIO_HELP['start-runtime [pkg]']="Load runtime service"
# shellcheck disable=SC2120
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

STUDIO_HELP['start-http']="Load HTTP service"
# shellcheck disable=SC2120
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

STUDIO_HELP['start-all']="Load all services"
start-all() {
    start-mysql && start-runtime && start-http
}


STUDIO_HELP['stop-mysql']="Unload MySQL services"
stop-mysql() {
    hab svc unload "${DB_SERVICE}"
}

STUDIO_HELP['stop-runtime']="Unload runtime services"
stop-runtime() {
    hab svc unload "${EMERGENCE_RUNTIME}"
}

STUDIO_HELP['stop-http']="Unload HTTP services"
stop-http() {
    hab svc unload emergence/nginx
}

STUDIO_HELP['stop-all']="Unload all services"
stop-all() {
    stop-http
    stop-runtime
    stop-mysql
}


##
## STUDIO CONFIGURATION
##

STUDIO_HELP['enable-xdebug <debugger_host>']="Enable PHP Xdebug and configure to connect to given host"
enable-xdebug() {
    export XDEBUG_HOST="${1:-127.0.0.1}"
    if [ -n "${EMERGENCE_RUNTIME}" ]; then
        "-write-runtime-config"
    fi
    echo "enabled Xdebug with remote debugger: ${XDEBUG_HOST}"
}

STUDIO_HELP['enable-runtime-update']="Enable updating site-specific runtime builds with new site code via \`update-site\` and \`watch-site\`"
enable-runtime-update() {
    export EMERGENCE_SITE_GIT_DIR="${EMERGENCE_REPO}/.git"
    "-write-runtime-config"
    echo "enabled updating ${EMERGENCE_RUNTIME} from ${EMERGENCE_SITE_GIT_DIR}"
}

STUDIO_HELP['enable-email [pkg=jarvus/postfix]']="Install a local MTA for queuing/relaying/delivering email and configure the current runtime to use it"
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

STUDIO_HELP['enable-email-relay <host> <port> <username> [password]']="Configure MTA to relay"
enable-email-relay() {
    if [ -z "${1}" ] || [ -z "${2}" ] || [ -z "${3}" ]; then
        echo >&2 'Usage: enable-email-relay <host> <port> <username> [password]'
        return 1
    fi

    studio-svc-config --force postfix "
        relayhost = '[${1}]:${2}'

        [smtp.sasl]
        password_maps = 'static:${3}:${4}'
    "
}


##
## SHELL TOOLS
##

STUDIO_HELP['shell-mysql']="Open a MySQL shell for the active MySQL service"
shell-mysql() {
    hab pkg exec "${DB_SERVICE}" mysql "${1:-$DB_DATABASE}" "$@"
}

STUDIO_HELP['shell-runtime']="Open a PHP shell for the active runtime service"
shell-runtime() {
    hab pkg exec emergence/studio psysh "$@"
}

STUDIO_HELP['load-sql [-|file...|URL|site] [database]']="Load one or more .sql files into the active MySQL service"
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

STUDIO_HELP['dump-sql [database] > file.sql']="Dump active MySQL database to SQL"
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

STUDIO_HELP['promote-user <username> [account_level]']="Promote a user in the database"
promote-user() {
    echo "UPDATE people SET AccountLevel = '${2:-Developer}' WHERE Username = '${1}'" | hab pkg exec "${DB_SERVICE}" mysql "${3:-$DB_DATABASE}"
}

STUDIO_HELP['reset-database [database_name]']="Drop and recreate the active MySQL database"
reset-mysql() {
    echo "DROP DATABASE IF EXISTS \`"${1:-$DB_DATABASE}"\`; CREATE DATABASE \`"${1:-$DB_DATABASE}"\`;" | hab pkg exec "${DB_SERVICE}" mysql
}

STUDIO_HELP['console-run <command> [args...]']="Execute a console command within the current runtime instance"
console-run() {
    local console_command="${1}"
    shift
    [ -z "$console_command" ] && { echo >&2 'Usage: console-run <command> [args...]'; return 1; }

    hab pkg exec "${EMERGENCE_RUNTIME}" emergence-console-run "${console_command}" "$@"
}


##
## SITE TOOLS
##

STUDIO_HELP['switch-site <repo_path>']="Switch environment to running a different site repository"
switch-site() {
    if [ -d "$1" ]; then
        export EMERGENCE_REPO="$( cd "$1" && pwd)"
        "-write-runtime-config"
    else
        >&2 echo "error: $1 does not exist"
    fi
}

STUDIO_HELP['update-site']="Update the running site from configured repo+holobranch"
update-site() {
    >&2 echo "Projecting ${EMERGENCE_REPO}#${EMERGENCE_HOLOBRANCH}"

    pushd "${EMERGENCE_REPO}" > /dev/null

    local previous_tree="${EMERGENCE_LOADED_TREE}"
    export EMERGENCE_LOADED_TREE=$(git holo project "${EMERGENCE_HOLOBRANCH}" --working ${EMERGENCE_FETCH:+--fetch})

    hab pkg exec "${EMERGENCE_RUNTIME}" emergence-php-load "${EMERGENCE_LOADED_TREE}"

    if [ -n "${previous_tree}" ]; then
        git diff --stat "${previous_tree}" "${EMERGENCE_LOADED_TREE}"
    fi

    popd > /dev/null
}

STUDIO_HELP['watch-site']="Watch for file changes and automatically update the running site from configured repo+holobranch"
watch-site() {
    >&2 echo "Watching ${EMERGENCE_REPO}#${EMERGENCE_HOLOBRANCH}"

    pushd "${EMERGENCE_REPO}" > /dev/null
    git holo project "${EMERGENCE_HOLOBRANCH}" --working --watch ${EMERGENCE_FETCH:+--fetch} | xargs -n 1 hab pkg exec "${EMERGENCE_RUNTIME}" emergence-php-load
    popd > /dev/null
}


## final init and output
if [ -z "${STUDIO_NOHELP}" ]; then
    studio-help
fi


# overall instructions
echo
echo "    For a complete studio debug environment:"
echo "      start-all # wait a moment for services to start up"
echo "      update-site # or watch-site"


# final blank line
export EMERGENCE_STUDIO="loaded"
echo
