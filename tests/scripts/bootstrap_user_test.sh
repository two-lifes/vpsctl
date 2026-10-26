#!/usr/bin/env bash
set -euo pipefail

# Bootstrap step 3: the deploy user and its sudoers rule. Changes the system, so it runs only inside the test
# container (tests/scripts/run.sh).

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOTSTRAP="$REPO_ROOT/scripts/bootstrap.sh"
SUDOERS_FILE="/etc/sudoers.d/vpsctl-deploy"
KEYS="/home/deploy/.ssh/authorized_keys"

if [[ ! -f /.dockerenv || "$EUID" -ne 0 ]]; then
	echo "bootstrap tests must run as root in the test container: tests/scripts/run.sh <24.04|26.04>" >&2
	exit 1
fi

# Earlier tests in the same container may have bootstrapped already; start step 3 from a clean slate.
if id deploy >/dev/null 2>&1; then
	userdel --remove deploy
fi
rm -f "$SUDOERS_FILE"

# Bad input fails before any change.
run bash "$BOOTSTRAP"
assert_status_nonzero "no key"
assert_contains "usage: bootstrap.sh --deploy-key" "no key"

run bash "$BOOTSTRAP" --deploy-key
assert_status_nonzero "key without value"

run bash "$BOOTSTRAP" --deploy-key "not a key"
assert_status_nonzero "malformed key"
assert_contains "is not a single-line SSH public key" "malformed key"

run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"$'\n'"ssh-ed25519 AAAA second"
assert_status_nonzero "multi-line key"

run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY" --bogus
assert_status_nonzero "unknown argument"
assert_contains "unknown argument: --bogus" "unknown argument"

run id deploy
assert_status_nonzero "deploy created by a refused run"
[[ ! -e "$SUDOERS_FILE" ]] || fail "sudoers written by a refused run"

# First run creates the user.
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "first run"
assert_contains "[step 3] done" "first run"

assert_eq "/home/deploy" "$(getent passwd deploy | cut -d: -f6)" "home directory"
[[ " $(id -nG deploy) " == *" docker "* ]] || fail "deploy is not in group docker: $(id -nG deploy)"
assert_eq "700 deploy deploy" "$(stat -c '%a %U %G' /home/deploy/.ssh)" ".ssh mode"
assert_eq "600 deploy deploy" "$(stat -c '%a %U %G' "$KEYS")" "authorized_keys mode"
assert_eq "$TEST_DEPLOY_KEY" "$(<"$KEYS")" "authorized_keys content"
assert_eq "440 root root" "$(stat -c '%a %U %G' "$SUDOERS_FILE")" "sudoers mode"

run visudo -c
assert_status 0 "visudo -c"

# The only command deploy may run via sudo is vpsctl-root.
run sudo -l -U deploy
assert_status 0 "sudo -l"
commands="$(sed -n '/may run the following commands/,$p' <<<"$output" | sed -n 's/^[[:space:]]\{1,\}//p')"
assert_eq 1 "$(grep -c . <<<"$commands")" "number of sudo rules for deploy (got: $commands)"
[[ "$commands" == *"NOPASSWD: /usr/local/sbin/vpsctl-root" ]] || fail "sudo rule for deploy: $commands"

run sudo -u deploy sudo -n bash -c true
assert_status_nonzero "root shell via sudo"

# Re-run: step 3 is skipped and the key is not duplicated, even with a different comment.
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "second run"
assert_contains "[step 3] skip" "second run"

read -r key_type key_blob _ <<<"$TEST_DEPLOY_KEY"
run bash "$BOOTSTRAP" --deploy-key "$key_type $key_blob renamed"
assert_status 0 "run with renamed key"
assert_contains "[step 3] skip" "run with renamed key"
assert_eq 1 "$(grep -c "$key_blob" "$KEYS")" "key lines in authorized_keys"

# A second key is appended next to the first one.
other_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyForTestsOnlyNotARealKeyAAAAAAAAA other"
run bash "$BOOTSTRAP" --deploy-key "$other_key"
assert_status 0 "run with another key"
assert_contains "[step 3] adding deploy key" "run with another key"
assert_eq 2 "$(wc -l <"$KEYS")" "authorized_keys lines"

# Drift is repaired on the next run.
chmod 0644 "$KEYS"
printf 'deploy ALL=(ALL) NOPASSWD: ALL\n' >"$SUDOERS_FILE"
gpasswd --delete deploy docker >/dev/null
run bash "$BOOTSTRAP" --deploy-key "$TEST_DEPLOY_KEY"
assert_status 0 "repair run"
assert_contains "[step 3] done" "repair run"
assert_eq "600 deploy deploy" "$(stat -c '%a %U %G' "$KEYS")" "authorized_keys mode repaired"
[[ " $(id -nG deploy) " == *" docker "* ]] || fail "docker membership not repaired"
run sudo -u deploy sudo -n bash -c true
assert_status_nonzero "root shell via sudo after repair"

finish
