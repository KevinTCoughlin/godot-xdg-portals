# XDG Portals

Typed, sandbox-safe access to selected XDG Desktop Portal APIs from Godot 4.4 or newer.

Enable **XDG Portals** under Project, Project Settings, Plugins. The plugin adds the `DesktopServices` autoload.

The version in `plugin.cfg` is the latest tagged release. Changes since that tag are listed as Unreleased in the repository changelog.

This git tree does not contain prebuilt libraries. Install a release archive, or the CI asset-store zip, to get them. Without those libraries the addon still loads. On Linux every call reports that the extension is not loaded. On every other platform it reports that portals are unavailable.

Documentation: <https://github.com/KevinTCoughlin/godot-xdg-portals>

License: MIT (`LICENSE` in this folder).
