#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMMON="$REPO_ROOT/scripts/lib/common.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# with_common CODE — runs CODE in a fresh bash with common.sh sourced, so `die` cannot exit this test.
with_common() {
	bash -c 'set -euo pipefail; source "$1"; eval "$2"' _ "$COMMON" "$1"
}

# log
run with_common 'log hello world'
assert_status 0 "log"
assert_eq "hello world" "$output" "log without step"

run with_common 'VPSCTL_STEP=2 log installing'
assert_eq "[step 2] installing" "$output" "log with step"

# die
run with_common 'die broken; echo unreachable'
assert_status 1 "die"
assert_eq "error: broken" "$output" "die message"

run with_common 'die broken 2>/dev/null'
assert_eq "" "$output" "die writes to stderr only"

run with_common 'VPSCTL_STEP=3 die broken'
assert_eq "[step 3] error: broken" "$output" "die with step"

# double sourcing is harmless
# shellcheck disable=SC2016 # $1 is expanded by the inner bash (path to common.sh)
run with_common 'source "$1"; log ok'
assert_status 0 "double source"
assert_eq "ok" "$output" "double source"

# require_root
if [[ "$EUID" -eq 0 ]]; then
	run with_common 'require_root; echo ok'
	assert_status 0 "require_root as root"
	assert_eq "ok" "$output" "require_root as root"

	# shellcheck disable=SC2016 # $1 is expanded by the inner bash
	run setpriv --reuid=65534 --regid=65534 --clear-groups \
		bash -c 'source "$1"; require_root; echo unreachable' _ "$COMMON"
else
	run with_common 'require_root; echo unreachable'
fi
assert_status 1 "require_root as non-root"
assert_contains "must be run as root" "require_root as non-root"

# os_check
os_release() {
	local name="$1"
	shift
	printf '%s\n' "$@" >"$tmp/$name"
	printf '%s' "$tmp/$name"
}

for v in 24.04 26.04; do
	f="$(os_release "ubuntu-$v" 'NAME="Ubuntu"' "VERSION_ID=\"$v\"" 'ID=ubuntu' 'ID_LIKE=debian')"
	run with_common "VPSCTL_OS_RELEASE='$f' os_check; echo ok"
	assert_status 0 "os_check ubuntu $v"
	assert_eq "ok" "$output" "os_check ubuntu $v"
done

# Last line without a trailing newline must still be read.
printf 'ID=ubuntu\nVERSION_ID="24.04"' >"$tmp/no-newline"
run with_common "VPSCTL_OS_RELEASE='$tmp/no-newline' os_check"
assert_status 0 "os_check without trailing newline"

f="$(os_release ubuntu-22.04 'NAME="Ubuntu"' 'VERSION_ID="22.04"' 'ID=ubuntu')"
run with_common "VPSCTL_OS_RELEASE='$f' os_check; echo unreachable"
assert_status 1 "os_check ubuntu 22.04"
assert_contains "unsupported OS: ubuntu 22.04" "os_check ubuntu 22.04"

f="$(os_release debian-12 'NAME="Debian GNU/Linux"' 'VERSION_ID="12"' 'ID=debian')"
run with_common "VPSCTL_OS_RELEASE='$f' os_check; echo unreachable"
assert_status 1 "os_check debian"
assert_contains "unsupported OS: debian 12" "os_check debian"

f="$(os_release ubuntu-like 'ID=linuxmint' 'ID_LIKE=ubuntu' 'VERSION_ID="24.04"')"
run with_common "VPSCTL_OS_RELEASE='$f' os_check; echo unreachable"
assert_status 1 "os_check ubuntu derivative"

run with_common "VPSCTL_OS_RELEASE='$tmp/missing' os_check; echo unreachable"
assert_status 1 "os_check missing file"
assert_contains "cannot read" "os_check missing file"

finish
