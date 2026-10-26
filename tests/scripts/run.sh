#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   tests/scripts/run.sh <24.04|26.04> [test-file...]   run each test file in its own privileged systemd container (ADR-038)
#   tests/scripts/run.sh --inside [test-file...]        run tests in the current environment (used inside the container)
# Without test files, all tests/scripts/*_test.sh are run. Test file paths are relative to the repository root.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
	printf 'usage: %s <24.04|26.04|--inside> [test-file...]\n' "$0" >&2
	exit 2
}

# Fills TESTS with the given files or, without arguments, all test files.
list_tests() {
	cd "$REPO_ROOT"
	if [[ $# -gt 0 ]]; then
		TESTS=("$@")
	else
		shopt -s nullglob
		TESTS=(tests/scripts/*_test.sh)
		shopt -u nullglob
	fi
}

run_inside() {
	local tests=() t failed=0 passed=0
	list_tests "$@"
	tests=("${TESTS[@]}")
	if [[ ${#tests[@]} -eq 0 ]]; then
		echo "no tests"
		return 0
	fi
	for t in "${tests[@]}"; do
		echo "=== $t"
		if bash "$t"; then
			echo "--- PASS $t"
			passed=$((passed + 1))
		else
			echo "--- FAIL $t"
			failed=$((failed + 1))
		fi
	done
	echo "passed: $passed, failed: $failed"
	[[ "$failed" -eq 0 ]]
}

wait_for_systemd() {
	local container="$1" state="" i
	for ((i = 0; i < 120; i++)); do
		state="$(docker exec "$container" systemctl is-system-running 2>/dev/null || true)"
		case "$state" in
		running | degraded) return 0 ;;
		esac
		sleep 1
	done
	echo "systemd did not start in container (state: ${state:-unknown})" >&2
	return 1
}

# Each test file gets a fresh container: bootstrap tests change the whole system and assume a clean one.
run_in_container() {
	local version="$1" image container t failed=0 passed=0
	shift
	list_tests "$@"
	echo "ubuntu:${version}"
	if [[ ${#TESTS[@]} -eq 0 ]]; then
		echo "no tests"
		return 0
	fi
	image="vpsctl-scripts-test:${version}"
	docker build --quiet --build-arg "UBUNTU_VERSION=${version}" -t "$image" "$REPO_ROOT/tests/scripts" >/dev/null
	for t in "${TESTS[@]}"; do
		container="$(docker run -d --privileged --cgroupns=host \
			-v /sys/fs/cgroup:/sys/fs/cgroup:rw \
			--tmpfs /run --tmpfs /run/lock \
			-v "$REPO_ROOT:/src:ro" \
			"$image")"
		# shellcheck disable=SC2064 # expand $container now: it is local and gone when the trap fires
		trap "docker rm -f '$container' >/dev/null" EXIT
		if wait_for_systemd "$container" && docker exec "$container" bash /src/tests/scripts/run.sh --inside "$t"; then
			passed=$((passed + 1))
		else
			failed=$((failed + 1))
		fi
		docker rm -f "$container" >/dev/null
		trap - EXIT
	done
	echo "ubuntu:${version} test files passed: $passed, failed: $failed"
	[[ "$failed" -eq 0 ]]
}

[[ $# -ge 1 ]] || usage
case "$1" in
--inside)
	shift
	run_inside "$@"
	;;
24.04 | 26.04)
	run_in_container "$@"
	;;
*)
	usage
	;;
esac
