pkg_name=studio
pkg_origin=emergence
pkg_version="0.2.0"
pkg_maintainer="Chris Alfano <chris@jarv.us>"
pkg_license=("MIT")
pkg_deps=(
  jarvus/hologit
  jarvus/watchman
  emergence/php-runtime
  emergence/nginx
)


do_build() {
  return 0
}

do_install() {
  cp -v "${PLAN_CONTEXT}/studio.sh" "${pkg_prefix}/"
}

do_strip() {
  return 0
}
