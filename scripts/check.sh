#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
#
# Formatting, static analysis and the test suites, as CI runs them.
#
#   scripts/check.sh format   Rewrite C/C++ (clang-format) and GDScript
#                             (gdformat) in place.
#   scripts/check.sh lint     Check formatting and run every linter:
#                             clang-format, clang-tidy, gdformat, gdlint,
#                             bash -n, shellcheck and reuse.
#   scripts/check.sh check    Build the editor target with -Werror, lint, then
#                             run the mock-backed suite and the native smoke
#                             test. Everything CI does except the sanitizer job.
#
# Single steps, as the CI jobs call them: clang-format, clang-tidy, gdscript,
# shell, reuse.
#
# Every tool except Godot is run through uvx at a pinned version, so local
# results match CI exactly; only uv (https://docs.astral.sh/uv/) is required.
# clang-tidy needs build-editor/compile_commands.json, which
# `scripts/build.sh --target editor` exports. It runs on Linux only.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Bump these together with any reformatting they cause. clang-format output in
# particular differs between releases.
CLANG_FORMAT_VERSION="22.1.8"
CLANG_TIDY_VERSION="22.1.8"
GDTOOLKIT_VERSION="4.5.0"
SHELLCHECK_VERSION="0.11.0.1"
REUSE_VERSION="6.2.0"

# C and C++ sources owned by this project. mac_power_monitor.mm is left out:
# it is Objective-C++ built only on macOS, and .clang-format disables
# formatting for Objective-C. godot-cpp lives under build-*/_deps and is never
# listed here.
CXX_FORMAT_FILES=(src/*.cpp src/*.h tests/native/*.c)
# The translation units clang-tidy analyses: the Linux build's sources.
CXX_TIDY_FILES=(src/gvariant_conv.cpp src/register_types.cpp src/xdg_portal_native.cpp)
GDSCRIPT_DIRS=(addons tests demo)
SHELL_FILES=(scripts/*.sh)

uvx_tool() {
	local package="$1"
	shift
	uvx --quiet --from "$package" "$@"
}

clang_format() { uvx_tool "clang-format==$CLANG_FORMAT_VERSION" clang-format "$@"; }
clang_tidy() { uvx_tool "clang-tidy==$CLANG_TIDY_VERSION" clang-tidy "$@"; }
gdformat() { uvx_tool "gdtoolkit==$GDTOOLKIT_VERSION" gdformat "$@"; }
gdlint() { uvx_tool "gdtoolkit==$GDTOOLKIT_VERSION" gdlint "$@"; }
shellcheck() { uvx_tool "shellcheck-py==$SHELLCHECK_VERSION" shellcheck "$@"; }
reuse() { uvx_tool "reuse==$REUSE_VERSION" reuse "$@"; }

step() {
	echo
	echo "==> $*"
}

run_format() {
	step "clang-format (rewrite)"
	clang_format -i "${CXX_FORMAT_FILES[@]}"
	step "gdformat (rewrite)"
	gdformat "${GDSCRIPT_DIRS[@]}"
}

lint_clang_format() {
	step "clang-format $CLANG_FORMAT_VERSION"
	clang_format --dry-run --Werror "${CXX_FORMAT_FILES[@]}"
}

lint_clang_tidy() {
	step "clang-tidy $CLANG_TIDY_VERSION"
	if [[ "$(uname -s)" != "Linux" ]]; then
		echo "clang-tidy analyses the Linux build only; skipped on $(uname -s)."
		return 0
	fi
	local database="${CLANG_TIDY_BUILD_DIR:-build-editor}"
	if [[ ! -f "$database/compile_commands.json" ]]; then
		echo "No $database/compile_commands.json; run ./scripts/build.sh --target editor first." >&2
		return 2
	fi
	clang_tidy -p "$database" --quiet "${CXX_TIDY_FILES[@]}"
}

lint_gdscript() {
	step "gdformat --check / gdlint $GDTOOLKIT_VERSION"
	gdformat --check "${GDSCRIPT_DIRS[@]}"
	gdlint "${GDSCRIPT_DIRS[@]}"
}

lint_shell() {
	step "bash -n / shellcheck $SHELLCHECK_VERSION"
	local script
	for script in "${SHELL_FILES[@]}"; do
		bash -n "$script"
	done
	shellcheck "${SHELL_FILES[@]}"
}

lint_reuse() {
	step "reuse lint $REUSE_VERSION"
	reuse lint
}

run_lint() {
	lint_clang_format
	lint_gdscript
	lint_shell
	lint_reuse
	lint_clang_tidy
}

run_check() {
	if [[ "$(uname -s)" == "Linux" ]]; then
		step "build (editor, -Werror)"
		./scripts/build.sh --target editor --werror
	fi
	run_lint
	step "mock-backed test suite"
	./scripts/run_tests.sh
	if [[ "$(uname -s)" == "Linux" ]]; then
		step "native smoke test"
		./scripts/run_native_smoke.sh
	fi
}

usage() {
	sed -n '5,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	format) run_format ;;
	lint) run_lint ;;
	check) run_check ;;
	clang-format) lint_clang_format ;;
	clang-tidy) lint_clang_tidy ;;
	gdscript) lint_gdscript ;;
	shell) lint_shell ;;
	reuse) lint_reuse ;;
	-h | --help | help) usage ;;
	*)
		usage >&2
		exit 2
		;;
esac
