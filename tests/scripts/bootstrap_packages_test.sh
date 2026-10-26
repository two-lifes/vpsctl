#!/usr/bin/env bash
set -euo pipefail

# Bootstrap steps 1–2. Changes the system, so it runs only inside the test container (tests/scripts/run.sh).

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOTSTRAP="$REPO_ROOT/scripts/bootstrap.sh"

if [[ ! -f /.dockerenv || "$EUID" -ne 0 ]]; then
	echo "bootstrap tests must run as root in the test container: tests/scripts/run.sh <24.04|26.04>" >&2
	exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Unsupported OS and architecture fail before any change. These run first, while the system is still clean.
system_state() {
	dpkg-query -W -f='${Package} ${Status}\n'
	find /etc/apt/sources.list.d /etc/apt/keyrings /usr/local/bin -type f 2>/dev/null | sort
}

before="$(system_state)"

printf '%s\n' 'ID=debian' 'VERSION_ID="12"' 'VERSION_CODENAME=bookworm' >"$tmp/debian"
run env VPSCTL_OS_RELEASE="$tmp/debian" bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status_nonzero "debian"
assert_contains "[step 1] error: unsupported OS: debian 12" "debian"

printf '%s\n' 'ID=ubuntu' 'VERSION_ID="22.04"' 'VERSION_CODENAME=jammy' >"$tmp/jammy"
run env VPSCTL_OS_RELEASE="$tmp/jammy" bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status_nonzero "ubuntu 22.04"
assert_contains "[step 1] error: unsupported OS: ubuntu 22.04" "ubuntu 22.04"

run env VPSCTL_ARCH=riscv64 bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status_nonzero "riscv64"
assert_contains "[step 1] error: unsupported architecture: riscv64" "riscv64"

assert_eq "$before" "$(system_state)" "system changed after a refused run"

# First run installs everything.
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "first run"
assert_contains "[step 2] done" "first run"

for p in git nginx certbot ufw curl docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
	assert_eq "install ok installed" "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || true)" "package $p"
done

run docker compose version
assert_status 0 "docker compose plugin"

run yq --version
assert_status 0 "yq"
assert_contains "v4.54.1" "yq version"
assert_eq "/usr/local/bin/yq" "$(command -v yq)" "yq path"

codename="$(sed -n 's/^UBUNTU_CODENAME=//p' /etc/os-release)"
run grep -h '^Suites:' /etc/apt/sources.list.d/docker.sources
assert_eq "Suites: $codename" "$output" "docker suite"

# Re-run: step 2 is skipped and apt sources stay byte- and mtime-identical.
apt_state() {
	find /etc/apt/sources.list.d /etc/apt/keyrings -type f -exec stat -c '%n %Y %s' {} + | sort
	find /etc/apt/sources.list.d /etc/apt/keyrings -type f -exec sha256sum {} + | sort
}

before="$(apt_state)"
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "second run"
assert_contains "[step 2] skip" "second run"
assert_eq "$before" "$(apt_state)" "apt sources changed on re-run"

# A tampered yq binary is replaced on the next run.
printf 'not yq\n' >/usr/local/bin/yq
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "yq repair run"
run yq --version
assert_contains "v4.54.1" "yq restored"

finish
