#!/usr/bin/env bash
set -euo pipefail

# Checks templates/<name>/{compose.yml,vpsctl.yml} against SERVER-STANDARD §4 and §8.
# Needs docker compose (no daemon), jq and yq v4; runs on the CI host, not in the systemd test containers.
# Usage: tests/templates/check.sh [template-dir-name...]   (default: every directory in templates/ with vpsctl.yml)

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Manifest field as JSON (null when absent).
mf() {
	yq -o=json "$1" "$manifest"
}

check_manifest() {
	local dir="$1" name template compose port
	name="$(yq '.name' "$manifest")"
	[[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || fail "$dir: name '$name' violates ADR-026"
	template="$(yq '.template' "$manifest")"
	case "$template" in
	bot | web | web+db | static) ;;
	*) fail "$dir: unknown template '$template'" ;;
	esac
	# Directory web-db holds template web+db (ARCHITECTURE §2).
	[[ "${template/+/-}" == "$dir" ]] || fail "$dir: template '$template' does not match directory"
	compose="$(yq '.compose' "$manifest")"
	[[ -f "$REPO_ROOT/templates/$dir/$compose" ]] || fail "$dir: compose file '$compose' not found"
	mf '.env // [] | map(select(test("^[A-Z_][A-Z0-9_]*$") | not)) | length' | grep -qx 0 ||
		fail "$dir: env keys must match [A-Z_][A-Z0-9_]*"
	port="$(mf '.port')"
	if [[ "$template" == bot ]]; then
		[[ "$port" == null ]] || fail "$dir: bot must have port: null, got $port"
	else
		if ! [[ "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
			fail "$dir: port must be 1-65535, got $port"
		fi
	fi
}

check_compose() {
	local dir="$1" compose project config template port
	compose="$(yq '.compose' "$manifest")"
	template="$(yq '.template' "$manifest")"
	port="$(mf '.port')"

	# Server layout: /opt/<project>/app is the clone, /opt/<project>/.env sits next to it.
	project="$tmp/$dir"
	mkdir -p "$project/app"
	cp -R "$REPO_ROOT/templates/$dir/." "$project/app/"
	touch "$project/.env"

	run docker compose -p "vpsctl-$dir" -f "$project/app/$compose" config --format json
	assert_status 0 "$dir: docker compose config"
	[[ "$status" -eq 0 ]] || return 0
	config="$output"

	run docker compose -p "vpsctl-$dir" -f "$project/app/$compose" config --images
	assert_eq "vpsctl-$(yq '.name' "$manifest"):local" "$(head -n1 <<<"$output")" "$dir: default image"
	VPSCTL_IMAGE=ghcr.io/owner/app:1 run docker compose -p "vpsctl-$dir" -f "$project/app/$compose" config --images
	assert_eq "ghcr.io/owner/app:1" "$(head -n1 <<<"$output")" "$dir: image from VPSCTL_IMAGE"

	jq -e '[.services[] | .restart == "unless-stopped"] | all' <<<"$config" >/dev/null ||
		fail "$dir: every service needs restart: unless-stopped"
	# env_file is checked in the source: compose versions render it differently in config output.
	yq -e '[.services[] | select(.build) | .env_file == "../.env"] | all' "$project/app/$compose" >/dev/null ||
		fail "$dir: built services need env_file: ../.env"
	jq -e '[.services[].ports // [] | .[] | .host_ip == "127.0.0.1"] | all' <<<"$config" >/dev/null ||
		fail "$dir: ports must be published on 127.0.0.1 only"

	case "$template" in
	bot)
		jq -e '[.services[] | has("ports")] | any | not' <<<"$config" >/dev/null || fail "$dir: bot must not publish ports"
		;;
	*)
		jq -e --arg port "$port" '[.services[].ports // [] | .[] | (.published | tostring) == $port] | any' \
			<<<"$config" >/dev/null || fail "$dir: no service published on 127.0.0.1:$port"
		;;
	esac
}

if [[ $# -gt 0 ]]; then
	dirs=("$@")
else
	dirs=()
	for m in "$REPO_ROOT"/templates/*/vpsctl.yml; do
		dirs+=("$(basename "$(dirname "$m")")")
	done
fi

for dir in "${dirs[@]}"; do
	echo "=== $dir"
	manifest="$REPO_ROOT/templates/$dir/vpsctl.yml"
	[[ -f "$manifest" ]] || {
		fail "$dir: vpsctl.yml not found"
		continue
	}
	check_manifest "$dir"
	check_compose "$dir"
done

finish
echo "templates ok: ${dirs[*]}"
