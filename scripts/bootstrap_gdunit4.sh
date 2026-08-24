#!/usr/bin/env bash

set -euo pipefail

GDUNIT_VERSION="6.2.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADDON_DIR="$PROJECT_ROOT/addons/gdUnit4"

if [ -d "$ADDON_DIR" ]; then
	exit 0
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gdunit4-bootstrap.XXXXXX")"
cleanup() {
	rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

ARCHIVE="$TEMP_DIR/gdUnit4.zip"
EXTRACTED="$TEMP_DIR/extracted"
DOWNLOAD_URL="https://github.com/godot-gdunit-labs/gdUnit4/archive/refs/tags/v${GDUNIT_VERSION}.zip"

mkdir -p "$EXTRACTED"
curl --fail --location --silent --show-error "$DOWNLOAD_URL" --output "$ARCHIVE"

case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*)
		archive_path="$ARCHIVE"
		extracted_path="$EXTRACTED"
		if command -v cygpath >/dev/null 2>&1; then
			archive_path="$(cygpath --windows "$ARCHIVE")"
			extracted_path="$(cygpath --windows "$EXTRACTED")"
		fi
		powershell.exe -NoProfile -NonInteractive -Command \
			"Expand-Archive -LiteralPath '$archive_path' -DestinationPath '$extracted_path' -Force"
		;;
	*)
		unzip -q "$ARCHIVE" -d "$EXTRACTED"
		;;
esac

SOURCE_DIR=""
for candidate in "$EXTRACTED/addons/gdUnit4" "$EXTRACTED/gdUnit4" "$EXTRACTED"/*/addons/gdUnit4; do
	if [ -d "$candidate" ]; then
		SOURCE_DIR="$candidate"
		break
	fi
done

if [ -z "$SOURCE_DIR" ]; then
	echo "The GdUnit4 release archive did not contain addons/gdUnit4." >&2
	exit 1
fi

mkdir -p "$PROJECT_ROOT/addons"
cp -R "$SOURCE_DIR" "$ADDON_DIR"
