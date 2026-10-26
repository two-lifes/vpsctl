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

DEPLOY_USER="deploy"
DEPLOY_HOME="/home/deploy"
SUDOERS_FILE="/etc/sudoers.d/vpsctl-deploy"
VPSCTL_ROOT="/usr/local/sbin/vpsctl-root"
DEPLOY_KEY_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [^[:cntrl:]]*)?$'

ARCH=""
CODENAME=""
DEPLOY_KEY=""

usage() {
	die "usage: bootstrap.sh --deploy-key '<ssh public key>'"
}

# Input is validated before step 1 so a bad invocation never changes the system.
parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--deploy-key)
			[[ $# -ge 2 ]] || usage
			DEPLOY_KEY="$2"
			shift 2
			;;
		*)
			die "unknown argument: $1"
			;;
		esac
	done
	[[ -n "$DEPLOY_KEY" ]] || usage
	[[ "$DEPLOY_KEY" =~ $DEPLOY_KEY_RE ]] || die "--deploy-key is not a single-line SSH public key"
}

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

sudoers_content() {
	printf '# Managed by vpsctl bootstrap. deploy may run only vpsctl-root as root (ADR-031).\n%s ALL=(root) NOPASSWD: %s\n' \
		"$DEPLOY_USER" "$VPSCTL_ROOT"
}

# Keys are compared by type and blob so a changed comment does not add a duplicate line.
deploy_key_present() {
	local file="$DEPLOY_HOME/.ssh/authorized_keys" type blob
	read -r type blob _ <<<"$DEPLOY_KEY"
	[[ -f "$file" ]] && awk -v t="$type" -v b="$blob" '$1 == t && $2 == b { found = 1 } END { exit !found }' "$file"
}

in_docker_group() {
	local g
	for g in $(id -nG "$DEPLOY_USER"); do
		[[ "$g" == docker ]] && return 0
	done
	return 1
}

# Checked by command, not package: newer Ubuntu releases may provide sudo through sudo-rs.
sudo_available() {
	command -v sudo >/dev/null && command -v visudo >/dev/null
}

mode_owner() {
	stat -c '%a %U %G' "$1" 2>/dev/null || true
}

user_done() {
	id "$DEPLOY_USER" >/dev/null 2>&1 || return 1
	[[ "$(getent passwd "$DEPLOY_USER" | cut -d: -f6)" == "$DEPLOY_HOME" ]] || return 1
	in_docker_group || return 1
	[[ "$(mode_owner "$DEPLOY_HOME/.ssh")" == "700 $DEPLOY_USER $DEPLOY_USER" ]] || return 1
	[[ "$(mode_owner "$DEPLOY_HOME/.ssh/authorized_keys")" == "600 $DEPLOY_USER $DEPLOY_USER" ]] || return 1
	deploy_key_present || return 1
	sudo_available || return 1
	[[ "$(mode_owner "$SUDOERS_FILE")" == "440 root root" && "$(<"$SUDOERS_FILE")" == "$(sudoers_content)" ]]
}

# The candidate is checked by visudo before it is moved into sudoers.d, so a broken file never becomes active.
install_sudoers() {
	local tmp
	tmp="$(mktemp)"
	sudoers_content >"$tmp"
	chmod 0440 "$tmp"
	if ! visudo -c -f "$tmp" >/dev/null; then
		rm -f "$tmp"
		die "generated sudoers file is invalid"
	fi
	install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE"
	rm -f "$tmp"
	visudo -c >/dev/null || die "sudoers configuration is invalid after writing $SUDOERS_FILE"
}

step_user() {
	export VPSCTL_STEP=3
	if user_done; then
		log "skip"
		return 0
	fi
	getent group docker >/dev/null || die "group docker does not exist"
	if ! sudo_available; then
		log "installing sudo"
		apt-get update
		apt_install sudo
	fi
	if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
		log "creating user $DEPLOY_USER"
		# No password is set, so the account is locked for password login and reachable only by key.
		useradd --create-home --home-dir "$DEPLOY_HOME" --shell /bin/bash "$DEPLOY_USER"
	fi
	if ! in_docker_group; then
		log "adding $DEPLOY_USER to group docker"
		usermod -aG docker "$DEPLOY_USER"
	fi
	install -d -m 0700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$DEPLOY_HOME/.ssh"
	[[ -f "$DEPLOY_HOME/.ssh/authorized_keys" ]] || : >"$DEPLOY_HOME/.ssh/authorized_keys"
	chmod 0600 "$DEPLOY_HOME/.ssh/authorized_keys"
	chown "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_HOME/.ssh/authorized_keys"
	if ! deploy_key_present; then
		log "adding deploy key"
		printf '%s\n' "$DEPLOY_KEY" >>"$DEPLOY_HOME/.ssh/authorized_keys"
	fi
	if [[ "$(mode_owner "$SUDOERS_FILE")" != "440 root root" || "$(<"$SUDOERS_FILE")" != "$(sudoers_content)" ]]; then
		log "writing $SUDOERS_FILE"
		install_sudoers
	fi
	user_done || die "user $DEPLOY_USER is not configured after step 3"
	log "done"
}

main() {
	parse_args "$@"
	require_root
	log "vpsctl bootstrap $BOOTSTRAP_VERSION"
	step_os
	step_packages
	step_user
}

main "$@"
