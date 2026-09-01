#!/usr/bin/env bash

# Release package contract: the archive contains addons/gdunit_e2e/** (with
# the shipped C# client), README.md, LICENSE, and NOTICE; and contains no root
# project/solution files, tests, GdUnit4, reports, or test output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/godot-e2e-package-test.XXXXXX")"
TEST_VERSION="9.8.7"

cleanup() {
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

GODOT_E2E_DIST_DIR="$WORK_DIR/dist" bash "$PROJECT_ROOT/scripts/package_release.sh" "$TEST_VERSION"

expected_archive="$WORK_DIR/dist/godot-e2e-$TEST_VERSION.zip"
if [ ! -f "$expected_archive" ]; then
	echo "Expected release archive: $expected_archive" >&2
	exit 1
fi

archives=("$WORK_DIR/dist"/*.zip)
if [ "${#archives[@]}" -ne 1 ]; then
	echo "Expected exactly one release archive, found ${#archives[@]}." >&2
	exit 1
fi
archive="${archives[0]}"
listing="$(unzip -Z1 "$archive")"

must_include=(
	"addons/gdunit_e2e/csharp/.gdignore"
	"addons/gdunit_e2e/csharp/GodotE2E.Client.csproj"
	"addons/gdunit_e2e/csharp/E2EClient.cs"
	"addons/gdunit_e2e/csharp/E2EGame.cs"
	"addons/gdunit_e2e/client/e2e_client.gd"
	"addons/gdunit_e2e/server/automation_server.gd"
	"README.md"
	"LICENSE"
	"NOTICE"
)
for entry in "${must_include[@]}"; do
	if ! grep -qxF "$entry" <<<"$listing"; then
		echo "Release archive is missing required entry: $entry" >&2
		exit 1
	fi
done

must_exclude=(
	"GodotE2E.csproj"
	"GodotE2E.sln"
	"tests/csharp/GodotE2E.Tests.csproj"
	"tests/fixtures/csharp/main.tscn"
	"addons/gdUnit4/plugin.cfg"
)
for entry in "${must_exclude[@]}"; do
	if grep -qxF "$entry" <<<"$listing"; then
		echo "Release archive must not contain: $entry" >&2
		exit 1
	fi
done

forbidden_prefixes=(
	"^tests/"
	"^addons/gdUnit4/"
	"^addons/gdunit_e2e/csharp/bin/"
	"^addons/gdunit_e2e/csharp/obj/"
	"^reports/"
	"^test_output/"
	"^GodotE2E\\.(csproj|sln)$"
)
for pattern in "${forbidden_prefixes[@]}"; do
	if grep -Eq "$pattern" <<<"$listing"; then
		echo "Release archive contains forbidden content ($pattern):" >&2
		grep -E "$pattern" <<<"$listing" >&2
		exit 1
	fi
done

echo "Release package contract satisfied: $archive"
