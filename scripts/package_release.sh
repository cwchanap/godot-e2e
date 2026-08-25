#!/usr/bin/env bash

set -euo pipefail

VERSION="0.1.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"
ARCHIVE="$DIST_DIR/godot-e2e-$VERSION.zip"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/godot-e2e-package.XXXXXX")"

cleanup() {
	rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if ! command -v zip >/dev/null 2>&1; then
	echo "The zip command is required to create the release archive." >&2
	exit 1
fi

for required_file in README.md LICENSE NOTICE; do
	if [ ! -f "$PROJECT_ROOT/$required_file" ]; then
		echo "Missing release file: $required_file" >&2
		exit 1
	fi
done

if [ ! -d "$PROJECT_ROOT/addons/gdunit_e2e" ]; then
	echo "Missing release addon: addons/gdunit_e2e" >&2
	exit 1
fi

mkdir -p "$STAGING_DIR/addons" "$DIST_DIR"
cp -R "$PROJECT_ROOT/addons/gdunit_e2e" "$STAGING_DIR/addons/"
cp "$PROJECT_ROOT/README.md" "$PROJECT_ROOT/LICENSE" "$PROJECT_ROOT/NOTICE" "$STAGING_DIR/"

# Build from an explicit staging tree so development-only files cannot enter
# the archive as a side effect of running this script from the repository root.
rm -f "$ARCHIVE"
(
	cd "$STAGING_DIR"
	zip -q -r "$ARCHIVE" addons/gdunit_e2e README.md LICENSE NOTICE
)

echo "Created $ARCHIVE"
