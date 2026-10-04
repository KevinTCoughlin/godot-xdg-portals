#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
#
# Runs the native backend against the scripted fake portal in
# tests/native/fake_portal.c, on a private session bus.
#
# This exercises the real GIO code path — bus connection, request-handle
# prediction, bounded synchronous calls, and the Response / PropertiesChanged /
# ActionInvoked signal paths — without a desktop. It does NOT replace the manual
# checks in docs/native-testing.md, which need a real portal service and a human
# to answer the dialogs it shows.
#
# Requirements: gcc, pkg-config, libglib2.0-dev, dbus-daemon, and an editor-target
# build of the extension (scripts/build.sh --target editor).
#
# --sanitize runs the same test against a library built with
# `scripts/build.sh --target editor --sanitize` (AddressSanitizer + UBSan).
# Godot itself is not instrumented, so the ASan runtime the library links is
# preloaded into the Godot process, and only into it: neither dbus-run-session
# nor the fake portal is affected. Leak checking is on; tests/native/lsan.supp
# suppresses only leaks from code this project does not own, and says why for
# each. Set XDG_PORTALS_ASAN_RUNTIME to the runtime's path if it cannot be
# found automatically.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SANITIZE=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--sanitize) SANITIZE=1; shift ;;
		-h|--help) sed -n '6,25p' "${BASH_SOURCE[0]}" | cut -c3-; exit 0 ;;
		*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
done

GODOT_BIN="${GODOT:-}"
if [[ -z "$GODOT_BIN" ]]; then
	for candidate in godot godot4 Godot; do
		if command -v "$candidate" >/dev/null 2>&1; then
			GODOT_BIN="$candidate"
			break
		fi
	done
fi

if [[ -z "$GODOT_BIN" ]]; then
	echo "No Godot binary found. Set GODOT=/path/to/godot (4.4 or newer)." >&2
	exit 2
fi

if ! command -v dbus-run-session >/dev/null 2>&1; then
	echo "dbus-run-session is required (package: dbus, dbus-daemon or dbus-bin)." >&2
	exit 2
fi

LIBRARIES=("$REPO_ROOT"/addons/xdg_portals/bin/libxdg_portals.linux.editor.*.so)
if [[ ! -f "${LIBRARIES[0]}" ]]; then
	echo "Build the editor target first: ./scripts/build.sh --target editor" >&2
	exit 2
fi

# Prints the path of the ASan runtime a sanitized library depends on, or
# nothing. GCC's libasan normally resolves through ldd; clang's
# libclang_rt.asan lives in the compiler's resource directory, which the
# compiler itself can name.
find_asan_runtime() {
	local library="$1" name path compiler
	name="$(ldd "$library" | awk '$1 ~ /^lib(asan|clang_rt\.asan)/ { print $1; exit }')"
	if [[ -z "$name" ]]; then
		return 0
	fi
	path="$(ldd "$library" | awk -v name="$name" '$1 == name && $3 ~ /^\// { print $3; exit }')"
	if [[ -z "$path" ]]; then
		for compiler in "${CXX:-}" clang++ g++; do
			if [[ -z "$compiler" ]] || ! command -v "$compiler" >/dev/null 2>&1; then
				continue
			fi
			path="$("$compiler" -print-file-name="$name")"
			if [[ "$path" == /* && -f "$path" ]]; then
				break
			fi
			path=""
		done
	fi
	printf '%s' "$path"
}

if [[ "$SANITIZE" -eq 1 ]]; then
	ASAN_RUNTIME="${XDG_PORTALS_ASAN_RUNTIME:-$(find_asan_runtime "${LIBRARIES[0]}")}"
	if [[ -z "$ASAN_RUNTIME" || ! -f "$ASAN_RUNTIME" ]]; then
		echo "${LIBRARIES[0]} links no ASan runtime that could be found." >&2
		echo "Build it with ./scripts/build.sh --target editor --sanitize, or set XDG_PORTALS_ASAN_RUNTIME." >&2
		exit 2
	fi
	echo "Preloading $ASAN_RUNTIME into Godot."

	# Godot opens extensions with RTLD_DEEPBIND, which the ASan runtime
	# rejects; this shim strips the flag. It must precede the runtime in
	# LD_PRELOAD to interpose dlopen() ahead of ASan's own interceptor, hence
	# verify_asan_link_order=0. See tests/native/sanitizer_preload.c.
	cc -std=c11 -Wall -Wextra -O1 -shared -fPIC -o "$WORK_DIR/sanitizer_preload.so" \
		"$REPO_ROOT/tests/native/sanitizer_preload.c" -ldl

	asan_options="detect_leaks=1:verify_asan_link_order=0"
	lsan_options="suppressions=$REPO_ROOT/tests/native/lsan.supp:print_suppressions=0"
	ubsan_options="print_stacktrace=1:halt_on_error=1"

	# A wrapper keeps the sanitizer environment off everything but Godot.
	# libstdc++ is preloaded too: the official Godot binaries link the C++
	# runtime statically, and the ASan/UBSan runtime needs its type_info
	# symbols from a shared one.
	{
		echo '#!/usr/bin/env bash'
		printf 'export LD_PRELOAD=%q\n' "$WORK_DIR/sanitizer_preload.so $ASAN_RUNTIME libstdc++.so.6"
		printf 'export ASAN_OPTIONS=%q\n' "$asan_options${ASAN_OPTIONS:+:$ASAN_OPTIONS}"
		printf 'export LSAN_OPTIONS=%q\n' "$lsan_options${LSAN_OPTIONS:+:$LSAN_OPTIONS}"
		printf 'export UBSAN_OPTIONS=%q\n' "$ubsan_options${UBSAN_OPTIONS:+:$UBSAN_OPTIONS}"
		printf 'exec %q "$@"\n' "$GODOT_BIN"
	} > "$WORK_DIR/godot"
	chmod +x "$WORK_DIR/godot"
	GODOT_BIN="$WORK_DIR/godot"
fi

echo "Building the fake portal fixture…"
# shellcheck disable=SC2046  # pkg-config intentionally expands to several flags.
cc -std=c11 -Wall -Wextra -O1 -o "$WORK_DIR/fake-portal" \
	"$REPO_ROOT/tests/native/fake_portal.c" $(pkg-config --cflags --libs gio-2.0)

# The suite refers to `class_name` types (XDGPortalBackend and friends), which
# are only resolvable once Godot has written the global class cache. On a fresh
# checkout .godot/ does not exist yet, so this import pass is required — without
# it the script fails to parse before a single check runs.
"$GODOT_BIN" --headless --path "$REPO_ROOT" --import >/dev/null

export WORK_DIR REPO_ROOT GODOT_BIN

# The single quotes are deliberate: the inner bash expands the exported
# variables itself.
# shellcheck disable=SC2016
dbus-run-session -- bash -euo pipefail -c '
	"$WORK_DIR/fake-portal" > "$WORK_DIR/portal.log" 2>&1 &
	portal_pid=$!
	trap "kill $portal_pid 2>/dev/null || true" EXIT

	# Wait for the fixture to own the portal name before starting the client.
	for _ in $(seq 1 100); do
		if grep -q "ready as" "$WORK_DIR/portal.log" 2>/dev/null; then
			break
		fi
		if ! kill -0 $portal_pid 2>/dev/null; then
			echo "The fake portal exited early:" >&2
			cat "$WORK_DIR/portal.log" >&2
			exit 1
		fi
		sleep 0.1
	done

	if ! grep -q "ready as" "$WORK_DIR/portal.log"; then
		echo "The fake portal never acquired org.freedesktop.portal.Desktop." >&2
		cat "$WORK_DIR/portal.log" >&2
		exit 1
	fi

	"$GODOT_BIN" --headless --path "$REPO_ROOT" --script res://tests/native/native_smoke.gd
'
