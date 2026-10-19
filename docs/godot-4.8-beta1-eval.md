# Godot 4.8 beta 1 evaluation

Evaluated 2026-10-19 on Fedora 44 x86_64, branch `eval/godot-4.8-beta1` (from
`main` at 6e14d99). Nothing here changes `main`, the godot-cpp pin
(`godot-4.4.1-stable`) or CI. The binding decision stays: production engine is
4.7.2.

Engine: official `Godot_v4.8-beta1_linux.x86_64` (4.8.beta1.official.4d10419ca),
SHA512 verified against the release's `SHA512-SUMS.txt`.

## Results

| Check | 4.7.2 (baseline) | 4.8 beta 1 |
|---|---|---|
| Current library (godot-cpp 4.4.1, editor target, `-Werror`) loads | yes | yes |
| `scripts/run_tests.sh` (mock-backed suite) | 88/88 | 88/88 |
| `scripts/run_native_smoke.sh`, all 5 modes | pass | pass |
| New warnings or errors in logs | — | none (the 9 `ERROR:` lines are the suite's own negative tests, identical on both) |
| `project.godot` rewritten by the editor | no | no |
| `demo/icon.svg.import` churn on import | yes (known) | same keys, no 4.8-specific additions |

## godot-cpp for 4.8

godot-cpp has no 4.7 or 4.8 branch or tag; its newest tag is `10.0.0-stable` and
`master` (2bb1acf, 2026-10-16) ships API JSONs up to `extension_api-4-7.json`.
Built against `master` with the 4.8 beta 1 API dumped by the editor
(`--dump-extension-api-with-docs`, passed as `GODOTCPP_CUSTOM_API_FILE`):

- Compiles with `-Werror`, no warnings, no source changes.
- Linking needed `-DGODOTCPP_USE_STATIC_CPP=OFF`: godot-cpp master now links
  libstdc++ statically on Linux by default, and Fedora has no static libstdc++.
  This is a godot-cpp change, unrelated to 4.8.
- That build passes 88/88 tests and all smoke modes on 4.8 beta 1.
- On 4.7.2 it refuses to load ("Cannot load a GDExtension built for Godot 4.8.0
  using an older version of Godot"), as expected.

## Conclusion

No compatibility work is needed for 4.8: the 4.4.1-pinned build runs unchanged
(`compatibility_minimum = "4.4"`). Keep the pin. Recheck at 4.8 RC/stable, and
when godot-cpp publishes a 4.8 API file, decide whether its
static-libstdc++ default needs a build flag.
