# shellcheck shell=bash
# Shared helpers for vpsctl server scripts. Sourced by scripts that already run under `set -euo pipefail`.

[[ -n "${VPSCTL_COMMON_LOADED:-}" ]] && return 0
VPSCTL_COMMON_LOADED=1

VPSCTL_SUPPORTED_UBUNTU=("24.04" "26.04")

# Output is line-oriented with a step prefix so the client can stream it (SERVER-STANDARD §7).
log() {
	if [[ -n "${VPSCTL_STEP:-}" ]]; then
		printf '[step %s] %s\n' "$VPSCTL_STEP" "$*"
	else
		printf '%s\n' "$*"
	fi
}

die() {
	if [[ -n "${VPSCTL_STEP:-}" ]]; then
		printf '[step %s] error: %s\n' "$VPSCTL_STEP" "$*" >&2
	else
		printf 'error: %s\n' "$*" >&2
	fi
	exit 1
}

require_root() {
	[[ "$EUID" -eq 0 ]] || die "must be run as root"
}

# VPSCTL_OS_RELEASE lets tests substitute the file. It is parsed, not sourced, so its content is never executed.
os_check() {
	local file="${VPSCTL_OS_RELEASE:-/etc/os-release}"
	local id="" version="" key value v
	[[ -r "$file" ]] || die "cannot read $file"
	while IFS='=' read -r key value || [[ -n "$key" ]]; do
		value="${value%\"}"
		value="${value#\"}"
		case "$key" in
		ID) id="$value" ;;
		VERSION_ID) version="$value" ;;
		esac
	done <"$file"
	if [[ "$id" == "ubuntu" ]]; then
		for v in "${VPSCTL_SUPPORTED_UBUNTU[@]}"; do
			[[ "$version" == "$v" ]] && return 0
		done
	fi
	die "unsupported OS: ${id:-unknown} ${version:-unknown} (supported: Ubuntu ${VPSCTL_SUPPORTED_UBUNTU[*]})"
}
