#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
#
# Runs the mock-backed test suite headlessly.
#
# The suite never touches D-Bus, so it produces identical results on a developer
# desktop and on a CI runner with no session bus and no display.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

echo "Using Godot: $("$GODOT_BIN" --headless --version)"

# The first headless run imports assets and generates the global class cache the
# suite relies on; it is expected to exit before the tests run.
"$GODOT_BIN" --headless --path "$REPO_ROOT" --import >/dev/null

"$GODOT_BIN" --headless --path "$REPO_ROOT" --script res://tests/run_tests.gd
