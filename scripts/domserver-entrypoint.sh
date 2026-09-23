#!/usr/bin/env bash

set -Eeuo pipefail

readonly LOG_PREFIX=domserver
# shellcheck source=scripts/common.sh
source /usr/local/lib/domjudge/common.sh

readonly DOMSERVER_ROOT=/opt/domjudge/domserver
readonly DOMSERVER_TEMPLATE=/usr/local/share/domjudge/domserver-root
readonly SETUP_CONFIG_DIR=/opt/domjudge/setup_config
readonly BOOTSTRAP_MARKER="${DOMSERVER_ROOT}/.inited"
readonly PHP_VERSION=8.3
DB_HOST="${DOMSERVER_MARIADB_ADDR-127.0.0.1}"
if [[ "${DB_HOST,,}" == localhost ]]; then
	DB_HOST=127.0.0.1
fi
readonly DB_HOST
readonly DB_PORT="${DOMSERVER_MARIADB_PORT-3306}"
readonly DB_NAME=domjudge
readonly DB_USER=domjudge
readonly TIMEZONE=Asia/Seoul
readonly FPM_MAX_CHILDREN=40
readonly FPM_MEMORY_LIMIT=2G

archive_setup_inputs() {
	local name
	local source_file
	local target
	local value

	mkdir -p "$SETUP_CONFIG_DIR"
	for name in domserver-db-root-password domserver-db-password \
		judgehost-domserver-password domserver-admin-username domserver-admin-password; do
		source_file="/run/secrets/${name//-/_}"
		target="${SETUP_CONFIG_DIR}/${name}"
		if [[ -e "$source_file" ]]; then
			[[ -f "$source_file" && -r "$source_file" && -s "$source_file" ]] ||
				die "empty or unreadable setup secret: $source_file"
			install -m 0600 "$source_file" "$target"
		fi
		[[ -f "$target" && -r "$target" && -s "$target" ]] ||
			die "missing or empty setup file: $target"
		value="$(<"$target")"
		[[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] ||
			die "setup file must contain one non-empty line: $target"
	done
}

validate_environment() {
	local bind_addr="${DOMSERVER_BIND_ADDR-*}"
	local error

	normalize_hosts
	if [[ "$bind_addr" != '*' ]] && ! is_ip "$bind_addr"; then
		die 'DOMSERVER_BIND_ADDR must be an IPv4/IPv6 address or *'
	fi
	validate_web_ports
	if [[ -n "${DOMSERVER_HTTPS_PORT-443}" ]]; then
		error="$(certificate_method_error "${DOMSERVER_CERT:-auto}")"
		[[ -z "$error" ]] || die "$error"
	fi
}

sync_domserver_root() {
	local admin_username="$1"
	mkdir -p "$DOMSERVER_ROOT"
	rsync -a \
		--exclude='/etc/*.secret' \
		--exclude='/log/' \
		--exclude='/run/' \
		--exclude='/tmp/' \
		--exclude='/webapp/var/' \
		"${DOMSERVER_TEMPLATE}/" "${DOMSERVER_ROOT}/"
	# Recognize the original administrator after its username has changed.
	sed -i \
		-e "s/findOneBy(\['username' => 'admin'\])/findOneBy(['externalid' => 'admin'])/" \
		-e "s#->setUsername('admin')#->setUsername('${admin_username}')#" \
		-e "s/trim(\$adminpasswordContents)/rtrim(\$adminpasswordContents, \"\\\\r\\\\n\")/" \
		"${DOMSERVER_ROOT}/webapp/src/DataFixtures/DefaultData/UserFixture.php"
}

configure_base_url() {
	local placeholder=https://domserver.invalid/
	local base_url
	local scheme=http
	local port="${DOMSERVER_HTTP_PORT-80}"
	local file

	if [[ -n "${DOMSERVER_HTTPS_PORT-443}" &&
		"${DOMSERVER_HTTPS_REDIRECT_TO_HTTP:-false}" == false ]]; then
		scheme=https
		port="${DOMSERVER_HTTPS_PORT-443}"
	fi
	base_url="${scheme}://$(url_host "${DOMSERVER_HOST_LIST[0]}")"
	if [[ "$scheme" == http && "$port" != 80 ||
		"$scheme" == https && "$port" != 443 ]]; then
		base_url+=":${port}"
	fi
	base_url+=/
	while IFS= read -r -d '' file; do
		sed -i "s#${placeholder}#${base_url}#g" "$file"
	done < <(
		grep -RIlZ --binary-files=without-match "$placeholder" \
			"$DOMSERVER_ROOT" || true
	)
}

configure_timezone() {
	ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
	printf '%s\n' "$TIMEZONE" >/etc/timezone
	dpkg-reconfigure --frontend noninteractive tzdata >/dev/null
}

configure_php() {
	local php_ini="/etc/php/${PHP_VERSION}/fpm/conf.d/99-domserver-container.ini"
	local fpm_pool="/etc/php/${PHP_VERSION}/fpm/pool.d/domjudge.conf"

	install -m 0644 "${DOMSERVER_ROOT}/etc/domjudge-fpm.conf" "$fpm_pool"
	cat >"$php_ini" <<EOF
[Date]
date.timezone = ${TIMEZONE}
memory_limit = ${FPM_MEMORY_LIMIT}
upload_max_filesize = 256M
post_max_size = 256M
max_file_uploads = 101
EOF

	sed -ri \
		-e "s/^pm\.max_children[[:space:]]*=.*/pm.max_children = ${FPM_MAX_CHILDREN}/" \
		-e "s/^php_admin_value\[memory_limit\].*/php_admin_value[memory_limit] = ${FPM_MEMORY_LIMIT}/" \
		"$fpm_pool"
}

configure_nginx() {
	local http_port="${DOMSERVER_HTTP_PORT-80}"
	local https_port="${DOMSERVER_HTTPS_PORT-443}"
	local redirect_to_http="${DOMSERVER_HTTPS_REDIRECT_TO_HTTP:-false}"
	local bind_addr="${DOMSERVER_BIND_ADDR-*}"
	local scheme port flags redirect address host
	local -a server_names=()
	local -a addresses=("$bind_addr")

	case "$bind_addr" in
	'*') addresses=(0.0.0.0 '[::]') ;;
	*:*) addresses=("[${bind_addr}]") ;;
	esac
	for host in "${DOMSERVER_HOST_LIST[@]}"; do
		server_names+=("$(url_host "$host")")
	done
	mkdir -p /etc/nginx/sites-enabled
	{
		cat <<'EOF'
upstream domjudge_php {
    server unix:/var/run/php-fpm-domjudge.sock;
}

map $http_x_forwarded_proto $fastcgi_param_https_variable {
    default $https;
    https on;
}

server {
    listen 127.0.0.1:8080;
    listen [::1]:8080;
    server_name domserver;
    include /etc/nginx/domserver-app.conf;
}
EOF
		if [[ -n "${DOMSERVER_RESTRICT_HOSTS+x}" ]]; then
			printf "map \$host \$domserver_host_allowed {\n    default 0;\n"
			printf '    "%s" 1;\n' "${server_names[@]}"
			printf '}\n'
		fi
		for scheme in http https; do
			flags=''
			redirect=''
			if [[ "$scheme" == http ]]; then
				port="$http_port"
				if [[ -n "$https_port" && "$redirect_to_http" == false ]]; then
					redirect="https://\$host"
					[[ "$https_port" == 443 ]] || redirect+=":${https_port}"
				fi
			else
				port="$https_port"
				flags=' ssl'
				if [[ "$redirect_to_http" == true ]]; then
					redirect="http://\$host"
					[[ "$http_port" == 80 ]] || redirect+=":${http_port}"
				fi
			fi
			[[ -n "$port" ]] || continue
			printf 'server {\n'
			for address in "${addresses[@]}"; do
				printf '    listen %s:%s%s default_server;\n' "$address" "$port" "$flags"
			done
			printf '    server_name %s;\n' "${server_names[*]}"
			if [[ -n "${DOMSERVER_RESTRICT_HOSTS+x}" ]]; then
				printf "    if (\$domserver_host_allowed = 0) { return 403; }\n"
			fi
			if [[ "$scheme" == https ]]; then
				cat <<'EOF'
    ssl_certificate /opt/domjudge/certs/domserver.fullchain.pem;
    ssl_certificate_key /opt/domjudge/certs/domserver.privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
EOF
			fi
			if [[ -n "$redirect" ]]; then
				printf "    return 301 %s\$request_uri;\n" "$redirect"
			else
				printf '    include /etc/nginx/domserver-app.conf;\n'
			fi
			printf '}\n'
		done
	} >/etc/nginx/sites-enabled/default
}

write_database_secret() {
	umask 077
	printf 'docker:%s:%s:%s:%s:%s\n' \
		"$DB_HOST" \
		"$DB_NAME" \
		"$DB_USER" \
		"${DOMSERVER_DB_PASSWORD}" \
		"$DB_PORT" \
		>"${DOMSERVER_ROOT}/etc/dbpasswords.secret"
	chown www-data:www-data "${DOMSERVER_ROOT}/etc/dbpasswords.secret"
}

generate_domjudge_secrets() {
	local restapi_file="${DOMSERVER_ROOT}/etc/restapi.secret"

	install -m 0600 "${SETUP_CONFIG_DIR}/domserver-admin-password" \
		"${DOMSERVER_ROOT}/etc/initial_admin_password.secret"

	if [[ ! -s "$restapi_file" ||
		! -s "${DOMSERVER_ROOT}/etc/symfony_app.secret" ||
		! -s "${DOMSERVER_ROOT}/etc/initial_admin_password.secret" ]]; then
		(
			cd "${DOMSERVER_ROOT}/etc"
			./gen_all_secrets
		)
	fi

	printf 'default\thttp://domserver:8080/api/v4\t%s\t%s\n' \
		judgehost \
		"${DOMSERVER_JUDGEHOST_PASSWORD}" \
		>"$restapi_file"

	chown www-data:www-data \
		"$restapi_file" \
		"${DOMSERVER_ROOT}/etc/symfony_app.secret" \
		"${DOMSERVER_ROOT}/etc/initial_admin_password.secret"
	chmod 600 \
		"$restapi_file" \
		"${DOMSERVER_ROOT}/etc/symfony_app.secret" \
		"${DOMSERVER_ROOT}/etc/initial_admin_password.secret"
}

wait_for_database() {
	local attempt

	for attempt in $(seq 1 60); do
		if mariadb \
			--protocol=tcp \
			--host="$DB_HOST" \
			--port="$DB_PORT" \
			--user="$DB_USER" \
			--password="${DOMSERVER_DB_PASSWORD}" \
			--database="$DB_NAME" \
			--execute='SELECT 1' >/dev/null 2>&1; then
			return
		fi
		log "waiting for MariaDB at ${DB_HOST}:${DB_PORT} (${attempt}/60)"
		sleep 2
	done
	die 'MariaDB is not available'
}

setup_database() {
	if "$DOMSERVER_ROOT/bin/dj_setup_database" \
		-u root -p "${DOMSERVER_DB_ROOT_PASSWORD}" status >/dev/null 2>&1; then
		log 'database is already installed; running upgrade'
		"$DOMSERVER_ROOT/bin/dj_setup_database" \
			-u root -p "${DOMSERVER_DB_ROOT_PASSWORD}" upgrade
	else
		log 'installing DOMjudge database'
		"$DOMSERVER_ROOT/bin/dj_setup_database" \
			-u root -p "${DOMSERVER_DB_ROOT_PASSWORD}" install
	fi
}

fix_permissions() {
	mkdir -p \
		"${DOMSERVER_ROOT}/tmp" \
		"${DOMSERVER_ROOT}/webapp/var/cache" \
		"${DOMSERVER_ROOT}/webapp/var/log" \
		"${DOMSERVER_ROOT}/webapp/public/images/affiliations" \
		"${DOMSERVER_ROOT}/webapp/public/images/banners" \
		"${DOMSERVER_ROOT}/webapp/public/images/countries" \
		"${DOMSERVER_ROOT}/webapp/public/images/teams"
	chown -R www-data:www-data \
		"${DOMSERVER_ROOT}/tmp" \
		"${DOMSERVER_ROOT}/webapp/var" \
		"${DOMSERVER_ROOT}/webapp/public/images/affiliations" \
		"${DOMSERVER_ROOT}/webapp/public/images/banners" \
		"${DOMSERVER_ROOT}/webapp/public/images/countries" \
		"${DOMSERVER_ROOT}/webapp/public/images/teams"
}

clear_php_cache() {
	runuser -u www-data -- env HOME=/tmp \
		"${DOMSERVER_ROOT}/webapp/bin/console" cache:clear --env=prod
}

configure_certificate() {
	if [[ -z "${DOMSERVER_HTTPS_PORT-443}" ]]; then
		log 'HTTPS is disabled; skipping certificate setup'
		return
	fi
	local name
	local source_file
	local -a args=("${DOMSERVER_CERT:-auto}")

	case "${DOMSERVER_CERT:-auto}" in
	auto | certbot-zerossl | acme-zerossl)
		for name in zerossl-eab-kid zerossl-hmac-key; do
			source_file="/run/secrets/${name//-/_}"
			if [[ -f "$source_file" && -r "$source_file" && -s "$source_file" ]]; then
				args+=("--${name}" "$(<"$source_file")")
			fi
		done
		;;
	esac
	/usr/local/bin/domserver-switch-cert "${args[@]}"
}

bootstrap() {
	local LC_ALL=C
	local DOMSERVER_DB_ROOT_PASSWORD
	local DOMSERVER_DB_PASSWORD
	local DOMSERVER_JUDGEHOST_PASSWORD
	local admin_username
	local admin_password

	[[ "$DB_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
		die 'DOMSERVER_MARIADB_ADDR must be a DNS name or IPv4 address; use a DNS name for IPv6'
	validate_port DOMSERVER_MARIADB_PORT "$DB_PORT"

	archive_setup_inputs
	DOMSERVER_DB_ROOT_PASSWORD="$(<"${SETUP_CONFIG_DIR}/domserver-db-root-password")"
	DOMSERVER_DB_PASSWORD="$(<"${SETUP_CONFIG_DIR}/domserver-db-password")"
	DOMSERVER_JUDGEHOST_PASSWORD="$(<"${SETUP_CONFIG_DIR}/judgehost-domserver-password")"
	admin_username="$(<"${SETUP_CONFIG_DIR}/domserver-admin-username")"
	admin_password="$(<"${SETUP_CONFIG_DIR}/domserver-admin-password")"
	[[ "$admin_username" =~ ^[A-Za-z0-9@._-]{1,255}$ &&
		"${admin_username,,}" != judgehost ]] || die 'invalid administrator username'
	((${#admin_password} <= 72)) || die 'administrator password exceeds 72 bytes'

	sync_domserver_root "$admin_username"
	configure_base_url
	configure_timezone
	configure_php
	configure_nginx
	configure_certificate
	write_database_secret
	generate_domjudge_secrets
	fix_permissions
	wait_for_database
	setup_database
	clear_php_cache
	nginx -t
	touch "$BOOTSTRAP_MARKER"
}

main() {
	if [[ ! -e "$BOOTSTRAP_MARKER" ]]; then
		validate_environment
		bootstrap
	fi
	nginx -t
	log 'starting systemd as PID 1'
	exec /sbin/init
}

main "$@"
