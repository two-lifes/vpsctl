#!/usr/bin/env bash
set -euo pipefail

# Deliberately failing test: CI checks that run.sh reports a failure with a non-zero exit code.

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fail "intentional failure"
finish
