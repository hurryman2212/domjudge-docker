#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_FILES=(
	domserver-db-root-password
	domserver-db-password
	judgehost-domserver-password
	domserver-admin-username
	domserver-admin-password
)
readonly EAB_FILES=(
	zerossl-eab-kid
	zerossl-hmac-key
)

die() {
	printf '[passwords] ERROR: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat >&2 <<'EOF'
usage:
  create-passwords.sh [--preserve] [--admin-name VALUE] \
    [--admin-password VALUE] [--zerossl-eab-kid VALUE] \
    [--zerossl-hmac-key VALUE]

Without --preserve, overwrite the database, judgehost, and admin files.
With --preserve, create only missing files. An explicit value for an existing
file is an error. ZeroSSL files are written only when their option is supplied.
EOF
	exit 2
}

existing_file_error() {
	die "$1 already exists; delete it and run this command again."
}

main() {
	local preserve=0
	local file
	local temporary_dir
	local -a files=("${DEFAULT_FILES[@]}")
	local -a write_files=()
	local -A values=(["domserver-admin-username"]=admin)
	local -A supplied=()

	while (($#)); do
		case "$1" in
		--preserve)
			preserve=1
			shift
			continue
			;;
		--admin-name) file=domserver-admin-username ;;
		--admin-password) file=domserver-admin-password ;;
		--zerossl-eab-kid) file=zerossl-eab-kid ;;
		--zerossl-hmac-key) file=zerossl-hmac-key ;;
		*) usage ;;
		esac
		[[ $# -ge 2 ]] || usage
		values["$file"]="$2"
		supplied["$file"]=1
		shift 2
	done

	cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
	umask 077
	for file in "${EAB_FILES[@]}"; do
		if [[ "${supplied[$file]:-0}" == 1 ]]; then
			files+=("$file")
		fi
	done

	# Check every destination before generating or replacing any files.
	for file in "${files[@]}"; do
		if [[ -e "$file" || -L "$file" ]]; then
			if ((preserve)) && [[ "${supplied[$file]:-0}" == 1 ]]; then
				existing_file_error "$file"
			fi
			[[ -f "$file" && ! -L "$file" ]] || existing_file_error "$file"
			if ((preserve)); then
				continue
			fi
		fi
		if [[ "${supplied[$file]:-0}" == 1 ]]; then
			[[ -n "${values[$file]}" &&
				"${values[$file]}" != *$'\n'* &&
				"${values[$file]}" != *$'\r'* ]] ||
				die "$file requires a non-empty, single-line value"
		fi
		write_files+=("$file")
	done

	if ((${#write_files[@]})); then
		temporary_dir="$(mktemp -d .create-passwords.XXXXXX)"
		trap 'rm -rf -- "$temporary_dir"' EXIT
		for file in "${write_files[@]}"; do
			if [[ -n "${values[$file]+set}" ]]; then
				printf '%s\n' "${values[$file]}" >"${temporary_dir}/${file}"
			elif ! openssl rand -hex 32 >"${temporary_dir}/${file}"; then
				die "could not generate a password for $file"
			fi
			chmod 600 "${temporary_dir}/${file}"
		done
		for file in "${write_files[@]}"; do
			if ((preserve)); then
				ln -- "${temporary_dir}/${file}" "$file" || existing_file_error "$file"
			else
				mv -f -- "${temporary_dir}/${file}" "$file"
			fi
		done
		rm -rf -- "$temporary_dir"
		trap - EXIT
	fi
	printf '%s\n' 'password and supplied EAB files are ready'
}

main "$@"
