# Editor and diff setup

Open the repository root in the editor. It is the Godot demo project and the
test bed. The committed `.editorconfig` sets LF line endings and tab indentation
for GDScript and native source. Editor-specific settings avoid automatic
reformatting of unrelated lines; personal launch paths stay local.

Run `./scripts/build.sh --target editor` to generate
`build-editor/compile_commands.json`. The committed `.clangd` and VS Code
settings point native-code completion at that build's actual compiler flags.

## Zed

The committed `.zed/settings.json` sets four-column hard tabs for GDScript, C
and C++. Install the [GDScript extension](https://zed.dev/extensions/gdscript)
for language support. Its language server needs Godot and `nc`/`ncat` on `PATH`,
and Godot must be running to provide GDScript completion and diagnostics.

To open scripts from Godot in Zed, enable **Text Editor → External → Use External
Editor** in Godot, set **Exec Path** to the local Zed executable, and set **Exec
Flags** to `{project} {file}:{line}:{col}`.

## VS Code

The committed `.vscode/settings.json` keeps tab indentation for GDScript and
native source and avoids watching generated Godot and CMake files. VS Code will
offer the extensions in `.vscode/extensions.json`: Godot Tools, CMake Tools and
C/C++. Godot Tools can use Godot's language server and debugger. Open the
project in Godot before expecting GDScript language features in VS Code.

To open scripts from Godot in VS Code, enable the same external-editor setting,
set **Exec Path** to the local `code` executable, and set **Exec Flags** to
`{project} --goto {file}:{line}:{col}`.

## Delta for Git diffs

If [Delta](https://dandavison.github.io/delta/get-started.html) is installed
and on `PATH`, run these commands in this clone to use it for Git output:

```bash
git config --local core.pager delta
git config --local interactive.diffFilter "delta --color-only"
git config --local delta.navigate true
```

This changes only this clone's `.git/config`. Delta is optional; contributors
without it keep Git's normal pager. For an isolated one-off view, use
`git -c core.pager=delta diff`.
