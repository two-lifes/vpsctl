#!/usr/bin/env bash
set -euo pipefail

# Bootstrap steps 6-7: layout, server scripts, server.yml, unattended-upgrades. Changes the system, so it runs
# only inside the test container (tests/scripts/run.sh).

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOTSTRAP="$REPO_ROOT/scripts/bootstrap.sh"
COMMON="$REPO_ROOT/scripts/lib/common.sh"
FIXTURES="$VPSCTL_SCRIPTS_DIR"
DEPLOY_BIN="/usr/local/bin/vpsctl-deploy"
ROOT_BIN="/usr/local/sbin/vpsctl-root"
SERVER_YML="/etc/vpsctl/server.yml"
AUTO_UPGRADES="/etc/apt/apt.conf.d/20auto-upgrades"
TIMESTAMP_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

if [[ ! -f /.dockerenv || "$EUID" -ne 0 ]]; then
	echo "bootstrap tests must run as root in the test container: tests/scripts/run.sh <24.04|26.04>" >&2
	exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

assert_installed_from_fixtures() {
	local msg="$1"
	assert_eq "755 root root" "$(stat -c '%a %U %G' "$DEPLOY_BIN" 2>/dev/null || true)" "$msg: vpsctl-deploy mode"
	assert_eq "755 root root" "$(stat -c '%a %U %G' "$ROOT_BIN" 2>/dev/null || true)" "$msg: vpsctl-root mode"
	cmp -s "$FIXTURES/vpsctl-deploy" "$DEPLOY_BIN" || fail "$msg: vpsctl-deploy content differs"
	cmp -s "$FIXTURES/vpsctl-root" "$ROOT_BIN" || fail "$msg: vpsctl-root content differs"
}

# Earlier tests in the same container may have bootstrapped already; start step 6 from a clean slate.
rm -f "$DEPLOY_BIN" "$ROOT_BIN" "$SERVER_YML"

# A missing server script fails step 6 before anything is installed.
mkdir "$tmp/partial"
cp "$FIXTURES/vpsctl-root" "$tmp/partial/"
run env VPSCTL_SCRIPTS_DIR="$tmp/partial" bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status_nonzero "missing vpsctl-deploy"
assert_contains "[step 6] error: vpsctl-deploy is not provided" "missing vpsctl-deploy"
[[ ! -e "$ROOT_BIN" && ! -e "$DEPLOY_BIN" ]] || fail "missing vpsctl-deploy: a script was installed"
[[ ! -e "$SERVER_YML" ]] || fail "missing vpsctl-deploy: server.yml was written"

# First run lays out the server.
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "first run"
assert_contains "[step 6] done" "first run"
assert_contains "[step 6] writing $SERVER_YML" "first run"

assert_eq "755 deploy deploy" "$(stat -c '%a %U %G' /opt)" "/opt mode"
assert_eq "755 root root" "$(stat -c '%a %U %G' /etc/vpsctl)" "/etc/vpsctl mode"
assert_eq "644 root root" "$(stat -c '%a %U %G' "$SERVER_YML")" "server.yml mode"
assert_installed_from_fixtures "first run"

script_version="$(sed -n 's/^BOOTSTRAP_VERSION="\(.*\)"$/\1/p' "$BOOTSTRAP")"
assert_eq "1" "$(yq '.standard_version' "$SERVER_YML")" "standard_version"
assert_eq "$script_version" "$(yq '.bootstrap_version' "$SERVER_YML")" "bootstrap_version"
first_at="$(yq '.bootstrapped_at' "$SERVER_YML")"
[[ "$first_at" =~ $TIMESTAMP_RE ]] || fail "bootstrapped_at is not RFC 3339 UTC: $first_at"
updated_at="$(yq '.updated_at' "$SERVER_YML")"
[[ "$updated_at" =~ $TIMESTAMP_RE ]] || fail "updated_at is not RFC 3339 UTC: $updated_at"

run sudo -u deploy sudo -n "$ROOT_BIN" --version
assert_status 0 "vpsctl-root via sudo"
assert_contains "vpsctl-root" "vpsctl-root via sudo"

assert_eq "install ok installed" "$(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null || true)" \
	"unattended-upgrades package"
grep -q '^APT::Periodic::Unattended-Upgrade "1";$' "$AUTO_UPGRADES" || fail "unattended upgrades are not enabled"

# Drift is repaired; bootstrapped_at survives, updated_at moves on.
chmod 0700 /opt
printf '# edited\n' >>"$DEPLOY_BIN"
sleep 1
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "repair run"
assert_contains "[step 6] installing $DEPLOY_BIN" "repair run"
assert_contains "[step 6] writing $SERVER_YML" "repair run"
assert_eq "755 deploy deploy" "$(stat -c '%a %U %G' /opt)" "/opt mode after repair"
assert_installed_from_fixtures "repair run"
assert_eq "$first_at" "$(yq '.bootstrapped_at' "$SERVER_YML")" "bootstrapped_at after repair"
[[ "$(yq '.updated_at' "$SERVER_YML")" != "$updated_at" ]] || fail "updated_at did not change after repair"

# Sent as one stdin stream, the script takes server scripts only from vpsctl_script_* functions (ADR-046).
payload() {
	local f name
	for f in "$FIXTURES"/*; do
		name="$(basename "$f")"
		printf 'vpsctl_script_%s() {\n\tcat <<'\''VPSCTL_EOF'\''\n' "${name//-/_}"
		cat "$f"
		printf 'VPSCTL_EOF\n}\n'
	done
}

rm -f "$DEPLOY_BIN" "$ROOT_BIN"
cat "$COMMON" "$BOOTSTRAP" >"$tmp/no-payload.sh"
run env -u VPSCTL_SCRIPTS_DIR bash -s -- --deploy-key "$TEST_DEPLOY_KEY" <"$tmp/no-payload.sh"
assert_status_nonzero "stream without payload"
assert_contains "is not provided: no vpsctl_script_" "stream without payload"

{
	cat "$COMMON"
	payload
	cat "$BOOTSTRAP"
} >"$tmp/stream.sh"
run env -u VPSCTL_SCRIPTS_DIR bash -s -- --deploy-key "$TEST_DEPLOY_KEY" <"$tmp/stream.sh"
assert_status 0 "stream run"
assert_contains "[step 6] done" "stream run"
assert_installed_from_fixtures "stream run"

# --no-unattended-upgrades turns them off without removing the package; the default turns them back on.
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY" --no-unattended-upgrades
assert_status 0 "disable run"
assert_contains "[step 7] done" "disable run"
grep -q '^APT::Periodic::Unattended-Upgrade "0";$' "$AUTO_UPGRADES" || fail "unattended upgrades are not disabled"

run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY" --no-unattended-upgrades
assert_status 0 "second disable run"
assert_contains "[step 7] skip" "second disable run"

run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "enable run"
assert_contains "[step 7] done" "enable run"
grep -q '^APT::Periodic::Unattended-Upgrade "1";$' "$AUTO_UPGRADES" || fail "unattended upgrades are not re-enabled"

finish
