echo "Welcome to Emergence Studio!"

hab pkg binlink jarvus/hologit
hab pkg binlink core/git
hab pkg binlink jarvus/watchman
mkdir -m 777 -p /hab/svc/watchman/var
