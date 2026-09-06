# Third-party notices

`godot-xdg-portals` is distributed under the MIT license (see `LICENSE`). It
builds against, and interoperates with, the third-party components below. None
of them are vendored into this repository, and no third-party code is bundled
into the release archive.

## godot-cpp

- Upstream: <https://github.com/godotengine/godot-cpp>
- Version: pinned to the `godot-4.4.1-stable` tag (`XDG_PORTALS_GODOT_CPP_TAG`)
- License: MIT
- Usage: fetched at configure time and linked **statically** into
  `libxdg_portals.linux.*.so`. The MIT license requires that its copyright
  notice accompany binary redistributions; the notice is reproduced below.

```
Copyright (c) 2017-present Godot Engine contributors.
Copyright (c) 2014-2017 Godot Engine contributors.
Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## GLib / GIO / GObject

- Upstream: <https://gitlab.gnome.org/GNOME/glib>
- License: LGPL-2.1-or-later
- Usage: linked **dynamically** against the host system's (or the Flatpak
  runtime's) `libglib-2.0`, `libgio-2.0` and `libgobject-2.0`. No GLib code is
  copied into this repository or into the release archive. Because the linkage
  is dynamic and unmodified, the LGPL's relinking requirement is satisfied by
  the system library itself.

## xdg-desktop-portal

- Upstream: <https://github.com/flatpak/xdg-desktop-portal>
- License: LGPL-2.1-or-later (the D-Bus interface descriptions are documentation)
- Usage: this addon is a *client* of the `org.freedesktop.portal.Desktop`
  service. Nothing from that project is copied here; the interface names, method
  signatures and response codes implemented in `src/` follow its published
  documentation.

## Godot Engine

- Upstream: <https://github.com/godotengine/godot>
- License: MIT
- Usage: the addon is loaded by the engine at runtime. No engine code is
  redistributed here.
