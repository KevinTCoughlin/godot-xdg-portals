<!--
SPDX-FileCopyrightText: 2026 Kevin Coughlin

SPDX-License-Identifier: MIT
-->

## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Why

<!-- The problem being solved, not just the diff. -->

## Testing

- [ ] `./scripts/run_tests.sh` (mock-backed suite)
- [ ] `./scripts/build.sh --target template_release`
- [ ] `./scripts/run_native_smoke.sh` (native backend vs. the fake portal)
- [ ] `bash -n scripts/*.sh`
- [ ] `reuse lint`

### Desktop checks

<!--
If this touches the native backend, say which rows of docs/native-testing.md you
ran and on which desktop. If you did not run any, say so — "not tested on
hardware" is a fine answer, a false claim is not.
-->

Rows run:
Desktop / portal version:

## Checklist

- [ ] Commits are signed off (`git commit -s`) per the [DCO](../DCO.txt)
- [ ] Unknown state is still reported honestly (`null` / `-1` / `""` / `false`)
- [ ] New facade methods have a backend method, a mock implementation and tests
- [ ] Optional portal members are gated on an interface version
- [ ] New files carry SPDX headers, or an entry in `REUSE.toml`
- [ ] `CHANGELOG.md` updated for a user-visible change
- [ ] No build artefacts committed (`.godot/`, `build*/`, `*.so`)
