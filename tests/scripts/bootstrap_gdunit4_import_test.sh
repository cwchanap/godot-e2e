#!/usr/bin/env bash

set -euo pipefail

if [ -z "${GODOT_BIN:-}" ]; then
	echo "GODOT_BIN must point to the Godot executable." >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gdunit4-clean-bootstrap.XXXXXX")"

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

git -C "$PROJECT_ROOT" archive HEAD | tar -x -C "$TEST_ROOT"
cp "$PROJECT_ROOT/scripts/bootstrap_gdunit4.sh" "$TEST_ROOT/scripts/bootstrap_gdunit4.sh"
mkdir -p "$TEST_ROOT/addons"
cp -R "$PROJECT_ROOT/addons/gdUnit4" "$TEST_ROOT/addons/gdUnit4"

GODOT_BIN="$GODOT_BIN" bash "$TEST_ROOT/scripts/bootstrap_gdunit4.sh"

CLASS_CACHE="$TEST_ROOT/.godot/global_script_class_cache.cfg"
if [ ! -f "$CLASS_CACHE" ]; then
	echo "Bootstrap did not create Godot's global script class cache." >&2
	exit 1
fi
if ! grep -q '"class": &"GdUnitTestCIRunner"' "$CLASS_CACHE"; then
	echo "Bootstrap did not index GdUnitTestCIRunner." >&2
	exit 1
fi
