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

SSHD_DROPIN="/etc/ssh/sshd_config.d/00-vpsctl.conf"

STANDARD_VERSION="1"
PROJECTS_ROOT="/opt"
VPSCTL_ETC="/etc/vpsctl"
SERVER_YML="$VPSCTL_ETC/server.yml"
# Server scripts by name -> install path. vpsctl-collect joins in T-2.5.
declare -A SERVER_SCRIPTS=(
	[vpsctl-deploy]="/usr/local/bin/vpsctl-deploy"
	[vpsctl-root]="$VPSCTL_ROOT"
)
# Empty when the script arrives on stdin: server scripts then come only from vpsctl_script_* functions (ADR-046).
SCRIPT_DIR=""
[[ -f "${BASH_SOURCE[0]:-}" ]] && SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

AUTO_UPGRADES="/etc/apt/apt.conf.d/20auto-upgrades"

ARCH=""
CODENAME=""
DEPLOY_KEY=""
UNATTENDED_UPGRADES=1
SSH_PORTS=()
LOGIN_CHECK_DIR=""
LOGIN_CHECK_PID=""
STAGE_DIR=""
# Set by any step that changed the system; server.yml is rewritten only then (F-04).
CHANGED=0

usage() {
	die "usage: bootstrap.sh --deploy-key '<ssh public key>' [--no-unattended-upgrades]"
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
		--no-unattended-upgrades)
			UNATTENDED_UPGRADES=0
			shift
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
	CHANGED=1
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
	CHANGED=1
	log "done"
}

# sshd refuses to parse its config without the privilege separation directory, which is absent while
# ssh.service waits for socket activation.
ensure_privsep_dir() {
	[[ -d /run/sshd ]] || install -d -m 0755 /run/sshd
}

sshd_effective() {
	sshd -T 2>/dev/null | awk -v k="$1" '$1 == k { print $2 }'
}

# The port is never changed (ADR-040): every port sshd is configured for stays open, plus the port of the
# current connection in case it differs (e.g. a socket unit override).
detect_ssh_ports() {
	local ports p
	ports="$(sshd_effective port)"
	if [[ -n "${SSH_CONNECTION:-}" ]]; then
		read -r _ _ _ p <<<"$SSH_CONNECTION"
		ports+=$'\n'"$p"
	fi
	mapfile -t SSH_PORTS < <(grep -E '^[0-9]+$' <<<"$ports" | sort -un)
	[[ ${#SSH_PORTS[@]} -gt 0 ]] || die "cannot determine the SSH port"
}

firewall_done() {
	local status port
	status="$(ufw status verbose 2>/dev/null)" || return 1
	grep -q '^Status: active$' <<<"$status" || return 1
	grep -q 'deny (incoming)' <<<"$status" || return 1
	for port in "${SSH_PORTS[@]}" 80 443; do
		grep -Eq "^${port}/tcp +ALLOW IN +Anywhere *$" <<<"$status" || return 1
	done
}

step_firewall() {
	export VPSCTL_STEP=4
	command -v sshd >/dev/null || die "sshd is not installed"
	ensure_privsep_dir
	detect_ssh_ports
	log "ssh port(s): ${SSH_PORTS[*]}"
	if firewall_done; then
		log "skip"
		return 0
	fi
	ufw default deny incoming
	ufw default allow outgoing
	local port
	# SSH goes first so the firewall never comes up without it.
	for port in "${SSH_PORTS[@]}" 80 443; do
		ufw allow "$port/tcp"
	done
	ufw --force enable
	firewall_done || die "ufw is not configured after step 4"
	CHANGED=1
	log "done"
}

sshd_dropin_content() {
	printf '# Managed by vpsctl bootstrap (ADR-029, ADR-045).\nPermitRootLogin no\nPasswordAuthentication no\n'
}

sshd_done() {
	[[ -f "$SSHD_DROPIN" && "$(<"$SSHD_DROPIN")" == "$(sshd_dropin_content)" ]] || return 1
	[[ "$(sshd_effective permitrootlogin)" == no && "$(sshd_effective passwordauthentication)" == no ]]
}

port_in_use() {
	(exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

cleanup_login_check() {
	if [[ -n "$LOGIN_CHECK_PID" ]]; then
		kill "$LOGIN_CHECK_PID" 2>/dev/null || true
		wait "$LOGIN_CHECK_PID" 2>/dev/null || true
	fi
	[[ -z "$LOGIN_CHECK_DIR" ]] || rm -rf "$LOGIN_CHECK_DIR"
	LOGIN_CHECK_PID=""
	LOGIN_CHECK_DIR=""
}

# Logs in as deploy through a temporary sshd on 127.0.0.1 that reads the new configuration (ADR-045). The
# private deploy key never reaches the server, so a one-time key stands in for it; everything else
# (AllowUsers/DenyUsers, shell, account state, PAM) is checked for real. Called in a condition, so every
# failure is handled explicitly.
verify_deploy_login() {
	local dir port i sshd_bin
	deploy_key_present || {
		log "deploy key is missing from $DEPLOY_HOME/.ssh/authorized_keys"
		return 1
	}
	sshd_bin="$(command -v sshd)" || return 1
	trap cleanup_login_check EXIT
	# Under /run, not /tmp: StrictModes rejects world-writable parents, and sshd reads the key file as deploy.
	dir="$(mktemp -d -p /run vpsctl-login.XXXXXX)" || return 1
	LOGIN_CHECK_DIR="$dir"
	chmod 0755 "$dir" || return 1
	ssh-keygen -q -t ed25519 -N '' -C vpsctl-login-check -f "$dir/key" || return 1
	install -m 0644 "$dir/key.pub" "$dir/$DEPLOY_USER" || return 1
	port=""
	for ((i = 0; i < 20; i++)); do
		port=$((20000 + RANDOM % 20000))
		port_in_use "$port" || break
		port=""
	done
	[[ -n "$port" ]] || {
		log "no free port for the temporary sshd"
		return 1
	}
	"$sshd_bin" -D -e -f /etc/ssh/sshd_config -p "$port" -o ListenAddress=127.0.0.1 \
		-o "PidFile=$dir/sshd.pid" -o "AuthorizedKeysFile=$dir/%u" >"$dir/sshd.log" 2>&1 &
	LOGIN_CHECK_PID=$!
	for ((i = 0; i < 50; i++)); do
		port_in_use "$port" && break
		kill -0 "$LOGIN_CHECK_PID" 2>/dev/null || break
		sleep 0.1
	done
	if ! ssh -n -F /dev/null -i "$dir/key" -p "$port" -o BatchMode=yes -o IdentitiesOnly=yes \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR \
		"$DEPLOY_USER@127.0.0.1" true; then
		log "temporary sshd log:"
		sed 's/^/  /' "$dir/sshd.log" || true
		cleanup_login_check
		trap - EXIT
		return 1
	fi
	cleanup_login_check
	trap - EXIT
}

# Puts back the drop-in that was there before step 5 (or removes it) so a failed step leaves sshd as it was.
restore_sshd_dropin() {
	local backup="$1"
	if [[ -n "$backup" ]]; then
		install -m 0644 -o root -g root "$backup" "$SSHD_DROPIN"
		rm -f "$backup"
	else
		rm -f "$SSHD_DROPIN"
	fi
}

step_sshd() {
	export VPSCTL_STEP=5
	ensure_privsep_dir
	if sshd_done; then
		log "skip"
		return 0
	fi
	local backup="" tmp
	if [[ -f "$SSHD_DROPIN" ]]; then
		backup="$(mktemp)"
		cp "$SSHD_DROPIN" "$backup"
	fi
	log "writing $SSHD_DROPIN"
	tmp="$(mktemp)"
	sshd_dropin_content >"$tmp"
	install -m 0644 -o root -g root "$tmp" "$SSHD_DROPIN"
	rm -f "$tmp"
	if ! sshd -t; then
		restore_sshd_dropin "$backup"
		die "sshd configuration is invalid; sshd was not reloaded"
	fi
	log "checking login as $DEPLOY_USER"
	if ! verify_deploy_login; then
		restore_sshd_dropin "$backup"
		die "login as $DEPLOY_USER failed with the new sshd configuration; sshd was not reloaded"
	fi
	[[ -z "$backup" ]] || rm -f "$backup"
	log "reloading ssh.service"
	# Inactive under socket activation means the next connection starts sshd with the new config anyway.
	systemctl try-reload-or-restart ssh.service
	sshd_done || die "sshd is not configured after step 5"
	CHANGED=1
	log "done"
}

# A function defined earlier in the stdin stream wins; from a checkout the file next to this script is used.
script_source() {
	local name="$1" fn="vpsctl_script_${1//-/_}" dir="${VPSCTL_SCRIPTS_DIR:-$SCRIPT_DIR}"
	if declare -F "$fn" >/dev/null; then
		"$fn"
		return
	fi
	[[ -n "$dir" && -f "$dir/$name" ]] || return 1
	cat "$dir/$name"
}

# Every script is resolved before anything is installed, so a missing one leaves the system unchanged.
stage_server_scripts() {
	local name
	STAGE_DIR="$(mktemp -d)"
	for name in "${!SERVER_SCRIPTS[@]}"; do
		if ! script_source "$name" >"$STAGE_DIR/$name"; then
			rm -rf "$STAGE_DIR"
			die "$name is not provided: no vpsctl_script_${name//-/_} function and no file in ${VPSCTL_SCRIPTS_DIR:-${SCRIPT_DIR:-<stdin>}}"
		fi
	done
}

# Content is compared instead of --version so a locally edited script is also replaced.
script_installed() {
	local name="$1" dest="${SERVER_SCRIPTS[$1]}"
	[[ "$(mode_owner "$dest")" == "755 root root" ]] && cmp -s "$STAGE_DIR/$name" "$dest"
}

layout_done() {
	local name
	[[ "$(mode_owner "$PROJECTS_ROOT")" == "755 $DEPLOY_USER $DEPLOY_USER" ]] || return 1
	[[ "$(mode_owner "$VPSCTL_ETC")" == "755 root root" ]] || return 1
	for name in "${!SERVER_SCRIPTS[@]}"; do
		script_installed "$name" || return 1
	done
}

step_layout() {
	export VPSCTL_STEP=6
	stage_server_scripts
	if layout_done; then
		rm -rf "$STAGE_DIR"
		log "skip"
		return 0
	fi
	install -d -m 0755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$PROJECTS_ROOT"
	install -d -m 0755 -o root -g root "$VPSCTL_ETC"
	local name
	for name in "${!SERVER_SCRIPTS[@]}"; do
		if ! script_installed "$name"; then
			log "installing ${SERVER_SCRIPTS[$name]}"
			install -m 0755 -o root -g root "$STAGE_DIR/$name" "${SERVER_SCRIPTS[$name]}"
		fi
	done
	if ! layout_done; then
		rm -rf "$STAGE_DIR"
		die "layout is not configured after step 6"
	fi
	rm -rf "$STAGE_DIR"
	CHANGED=1
	log "done"
}

auto_upgrades_content() {
	printf '// Managed by vpsctl bootstrap (ADR-040).\nAPT::Periodic::Update-Package-Lists "%s";\nAPT::Periodic::Unattended-Upgrade "%s";\n' "$1" "$1"
}

auto_upgrades_is() {
	[[ "$(mode_owner "$AUTO_UPGRADES")" == "644 root root" && "$(<"$AUTO_UPGRADES")" == "$(auto_upgrades_content "$1")" ]]
}

# With --no-unattended-upgrades only an existing file that turns them on is touched; nothing is installed.
unattended_done() {
	if [[ "$UNATTENDED_UPGRADES" -eq 1 ]]; then
		package_installed unattended-upgrades && auto_upgrades_is 1
	else
		[[ ! -f "$AUTO_UPGRADES" ]] || ! grep -Eq '^[[:space:]]*APT::Periodic::Unattended-Upgrade[[:space:]]+"1"' "$AUTO_UPGRADES"
	fi
}

step_unattended() {
	export VPSCTL_STEP=7
	if unattended_done; then
		log "skip"
		return 0
	fi
	local value=0 tmp
	if [[ "$UNATTENDED_UPGRADES" -eq 1 ]]; then
		value=1
		if ! package_installed unattended-upgrades; then
			log "installing unattended-upgrades"
			apt-get update
			apt_install unattended-upgrades
		fi
	fi
	log "writing $AUTO_UPGRADES (unattended upgrades: $value)"
	tmp="$(mktemp)"
	auto_upgrades_content "$value" >"$tmp"
	install -m 0644 -o root -g root "$tmp" "$AUTO_UPGRADES"
	rm -f "$tmp"
	unattended_done || die "unattended-upgrades are not configured after step 7"
	CHANGED=1
	log "done"
}

server_yml_current() {
	[[ -f "$SERVER_YML" && "$(mode_owner "$SERVER_YML")" == "644 root root" ]] || return 1
	[[ "$(yq '.standard_version' "$SERVER_YML" 2>/dev/null)" == "$STANDARD_VERSION" ]] || return 1
	[[ "$(yq '.bootstrap_version' "$SERVER_YML" 2>/dev/null)" == "$BOOTSTRAP_VERSION" ]]
}

# Written last, so the file records only a fully successful run, and left as is when nothing changed (F-04).
record_server_yml() {
	export VPSCTL_STEP=6
	if [[ "$CHANGED" -eq 0 ]] && server_yml_current; then
		log "skip $SERVER_YML"
		return 0
	fi
	local now first="" tmp
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	[[ ! -f "$SERVER_YML" ]] || first="$(yq '.bootstrapped_at // ""' "$SERVER_YML" 2>/dev/null || true)"
	[[ "$first" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || first="$now"
	log "writing $SERVER_YML"
	tmp="$(mktemp)"
	printf 'standard_version: %s\nbootstrap_version: %s\nbootstrapped_at: %s\nupdated_at: %s\n' \
		"$STANDARD_VERSION" "$BOOTSTRAP_VERSION" "$first" "$now" >"$tmp"
	install -m 0644 -o root -g root "$tmp" "$SERVER_YML"
	rm -f "$tmp"
}

main() {
	parse_args "$@"
	require_root
	log "vpsctl bootstrap $BOOTSTRAP_VERSION"
	step_os
	step_packages
	step_user
	step_firewall
	step_sshd
	step_layout
	step_unattended
	record_server_yml
}

main "$@"
