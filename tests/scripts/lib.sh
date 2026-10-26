# shellcheck shell=bash
# Assertion helpers for script tests. A test file sources this, calls assertions and ends with `finish`.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# Public half of a throwaway key; the private half was never kept.
TEST_DEPLOY_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDhAP1G1sijnc/8jJyPtrCYnlQQvdJ24Wt+v5H05bKac vpsctl-test"
export TEST_DEPLOY_KEY

# Stand-ins for vpsctl-deploy and vpsctl-root installed by bootstrap step 6 (ADR-046); replaced by the real
# scripts in T-1.8 and T-1.9.
VPSCTL_SCRIPTS_DIR="$REPO_ROOT/tests/scripts/fixtures/server-scripts"
export VPSCTL_SCRIPTS_DIR

TEST_FAILURES=0
status=0
output=""

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	TEST_FAILURES=$((TEST_FAILURES + 1))
}

# run CMD... — executes CMD, storing its exit code in $status and combined stdout/stderr in $output.
run() {
	status=0
	output="$("$@" 2>&1)" || status=$?
}

assert_eq() {
	local expected="$1" actual="$2" msg="${3:-values differ}"
	[[ "$expected" == "$actual" ]] || fail "$msg: expected '$expected', got '$actual'"
}

assert_status() {
	local expected="$1" msg="${2:-exit status}"
	[[ "$status" -eq "$expected" ]] || fail "$msg: expected status $expected, got $status (output: $output)"
}

assert_status_nonzero() {
	local msg="${1:-exit status}"
	[[ "$status" -ne 0 ]] || fail "$msg: expected non-zero status (output: $output)"
}

assert_contains() {
	local needle="$1" msg="${2:-output}"
	[[ "$output" == *"$needle"* ]] || fail "$msg: '$needle' not found in: $output"
}

finish() {
	if [[ "$TEST_FAILURES" -gt 0 ]]; then
		printf '%d assertion(s) failed\n' "$TEST_FAILURES" >&2
		exit 1
	fi
}
