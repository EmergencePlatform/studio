pkg_name=studio
pkg_origin=emergence
pkg_version="0.5.0"
pkg_maintainer="Chris Alfano <chris@jarv.us>"
pkg_license=("MIT")
pkg_deps=(
  core/coreutils
  core/composer
  jarvus/rs-git-fsmonitor
  jarvus/hologit
  jarvus/watchman
  emergence/php-runtime
  emergence/php5
  emergence/nginx
)

pkg_bin_dirs=(vendor/bin)


do_build() {
  pushd "${PLAN_CONTEXT}" > /dev/null
  cp composer.{json,lock} "${CACHE_PATH}/"
  popd > /dev/null

  pushd "${CACHE_PATH}" > /dev/null

  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev  --no-interaction --optimize-autoloader --classmap-authoritative

  build_line "Fixing PHP bin scripts"
  find -L "vendor/bin" -type f -executable \
    -print \
    -exec bash -c 'sed -e "s#\#\!/usr/bin/env php#\#\!$1/bin/php#" --in-place "$(readlink -f "$2")"' _ "$(pkg_path_for php5)" "{}" \;

  popd > /dev/null

}

do_install() {
  cp -v "${PLAN_CONTEXT}/studio.sh" "${pkg_prefix}/"
  cp -r "${CACHE_PATH}/"* "${pkg_prefix}/"
}

do_strip() {
  return 0
}
