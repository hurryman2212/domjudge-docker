#!/usr/bin/env bash

log() {
	printf '[%s] %s\n' "$LOG_PREFIX" "$*"
}

die() {
	log "ERROR: $*" >&2
	exit 1
}

validate_port() {
	local name="$1" value="$2"

	if [[ -z "$value" && "${3:-false}" == true ]]; then
		return
	fi
	if [[ ! "$value" =~ ^[0-9]{1,5}$ ]] ||
		((10#$value < 1 || 10#$value > 65535)); then
		die "$name must be a port number between 1 and 65535"
	fi
}

validate_web_ports() {
	local http_port="${DOMSERVER_HTTP_PORT-80}"
	local https_port="${DOMSERVER_HTTPS_PORT-443}"
	local redirect="${DOMSERVER_HTTPS_REDIRECT_TO_HTTP:-false}"
	local port

	validate_port DOMSERVER_HTTP_PORT "$http_port" true
	validate_port DOMSERVER_HTTPS_PORT "$https_port" true
	[[ -n "$http_port" || -n "$https_port" ]] ||
		die 'at least one of DOMSERVER_HTTP_PORT or DOMSERVER_HTTPS_PORT must be enabled'
	if [[ -n "$http_port" && -n "$https_port" ]] &&
		((10#$http_port == 10#$https_port)); then
		die 'DOMSERVER_HTTP_PORT and DOMSERVER_HTTPS_PORT must be different'
	fi
	for port in "$http_port" "$https_port"; do
		[[ -z "$port" ]] || ((10#$port != 8080)) ||
			die 'port 8080 is reserved for the internal API and healthcheck'
	done
	[[ "$redirect" == true || "$redirect" == false ]] ||
		die 'DOMSERVER_HTTPS_REDIRECT_TO_HTTP must be true or false'
	if [[ "$redirect" == true ]]; then
		[[ -n "$http_port" && -n "$https_port" ]] ||
			die 'HTTP and HTTPS must both be enabled for HTTPS redirect to HTTP'
	fi
}

is_ip() {
	php -r "exit(filter_var(\$argv[1], FILTER_VALIDATE_IP) === false ? 1 : 0);" "$1"
}

is_public_ip() {
	php -r "exit(filter_var(\$argv[1], FILTER_VALIDATE_IP, FILTER_FLAG_GLOBAL_RANGE) === false ? 1 : 0);" "$1"
}

canonical_ip() {
	php -r "echo inet_ntop(inet_pton(\$argv[1]));" "$1"
}

is_dns_name() {
	[[ ${#1} -le 253 && ! "$1" =~ ^[0-9.]+$ &&
		"$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]
}

discover_hosts() (
	local temporary_dir interfaces family iface response address name resolved type
	local running=0
	local -a responses=() addresses=() names=()
	local -A seen=()

	interfaces="$(ip -o address show up scope global)" ||
		die 'could not list network interfaces; set DOMSERVER_HOSTS explicitly'
	temporary_dir="$(mktemp -d /tmp/domjudge-discovery.XXXXXX)" || return 1
	trap 'rm -rf -- "$temporary_dir"' EXIT

	while read -r family iface; do
		response="${temporary_dir}/${#responses[@]}"
		responses+=("$response")
		(
			trap - EXIT
			if address="$(curl "$family" --interface "if!${iface}" --noproxy '*' \
				--fail --silent --connect-timeout 5 --max-time 10 --max-filesize 64 \
				https://api64.ipify.org)" && is_public_ip "$address"; then
				canonical_ip "$address" >"$response"
			fi
		) &
		running=$((running + 1))
		if ((running >= 8)); then
			wait -n || true
			running=$((running - 1))
		fi
	done < <(
		awk '$2 != "lo" && $0 !~ / (tentative|dadfailed) / {
			split($2, parts, "@"); $2 = parts[1]
			if ($3 == "inet") print "-4", $2
			if ($3 == "inet6") print "-6", $2
		}' <<<"$interfaces" | LC_ALL=C sort -u
	)
	wait || true

	for response in "${responses[@]}"; do
		[[ -s "$response" ]] || continue
		address="$(<"$response")"
		[[ -z "${seen[$address]+x}" ]] || continue
		seen[$address]=1
		addresses+=("$address")
	done
	((${#addresses[@]})) ||
		die 'could not detect a public IP on any interface; set DOMSERVER_HOSTS explicitly'

	for address in "${addresses[@]}"; do
		type=A
		if [[ "$address" == *:* ]]; then type=AAAA; fi
		while IFS= read -r name; do
			name="${name,,}"
			name="${name%.}"
			is_dns_name "$name" || continue
			[[ -z "${seen[$name]+x}" ]] || continue
			while IFS= read -r resolved; do
				is_ip "$resolved" || continue
				if [[ "$(canonical_ip "$resolved")" == "$address" ]]; then
					seen[$name]=1
					names+=("$name")
					break
				fi
			done < <(dig +short +time=2 +tries=1 "$name" "$type" 2>/dev/null || true)
		done < <(dig +short +time=2 +tries=1 -x "$address" 2>/dev/null || true)
	done
	log "discovered ${#addresses[@]} public IP(s) and ${#names[@]} verified DNS name(s)" >&2
	addresses+=("${names[@]}")
	IFS=,
	printf '%s\n' "${addresses[*]}"
)

normalize_hosts() {
	local input="${DOMSERVER_HOSTS-}" host
	local -a entries=()
	local -A seen=()

	[[ -n "$input" ]] || input="$(discover_hosts)"
	[[ "$input" != *$'\n'* && "$input" != *$'\r'* && "$input" != *, ]] ||
		die 'DOMSERVER_HOSTS must be a comma-separated list without empty entries'
	IFS=, read -r -a entries <<<"$input"
	DOMSERVER_HOST_LIST=()
	DOMSERVER_HAS_IP=0
	DOMSERVER_HAS_NONPUBLIC_IP=0
	for host in "${entries[@]}"; do
		host="${host#"${host%%[![:space:]]*}"}"
		host="${host%"${host##*[![:space:]]}"}"
		[[ -n "$host" ]] || die 'DOMSERVER_HOSTS contains an empty entry'
		if [[ "$host" == \[*\] ]]; then
			host="${host:1:${#host}-2}"
			if [[ "$host" != *:* ]] || ! is_ip "$host"; then
				die "invalid IPv6 address in DOMSERVER_HOSTS: [$host]"
			fi
		fi
		if is_ip "$host"; then
			host="$(canonical_ip "$host")"
			DOMSERVER_HAS_IP=1
			if ! is_public_ip "$host"; then
				DOMSERVER_HAS_NONPUBLIC_IP=1
			fi
		else
			host="${host,,}"
			host="${host%.}"
			is_dns_name "$host" ||
				die "invalid domain or IP address in DOMSERVER_HOSTS: $host"
		fi
		[[ -z "${seen[$host]+x}" ]] || continue
		seen[$host]=1
		DOMSERVER_HOST_LIST+=("$host")
	done
	printf -v DOMSERVER_HOSTS '%s,' "${DOMSERVER_HOST_LIST[@]}"
	DOMSERVER_HOSTS="${DOMSERVER_HOSTS%,}"
	export DOMSERVER_HOSTS
}

url_host() {
	if [[ "$1" == *:* ]]; then
		printf '[%s]' "$1"
	else
		printf '%s' "$1"
	fi
}

certificate_method_error() {
	case "$1" in
	auto | user) return 0 ;;
	certbot-zerossl | acme-zerossl)
		if ((DOMSERVER_HAS_IP)); then
			printf '%s\n' 'ZeroSSL ACME does not support IP targets; use certbot-letscrypt, acme-letscrypt, or user'
			return
		fi
		;;
	certbot-letscrypt | acme-letscrypt) ;;
	*)
		printf 'unsupported certificate selector: %s\n' "$1"
		return
		;;
	esac
	if ((DOMSERVER_HAS_NONPUBLIC_IP)); then
		printf '%s\n' 'ACME requires public IP addresses; use user for private or reserved IP addresses'
	fi
}

run_with_retry() {
	local description="$1"
	shift

	if "$@"; then return 0; fi
	log "$description failed; retrying once"
	if "$@"; then return 0; fi
	log "$description failed after one retry"
	return 1
}

pair_is_valid() {
	local cert="$1" key="$2"
	local cert_public_key key_public_key

	[[ -s "$cert" && -s "$key" ]] || return 1
	cert_public_key="$(openssl x509 -in "$cert" -pubkey -noout |
		openssl pkey -pubin -outform DER | sha256sum)" || return 1
	key_public_key="$(openssl pkey -in "$key" -pubout |
		openssl pkey -pubin -outform DER | sha256sum)" || return 1
	[[ "$cert_public_key" == "$key_public_key" ]]
}

pair_matches_hosts() {
	local cert="$1" key="$2" host option

	pair_is_valid "$cert" "$key" || return 1
	openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1 || return 1
	for host in "${DOMSERVER_HOST_LIST[@]}"; do
		option=-checkhost
		if is_ip "$host"; then option=-checkip; fi
		openssl x509 -in "$cert" "$option" "$host" -noout 2>/dev/null |
			grep -Fq ' does match certificate' || return 1
	done
}

with_nginx_stopped() {
	local running=0 result=0

	if pgrep --exact nginx >/dev/null 2>&1; then
		running=1
		systemctl stop domserver-nginx.service >/dev/null || result=1
	fi
	if ((result == 0)); then
		"$@" || result=$?
	else
		log 'could not stop nginx; restoring it'
	fi
	if ((running)); then
		if ! systemctl start domserver-nginx.service >/dev/null 2>&1 ||
			! systemctl is-active --quiet domserver-nginx.service; then
			die 'could not restore nginx after certificate operation'
		fi
	fi
	return "$result"
}
