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

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

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

if ! compgen -G "$REPO_ROOT/addons/xdg_portals/bin/libxdg_portals.linux.editor.*.so" >/dev/null; then
	echo "Build the editor target first: ./scripts/build.sh --target editor" >&2
	exit 2
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
