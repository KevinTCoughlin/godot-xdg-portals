#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
#
# Build a distributable zip of the addon.
#
#   scripts/package_addon.sh --layout asset-store --output dist
#   scripts/package_addon.sh --layout linux --arch x86_64 --output dist
#   scripts/package_addon.sh --self-test
#   scripts/package_addon.sh --check-export
#
# asset-store is the Godot Asset Library layout: the zip root is addons/, and
# the licence, readme, changelog and third-party notices sit inside the plugin
# folder. Every library named by xdg_portals.gdextension must already be in
# addons/xdg_portals/bin/.
#
# linux is one architecture, with the docs at the archive root. Same
# requirement for that architecture's three libraries.
#
# --revision TEXT is appended to the version in the filename
# (godot-xdg-portals-0.2.1-g<sha>-asset-store.zip). Release tags omit it.
# The version in the filename defaults to plugin.cfg. --version overrides it.
#
# The zip bytes depend only on the file contents and SOURCE_DATE_EPOCH
# (the commit time, unless you set it). Native libraries are not bit-identical
# across compilers; given the same inputs, the archive is.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TZ=UTC

usage() {
	sed -n '5,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

plugin_version() {
	local version
	version="$(sed -n 's/^version="\([0-9][0-9.]*\)"$/\1/p' \
		"$REPO_ROOT/addons/xdg_portals/plugin.cfg")"
	if [[ -z "$version" ]]; then
		echo "Could not read version= from addons/xdg_portals/plugin.cfg." >&2
		exit 1
	fi
	printf '%s\n' "$version"
}

# Print res:// library paths, one per line, unique.
gdextension_libraries() {
	grep -o 'res://addons/xdg_portals/[^"]*' \
		"$REPO_ROOT/addons/xdg_portals/xdg_portals.gdextension" | sort -u
}

write_deterministic_zip() {
	local root="$1"
	local destination="$2"
	local epoch="$3"
	python3 - "$root" "$destination" "$epoch" <<'PY'
import sys
import time
import zipfile
from pathlib import Path

root = Path(sys.argv[1])
destination = Path(sys.argv[2])
epoch = int(sys.argv[3])
stamp = time.gmtime(epoch)[:6]
files = []
for path in root.rglob("*"):
    if not path.is_file():
        continue
    rel = path.relative_to(root).as_posix()
    files.append((rel, path))
files.sort()
destination.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(destination, "w") as archive:
    for rel, path in files:
        info = zipfile.ZipInfo(filename=rel, date_time=stamp)
        mode = 0o755 if rel.endswith((".so", ".dylib")) else 0o644
        info.external_attr = (mode & 0xFFFF) << 16
        info.create_system = 3
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, path.read_bytes(), compresslevel=9)
PY
}

copy_docs_into_plugin() {
	local plugin_dir="$1"
	cp "$REPO_ROOT/README.md" "$plugin_dir/README.md"
	cp "$REPO_ROOT/LICENSE" "$plugin_dir/LICENSE"
	cp "$REPO_ROOT/CHANGELOG.md" "$plugin_dir/CHANGELOG.md"
	cp "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$plugin_dir/THIRD_PARTY_NOTICES.md"
}

# Drop editor noise. Keep bin/.gdignore: Godot must not import the libraries.
strip_hidden() {
	local root="$1"
	# -prune so a removed directory is not visited again.
	find "$root" -mindepth 1 -name '.*' ! -name '.gdignore' -prune -exec rm -rf {} +
}

require_file() {
	local path="$1"
	if [[ ! -f "$path" ]]; then
		echo "Missing ${path}" >&2
		exit 1
	fi
}

package_asset_store() {
	local output_dir="$1"
	local version="$2"
	local revision="$3"
	local epoch="$4"
	local name="godot-xdg-portals-${version}"
	local stage plugin rel dest
	if [[ -n "$revision" ]]; then
		name="${name}-${revision}"
	fi
	name="${name}-asset-store"
	stage="$(mktemp -d)"
	mkdir -p "${stage}/addons"
	cp -a "$REPO_ROOT/addons/xdg_portals" "${stage}/addons/"
	plugin="${stage}/addons/xdg_portals"
	copy_docs_into_plugin "$plugin"
	strip_hidden "$stage"
	while IFS= read -r rel; do
		require_file "${stage}/${rel#res://}"
	done < <(gdextension_libraries)
	require_file "${plugin}/plugin.cfg"
	require_file "${plugin}/LICENSE"
	require_file "${plugin}/README.md"
	dest="${output_dir}/${name}.zip"
	mkdir -p "$output_dir"
	write_deterministic_zip "$stage" "$dest" "$epoch"
	rm -rf "$stage"
	(
		cd "$output_dir"
		sha256sum "${name}.zip" > "${name}.zip.sha256"
	)
	unzip -l "$dest"
	echo "Wrote ${dest}"
}

package_linux() {
	local output_dir="$1"
	local version="$2"
	local revision="$3"
	local arch="$4"
	local epoch="$5"
	local name="godot-xdg-portals-${version}"
	local stage root plugin bin dest other
	if [[ -n "$revision" ]]; then
		name="${name}-${revision}"
	fi
	name="${name}-linux-${arch}"
	stage="$(mktemp -d)"
	root="${stage}/${name}"
	mkdir -p "${root}/addons"
	cp -a "$REPO_ROOT/addons/xdg_portals" "${root}/addons/"
	plugin="${root}/addons/xdg_portals"
	bin="${plugin}/bin"
	cp "$REPO_ROOT/README.md" "$REPO_ROOT/LICENSE" \
		"$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$REPO_ROOT/CHANGELOG.md" "$root/"
	if [[ "$arch" == "x86_64" ]]; then
		other="arm64"
	else
		other="x86_64"
	fi
	find "$bin" -type f \( -name '*.dylib' -o -name "*.${other}.so" \) -delete
	require_file "${bin}/libxdg_portals.linux.template_release.${arch}.so"
	require_file "${bin}/libxdg_portals.linux.template_debug.${arch}.so"
	require_file "${bin}/libxdg_portals.linux.editor.${arch}.so"
	require_file "${plugin}/plugin.cfg"
	require_file "${plugin}/xdg_portals.gdextension"
	require_file "${plugin}/desktop_services.gd"
	require_file "${root}/LICENSE"
	strip_hidden "$stage"
	dest="${output_dir}/${name}.zip"
	mkdir -p "$output_dir"
	write_deterministic_zip "$stage" "$dest" "$epoch"
	rm -rf "$stage"
	(
		cd "$output_dir"
		sha256sum "${name}.zip" > "${name}.zip.sha256"
	)
	unzip -l "$dest"
	echo "Wrote ${dest}"
}

self_test() {
	local work first second third epoch
	work="$(mktemp -d)"
	mkdir -p "${work}/tree/bin" "${work}/out"
	printf 'hello\n' > "${work}/tree/bin/readme.txt"
	printf 'ignore\n' > "${work}/tree/bin/.gdignore"
	printf 'elf\n' > "${work}/tree/bin/libxdg_portals.linux.editor.x86_64.so"
	epoch=1700000000
	first="${work}/out/one.zip"
	second="${work}/out/two.zip"
	third="${work}/out/three.zip"
	write_deterministic_zip "${work}/tree" "$first" "$epoch"
	write_deterministic_zip "${work}/tree" "$second" "$epoch"
	cmp "$first" "$second"
	# DOS timestamps inside zip use a 2-second resolution.
	write_deterministic_zip "${work}/tree" "$third" "$((epoch + 2))"
	if cmp -s "$first" "$third"; then
		echo "A different SOURCE_DATE_EPOCH produced the same zip." >&2
		exit 1
	fi
	unzip -l "$first" | grep -q 'bin/.gdignore'
	unzip -l "$first" | grep -q 'bin/readme.txt'
	python3 - "$first" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    for info in archive.infolist():
        if info.date_time != (2023, 11, 14, 22, 13, 20):
            raise SystemExit(f"unexpected timestamp on {info.filename}: {info.date_time}")
        mode = (info.external_attr >> 16) & 0xFFFF
        if info.filename.endswith(".so"):
            if mode != 0o755:
                raise SystemExit(f"{info.filename} mode is {oct(mode)}")
        elif mode != 0o644:
            raise SystemExit(f"{info.filename} mode is {oct(mode)}")
PY
	rm -rf "$work"
	echo "package_addon self-test ok"
}

check_export() {
	local list path pattern
	list="$(git -C "$REPO_ROOT" archive --format=tar HEAD | tar -t)"
	for path in \
		addons/xdg_portals/plugin.cfg \
		addons/xdg_portals/plugin.gd \
		addons/xdg_portals/desktop_services.gd \
		addons/xdg_portals/LICENSE \
		addons/xdg_portals/README.md \
		addons/xdg_portals/icon.svg \
		addons/xdg_portals/bin/.gdignore; do
		if ! grep -qx "$path" <<<"$list"; then
			echo "git archive is missing ${path}" >&2
			exit 1
		fi
	done
	for pattern in \
		'^src/' '^tests/' '^demo/' '^docs/' '^scripts/' '^\.github/' \
		'^project.godot$' '^CMakeLists.txt$' '^README.md$'; do
		if grep -Eq "$pattern" <<<"$list"; then
			echo "git archive should not contain a path matching ${pattern}" >&2
			exit 1
		fi
	done
	echo "git archive export-ignore ok"
}

layout=""
output_dir=""
arch=""
version=""
revision=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--layout)
			layout="${2:-}"
			shift 2
			;;
		--output)
			output_dir="${2:-}"
			shift 2
			;;
		--arch)
			arch="${2:-}"
			shift 2
			;;
		--version)
			version="${2:-}"
			shift 2
			;;
		--revision)
			revision="${2:-}"
			shift 2
			;;
		--self-test)
			self_test
			exit 0
			;;
		--check-export)
			check_export
			exit 0
			;;
		-h | --help | help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

if [[ "$layout" != "asset-store" && "$layout" != "linux" ]]; then
	echo "--layout must be asset-store or linux." >&2
	exit 2
fi
if [[ -z "$output_dir" ]]; then
	echo "--output is required." >&2
	exit 2
fi
if [[ -z "$version" ]]; then
	version="$(plugin_version)"
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "Version '${version}' is not MAJOR.MINOR.PATCH." >&2
	exit 2
fi
if [[ -n "$revision" && ! "$revision" =~ ^[A-Za-z0-9._-]+$ ]]; then
	echo "Revision '${revision}' has characters that cannot go in a filename." >&2
	exit 2
fi

if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
	SOURCE_DATE_EPOCH="$(git -C "$REPO_ROOT" log -1 --format=%ct)"
fi
if [[ ! "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]]; then
	echo "SOURCE_DATE_EPOCH must be seconds since the epoch." >&2
	exit 2
fi
export SOURCE_DATE_EPOCH

output_dir="$(mkdir -p "$output_dir" && cd "$output_dir" && pwd)"

case "$layout" in
	asset-store)
		package_asset_store "$output_dir" "$version" "$revision" "$SOURCE_DATE_EPOCH"
		;;
	linux)
		case "$arch" in
			x86_64 | arm64) ;;
			*)
				echo "--arch must be x86_64 or arm64 for the linux layout." >&2
				exit 2
				;;
		esac
		package_linux "$output_dir" "$version" "$revision" "$arch" "$SOURCE_DATE_EPOCH"
		;;
esac
