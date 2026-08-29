#!/usr/bin/env bash

set -euo pipefail

if [ -z "${GODOT_BIN:-}" ]; then
	echo "GODOT_BIN must point to the Godot executable." >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Strip the C# feature from config/features and drop the [dotnet] section so
# the temporary project is a plain GDScript Godot project.
strip_csharp_metadata() {
	local target="$1"
	awk '
		/^\[dotnet\][ \t]*$/ { in_dotnet = 1; next }
		in_dotnet && /^\[/ { in_dotnet = 0 }
		in_dotnet { next }
		/^config\/features=/ {
			sub(/"C#", /, "")
			sub(/, "C#"/, "")
		}
		{ print }
	' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gdunit4-clean-bootstrap.XXXXXX")"

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

git -C "$PROJECT_ROOT" archive HEAD | tar -x -C "$TEST_ROOT"
cp "$PROJECT_ROOT/scripts/bootstrap_gdunit4.sh" "$TEST_ROOT/scripts/bootstrap_gdunit4.sh"
mkdir -p "$TEST_ROOT/addons"
cp -R "$PROJECT_ROOT/addons/gdUnit4" "$TEST_ROOT/addons/gdUnit4"

# Restore the GDScript-only consumer shape: remove repository-only C# project
# and test/fixture material. The shipped client under addons/gdunit_e2e/csharp
# intentionally stays; .gdignore keeps it out of Godot's resource scan and the
# temp project is never C#-built.
rm -f "$TEST_ROOT/GodotE2E.csproj" "$TEST_ROOT/GodotE2E.sln"
rm -rf "$TEST_ROOT/tests/csharp" "$TEST_ROOT/tests/fixtures/csharp"
strip_csharp_metadata "$TEST_ROOT/project.godot"

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
