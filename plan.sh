pkg_name=studio
pkg_origin=emergence
pkg_version="0.2.1"
pkg_maintainer="Chris Alfano <chris@jarv.us>"
pkg_license=("MIT")
pkg_deps=(
  core/composer
  core/perl # needed by bin/emergence-studio-fsmonitor
  jarvus/hologit
  jarvus/watchman
  emergence/php-runtime
  emergence/php5
  emergence/nginx
)

pkg_bin_dirs=(
  bin
  vendor/bin
)


do_build() {
  pushd "${PLAN_CONTEXT}" > /dev/null
  cp -r bin "${CACHE_PATH}/"
  cp composer.{json,lock} "${CACHE_PATH}/"
  popd > /dev/null

  pushd "${CACHE_PATH}" > /dev/null

  fix_interpreter bin/emergence-studio-fsmonitor core/perl bin/perl

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
