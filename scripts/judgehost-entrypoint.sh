#!/usr/bin/env bash

set -Eeuo pipefail

readonly LOG_PREFIX=judgehost
# shellcheck source=scripts/common.sh
source /usr/local/lib/domjudge/common.sh

readonly JUDGEHOST_ROOT=/opt/domjudge/judgehost
readonly JUDGEHOST_TEMPLATE=/usr/local/share/domjudge/judgehost-root
readonly SETUP_CONFIG_DIR=/opt/domjudge/setup_config
readonly BOOTSTRAP_MARKER="${JUDGEHOST_ROOT}/.inited"
readonly CHROOT_DIR=/chroot/domjudge
readonly UNIT_TEMPLATE=/usr/local/share/domjudge/domjudge-judgedaemon@.service.template
readonly UNIT_FILE=/etc/systemd/system/domjudge-judgedaemon@.service
readonly UNIT_WANTS=/etc/systemd/system/multi-user.target.wants
readonly CHROOT_DISTRO=Ubuntu
readonly CHROOT_RELEASE=jammy
readonly CHROOT_MIRROR=https://ftp.kaist.ac.kr/ubuntu/
readonly RUN_USER_UID_GID=62860
readonly TIMEZONE=Asia/Seoul

declare -a CPU_IDS=()

load_secret_environment() {
	local secret_file=/run/secrets/judgehost_domserver_password

	[[ -r "$secret_file" ]] ||
		die "missing secret file: $secret_file"
	JUDGEHOST_DOMSERVER_PASSWORD="$(<"$secret_file")"
	[[ -n "$JUDGEHOST_DOMSERVER_PASSWORD" ]] ||
		die "empty secret file: $secret_file"
	mkdir -p "$SETUP_CONFIG_DIR"
	install -m 0600 "$secret_file" \
		"${SETUP_CONFIG_DIR}/judgehost-domserver-password"
}

validate_nonnegative_integer() {
	local name="$1"
	local value="$2"

	[[ "$value" =~ ^[0-9]+$ ]] ||
		die "${name} must be a non-negative integer"
}

select_cpu_ids() {
	local cpu_range="${JUDGEHOST_CPU_RANGE:-}"
	local first_cpu
	local last_cpu
	local cpu
	local count

	if [[ -z "$cpu_range" ]]; then
		count="$(nproc)"
		[[ "$count" =~ ^[1-9][0-9]*$ ]] ||
			die 'nproc did not return a positive integer'
		cpu_range="0-$((count - 1))"
		log "JUDGEHOST_CPU_RANGE is unset; using visible CPU range ${cpu_range}"
	fi
	[[ "$cpu_range" =~ ^([0-9]+)-([0-9]+)$ ]] ||
		die 'JUDGEHOST_CPU_RANGE must use the form FIRST-LAST'
	first_cpu="${BASH_REMATCH[1]}"
	last_cpu="${BASH_REMATCH[2]}"
	((first_cpu <= last_cpu)) ||
		die 'JUDGEHOST_CPU_RANGE must have FIRST no greater than LAST'

	for ((cpu = first_cpu; cpu <= last_cpu; cpu++)); do
		CPU_IDS+=("$cpu")
	done
}

sync_judgehost_root() {
	mkdir -p "$JUDGEHOST_ROOT"
	rsync -a \
		--exclude='/etc/restapi.secret' \
		--exclude='/judgings/' \
		--exclude='/log/' \
		--exclude='/run/' \
		--exclude='/tmp/' \
		"${JUDGEHOST_TEMPLATE}/" "${JUDGEHOST_ROOT}/"
}

prepare_judgehost_directories() {
	mkdir -p \
		"${JUDGEHOST_ROOT}/log" \
		"${JUDGEHOST_ROOT}/run" \
		"${JUDGEHOST_ROOT}/tmp" \
		"${JUDGEHOST_ROOT}/judgings"
	chown domjudge:domjudge \
		"${JUDGEHOST_ROOT}/log" \
		"${JUDGEHOST_ROOT}/run" \
		"${JUDGEHOST_ROOT}/tmp" \
		"${JUDGEHOST_ROOT}/judgings"
	chmod 0700 \
		"${JUDGEHOST_ROOT}/log" \
		"${JUDGEHOST_ROOT}/run" \
		"${JUDGEHOST_ROOT}/tmp"
	chmod 0711 "${JUDGEHOST_ROOT}/judgings"
}

create_run_users() {
	local base_uid="$RUN_USER_UID_GID"
	local index=0
	local cpu
	local uid
	local username

	validate_nonnegative_integer RUN_USER_UID_GID "$base_uid"
	if ! getent group domjudge-run >/dev/null; then
		groupadd --gid "$base_uid" domjudge-run
	fi

	for cpu in "${CPU_IDS[@]}"; do
		username="domjudge-run-${cpu}"
		if ! id --user "$username" >/dev/null 2>&1; then
			uid=$((base_uid + index))
			while getent passwd "$uid" >/dev/null; do
				uid=$((uid + 1))
			done
			useradd \
				--uid "$uid" \
				--no-user-group \
				--no-create-home \
				--home-dir /nonexistent \
				--gid domjudge-run \
				--shell /bin/false \
				"$username"
		fi
		usermod --gid domjudge-run "$username"
		index=$((index + 1))
	done
}

create_chroot() {
	local arch=''
	local -a args

	if [[ -z "$arch" ]]; then
		arch="$(dpkg --print-architecture)"
	fi
	args=(
		-D "$CHROOT_DISTRO"
		-R "$CHROOT_RELEASE"
		-a "$arch"
		-m "$CHROOT_MIRROR"
	)

	if [[ ! -d "${CHROOT_DIR}/etc" ]]; then
		log "creating submission chroot (${CHROOT_DISTRO} ${CHROOT_RELEASE}, ${arch})"
		"${JUDGEHOST_ROOT}/bin/dj_make_chroot" "${args[@]}"
	fi
	[[ -d "${CHROOT_DIR}/etc" ]] ||
		die "submission chroot was not created at ${CHROOT_DIR}"

	unlink "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true
	cp --dereference /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"
}

prepare_chroot_permissions() {
	chmod 0755 "${CHROOT_DIR%/*}" "$CHROOT_DIR"
}

domserver_base_url() {
	local host
	local http_port="${DOMSERVER_HTTP_PORT-80}"
	local https_port="${DOMSERVER_HTTPS_PORT-443}"
	local redirect_to_http="${DOMSERVER_HTTPS_REDIRECT_TO_HTTP:-false}"
	local scheme
	local port

	validate_web_ports
	if [[ -z "${DOMSERVER_HOSTS:-}" ]]; then
		printf '%s\n' 'http://127.0.0.1:8080/'
		return
	fi
	normalize_hosts
	host="$(url_host "${DOMSERVER_HOST_LIST[0]}")"

	if [[ "$redirect_to_http" == true && -n "$http_port" ]]; then
		scheme=http
		port="$http_port"
	elif [[ -n "$https_port" ]]; then
		scheme=https
		port="$https_port"
	else
		scheme=http
		port="$http_port"
	fi

	if [[ "$scheme" == https && "$port" == 443 ||
		"$scheme" == http && "$port" == 80 ]]; then
		printf '%s\n' "${scheme}://${host}/"
	else
		printf '%s\n' "${scheme}://${host}:${port}/"
	fi
}

write_restapi_secret() {
	local password="$JUDGEHOST_DOMSERVER_PASSWORD"
	local username=judgehost
	local base_url

	[[ -n "$password" ]] ||
		die 'JUDGEHOST_DOMSERVER_PASSWORD must be set'
	base_url="$(domserver_base_url)"

	base_url="${base_url%/}"
	umask 077
	printf 'default\t%s/api/v4\t%s\t%s\n' \
		"$base_url" "$username" "$password" \
		>"${JUDGEHOST_ROOT}/etc/restapi.secret"
	chown domjudge:domjudge "${JUDGEHOST_ROOT}/etc/restapi.secret"
	chmod 600 "${JUDGEHOST_ROOT}/etc/restapi.secret"
}

wait_for_domserver() {
	local base_url
	local attempt

	base_url="$(domserver_base_url)"
	for attempt in $(seq 1 60); do
		if curl \
			--fail \
			--silent \
			--insecure \
			--location \
			--max-time 10 \
			"$base_url" \
			>/dev/null 2>&1; then
			log "DOMserver is reachable at ${base_url}"
			return
		fi
		log "waiting for DOMserver at ${base_url} (${attempt}/60)"
		sleep 2
	done
	die "DOMserver did not become reachable at ${base_url}"
}

create_cgroups() {
	log 'initializing DOMjudge cgroups'
	"${JUDGEHOST_ROOT}/bin/create_cgroups"
}

install_daemon_units() {
	local writable=0
	local cpu

	sed "s/__CREATE_WRITABLE_TEMP_DIR__/${writable}/g" \
		"$UNIT_TEMPLATE" >"$UNIT_FILE"
	chmod 644 "$UNIT_FILE"
	mkdir -p "$UNIT_WANTS"
	find "$UNIT_WANTS" -maxdepth 1 -type l \
		-name 'domjudge-judgedaemon@*.service' -delete
	for cpu in "${CPU_IDS[@]}"; do
		ln -sfn "$UNIT_FILE" \
			"${UNIT_WANTS}/domjudge-judgedaemon@${cpu}.service"
	done
}

configure_timezone() {
	ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
	printf '%s\n' "$TIMEZONE" >/etc/timezone
	dpkg-reconfigure --frontend noninteractive tzdata >/dev/null
}

bootstrap() {
	local JUDGEHOST_DOMSERVER_PASSWORD

	load_secret_environment
	configure_timezone
	sync_judgehost_root
	prepare_judgehost_directories
	create_run_users
	create_chroot
	prepare_chroot_permissions
	write_restapi_secret
}

main() {
	domserver_base_url >/dev/null
	select_cpu_ids
	if [[ ! -e "$BOOTSTRAP_MARKER" ]]; then
		bootstrap
	fi
	create_cgroups
	install_daemon_units
	wait_for_domserver
	if [[ ! -e "$BOOTSTRAP_MARKER" ]]; then
		touch "$BOOTSTRAP_MARKER"
	fi
	log "starting ${#CPU_IDS[@]} judgedaemon systemd instance(s): ${CPU_IDS[*]}"
	exec /sbin/init
}

main "$@"
