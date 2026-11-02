#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT
#
# Downloads an official Godot editor binary and writes it to DEST.
#
#   scripts/install_godot.sh RELEASE DEST ARCH
#
# RELEASE is a Godot version or a GitHub release tag: 4.7.2, 4.7.2-stable or
# 4.8-beta2. A bare version is a stable release. Stable tags are published on
# godotengine/godot. Pre-releases (beta, rc, dev) are published on
# godotengine/godot-builds and are not on godotengine/godot.
# ARCH is x86_64 or arm64, matching the asset name Godot uses.

set -euo pipefail

usage() {
	echo "Usage: scripts/install_godot.sh RELEASE DEST ARCH" >&2
	echo "  RELEASE  Version or GitHub tag, e.g. 4.7.2 or 4.8-beta2" >&2
	echo "  DEST     Output path for the editor binary" >&2
	echo "  ARCH     x86_64 or arm64" >&2
}

if [[ $# -ne 3 ]]; then
	usage
	exit 2
fi

RELEASE="$1"
DEST="$2"
ARCH="$3"

case "$ARCH" in
	x86_64 | arm64) ;;
	*)
		echo "Unsupported architecture '$ARCH'. Expected x86_64 or arm64." >&2
		exit 2
		;;
esac

# A bare "4.7.2" is the stable release. Pre-release tags already carry their
# channel, as in "4.8-beta2".
case "$RELEASE" in
	*-stable | *-beta* | *-rc* | *-dev*) ;;
	*)
		if [[ "$RELEASE" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
			RELEASE="${RELEASE}-stable"
		else
			echo "Unsupported release '$1'. Use a version such as 4.7.2 or a tag such as 4.8-beta2." >&2
			exit 2
		fi
		;;
esac

case "$RELEASE" in
	*-stable) REPO="godotengine/godot" ;;
	*) REPO="godotengine/godot-builds" ;;
esac

archive="Godot_v${RELEASE}_linux.${ARCH}"
url="https://github.com/${REPO}/releases/download/${RELEASE}/${archive}.zip"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

curl --fail --location --silent --show-error --output "$workdir/godot.zip" "$url"
unzip -q "$workdir/godot.zip" -d "$workdir"
if [[ ! -f "$workdir/$archive" ]]; then
	echo "Expected $archive inside $url, but it was not there." >&2
	exit 1
fi
chmod +x "$workdir/$archive"

mkdir -p "$(dirname "$DEST")"
mv -f "$workdir/$archive" "$DEST"
echo "Installed Godot ${RELEASE} (${ARCH}) from ${REPO} to ${DEST}"
