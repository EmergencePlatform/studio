#!/bin/bash


echo
echo "Welcome to Emergence Studio!"


# detect environment
export EMERGENCE_STUDIO="loading"
if [ -z "${EMERGENCE_REPO}" ]; then
    EMERGENCE_REPO="$( cd "$( dirname "${BASH_SOURCE[1]}" )" && pwd)"
    EMERGENCE_REPO="${EMERGENCE_REPO:-/src}"
fi
echo "Site: ${EMERGENCE_REPO}"
export EMERGENCE_REPO

export EMERGENCE_HOLOBRANCH="${EMERGENCE_HOLOBRANCH:-emergence-site}"


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
  echo "Linked ${HAB_BINLINK_DIR:-/bin}/git-holo to src/hologit/bin/cli.js"
else
  hab pkg binlink jarvus/hologit
fi


echo
echo "--> Populating common commands"
hab pkg binlink core/git
hab pkg binlink jarvus/watchman
hab pkg binlink emergence/php-runtime
mkdir -m 777 -p /hab/svc/watchman/var


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
    config_pkg_name="$1"
    config_default="$2"
    [ -z "$config_pkg_name" -o -z "$config_default" ] && { echo >&2 'Usage: init-user-config pkg_name "[default]\nconfig = value"'; return 1; }

    config_toml_path="/hab/user/${config_pkg_name}/config/user.toml"

    if [ ! -f "$config_toml_path" ]; then
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


echo

echo "    * Use 'start-mysql-local' to start local mysql service"
start-mysql-local() {
    stop-mysql
    hab svc load core/mysql \
        --strategy at-once
}

echo "    * Use 'start-mysql-remote' to start remote mysql service"
start-mysql-remote() {
    stop-mysql
    hab svc load jarvus/mysql-remote \
        --strategy at-once
}

echo "    * Use 'start-runtime-local' to start runtime service bound to local mysql"
start-runtime-local() {
    hab svc load "emergence/php-runtime" \
        --bind=database:mysql.default \
        --strategy at-once
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

echo "    * Use 'start-all-local' to start all services individually with local mysql"
start-all-local() {
    start-mysql-local && start-runtime-local && start-http
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

echo "    * Use 'shell-mysql-local' to open a mysql shell for the local mysql service"
shell-mysql-local() {
    hab pkg exec core/mysql mysql -u root -h 127.0.0.1
}

echo "    * Use 'shell-mysql-remote' to open a mysql shell for the remote mysql service"
shell-mysql-remote() {
    hab pkg exec core/mysql mysql --defaults-extra-file=/hab/svc/mysql-remote/config/client.cnf
}

echo "    * Use 'shell-runtime' to open a php shell for the studio runtime service"
shell-runtime() {
    hab pkg exec emergence/studio psysh
}


echo "    * Use 'load-sql-local [file...]' to load one or more .sql files into the local mysql service"
load-sql-local() {
    cat "${1:-/hab/svc/php-runtime/var/site-data/seed.sql}" | hab pkg exec core/mysql mysql -u root -h 127.0.0.1
}


echo
echo "--> Setting up development commands..."
if [ -f /src/emergence-php-core/composer.json ]; then
    echo "    Using php-core from /src/emergence-php-core"

    pushd /src/emergence-php-core > /dev/null
    COMPOSER_ALLOW_SUPERUSER=1 hab pkg exec core/composer composer install
    popd > /dev/null

    init-user-config php-runtime "
        [core]
        root = \"/src/emergence-php-core\"

        [sites.default.holo]
        gitDir = \"${EMERGENCE_REPO}/.git\"
    "
else
    init-user-config php-runtime "
        [sites.default.holo]
        gitDir = \"${EMERGENCE_REPO}/.git\"
    "
fi

echo "    * Use 'update-site' to update the running site from ${EMERGENCE_REPO}#${EMERGENCE_HOLOBRANCH}"
update-site() {
    pushd "${EMERGENCE_REPO}" > /dev/null
    git holo project "${EMERGENCE_HOLOBRANCH}" --working | emergence-php-load --stdin
    popd > /dev/null
}

echo "    * Use 'watch-site' to watch the running site in ${EMERGENCE_REPO}#${EMERGENCE_HOLOBRANCH}"
watch-site() {
    pushd "${EMERGENCE_REPO}" > /dev/null
    git holo project "${EMERGENCE_HOLOBRANCH}" --working --watch | xargs -n 1 emergence-php-load
    popd > /dev/null
}


# overall instructions
echo
echo "    For a complete studio debug environment:"
echo "      start-all-local && watch-site"


# final blank line
export EMERGENCE_STUDIO="loaded"
echo
