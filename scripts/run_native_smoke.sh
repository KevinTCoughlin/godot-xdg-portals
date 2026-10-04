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
# The test runs once per mode, each on a fresh bus with the fake portal started
# with that mode's options. --mode NAME (repeatable) runs only those modes.
#
#   default      The full check against a well-behaved portal.
#   immediate    The full check with Request::Response sent the instant the
#                method returns, and GameMode already active for another game.
#   slow-start   The portal stalls its first property read past the client's
#                timeout; change notifications must still arrive.
#   restart      The portal exits with an OpenURI request pending and is
#                started again; the request must complete, and the client must
#                follow the new instance.
#   wedged-bus   The extension is pointed at a socket that accepts connections
#                and never answers; connecting must give up in bounded time.
#                Godot itself keeps the real session bus: it talks D-Bus too,
#                without a timeout, and would hang first.
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

ALL_MODES=(default immediate slow-start restart wedged-bus)
MODES=()
SANITIZE=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--sanitize) SANITIZE=1; shift ;;
		--mode)
			if [[ $# -lt 2 || " ${ALL_MODES[*]} " != *" $2 "* ]]; then
				echo "--mode takes one of: ${ALL_MODES[*]}" >&2
				exit 2
			fi
			MODES+=("$2")
			shift 2
			;;
		-h|--help) sed -n '6,40p' "${BASH_SOURCE[0]}" | cut -c3-; exit 0 ;;
		*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
done
if [[ ${#MODES[@]} -eq 0 ]]; then
	MODES=("${ALL_MODES[@]}")
fi

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

# The suite refers to `class_name` types (DesktopServicesBackend and friends), which
# are only resolvable once Godot has written the global class cache. On a fresh
# checkout .godot/ does not exist yet, so this import pass is required — without
# it the script fails to parse before a single check runs.
"$GODOT_BIN" --headless --path "$REPO_ROOT" --import >/dev/null

export WORK_DIR REPO_ROOT GODOT_BIN

# Every pass is bounded from outside as well as by the test's own watchdog: a
# client that blocks Godot's main thread never lets the watchdog fire.
PASS_TIMEOUT_SECONDS=60

run_client() {
	local mode="$1"
	XDG_PORTALS_SMOKE_MODE="$mode" timeout --kill-after=5 "$PASS_TIMEOUT_SECONDS" \
		"$GODOT_BIN" --headless --path "$REPO_ROOT" --script res://tests/native/native_smoke.gd
}

# Runs inside dbus-run-session: starts the fake portal with the mode's options,
# waits for it to own the portal name, then runs the client.
run_session_pass() {
	local mode="$1" log="$WORK_DIR/portal-$1.log"
	local -a options=()
	case "$mode" in
		immediate) options=(--response-delay 0 --gamemode-other-active) ;;
		slow-start) options=(--first-get-delay 2500) ;;
		restart) options=(--exit-after-open-uri) ;;
	esac

	if [[ "$mode" == "restart" ]]; then
		# The first instance exits on its own mid-request; a well-behaved one
		# takes its place, as a session manager would restart the service.
		(
			"$WORK_DIR/fake-portal" "${options[@]}"
			echo "fake-portal: restarting"
			exec "$WORK_DIR/fake-portal"
		) > "$log" 2>&1 &
	else
		"$WORK_DIR/fake-portal" "${options[@]}" > "$log" 2>&1 &
	fi
	portal_pid=$!
	# Global, not local: the EXIT trap runs after this function has returned.
	# Ending the session takes the bus down, and the fixture with it.
	trap 'kill "$portal_pid" 2>/dev/null || true' EXIT

	for _ in $(seq 1 100); do
		if grep -q "ready as" "$log" 2>/dev/null; then
			break
		fi
		if ! kill -0 "$portal_pid" 2>/dev/null; then
			echo "The fake portal exited early:" >&2
			cat "$log" >&2
			return 1
		fi
		sleep 0.1
	done

	if ! grep -q "ready as" "$log"; then
		echo "The fake portal never became ready." >&2
		cat "$log" >&2
		return 1
	fi

	if [[ "$mode" == "wedged-bus" ]]; then
		# A second fixture, as the socket that never answers. The ordinary one
		# keeps owning the portal name, or Godot's own D-Bus traffic would
		# activate whatever real portal service is installed.
		local socket="$WORK_DIR/wedged-bus.sock"
		"$WORK_DIR/fake-portal" --wedged-bus "$socket" >> "$log" 2>&1 &
		wedged_pid=$!
		trap 'kill "$portal_pid" "$wedged_pid" 2>/dev/null || true' EXIT
		for _ in $(seq 1 100); do
			if [[ -S "$socket" ]]; then
				break
			fi
			sleep 0.1
		done
		# Read by native_smoke.gd, which points only the extension at it.
		XDG_PORTALS_SMOKE_WEDGED_BUS="unix:path=$socket" run_client "$mode"
	else
		run_client "$mode"
	fi
}
export -f run_client run_session_pass
export PASS_TIMEOUT_SECONDS

failed_modes=()
for mode in "${MODES[@]}"; do
	echo
	echo "==> native smoke: $mode"
	status=0
	# The single quotes are deliberate: "$1" is the inner shell's argument.
	# shellcheck disable=SC2016
	dbus-run-session -- bash -euo pipefail -c 'run_session_pass "$1"' _ "$mode" || status=$?
	if [[ "$status" -ne 0 ]]; then
		failed_modes+=("$mode")
		if [[ -f "$WORK_DIR/portal-$mode.log" ]]; then
			echo "--- fake portal log ($mode) ---"
			cat "$WORK_DIR/portal-$mode.log"
		fi
	fi
done

echo
if [[ ${#failed_modes[@]} -gt 0 ]]; then
	echo "native smoke: failed in ${failed_modes[*]}"
	exit 1
fi
echo "native smoke: every mode passed (${MODES[*]})"
