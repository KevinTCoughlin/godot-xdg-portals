# Governance

`godot-xdg-portals` is a small, single-maintainer project. This document says who
decides what, so contributors know what to expect rather than having to guess.

## Roles

**Maintainer.** Kevin Coughlin ([@KevinTCoughlin](https://github.com/KevinTCoughlin))
is the current maintainer: final say on scope, API design and releases, and the
only person who can merge to `main` or publish a release.

**Contributors.** Anyone who opens an issue or pull request. No formal status is
required and none is conferred.

**Committers.** None beyond the maintainer today. If the project attracts
sustained contribution, contributors with a track record of merged, reviewed work
may be invited; the invitation and its acceptance are recorded in this file.

## How decisions are made

Ordinary changes — bug fixes, tests, documentation, portal members added behind
a version gate — are decided in the pull request. One maintainer approval merges
them.

Scope changes — a new portal interface, a change to the public API, a new
dependency, or anything touching the Flatpak permission set — start as an issue
so the discussion is public and searchable before code exists. The maintainer
decides, and writes down the reason. Decisions that shape what the project is
end up in [`docs/roadmap.md`](docs/roadmap.md), including the ones that are a
"no".

There is no voting. If a decision proves wrong, it gets revisited; being able to
point at the recorded reason is what makes that possible.

## What is not negotiable

Three properties are the reason this project exists, and a change that breaks one
will be declined regardless of its merits:

1. **Honest reporting.** An unavailable operation is never reported as
   successful, and an unknown value is never replaced by a guess.
2. **No arbitrary D-Bus invocation** reachable from game code.
3. **Minimal sandbox permissions** — no broad `--talk-name`, no system bus.

## Releases

The maintainer tags releases. A release requires: green CI, a
[`CHANGELOG.md`](CHANGELOG.md) entry, and — for anything touching the native
backend — the desktop checklist in
[`docs/native-testing.md`](docs/native-testing.md) run on real hardware, with the
results and any gaps recorded in the release notes. A release never claims a
check that was not run.

## Code of conduct

Participation is governed by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). The
maintainer handles reports and enforcement.

## Succession

If the maintainer becomes unavailable for an extended period, the repository is
MIT-licensed: fork it. If you would like to take over the canonical repository
rather than fork, open an issue — if there is no response within 90 days, treat
the project as unmaintained and say so clearly in your fork.
