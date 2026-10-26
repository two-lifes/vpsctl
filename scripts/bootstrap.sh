#!/usr/bin/env bash
set -euo pipefail

# Brings an Ubuntu VPS to the vpsctl server standard (docs/SERVER-STANDARD.md §6). Safe to re-run (F-04).
# The client sends lib/common.sh and this script as one stdin stream, so the library is sourced only when
# running from a checkout (ADR-042).

# shellcheck source=scripts/lib/common.sh
declare -F die >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

BOOTSTRAP_VERSION="0.1.0"

BASE_PACKAGES=(ca-certificates curl git nginx certbot ufw)
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
DOCKER_KEY="/etc/apt/keyrings/docker.asc"
DOCKER_SOURCES="/etc/apt/sources.list.d/docker.sources"

YQ_VERSION="v4.54.1"
YQ_BIN="/usr/local/bin/yq"
declare -A YQ_SHA256=(
	[amd64]="8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f"
	[arm64]="189088da0c6429ec5178dfaab1a114805f6cab0b61b165ab236efedf1d57a71b"
)

ARCH=""
CODENAME=""

# Same file as os_check, parsed rather than sourced.
os_codename() {
	local file="${VPSCTL_OS_RELEASE:-/etc/os-release}"
	local key value ubuntu="" version=""
	while IFS='=' read -r key value || [[ -n "$key" ]]; do
		value="${value%\"}"
		value="${value#\"}"
		case "$key" in
		UBUNTU_CODENAME) ubuntu="$value" ;;
		VERSION_CODENAME) version="$value" ;;
		esac
	done <"$file"
	printf '%s' "${ubuntu:-$version}"
}

# Step 1 runs before any change to the system.
step_os() {
	export VPSCTL_STEP=1
	os_check
	ARCH="${VPSCTL_ARCH:-$(dpkg --print-architecture)}"
	[[ -n "${YQ_SHA256[$ARCH]:-}" ]] || die "unsupported architecture: $ARCH (supported: ${!YQ_SHA256[*]})"
	CODENAME="$(os_codename)"
	[[ -n "$CODENAME" ]] || die "cannot determine Ubuntu codename"
	log "os ok: $CODENAME $ARCH"
}

docker_sources() {
	printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n' \
		"$CODENAME" "$ARCH" "$DOCKER_KEY"
}

package_installed() {
	[[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == "install ok installed" ]]
}

yq_installed() {
	[[ -f "$YQ_BIN" && "$(sha256sum "$YQ_BIN" | cut -d' ' -f1)" == "${YQ_SHA256[$ARCH]}" ]]
}

docker_repo_configured() {
	[[ -s "$DOCKER_KEY" && -f "$DOCKER_SOURCES" && "$(<"$DOCKER_SOURCES")" == "$(docker_sources)" ]]
}

packages_done() {
	local p
	for p in "${BASE_PACKAGES[@]}" "${DOCKER_PACKAGES[@]}"; do
		package_installed "$p" || return 1
	done
	docker_repo_configured && yq_installed
}

apt_install() {
	DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

install_docker_repo() {
	if [[ ! -s "$DOCKER_KEY" ]]; then
		log "adding Docker apt key"
		install -m 0755 -d "$(dirname "$DOCKER_KEY")"
		curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o "$DOCKER_KEY"
		chmod a+r "$DOCKER_KEY"
	fi
	# Rewritten only on mismatch so a re-run leaves apt sources untouched.
	if [[ ! -f "$DOCKER_SOURCES" || "$(<"$DOCKER_SOURCES")" != "$(docker_sources)" ]]; then
		log "writing $DOCKER_SOURCES"
		docker_sources >"$DOCKER_SOURCES"
	fi
}

install_yq() {
	local tmp url
	yq_installed && return 0
	log "installing yq $YQ_VERSION"
	tmp="$(mktemp -d)"
	url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}"
	if ! curl -fsSL --retry 3 "$url" -o "$tmp/yq"; then
		rm -rf "$tmp"
		die "cannot download $url"
	fi
	if [[ "$(sha256sum "$tmp/yq" | cut -d' ' -f1)" != "${YQ_SHA256[$ARCH]}" ]]; then
		rm -rf "$tmp"
		die "yq sha256 mismatch for $url"
	fi
	install -m 0755 -o root -g root "$tmp/yq" "$YQ_BIN"
	rm -rf "$tmp"
}

step_packages() {
	export VPSCTL_STEP=2
	if packages_done; then
		log "skip"
		return 0
	fi
	log "installing base packages"
	apt-get update
	apt_install "${BASE_PACKAGES[@]}"
	install_docker_repo
	log "installing Docker"
	apt-get update
	apt_install "${DOCKER_PACKAGES[@]}"
	install_yq
	packages_done || die "packages are not installed after step 2"
	log "done"
}

main() {
	require_root
	log "vpsctl bootstrap $BOOTSTRAP_VERSION"
	step_os
	step_packages
}

main "$@"
