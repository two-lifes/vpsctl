#!/usr/bin/env bash
set -euo pipefail

# Full bootstrap twice in a row: the second run must succeed with every step skipped and change nothing (F-04).
# Changes the system, so it runs only inside the test container (tests/scripts/run.sh).

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOTSTRAP="$REPO_ROOT/scripts/bootstrap.sh"

if [[ ! -f /.dockerenv || "$EUID" -ne 0 ]]; then
	echo "bootstrap tests must run as root in the test container: tests/scripts/run.sh <24.04|26.04>" >&2
	exit 1
fi

assert_not_contains() {
	local needle="$1" msg="${2:-output}"
	[[ "$output" != *"$needle"* ]] || fail "$msg: '$needle' found in: $output"
}

# Every file bootstrap writes, with mtime and content, plus users and the firewall.
system_state() {
	local f
	for f in /etc/apt/sources.list.d/* /etc/apt/keyrings/* /usr/local/bin/* /usr/local/sbin/* \
		/etc/sudoers.d/vpsctl-deploy /home/deploy/.ssh/authorized_keys /etc/ssh/sshd_config.d/* \
		/etc/vpsctl/server.yml /etc/apt/apt.conf.d/20auto-upgrades /opt /etc/vpsctl; do
		[[ -e "$f" ]] || continue
		stat -c '%n %a %U %G %Y' "$f"
		[[ -f "$f" ]] && sha256sum "$f"
	done
	id deploy
	ufw status verbose
	dpkg-query -W -f='${Package} ${Status}\n'
}

run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "first run"

before="$(system_state)"
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "second run"
for step in 2 3 4 5 6 7; do
	assert_contains "[step $step] skip" "second run"
done
assert_contains "[step 6] skip /etc/vpsctl/server.yml" "second run"
assert_not_contains "] done" "second run"
assert_eq "$before" "$(system_state)" "system changed on re-run"

finish
