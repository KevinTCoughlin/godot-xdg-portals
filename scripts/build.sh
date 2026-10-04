#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
#
# Builds the GDExtension into addons/xdg_portals/bin. What gets built depends on
# the host: the full XdgPortalNative portal bridge on Linux, the MacPowerMonitor
# power monitor on macOS. No other platform has a native build.
#
# Requirements: cmake >= 3.22 and a C++17 compiler, plus — on Linux —
# pkg-config and the GLib/GIO development headers (libglib2.0-dev on
# Debian/Ubuntu). macOS needs only the Xcode command line tools.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGET="template_release"
BUILD_TYPE="Release"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
GODOT_CPP_PATH=""
BUILD_DIR=""
WERROR=0
SANITIZE=0

usage() {
	cat <<'EOF'
Usage: scripts/build.sh [options]

Options:
  -t, --target TARGET   godot-cpp target: template_release (default),
                        template_debug or editor.
  -j, --jobs N          Parallel compile jobs (default: nproc).
      --godot-cpp PATH  Use a local godot-cpp checkout instead of fetching the
                        pinned tag.
      --build-dir PATH  Build directory (default: build-<target>).
      --clean           Remove the build directory before configuring.
      --werror          Treat compiler warnings as errors (CI does this).
      --sanitize        Build with AddressSanitizer and UBSan (Linux only;
                        default build directory build-<target>-sanitize).
                        Run the result with scripts/run_native_smoke.sh
                        --sanitize. The library overwrites the normal one in
                        addons/xdg_portals/bin, so rebuild without it after.
  -h, --help            Show this help.

The resulting library is written to the path
addons/xdg_portals/xdg_portals.gdextension expects:

  Linux   addons/xdg_portals/bin/libxdg_portals.linux.<target>.<arch>.so
  macOS   addons/xdg_portals/bin/libxdg_portals.macos.<target>.dylib

macOS libraries are universal (x86_64 + arm64), so no architecture appears in
the name.
EOF
}

CLEAN=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		-t|--target) TARGET="$2"; shift 2 ;;
		-j|--jobs) JOBS="$2"; shift 2 ;;
		--godot-cpp) GODOT_CPP_PATH="$2"; shift 2 ;;
		--build-dir) BUILD_DIR="$2"; shift 2 ;;
		--clean) CLEAN=1; shift ;;
		--werror) WERROR=1; shift ;;
		--sanitize) SANITIZE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

case "$TARGET" in
	template_release|template_debug|editor) ;;
	*) echo "Invalid target '$TARGET'." >&2; exit 2 ;;
esac

if [[ "$TARGET" == "template_debug" ]]; then
	BUILD_TYPE="Debug"
fi
# Sanitizer reports need line numbers and frames that were not inlined away.
if [[ "$SANITIZE" -eq 1 ]]; then
	BUILD_TYPE="RelWithDebInfo"
fi

if [[ -z "$BUILD_DIR" ]]; then
	BUILD_DIR="$REPO_ROOT/build-$TARGET"
	if [[ "$SANITIZE" -eq 1 ]]; then
		BUILD_DIR="$BUILD_DIR-sanitize"
	fi
fi

if [[ "$CLEAN" -eq 1 ]]; then
	rm -rf "$BUILD_DIR"
fi

CONFIGURE_ARGS=(
	-S "$REPO_ROOT"
	-B "$BUILD_DIR"
	-DCMAKE_BUILD_TYPE="$BUILD_TYPE"
	-DGODOTCPP_TARGET="$TARGET"
	-DXDG_PORTALS_WERROR="$([[ "$WERROR" -eq 1 ]] && echo ON || echo OFF)"
	-DXDG_PORTALS_SANITIZE="$([[ "$SANITIZE" -eq 1 ]] && echo ON || echo OFF)"
)
if [[ -n "$GODOT_CPP_PATH" ]]; then
	CONFIGURE_ARGS+=(-DXDG_PORTALS_GODOT_CPP_PATH="$GODOT_CPP_PATH")
fi

cmake "${CONFIGURE_ARGS[@]}"
# The normal and --sanitize builds write the same output file from different
# build directories, so whichever ran last would look up to date to the other
# and never be relinked. Removing it first forces the link; nothing recompiles.
case "$(uname -s)" in
	Darwin) OUTPUT_NAME="libxdg_portals.macos.$TARGET.dylib" ;;
	*)
		case "$(uname -m)" in
			aarch64|arm64) OUTPUT_ARCH="arm64" ;;
			*) OUTPUT_ARCH="$(uname -m)" ;;
		esac
		OUTPUT_NAME="libxdg_portals.linux.$TARGET.$OUTPUT_ARCH.so"
		;;
esac
rm -f "$REPO_ROOT/addons/xdg_portals/bin/$OUTPUT_NAME"

cmake --build "$BUILD_DIR" --parallel "$JOBS"

echo
echo "Built libraries in addons/xdg_portals/bin:"
ls -1 "$REPO_ROOT/addons/xdg_portals/bin"
