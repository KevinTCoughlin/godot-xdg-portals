# Contributing

Thanks for considering a contribution to `godot-xdg-portals`.

## Before you start

For anything larger than a bug fix, open an issue first. The API is deliberately
small — see [`docs/roadmap.md`](docs/roadmap.md) for what is planned and what is
explicitly out of scope. A patch that adds a general D-Bus bridge, or a portal
interface listed as out of scope, will be declined however good the code is.

## Developer Certificate of Origin

Contributions are accepted under the [DCO](DCO.txt), not a CLA. Sign off every
commit:

```bash
git commit -s
```

which appends `Signed-off-by: Your Name <you@example.com>`. By signing off you
certify the DCO's terms. Commits without a sign-off cannot be merged.

## Setting up

```bash
git clone https://github.com/KevinTCoughlin/godot-xdg-portals.git
cd godot-xdg-portals

# Debian/Ubuntu; adjust for your distribution.
sudo apt-get install build-essential cmake pkg-config libglib2.0-dev dbus

./scripts/build.sh --target editor        # for running from the Godot editor
./scripts/build.sh --target template_release
```

Open the repository root as a Godot 4.4+ project: it is both the demo project and
the test bed.

## Before you open a pull request

Run all of it. CI runs the same things, and a red CI costs a review round.

```bash
./scripts/run_tests.sh                    # mock-backed suite, no bus needed
./scripts/build.sh --target editor
./scripts/run_native_smoke.sh             # native backend vs. the fake portal
bash -n scripts/*.sh
reuse lint                                # pipx install reuse
```

If your change touches the native backend and you have a graphical Linux
session, also work through the relevant rows of the desktop checklist in
[`docs/native-testing.md`](docs/native-testing.md), and say in the pull request
which rows you ran and on which desktop. **Do not claim a desktop check passed if
you did not run it** — "not tested on hardware" is a perfectly good pull request
note, and a false one is worse than none.

## House rules

- **Honest returns.** Unknown state is `null` or `-1`; a failed operation is
  `false` or an empty handle. Never report an unavailable operation as
  successful, and never substitute a plausible guess for an unknown value.
- **Keep the API small, typed and mockable.** Every new facade method needs
  a `XDGPortalBackend` method, a mock implementation, and tests. Anything
  reachable from game code must be exercisable without a bus.
- **No new capability without a version gate.** Optional portal members are
  adopted behind an interface-version check, as `SchemeSupported` is gated on
  `OpenURI` version 5.
- **No shelling out.** GLib/GIO only. No `dbus-send`, `gdbus`, `busctl`, or
  desktop-specific command-line helpers.
- **Bounded blocking.** Only non-interactive calls may be synchronous, and they
  must carry a timeout. Anything that can show UI returns a request handle.
- **Threading.** Read the threading section of
  [`docs/architecture.md`](docs/architecture.md) before touching `src/`. GLib
  calls that capture the thread-default context must go through
  `run_on_worker()`; getting this wrong fails silently rather than loudly.
- **No stubs, no unexplained TODOs.** If something is deliberately unimplemented,
  say so in `docs/roadmap.md` with the reason.
- **No build artefacts in commits.** No `.godot/`, no `build*/`, no `.so`.

## Style

- **GDScript**: tabs, static types everywhere, `##` doc comments on public
  members, `_leading_underscore` for private members.
- **C++**: C++17, tabs, `p_` prefix on parameters and `r_` on out-parameters
  (Godot's convention), 4-space-equivalent indentation. Comments explain *why*,
  not *what*.
- **Licensing**: every new file needs an SPDX header — a copyright line and an
  MIT license identifier, matching the headers in existing files — or an entry
  in `REUSE.toml` if the format cannot carry comments. `reuse lint` must pass.

## Reporting bugs

Use the issue templates. For a native-backend bug, include your distribution,
desktop environment, `xdg-desktop-portal --version`, whether you are in a
Flatpak, and the output of the failing run with `XDG_PORTALS_DEBUG=1` set.

## Security

Do not open a public issue for a security problem — see
[`SECURITY.md`](SECURITY.md).
