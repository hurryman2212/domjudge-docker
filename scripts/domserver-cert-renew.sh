#!/usr/bin/env bash

set -Eeuo pipefail

readonly LOG_PREFIX=certificate
# shellcheck source=scripts/common.sh
source /usr/local/lib/domjudge/common.sh

readonly CERT_DIR=/opt/domjudge/certs
CERT_NAME=''

validate_method() {
	case "$1" in
	certbot-zerossl | certbot-letscrypt | acme-zerossl | acme-letscrypt) ;;
	*) die "unsupported active certificate: $1" ;;
	esac
}

renew_certbot() {
	local method="$1"
	local directory="${CERT_DIR}/${method}"
	local config_dir="${directory}/certbot/config"
	local work_dir="${directory}/certbot/work"
	local logs_dir="${directory}/certbot/logs"
	local live_dir="${config_dir}/live/${CERT_NAME}"

	run_with_retry 'Certbot renewal' certbot renew \
		--non-interactive \
		--cert-name "$CERT_NAME" \
		--config-dir "$config_dir" \
		--work-dir "$work_dir" \
		--logs-dir "$logs_dir" || return 1
	run_with_retry 'Certbot fullchain installation' install -m 0644 \
		"${live_dir}/fullchain.pem" \
		"${directory}/fullchain.pem" || return 1
	run_with_retry 'Certbot private key installation' install -m 0600 \
		"${live_dir}/privkey.pem" \
		"${directory}/privkey.pem" || return 1
}

run_acme_renew() {
	local status=0

	/usr/local/bin/acme.sh --renew "$@" || status=$?
	((status == 0 || status == 2))
}

renew_acme() {
	local method="$1"
	local directory="${CERT_DIR}/${method}"
	local acme_home="${directory}/acme"
	local server

	case "$method" in
	acme-zerossl) server=zerossl ;;
	acme-letscrypt) server=letsencrypt ;;
	*) return 1 ;;
	esac

	run_with_retry 'acme.sh renewal' run_acme_renew \
		-d "$CERT_NAME" --ecc \
		--home "$acme_home" \
		--server "$server" || return 1
	run_with_retry 'acme.sh certificate installation' /usr/local/bin/acme.sh \
		--install-cert \
		-d "$CERT_NAME" \
		--ecc \
		--home "$acme_home" \
		--key-file "${directory}/privkey.pem" \
		--fullchain-file "${directory}/fullchain.pem" || return 1
}

main() {
	local method
	local directory

	[[ -r "${CERT_DIR}/.active" ]] ||
		die "missing active certificate marker: ${CERT_DIR}/.active"
	method="$(<"${CERT_DIR}/.active")"
	if [[ "$method" == user ]]; then
		log 'user certificate is active; renewal is not required'
		exit 0
	fi
	validate_method "$method"
	directory="${CERT_DIR}/${method}"
	[[ -s "${directory}/.name" && -s "${directory}/.hosts" ]] ||
		die "missing certificate target records for $method; run domserver-switch-cert $method"
	CERT_NAME="$(<"${directory}/.name")"
	DOMSERVER_HOSTS="$(<"${directory}/.hosts")"
	normalize_hosts
	[[ -e "${directory}/.inited" ]] ||
		die "certificate method is not initialized: $method"

	case "$method" in
	certbot-zerossl | certbot-letscrypt) with_nginx_stopped renew_certbot "$method" ;;
	acme-zerossl | acme-letscrypt) with_nginx_stopped renew_acme "$method" ;;
	esac
	pair_matches_hosts "${directory}/fullchain.pem" "${directory}/privkey.pem" ||
		die "renewed certificate pair is invalid: $method"
	touch "${directory}/.inited"
	log "${method} renewal completed"
}

main "$@"
