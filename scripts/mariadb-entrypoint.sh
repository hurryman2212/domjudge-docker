#!/usr/bin/env bash

set -Eeuo pipefail

readonly LOG_PREFIX=mariadb
# shellcheck source=scripts/common.sh
source /usr/local/lib/domjudge/common.sh

readonly ROOT_PASSWORD_FILE=/run/secrets/domserver_db_root_password
readonly DATABASE_PASSWORD_FILE=/run/secrets/domserver_db_password
readonly SETUP_CONFIG_DIR=/opt/domjudge/setup_config

copy_secret() {
	local source_file="$1"
	local target_file="$2"
	local value

	[[ -r "$source_file" ]] || die "missing secret file: $source_file"
	value="$(<"$source_file")"
	[[ -n "$value" ]] || die "empty secret file: $source_file"
	mkdir -p "$SETUP_CONFIG_DIR"
	install -m 0600 "$source_file" "$target_file"
}

main() {
	local bind_addr="${MARIADB_BIND_ADDR-127.0.0.1}"
	local bind_port="${MARIADB_BIND_PORT-3306}"

	(($#)) || set -- mariadbd
	if [[ "$1" == -* ]]; then
		set -- mariadbd "$@"
	fi
	if [[ "$1" != mariadbd && "$1" != mysqld ]]; then
		exec /usr/local/bin/docker-entrypoint.sh "$@"
	fi
	[[ -n "$bind_addr" && "$bind_addr" != *[[:space:]]* ]] ||
		die 'MARIADB_BIND_ADDR must be a non-empty local bind address'
	validate_port MARIADB_BIND_PORT "$bind_port"
	# The configured values also override legacy arguments on existing containers.
	set -- "$@" "--bind-address=${bind_addr}" "--port=${bind_port}"

	if [[ ! -d /var/lib/mysql/mysql ]]; then
		copy_secret "$ROOT_PASSWORD_FILE" \
			"${SETUP_CONFIG_DIR}/domserver-db-root-password"
		copy_secret "$DATABASE_PASSWORD_FILE" \
			"${SETUP_CONFIG_DIR}/domserver-db-password"
		export MARIADB_ROOT_PASSWORD_FILE="${SETUP_CONFIG_DIR}/domserver-db-root-password"
		export MARIADB_PASSWORD_FILE="${SETUP_CONFIG_DIR}/domserver-db-password"
		export MARIADB_ROOT_HOST='%'
		export MARIADB_DATABASE=domjudge
		export MARIADB_USER=domjudge
	fi
	exec /usr/local/bin/docker-entrypoint.sh "$@"
}

main "$@"
