#!/usr/bin/env bash
set -euo pipefail

# Bootstrap steps 4-5: ufw and sshd. Changes the system, so it runs only inside the test container
# (tests/scripts/run.sh). ufw and sshd behave only partly as on a VPS there; the full check is the stage gate
# checklist (ADR-038).

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOTSTRAP="$REPO_ROOT/scripts/bootstrap.sh"
DROPIN="/etc/ssh/sshd_config.d/00-vpsctl.conf"
TEST_DROPIN="/etc/ssh/sshd_config.d/01-test.conf"

if [[ ! -f /.dockerenv || "$EUID" -ne 0 ]]; then
	echo "bootstrap tests must run as root in the test container: tests/scripts/run.sh <24.04|26.04>" >&2
	exit 1
fi

assert_not_contains() {
	local needle="$1" msg="${2:-output}"
	[[ "$output" != *"$needle"* ]] || fail "$msg: '$needle' found in: $output"
}

assert_allowed() {
	local port="$1" msg="$2"
	grep -Eq "^${port}/tcp +ALLOW IN +Anywhere *$" <<<"$(ufw status verbose)" || fail "$msg: no ufw rule for $port/tcp"
}

assert_no_login_check_left() {
	local msg="$1"
	! compgen -G '/run/vpsctl-login.*' >/dev/null || fail "$msg: temporary login check directory left behind"
	# The bracket keeps grep from matching its own command line; procps is not in the base image.
	! grep -qs 'vpsctl-logi[n]' /proc/[0-9]*/cmdline || fail "$msg: temporary sshd still running"
}

# Earlier tests in the same container may have bootstrapped already; start steps 4-5 from a clean slate.
rm -f "$DROPIN" "$TEST_DROPIN"
if command -v ufw >/dev/null; then
	ufw --force reset >/dev/null
fi

# First run configures the firewall and sshd.
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "first run"
assert_contains "[step 4] done" "first run"
assert_contains "[step 5] checking login as deploy" "first run"
assert_contains "[step 5] done" "first run"

status_out="$(ufw status verbose)"
grep -q '^Status: active$' <<<"$status_out" || fail "ufw is not active: $status_out"
grep -q 'deny (incoming)' <<<"$status_out" || fail "ufw does not deny incoming: $status_out"
for port in 22 80 443; do
	assert_allowed "$port" "first run"
done

assert_eq "644 root root" "$(stat -c '%a %U %G' "$DROPIN")" "drop-in mode"
run sshd -T
assert_status 0 "sshd -T"
assert_contains $'\npermitrootlogin no\n' "permitrootlogin"
assert_contains $'\npasswordauthentication no\n' "passwordauthentication"
assert_no_login_check_left "first run"

# Re-run changes nothing.
ufw_before="$(ufw status verbose)"
dropin_before="$(stat -c '%Y' "$DROPIN")"
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "second run"
assert_contains "[step 4] skip" "second run"
assert_contains "[step 5] skip" "second run"
assert_not_contains "reloading ssh.service" "second run"
assert_eq "$ufw_before" "$(ufw status verbose)" "ufw changed on re-run"
assert_eq "$dropin_before" "$(stat -c '%Y' "$DROPIN")" "drop-in rewritten on re-run"

# The SSH port is detected, not assumed: from sshd configuration and from the current connection.
printf 'Port 2222\n' >"$TEST_DROPIN"
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "custom port run"
assert_contains "[step 4] ssh port(s): 2222" "custom port run"
assert_allowed 2222 "custom port"
rm -f "$TEST_DROPIN"

run env SSH_CONNECTION="10.0.0.1 50000 10.0.0.2 2200" bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "connection port run"
assert_contains "[step 4] ssh port(s): 22 2200" "connection port run"
assert_allowed 2200 "connection port"

# A failed login check leaves sshd alone: the drop-in is not installed and sshd is not reloaded.
rm -f "$DROPIN"
printf 'DenyUsers deploy\n' >"$TEST_DROPIN"
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status_nonzero "denied login"
assert_contains "[step 5] error: login as deploy failed" "denied login"
assert_not_contains "reloading ssh.service" "denied login"
[[ ! -e "$DROPIN" ]] || fail "drop-in left in place after a failed login check"
assert_no_login_check_left "denied login"

# The previous drop-in is restored, not removed.
drifted=$'PermitRootLogin yes\nPasswordAuthentication yes'
printf '%s\n' "$drifted" >"$DROPIN"
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status_nonzero "denied login with old drop-in"
assert_eq "$drifted" "$(<"$DROPIN")" "old drop-in restored"
rm -f "$TEST_DROPIN"

# Drift is repaired on the next run.
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "repair run"
assert_contains "[step 5] reloading ssh.service" "repair run"
assert_contains "[step 5] done" "repair run"
run sshd -T
assert_contains $'\npermitrootlogin no\n' "permitrootlogin repaired"
assert_contains $'\npasswordauthentication no\n' "passwordauthentication repaired"

finish
