# linux-submit.sh

One script for publishing an app to Linux, from one set of answers: NixOS
(nixpkgs), Arch (AUR), Debian, Ubuntu (Launchpad PPA), Fedora (COPR and its
own repositories), openSUSE (OBS), Alpine (aports), Gentoo (GURU), Flathub,
the Snap Store and Homebrew.

- `linux-submit.sh [options]` — pick the distros, answer once, publish to each
- `linux-submit.sh <distro> [options]` — one distro's wizard, where `<distro>`
  is `nix`, `aur`, `debian`, `ppa`, `copr`, `fedora`, `obs`, `alpine`, `guru`,
  `flathub`, `snap` or `brew` (each takes `--help`)

How far each wizard goes, and what is left to people:

| distro | the wizard | then |
| --- | --- | --- |
| `nix` — NixOS / Nix | opens the pull request to nixpkgs | nixpkgs reviewers merge it |
| `aur` — Arch | publishes the package to the AUR | — |
| `debian` — Debian | uploads to mentors.debian.net; writes the ITP and the request for a sponsor (and sends them if your mail is set up) | a Debian developer reviews and uploads it |
| `ppa` — Ubuntu | uploads to your PPA | Launchpad builds it |
| `copr` — Fedora | uploads the source package to your COPR project | COPR builds it |
| `fedora` — Fedora | the spec and source package, and files the package review request (with a Bugzilla API key; else it's handed to you) | a Fedora packager reviews it; your first package needs a sponsor |
| `obs` — openSUSE | commits it to your home project | OBS builds it |
| `alpine` — Alpine | opens the merge request to aports | Alpine developers review it |
| `guru` — Gentoo | pushes to GURU once you have access; until then opens a Codeberg pull request, or writes a patch for the mailing list | GURU reviews it |
| `flathub` — every distro | prepares the submission | you open the pull request; Flathub reviews it |
| `snap` — every distro | builds and uploads it | the Snap Store reviews it |
| `brew` — Homebrew | opens the pull request to homebrew/core, or publishes your own tap | Homebrew maintainers review a core pull request |

Each distro's wizard runs in a process of its own, so running one directly or
from `linux-submit.sh` behaves the same. Remembered answers stay in
`~/.config/<distro>-submit/` (`nixpkgs-submit` for nix, `linux-submit` for the
several-distro run); what the packages say about the app is in
`.store-submit.conf` in the app's own repository.

Adding a distro is a line in `DISTROS`, a `wizard_<id>` function, and its id
in the `case` at the bottom of `linux-submit.sh` — plus, for questions a
several-distro run should ask up front, an `<id>_questions` function that
`wizard_linux` calls.

## Linux: `linux-submit.sh`

Publishes one app to several Linux distributions in one go:

1. **distros** — a checkbox list (or `--distros nix,aur`)
2. **your app** — the questions every distro needs are asked **once**: name,
   build system, description (checked against the distros' rules), license
   (GPL "only / or later" settled from your source notices), homepage, main
   program, and you as maintainer. The release tag is created and pushed if
   needed.
3. **publish** — each distro's wizard runs in turn with those answers; a
   failure in one doesn't stop the others, and the summary says what to re-run
   and lists everything left for you to do (like opening Flathub's pull
   request)

Distros with questions of their own ask them in step 2 too: the Flathub app
ID, the snap name, whether the app uses the internet (asked once for both),
your Launchpad account, PPA and Ubuntu releases, Debian's package name and
section, your COPR project and its Fedora releases, your Fedora and Bugzilla
accounts, your OBS account and openSUSE releases, Alpine's release tarball,
the Gentoo category, and homebrew/core or a tap.

The answers go into `.store-submit.conf` in the app's repository — a plain
`key = value` file, read (never executed), yours to edit and commit:

```
name = linkstow
build-system = flutter
description = Bookmark manager for Karakeep
license = GPL-3.0-only
homepage = https://github.com/by-architect/KarakeepMobile
main-program = linkstow
maintainer-name = neo
maintainer-email = you@example.org
distros = nix aur
```

With it in place, every run — `linux`, `nix` or `aur` — asks nothing about the
app; only the version and tag come from each release. `--ask` goes through the
questions again.

```bash
~/path/to/linux-submit.sh                        # pick distros, answer once, publish
~/path/to/linux-submit.sh --distros nix,aur -n   # a dry run of both
```

## nixpkgs: `linux-submit.sh nix`

Gets an app into [nixpkgs](https://github.com/NixOS/nixpkgs) — what Nix and
NixOS install from — or ships a new version of one that's already there:
writes `pkgs/by-name/<xx>/<name>/package.nix`, builds it, checks it the way
nixpkgs reviewers do, and opens the pull request.

```bash
cd ~/path/to/your-app
~/path/to/linux-submit.sh nix             # new package or update: it works out which
~/path/to/linux-submit.sh nix --dry-run   # everything up to the commits, nothing pushed
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | use everything detected, ask nothing; a new package becomes a **draft** PR |
| `--ask` | ask every question, including the ones it can answer itself |
| `--repo PATH` | the app's checkout (default: the git repo you run it in) |
| `--nixpkgs PATH` | your nixpkgs checkout (default: asked, `~/nixpkgs`) |
| `--review` | also run `nixpkgs-review` (slow; offered for updates) |
| `--draft` | open the pull request as a draft |
| `-n`, `--dry-run` | build, check and commit locally; push nothing |
| `--no-save`, `--forget` | control `~/.config/nixpkgs-submit/last.conf` |

### What it supports

| project | builder it writes |
| --- | --- |
| Flutter (Linux desktop target) | `flutterXYY.buildFlutterApplication`, from the project's `.fvmrc`; `pubspec.lock.json`, `gitHashes`, a desktop entry and icon |
| Rust | `rustPlatform.buildRustPackage`; `-sys` crates' system libraries added up front |
| Go | `buildGoModule`; `-X main.version` when `main` has a version variable |
| Node (npm) | `buildNpmPackage` |
| Python (`pyproject.toml`) | `python3Packages.buildPythonApplication`; build system and dependencies mapped to nixpkgs |
| Meson / CMake / Make | `stdenv.mkDerivation`; pkg-config dependencies mapped to nixpkgs |

All in nixpkgs' current style (`finalAttrs`, `tag =`, `passthru.updateScript`
so nixpkgs' update bot keeps it current).

### What it works out by itself

- **the app:** build system, version, name, release tag, license (the forge's,
  the manifest's, or recognised from `LICENSE`; GPL "only / or later" is
  asked), description (cleaned up to nixpkgs' rules and checked against them),
  homepage, changelog, the main program
- **the release tag:** created and pushed if missing, and checked to hold this
  version — nixpkgs downloads exactly that tag
- **GitHub:** your login (offers `gh auth login`), your nixpkgs fork (made if
  missing), open PRs for the same package (warned about), a "Package request"
  issue (closed by the PR)
- **the checkout:** asked where, shallow-cloned (~200 MB), retried if the
  connection drops; your own checkout is reused, and if it has uncommitted
  work the wizard builds in a separate worktree instead
- **new or update:** from nixpkgs itself. A name taken by different software
  is caught and a new one asked for. Updates use `nix-update`
- **you as maintainer:** added to `maintainer-list.nix` (sorted, GitHub id
  filled in) in its own `maintainers: add <you>` commit, the first time

### Build, check, fix

Each hash starts as its own placeholder; the build fails with the real value
and the wizard fills it in, so every hash is the one Nix computed. Common
failures are fixed automatically and said so — a missing pkg-config library or
build tool (from a table, or `nix-locate` if installed), Python dependencies,
Go without dependencies, a Flutter too old for the project's Dart SDK. Failing
tests are named, with the option to skip them and write the reason in a
comment (reviewers ask for it). Anything else: the relevant log lines, then
edit / read the log / rebuild / quit.

After it builds: `meta.mainProgram` is matched to what's in `bin/`, a CLI that
prints its version gets `versionCheckHook` (so every future build checks it),
a GUI app is started for you to try, and the files are formatted with
nixpkgs' own `treefmt` — the one CI checks with. Then the reviewers' checklist
from `pkgs/README.md`: description rules, license, maintainers, mainProgram,
by-name path, name, version, platform, fetcher, formatting.

### Review, and nixpkgs' automation policy

nixpkgs requires a person to review generated code and the use of automation
to be disclosed ([CONTRIBUTING.md, "Automation/AI policy"](https://github.com/NixOS/nixpkgs/blob/master/CONTRIBUTING.md#automationai-policy)).
So for a new package the wizard shows the whole change and asks whether you
have read it and stand behind it; the PR says the package was generated with
this script and whether you reviewed it. With `--yes`, or if you say no, the
PR is opened as a draft for you to review first. Updates made with
`nix-update` are exempt (it's standard community automation).

The PR uses nixpkgs' own template, ticking only what the run verified: built
on your platform, binaries tested, nixpkgs-review run, fits CONTRIBUTING.md,
follows the automation policy.

### What you need

- Nix, `git` and `gh`; `nix-update`, `nixpkgs-review`, `jq` and `yq` come from
  nixpkgs automatically when not installed
- the app on GitHub, GitLab, Codeberg or another public git host
- after your first package is merged, GitHub emails an invite to
  NixOS/nixpkgs-maintainers — **accept it within a week**, it expires

### References

- <https://github.com/NixOS/nixpkgs/blob/master/pkgs/README.md>
- <https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/README.md>
- <https://github.com/NixOS/nixpkgs/blob/master/maintainers/README.md>

## Arch (AUR): `linux-submit.sh aur`

Publishes an app to the [AUR](https://aur.archlinux.org), or ships a new
version of one already there, following Arch's
[AUR submission guidelines](https://wiki.archlinux.org/title/AUR_submission_guidelines)
and [package guidelines](https://manual.archlinux.page/package-guidelines/).

```bash
~/path/to/linux-submit.sh aur            # new package or update: it works out which
~/path/to/linux-submit.sh aur --dry-run  # everything up to the commit, nothing pushed
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | ask nothing; an update goes straight through, a new package stops before publishing for you to review it |
| `--ask` | ask every question again |
| `--repo PATH`, `--config FILE` | the app's checkout, the shared answers |
| `--key FILE` | the SSH key your AUR account has (default: `~/.ssh/aur`) |
| `--no-test` | skip the test build in an Arch container |
| `-n`, `--dry-run` | write, check and commit locally; push nothing |
| `--no-save`, `--forget` | control `~/.config/aur-submit/last.conf` |

### What it does

- **the rules first:** refuses a name Arch already ships in its official
  repositories; finds out whether the AUR package is new, yours (an update),
  orphaned (adopt it first — linked) or someone else's (comment or ask to
  co-maintain — linked)
- **SSH:** checks the AUR accepts your key (`ssh aur@aur.archlinux.org
  list-repos`); if not, offers to create a dedicated `~/.ssh/aur` key as Arch
  recommends, shows the public key and where to paste it, and checks again. It
  uses the key for AUR commands only — your `~/.ssh/config` is left alone
- **PKGBUILD:** in Arch's current style for Rust (`cargo fetch --locked`,
  `--frozen`), Go (PIE build flags), Python (`python -m build` /
  `installer`), Node (`npm pack` + global install), Meson (`arch-meson`),
  CMake, Make, and Flutter (Linux bundle in `/usr/lib/<name>`, a desktop entry
  and icon). Maintainer line with an obfuscated email, SPDX `license=()`, the
  license text installed where Arch needs it, dependencies checked against the
  official repos and the AUR. The checksum comes from the real release tarball
- **updates:** bumps `pkgver`, resets `pkgrel`, refreshes the checksum
- **alongside it:** a 0BSD `LICENSE` for the PKGBUILD (as the AUR guidelines
  encourage) and a `.gitignore` that keeps build leftovers out
- **check:** `.SRCINFO` written (with `makepkg` when installed, else read from
  the PKGBUILD the same way — it works on any distro); a clean test build in an
  Arch container with podman or docker: AUR dependencies built first, the
  package built, `namcap` run on the PKGBUILD and the package, the package
  installed and its program run with `--version`. A failed build names the
  problem (a dependency that doesn't exist, a checksum) and offers edit /
  read the log / rebuild / skip / quit
- **review:** the whole change is shown; the AUR asks for it to be verified
  carefully, so a new package is never published unread
- **publish:** committed as you (from the config), pushed to the AUR's
  `master`, and the AUR's own API checked to show the new version

### What you need

- an [AUR account](https://aur.archlinux.org/register) — the wizard handles
  the SSH key
- `git`, `ssh`, `curl`; podman or docker for the test build (recommended)
- the app on GitHub, GitLab, Codeberg or another public git host

## Flathub: `linux-submit.sh flathub`

Prepares an app for [Flathub](https://flathub.org), or an update of one
already there — everything **up to the pull request, which you open
yourself**. Flathub's [Generative AI policy](https://docs.flathub.org/docs/for-app-authors/requirements#generative-ai-policy)
says tools must not open or automate submission pull requests, so the wizard
ends with your to-do list and a link that opens the pull request form with
the branch and title filled in.

```bash
~/path/to/linux-submit.sh flathub            # new app or update: it works out which
~/path/to/linux-submit.sh flathub --dry-run  # build and check; your fork isn't touched
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | ask nothing (the metadata step still needs you once) |
| `--ask` | ask every question again |
| `--repo PATH`, `--config FILE` | the app's checkout, the shared answers |
| `--app-id ID` | the Flathub app ID (else from the config, or worked out) |
| `-n`, `--dry-run` | build and check; don't touch your fork |

### What it does

1. **app ID** — worked out from where the app lives (`io.github.<owner>.<repo>`
   for GitHub) and checked against every rule in Flathub's requirements,
   including that the repository it points at exists. Asked once — it's
   permanent on Flathub — and kept in `.store-submit.conf`
2. **tools** — adds the Flathub remote and installs `org.flatpak.Builder`
   (Flathub's own builder and linter) for your user if needed; the Python
   helpers come from nixpkgs (or a private virtualenv) — nothing system-wide
3. **metadata** — Flathub wants a metainfo file, a desktop file and an icon
   (SVG or ≥256×256 PNG) *in your app's repository*. Missing ones are written
   into it (name, the description in your words, screenshots, age rating,
   releases from your tags), validated with Flathub's linter, and the wizard
   stops: you check them, commit, release, and run it again
4. **manifest** — yours if the repo has `<app-id>.yml` or `flatpak-flutter.yml`;
   otherwise made with the community tools Flathub points to:
   [flatpak-flutter](https://github.com/TheAppgineer/flatpak-flutter)'s own
   template for Flutter apps (in subdirectories too), the documented recipes
   for Rust (with `flatpak-cargo-generator`), Meson and CMake. Always the
   latest runtime, the source pinned to your tag and commit, and
   `x-checker-data` so Flathub's bot opens update pull requests for new tags
5. **build + lint** — `flathub-build` (offline, sandboxed, like Flathub's
   builders), then `flatpak-builder-lint` on the manifest and the build, each
   error linked to its explanation; the app is started for you to try
6. **hand-off** — your fork (made if missing), a branch with exactly the
   files the pull request needs, pushed; then the to-do list:

```
   ┏━━ Your turn — Flathub wants a person to open this pull request
   ┃ 1. Open the pull request — the link below fills in the branch and the title
   ┃ 2. In the pull request, fill in Flathub's checklist yourself
   ┃ 3. Flathub's AI policy: say whether AI-generated material is in your app or
   ┃    its packaging … — state it as it is; reviewers decide
   ┃ 4. Answer the reviewers yourself; comment "bot, build" for a test build
   ┃ 5. Turn on GitHub two-factor authentication — accept the maintainer invite
   ┃    within a week
   ┃ 6. Once it's live: verify the app on flathub.org's Developer Portal
   ┃
   ┃    https://github.com/flathub/flathub/compare/new-pr...you:flathub:<app-id>?expand=1&title=…
   ┗━━
```

**Updates** go to the app's own repository (`flathub/<app-id>`): the source
moves to the new tag, flatpak-flutter or the cargo generator runs again,
it's built and linted, and the link opens the update pull request there. If
Flathub's bot already opened one for that version, you're told.

Any store that wants a person to open the pull request can end the same way:
`handoff_add` and `handoff_show` in the shared Linux helpers.

### What you need

- Flatpak (NixOS: `services.flatpak.enable = true;`), `git`, `python3`, `gh`
- a GitHub account with two-factor authentication (for the maintainer invite)

## Snap Store: `linux-submit.sh snap`

Publishes an app to the [Snap Store](https://snapcraft.io), or a new version,
following [Snapcraft's documentation](https://ubuntu.com/docs/snapcraft/stable/how-to/publishing/).
The Snap Store has no rule against automated uploads; instead it reviews
every new snap and revision before it's public, so the wizard publishes by
itself and tells you when a release waits for that review.

```bash
~/path/to/linux-submit.sh snap            # new snap or update
~/path/to/linux-submit.sh snap --dry-run  # build it; register and upload nothing
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | ask nothing (the first login still needs you) |
| `--ask` | ask every question again |
| `--repo PATH`, `--config FILE` | the app's checkout, the shared answers |
| `--channel NAME` | `stable`, `candidate`, `beta` or `edge` (remembered) |
| `-n`, `--dry-run` | build the snap; don't register or upload |
| `--forget` | forget the remembered answers and the saved login |

- **no snapcraft to install:** it runs in Canonical's own container image
  (`ghcr.io/canonical/snapcraft:8_core24`) with podman or docker — so it works
  on NixOS and any other distro. Files the container writes are handed back
  to you
- **login, once:** snapcraft asks for your Ubuntu One email, password and 2FA
  itself; the exported login is kept in `~/.config/snap-submit/credentials`
  (readable only by you), checked with `snapcraft whoami` each run, and
  passed to the container as an environment variable, never on a command line
- **snap name:** from your package name, checked against the store's rules
  (≤ 40 characters, lowercase, digits, hyphens), asked once — it's unique
  store-wide and permanent
- **snapcraft.yaml:** yours if the repo has one (built from the release tag);
  otherwise written for your build system — Flutter (the `flutter` plugin,
  subdirectories included), Rust, Go, Python, npm, Meson, CMake, Make — on
  `core24`, strict confinement, the `gnome` extension for graphical apps,
  `network` only if the app uses it, your icon, and the source pinned to your
  release tag
- **build:** `snapcraft pack`, with its linter's remarks passed on; a failure
  shows the log and offers edit / read the log / rebuild / quit
- **register** the name (first time; a taken name is explained), **upload**
  to your channel and show the store's status for it

### What you need

- podman or docker (NixOS: `virtualisation.podman.enable = true;`)
- a free [Snapcraft developer account](https://snapcraft.io/account) (Ubuntu One)

## Ubuntu (Launchpad PPA): `linux-submit.sh ppa`

Ubuntu and the distributions built on it — Linux Mint, Pop!_OS, Zorin,
elementary — are the most used Linux desktops. Their App Center is the Snap
Store (above); for `apt`, the way a developer publishes directly is a
[Launchpad PPA](https://launchpad.net/ubuntu/+ppas):
`sudo add-apt-repository ppa:you/app && sudo apt install app`. (Debian's own
archive needs a Debian developer to sponsor each new upload:
`linux-submit.sh debian` does everything up to that.) Launchpad's rules ask only for an open-source license and signed,
source-only uploads; it builds the binaries itself.

```bash
~/path/to/linux-submit.sh ppa            # new package or a new version
~/path/to/linux-submit.sh ppa --dry-run  # make and test-build; don't sign or upload
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | ask nothing (the first key registration still needs you) |
| `--ask` | ask every question again (account, PPA, releases) |
| `--repo PATH`, `--config FILE` | the app's checkout, the shared answers |
| `--no-test` | skip the offline test builds |
| `-n`, `--dry-run` | make and test the packages; don't sign or upload |

- **what it can package:** Meson, CMake, Make, Python (dependencies from
  Ubuntu), Rust and Go (their dependencies vendored into the source).
  Launchpad builds **without internet** and Ubuntu has no Flutter SDK, so
  Flutter and npm apps can't go in a PPA — the picker says so up front; Ubuntu
  users get those from the Snap Store or Flathub
- **releases:** the currently supported Ubuntu releases, read from Launchpad
  each run, in a checkbox list (the LTS releases preselected)
- **signing:** finds a GPG key of yours that Launchpad knows; otherwise picks
  (or creates) one, publishes it to keyserver.ubuntu.com, and walks you
  through the one step only you can do — importing it on Launchpad and
  opening the link in the encrypted email Launchpad sends — then checks again.
  No gpg installed? GnuPG comes from nixpkgs
- **your PPA:** checked through Launchpad's API; if it doesn't exist yet, you
  create it once on the web (its terms of use are yours to accept) and the
  wizard checks again
- **debian/:** yours if the repo has one; otherwise `control`, `rules`,
  `copyright` and `source/format` written for your build system, with
  Ubuntu's `-dev` packages for your pkg-config dependencies
- **versions:** `<version>-1ppa1~ubuntu<release>.1`, one per release; the
  `ppa` number goes up by itself when that version is in the PPA already
- **build + check:** in Ubuntu containers (podman or docker): Rust/Go
  dependencies vendored, the orig tarball and a source package per release,
  then a **test build per release with the network cut** — like Launchpad's
  builders — and `lintian`. Too-old Rust or Go on an older release is named,
  with the fix (Ubuntu's versioned toolchains) or skipping that release
- **upload:** signed like `debsign` (the `.dsc`, its new checksums in the
  `.changes`, then the `.changes`), sent to Launchpad in the right order (the
  first carries the orig tarball), and Launchpad's API checked until it lists
  the upload

### What you need

- a [Launchpad account](https://launchpad.net/+login) and podman or docker
- a GPG key (the wizard can make one); its email must be a confirmed address
  of your Launchpad account

## Debian: `linux-submit.sh debian`

Gets an app into [Debian](https://www.debian.org) itself, or ships a new
version of one already there. Ubuntu imports Debian's packages, and Linux
Mint, Pop!_OS, elementary and the rest follow Ubuntu: once the app is in
Debian, they get it with their next releases.

Only a Debian developer can upload a new package (your **sponsor**), and
Debian's FTP masters review each new one. So the wizard does everything up to
the sponsor, the way [mentors.debian.net](https://mentors.debian.net/intro-maintainers/)
and the [Developer's Reference](https://www.debian.org/doc/manuals/developers-reference/pkgs.en.html#new-package)
describe it, and ends with your to-do list.

```bash
~/path/to/linux-submit.sh debian            # new package or a new version
~/path/to/linux-submit.sh debian --dry-run  # package, build and check; send, sign and upload nothing
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | ask nothing; mail in your name is written out, never sent, and a new package stops before its upload for you to read it |
| `--ask` | ask every question again |
| `--repo PATH`, `--config FILE` | the app's checkout, the shared answers |
| `--itp NUMBER` | the ITP bug you filed already (otherwise it's found, or filed) |
| `--fresh` | write the debian/ packaging anew (the old one is kept beside it) |
| `--no-test` | skip the offline test build and lintian |
| `-n`, `--dry-run` | package, build and check; send, sign and upload nothing |
| `--no-save`, `--forget` | control `~/.config/debian-submit/last.conf` |

### What it can package

Debian builds every package from source, **offline, from Debian's own
packages**; bundled (vendored) dependencies aren't allowed. So:

- **Meson, CMake, Make:** yes — C/C++ libraries come from Debian's `-dev`
  packages (worked out from your `pkg-config` dependencies)
- **Rust, Go, Python:** only when every library the app builds with is
  packaged in Debian already. The wizard checks: each crate in `Cargo.lock`
  (Windows/macOS-only crates and dev-dependencies left out) against Debian's
  `rust-*` packages and their semver, each module in `go.mod` against the Go
  import paths Debian's archive knows, each dependency in `pyproject.toml`
  against dh-python's list — and names what's missing, with where it would
  have to go in first (the Rust team's debcargo-conf, one Go package each, the
  Python team). It also checks the Rust and Go versions the app asks for
  against Debian unstable's.
- **Flutter and npm:** no — Debian has no Flutter SDK, and an npm app needs
  every module in Debian first. The wizard (and the distro picker's
  questions) say so up front.

What Debian can't take, Debian users get from **Flathub** (`sudo apt install
flatpak`) or the **Snap Store** (`sudo apt install snapd`) — both work on
Debian.

### What it does

- **in Debian already?** asks Debian's archive (the package name, as source
  or binary, in every suite), the NEW queue, the WNPP list and the bug
  tracker, and mentors.debian.net. The app's name taken by another package,
  someone else's ITP for it, or the package in Debian under someone else's
  care each stop it, with who to talk to. An RFP (someone asked for the app)
  becomes your ITP. If you maintain the package in Debian, it's a new
  version: it starts from the packaging in the archive and adds a changelog
  entry
- **debian/** written to Debian's standards: format `3.0 (quilt)` with the
  upstream tarball fetched exactly as `uscan` would (GitHub/GitLab's tag
  archive, or `git archive` of the tag), debhelper compat 14, the current
  Standards-Version (read from Debian's archive), `Rules-Requires-Root: no`,
  dh-cargo (build-dependencies from `debcargo deb-dependencies`), dh-golang
  (`XS-Go-Import-Path`, `Static-Built-Using`) or pybuild, a machine-readable
  `debian/copyright` (DEP-5: holders from your source's notices, GPL/LGPL/
  Apache/MPL/CC0 pointing to `/usr/share/common-licenses`, every other
  license in full from your own license file), `debian/watch` in format 5
  (its GitHub/GitLab templates, or git mode), `debian/upstream/metadata`,
  and a changelog that closes the ITP. Section and the long description are
  asked once
- **kept for you:** the packaging lives in
  `~/.local/share/store-submit/debian/<name>/debian` — edit it there when a
  reviewer asks for changes; every run builds from it and only updates the
  changelog
- **build + check**, like Debian's build daemons: in a fresh Debian unstable
  container (podman or docker), only the build dependencies installed, the
  network cut, built as an ordinary user with no home directory; then
  **lintian** `--pedantic --info` (errors stop it, warnings and the rest
  are listed), **licensecheck** for files under other licenses than the
  app's, the package installed and its program run with `--version`.
  Programs without a manual page get one from `help2man` (you're asked
  first). A failed build names the problem (a missing build dependency, a
  crate or Go module Debian lacks, a download attempt) and offers edit /
  read the log / rebuild / skip / quit
- **ITP:** the "intent to package" bug, in the form `reportbug` writes
  (`X-Debbugs-Cc: debian-devel`), shown in full; with a mail setup on your
  machine (msmtp, or a sendmail) it's sent when you say so and the wizard
  waits for its bug number; otherwise it's saved for you to send, and the
  next run finds the number by itself
- **sign + upload:** a new package is shown to you to read first. Your GPG
  key (one is made if you have none; no gpg installed? GnuPG comes from
  nixpkgs) signs the upload like `debsign`, and `dput` sends it to
  mentors.debian.net, whose API then shows it. The one step only you can
  do — an account there, with your key in it — is walked through once
- **sponsor:** the RFS (request for sponsorship) from mentors' own template,
  sent or saved like the ITP; if your RFS is still open, a follow-up to it
  instead (and the `moreinfo` tag removed)

### What you need

- podman or docker (NixOS: `virtualisation.podman.enable = true;`)
- your email in the config (it's the package's Maintainer address)
- a GPG key (the wizard can make one) and a free
  [mentors.debian.net account](https://mentors.debian.net/accounts/register/)
  with that key in it
- to send the ITP and RFS from the wizard: msmtp or a sendmail set up on your
  machine — otherwise any mail program, from your address, in plain text
- patience after it: a sponsor reviews it, then the FTP masters (the NEW
  queue, often weeks); answer them on the RFS bug and re-run the wizard for
  each change

### References

- <https://mentors.debian.net/intro-maintainers/>, <https://mentors.debian.net/sponsors/rfs-howto/>
- <https://www.debian.org/devel/wnpp/>
- <https://www.debian.org/doc/debian-policy/>,
  <https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/>
- <https://wiki.debian.org/Teams/RustPackaging/Policy>,
  <https://go-team.pages.debian.net/packaging.html>

## RPM: the spec they share

The three RPM wizards below — `copr`, `fedora` and `obs` — write the `.spec`
with one shared writer, for each build system:

| project | how it's built |
| --- | --- |
| Rust | crates vendored (`cargo vendor`): Fedora's `%cargo_prep -v vendor` / `%cargo_build` / `%cargo_vendor_manifest`, the executables installed from `target/rpm`, `License:` covering every crate linked in; openSUSE's `cargo-packaging` with `vendor.tar.zst` |
| Go | Fedora: modules vendored with `go-vendor-tools` (which also fills in `License:`), `%gobuild`; openSUSE: `vendor.tar.zst`, `go build -mod=vendor -buildmode=pie` |
| Python (`pyproject.toml`) | Fedora: `%pyproject_buildrequires` / `%pyproject_wheel` / `%pyproject_save_files -l <modules>`; openSUSE: `python-rpm-macros`, its dependencies listed as `python3dist()` |
| Node (npm) | the modules from `package-lock.json` bundled (Fedora's Node.js guidelines: apps bundle), the bundled licenses listed; a build step runs offline with the dev modules |
| Meson / CMake / Make | `%meson` / `%cmake` / `%make_build`, pkg-config dependencies as `pkgconfig()`, the compilers the project's languages need |

What the package contains is not guessed: a first build installs the app into
a scratch buildroot, and the `%files` list is written from what's there — the
programs, man pages, desktop file and metainfo (then validated in `%check`),
icons, translations (`%find_lang`), a `-devel` package for headers and
pkg-config files. Then everything is built again with the finished spec, the
way the build servers will.

Every test build runs **offline** — the build dependencies are installed with
the network on, then it's cut, like Fedora's, COPR's and OBS's builders — in
a container (podman or docker): Fedora for `copr` and `fedora`, openSUSE
Tumbleweed for `obs`. Then `rpmlint`, and the packages are installed in a
fresh container the way users get them (dependencies from the distro) and
the program is run with `--version`. A failed build names the cause (a
missing dependency, a compiler too old, a download attempt, unlisted files)
and offers edit / read the log / rebuild / skip / quit.

An app that ships its own `<name>.spec` in its repository gets that one,
with the new Version; its sources are fetched with `spectool`.

Flutter apps can't be RPMs: Fedora and openSUSE have no Flutter SDK and
their builders are offline — the wizards say so up front (Flathub and the
Snap Store have them).

## Fedora COPR: `linux-submit.sh copr`

[COPR](https://copr.fedorainfracloud.org) is Fedora's community build
service: a repository of your own, built on Fedora's servers for the Fedora
(and EPEL, CentOS Stream…) releases you pick. People install from it with
`sudo dnf copr enable you/app && sudo dnf install app`. It follows
[COPR's documentation](https://docs.pagure.org/copr.copr/user_documentation.html)
and [Fedora's packaging guidelines](https://docs.fedoraproject.org/en-US/packaging-guidelines/).

```bash
~/path/to/linux-submit.sh copr            # new project or a new version
~/path/to/linux-submit.sh copr --dry-run  # write and test-build; nothing goes to COPR
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | ask nothing (the first login still needs you) |
| `--ask` | ask every question again (project, releases) |
| `--repo PATH`, `--config FILE` | the app's checkout, the shared answers |
| `--no-test` | skip the offline test build (the `%files` list is then a guess) |
| `-n`, `--dry-run` | write, vendor and test-build; create and upload nothing |
| `--no-save`, `--forget` | control `~/.config/copr-submit/last.conf` |

- **project and releases:** the project name (default: the package name),
  then two checkbox lists — releases (Fedora's current ones preselected;
  Rawhide, EPEL, CentOS Stream, openSUSE and Mageia offered, with a note that
  the spec is Fedora-style) and architectures (x86_64, aarch64 preselected) —
  read from COPR's API each time, kept in `.store-submit.conf`
- **login:** copr-cli's own: the API token in `~/.config/copr`. Missing or
  expired, the wizard shows where to get it
  (<https://copr.fedorainfracloud.org/api/>), takes the pasted block and
  saves it readable only by you. No copr-cli installed? It runs in a Fedora
  container (it isn't in nixpkgs)
- **spec:** the shared writer with a plain `Release:` and `%changelog`, so
  EPEL and non-Fedora chroots can build it; the release number goes up by
  itself when COPR has this version already
- **test build:** in the newest Fedora release you picked; packages the
  project already has (dependencies you built there) are available to it
- **project:** created if missing (description, install instructions,
  network off for builds, new Fedora releases added by themselves), or given
  the releases it lacks
- **build:** the source RPM uploaded with `copr-cli build`, COPR's progress
  followed (safe to interrupt), each release's result shown — with the end of
  its build log when it failed

### What you need

- a Fedora account (<https://accounts.fedoraproject.org>), to log in to COPR
- podman or docker (NixOS: `virtualisation.podman.enable = true;`)

## Fedora: `linux-submit.sh fedora`

Gets an app into Fedora's own repositories — everything **up to the package
review, which people do**, following Fedora's
[New Package Process](https://docs.fedoraproject.org/en-US/package-maintainers/New_Package_Process_for_New_Contributors/)
and [Package Review Process](https://docs.fedoraproject.org/en-US/package-maintainers/Package_Review_Process/).

```bash
~/path/to/linux-submit.sh fedora            # new package (or a new spec for an open review)
~/path/to/linux-submit.sh fedora --dry-run  # write and test-build; nothing goes to COPR or Bugzilla
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | ask nothing — but a new spec still needs you to read it once |
| `--ask` | ask every question again (Fedora account, Bugzilla email, packager) |
| `--repo PATH`, `--config FILE` | the app's checkout, the shared answers |
| `--no-test` | skip the test build (reviewers check that it builds) |
| `-n`, `--dry-run` | write and test-build; nothing goes to COPR or Bugzilla |
| `--no-save`, `--forget` | control `~/.config/fedora-submit/` (answers, the saved Bugzilla API key) |

1. **in Fedora already?** — asked of Fedora's own services: the package
   (mdapi, dist-git), a name taken by a different project, a retired package,
   and open or closed review requests in Bugzilla. Your own open review gets
   a new spec and SRPM; someone else's stops the wizard with the link
2. **spec** — the shared writer as Fedora wants it for a review:
   `%autorelease` / `%autochangelog`, vendoring where the language
   guidelines allow it (Rust: allowed, though packaged crates are preferred —
   it says so; Go: required) and bundling for Node.js apps
3. **build + check** — offline in a Fedora Rawhide container, `rpmlint`
   (Fedora's setup fails on any error — named), installed and run;
   Python dependencies Fedora lacks are listed (each needs its own review).
   `fedora-review` runs too when you have it and mock. Then you read the spec:
   Fedora wants packagers who understand their packages
4. **online copy** — built on COPR (what Fedora's docs recommend for the
   review), giving the Spec URL and SRPM URL reviewers download
5. **review request** — `Review Request: <name> - <summary>` with Fedora's
   template (Spec URL, SRPM URL, description, your Fedora account), filed
   through Bugzilla's REST API with your API key (kept off the command line,
   saved readable only by you), blocking FE-NEEDSPONSOR if you're new. No key:
   the exact text is saved and the form linked. Fedora's Review Service then
   builds it and posts fedora-review's results on the bug
6. **hand-off** — what only a person can do: the Fedora account and
   agreement, a sponsor, answering the reviewers (running the wizard again
   posts the fixed spec), then after approval the Forge API token,
   `fedpkg request-repo`, `fedpkg import`, `fedpkg build`, branches and Bodhi
   updates, and release monitoring

**Already in Fedora?** Updates are made by the package's maintainers with
fedpkg and Bodhi. The wizard says who they are, bumps Fedora's spec to the
new version, test-builds it, and hands you the fedpkg steps if you're a
maintainer — or how to propose it (a pull request on src.fedoraproject.org)
if you aren't.

### What you need

- a Fedora account, and a Red Hat Bugzilla account with the same email
- podman or docker; optionally a Bugzilla API key
  (<https://bugzilla.redhat.com/userprefs.cgi?tab=apikey>) to file the review

## openSUSE (OBS): `linux-submit.sh obs`

Publishes an app for openSUSE through the
[Open Build Service](https://build.opensuse.org), in your `home:<you>`
project: OBS builds it for the openSUSE releases you pick, and people add
your repository with zypper. It follows
[openSUSE's packaging guidelines](https://en.opensuse.org/openSUSE:Packaging_guidelines).

```bash
~/path/to/linux-submit.sh obs            # new package or a new version
~/path/to/linux-submit.sh obs --dry-run  # write and test-build; commit nothing
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | ask nothing (osc's first login still needs you) |
| `--ask` | ask every question again (account, releases) |
| `--repo PATH`, `--config FILE` | the app's checkout, the shared answers |
| `--no-test` | skip the offline test build in a Tumbleweed container |
| `-n`, `--dry-run` | write, vendor and test-build; commit nothing to OBS |
| `--no-save`, `--forget` | control `~/.config/obs-submit/last.conf` |

- **osc:** OBS's own client — yours, or from nixpkgs. Its own login: the
  first time, osc asks for your openSUSE username and password and keeps them
  (in your keyring if there is one); the wizard checks it with `osc whois`
- **releases:** a checkbox list of the openSUSE releases OBS builds for, read
  from OBS itself (Tumbleweed preselected); they're added to your home
  project's build targets
- **spec:** the shared writer in openSUSE's conventions — the spec header,
  `Release: 0`, the changelog in a `.changes` file (osc's format), vendored
  dependencies laid out like OBS's own services make them (`vendor.tar.zst`)
- **test build:** offline in a Tumbleweed container (with the `.changes`
  turned into `%changelog` the way OBS does), `rpmlint`, installed and run
- **commit:** the package created if missing, a working copy in the cache,
  the spec, tarballs and `.changes` committed with `osc commit`
- **results:** OBS's build results followed until every release is done,
  failures shown with the end of their build log; then the `zypper addrepo`
  lines and the one-click install page

**Into openSUSE itself** (optional): Tumbleweed's packages come from
openSUSE:Factory, which takes packages through a *devel project*: find one
that fits (`osc develproject openSUSE:Factory <a similar package>`), send it
there with `osc submitrequest home:<you> <name> <devel project>`; its
maintainers review it and pass it on to Factory. The wizard prints these
steps at the end — that review is people's.

### What you need

- an openSUSE account (sign up on <https://build.opensuse.org>)
- podman or docker; osc (or Nix, which provides it)

## Alpine Linux (aports): `linux-submit.sh alpine`

Gets an app into [Alpine Linux](https://alpinelinux.org)'s package tree,
[aports](https://gitlab.alpinelinux.org/alpine/aports) — new packages start in
`testing/`, as Alpine asks — or ships a new version of one that's already
there, following Alpine's
[Creating an Alpine package](https://wiki.alpinelinux.org/wiki/Creating_an_Alpine_package),
the [APKBUILD reference](https://wiki.alpinelinux.org/wiki/APKBUILD_Reference),
[Creating patches](https://wiki.alpinelinux.org/wiki/Creating_patches) and
aports' own
[CODINGSTYLE.md](https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/CODINGSTYLE.md)
and [COMMITSTYLE.md](https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/COMMITSTYLE.md).
It ends with a merge request on gitlab.alpinelinux.org.

```bash
~/path/to/linux-submit.sh alpine            # new package or upgrade: it works out which
~/path/to/linux-submit.sh alpine --dry-run  # everything up to the commit, nothing pushed
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | ask nothing; a new package's merge request is opened as a **draft**, for you to review first |
| `--ask` | ask every question again |
| `--repo PATH`, `--config FILE` | the app's checkout, the shared answers |
| `--no-test` | skip the build and checks in an Alpine container (aports' CI still builds it) |
| `--draft` | open the merge request as a draft |
| `-n`, `--dry-run` | write, build, check and commit locally; push nothing |
| `--no-save`, `--forget` | control `~/.config/alpine-submit/last.conf` |

### What it does

- **the name:** checked against aports (main, community, testing) and
  Alpine's package index, subpackages included. The same software already
  there makes it an upgrade; a name used by something else is caught and a
  new one asked for (kept as `alpine-name` in `.store-submit.conf`). Open
  merge requests for the same aport are shown first
- **GitLab:** glab (GitLab's CLI; fetched from nixpkgs when it isn't
  installed) logs in to gitlab.alpinelinux.org once, with a personal access
  token you make on the page the wizard links (`api` scope) — the token stays
  in glab's own config, the wizard never sees it. Your fork of `alpine/aports`
  is found, or made
- **aports:** a blob-less clone in `~/.cache/store-submit/alpine/aports` (all
  of its history, file contents fetched only when needed; ~250 MB the first
  time), with only the aport at hand checked out, updated every run
- **APKBUILD:** in aports' current style — `maintainer=` first, then
  `pkgname`/`pkgver`/`pkgrel`, tabs, SPDX `license`, the release tarball as
  `source` (named so abuild doesn't refuse it, with no `$pkgname` in the URL),
  `builddir` only when it isn't the default, the recipes of `newapkbuild` and
  aports for Rust (`cargo-auditable`, `cargo fetch --locked` with
  `options="net"`), Go, Python (`gpep517`, `-pyc`, the build backend and
  dependencies mapped to `py3-…` packages), Node (`npm ci`, the published
  files plus production dependencies in `/usr/lib/node_modules`), Meson
  (`abuild-meson`), CMake and Make. A `check()` when there are tests,
  otherwise `options="!check" # no test suite`, as reviewers ask. pkg-config
  modules and programs the build uses are mapped to Alpine packages through
  Alpine's own package index; MIT/BSD/ISC license texts are installed into
  `-doc`. Versions apk can't take (`1.0-rc.1`) become apk's (`1.0_rc1`)
- **checksums:** `sha512sums` computed the way `abuild checksum` writes them
- **upgrades:** `pkgver` bumped, `pkgrel` reset to 0, checksums renewed (an
  aport that builds a git snapshot, `_commit=`, is left to you). Running it
  again while a merge request is open starts from your branch on GitLab, so
  the changes the review asked for stay
- **build + checks:** in an `alpine:edge` container (podman or docker), with a
  throwaway signing key: first the checks aports' CI runs on a merge request
  (the APKBUILD parses, `abuild validate`, `apkbuild-shellcheck`,
  `apkbuild-lint`), then `abuild -r`; the package is installed and its program
  run with `--version`. What has a clear fix is fixed and said so — man pages,
  completions, translations or services in the main package get their
  subpackages (`-doc`, `-bash-completion`, `-lang`, `-openrc`…), `arch` follows
  abuild's verdict on `noarch`, a missing pkg-config module, program or Python
  module is added from Alpine's index. Anything else: the relevant log lines,
  then edit / read the log / rebuild / skip the tests with a reason / quit
- **review + commit:** the whole change is shown; you'll be the package's
  maintainer, so a new APKBUILD is read before it's sent (with `--yes`, the
  merge request becomes a draft). Committed as you, in aports' style:
  `testing/<name>: new aport` with the homepage and description as the body,
  or `<repo>/<name>: upgrade to <version>`
- **merge request:** your fork's master synced with Alpine's (so the push is
  small), the branch pushed with glab as git's credential helper (no SSH key
  needed), and the merge request opened against `alpine/aports` master, with
  commits from maintainers allowed. It says how the APKBUILD was made and
  checked. Then the to-do list: watch the pipeline (it builds every
  architecture), answer the reviewers, move the package from testing to
  community once people have used it (testing is edge-only, and aports
  removes what isn't moved within 9 months), add it to
  [Anitya](https://release-monitoring.org)

**Flutter apps** are refused up front: Alpine's Flutter is only in testing
(x86_64 and aarch64), and each Flutter app needs hand-written patches to build
with it (see `testing/goguma` or `testing/sly`). Alpine users can install them
from Flathub — flatpak is in Alpine's community repository.

### What you need

- an account on [gitlab.alpinelinux.org](https://gitlab.alpinelinux.org/users/sign_in)
  — the wizard links the token page and runs `glab auth login` for you
- `git`, `curl`, `tar`; podman or docker for the build (recommended)
- the app on GitHub, GitLab or Codeberg — or anywhere that has a release
  tarball (self-hosted GitLab and Gitea/Forgejo are found by themselves;
  otherwise it's asked once and kept as `alpine-source`)
- an email address for the APKBUILD's `maintainer=` line (the config's
  `maintainer-email`, or `alpine-email` for Alpine only)

## Gentoo (GURU): `linux-submit.sh guru`

Publishes an app to [GURU](https://wiki.gentoo.org/wiki/Project:GURU) — the
official Gentoo repository of packages maintained by Gentoo users — or ships a
new version of one already there, following GURU's
[rules](https://wiki.gentoo.org/wiki/Project:GURU#Rules) and
[contributor guide](https://wiki.gentoo.org/wiki/Project:GURU/Information_for_Contributors),
the [devmanual](https://devmanual.gentoo.org/), and Gentoo's copyright
([GLEP 76](https://www.gentoo.org/glep/glep-0076.html)) and key
([GLEP 63](https://www.gentoo.org/glep/glep-0063.html)) policies.

GURU's rules let Gentoo users publish software they wrote, and ask every
contributor to agree to them first; the wizard asks both once. Newcomers send
pull requests on Codeberg; after a few are merged, GURU gives you direct push
access to its `dev` branch — the wizard does whichever you have, and says how
to ask for access.

```bash
~/path/to/linux-submit.sh guru            # new package or update: it works out which
~/path/to/linux-submit.sh guru --dry-run  # write, check, build and commit locally; send nothing
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | ask nothing; a new ebuild the wizard wrote still stops for your review, and your `Signed-off-by` is only added once you've given it in an earlier run |
| `--ask` | ask every question again |
| `--repo PATH`, `--config FILE` | the app's checkout, the shared answers |
| `--category CAT` | the Gentoo category (else from the config, or asked with a suggestion) |
| `--key FILE` | the SSH key for git.gentoo.org and codeberg.org |
| `--gpg-key ID` | the OpenPGP key to sign with (else remembered, or found by your e-mail) |
| `--pr` | send a pull request even if you can push to `dev` |
| `--no-test` | skip the test build in a Gentoo container |
| `-n`, `--dry-run` | write, check, build and commit locally; push and upload nothing |
| `--no-save`, `--forget` | control `~/.config/guru-submit/` |

### What it does

- **what can't work, first:** Gentoo has no Flutter SDK and Portage builds
  offline, so Flutter and npm apps are refused up front (GURU only has Flutter
  apps as `-bin` repackages) — Gentoo users get those from Flathub
- **the rules:** asks once whether you use Gentoo and agree to GURU's rules
  (again whenever GURU's pull request form shows they changed); checks the
  maintainer e-mail against Gentoo Bugzilla — GURU lists only addresses known
  there in `metadata.xml` — or leaves you out of it if you prefer
- **the category:** suggested from the description, checked against
  ::gentoo's and GURU's category lists, kept in `.store-submit.conf`
- **Gentoo's tree:** the signed daily snapshot, checked against Gentoo's
  snapshot key in a keyring of its own, refreshed once a day
- **new, update, or taken:** refuses what ::gentoo already packages (GURU
  doesn't duplicate it); finds your app in GURU even under another name;
  asks for another name if a different package has yours
- **ebuild:** `<category>/<name>/<name>-<version>.ebuild` with the newest EAPI
  its eclasses support — `cargo.eclass` (CRATES and crate licenses filled in by
  Gentoo's `pycargoebuild`; a crate tarball above 300 crates, as the eclass
  asks), `go-module.eclass` (a dependency tarball of the module cache, as the
  eclass describes, and the modules' licenses), `distutils-r1` (the
  `DISTUTILS_USE_PEP517` backend from `pyproject.toml`, dependencies mapped to
  `dev-python/*` and checked to exist), `meson`/`cmake` (pkg-config and
  `find_package` dependencies mapped to Gentoo packages, `xdg`/`gnome2-utils`
  for desktop files and schemas), or a plain Makefile with `toolchain-funcs`.
  `~arch` keywords only, as GURU requires. Plus `metadata.xml` with you as
  maintainer and the upstream `remote-id`
- **your own ebuild** (any `<name>-<version>.ebuild` in the app's repository)
  is used as it is instead — stable keywords turned into `~arch`
- **updates:** the ebuild already in GURU is copied to the new version (crates
  or the Go dependency tarball refreshed, the copyright year updated) and the
  old version dropped, as GURU usually does
- **dependency tarballs:** Gentoo doesn't host them, and GURU has no space of
  its own for them — so they're assets of your release: uploaded with `gh`
  when the app is on GitHub (after you say so), otherwise you upload it and
  the wizard checks it's the very file the Manifest hashed
- **Manifest + QA:** `pkgdev manifest` and `pkgcheck scan --net` (errors stop
  it: edit / carry on / quit), in a Gentoo container made once from
  `gentoo/stage3` with Gentoo's own tools — or yours, on a Gentoo machine
  without podman or docker
- **test build:** `ebuild … merge` in a clean `gentoo/stage3` container with
  the snapshot: dependencies from Gentoo's binary packages, then the network
  cut as Portage builds, tests on (`FEATURES=test`), QA notices shown, the
  program run with `--version`. Failing tests can be skipped for the build or
  restricted in the ebuild with your reason
- **review, AI policy, sign-off:** shows the whole change. Gentoo's AI policy
  (GURU follows it) forbids content made with the help of AI tools — the
  wizard says plainly that its ebuilds come from fixed templates in a script
  that was itself written with AI help, and that the call is GURU's; your own
  ebuild avoids the question. Then the GLEP 76 Certificate of Origin, and a
  commit signed with your OpenPGP key (checked against GLEP 63; one can be
  made the GLEP 63 way) and signed off, in GURU's style:
  `app-misc/foo: new package, add 1.0` / `app-misc/foo: add 1.1, drop 1.0`;
  then `pkgcheck scan --commits --net`
- **publish:** with access, rebased on `dev` from git.gentoo.org and pushed
  (signed push). Without, a pull request on Codeberg via AGit (no fork), as a
  draft (`WIP:`) with GURU's own form, ticked only where the run checked it or
  you said so — the AI-policy and Bugzilla boxes stay yours. No Codeberg
  account: a patch for the gentoo-guru mailing list. Then your to-do list:

```
   ┏━━ Your turn — GURU's reviewers take it from here
   ┃ 1. Open the pull request and tick the boxes still empty only if they're true for you …
   ┃ 2. Then remove "WIP:" from the title — that marks it ready for review
   ┃ 3. Answer the reviewers there; re-running linux-submit.sh guru updates the same pull request
   ┃ 4. After a few merged pull requests, ask for direct access to dev: https://bugs.gentoo.org/…
   ┃
   ┃    https://codeberg.org/gentoo/guru/pulls/…
   ┗━━
```

### What you need

- podman or docker (or, on Gentoo, `dev-util/pkgdev` and `dev-util/pkgcheck`
  — then without the test build); `git`, `ssh`, `curl`, `python3`, GnuPG
- a Codeberg account with your SSH key for pull requests — or GURU access for
  pushing to `dev`
- an OpenPGP key (the wizard can make one, GLEP 63 style) and, to be listed as
  maintainer, a [Gentoo Bugzilla](https://bugs.gentoo.org/createaccount.cgi)
  account with your e-mail
- the app on GitHub, GitLab, Codeberg or another public git host

## Homebrew: `linux-submit.sh brew`

Publishes an app to [Homebrew](https://brew.sh) — the package manager of macOS,
and of many Linux users — or ships a new version of it: a formula in
[homebrew/core](https://github.com/Homebrew/homebrew-core) when the app meets
Homebrew's [notability bar](https://docs.brew.sh/Package-Acceptance-Policy#notability),
otherwise in a tap of your own. It follows
[Adding Software to Homebrew](https://docs.brew.sh/Adding-Software-to-Homebrew),
[Acceptable Formulae](https://docs.brew.sh/Acceptable-Formulae), the
[Formula Cookbook](https://docs.brew.sh/Formula-Cookbook),
[How to Open a Homebrew Pull Request](https://docs.brew.sh/How-To-Open-a-Homebrew-Pull-Request)
and [Responsible AI Usage](https://docs.brew.sh/Responsible-AI-Usage).

```bash
~/path/to/linux-submit.sh brew            # new formula or update: it works out which
~/path/to/linux-submit.sh brew --dry-run  # write, build and check, commit locally; push nothing
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | ask nothing; a new homebrew/core formula still stops for you to review it |
| `--ask` | ask every question again |
| `--repo PATH`, `--config FILE` | the app's checkout, the shared answers |
| `--core` / `--tap` | homebrew/core, or your own tap (else from the config, or asked) |
| `--no-test` | don't build and check it — your own tap only |
| `-n`, `--dry-run` | write, build and check, commit locally; push nothing |
| `--no-save`, `--forget` | control `~/.config/brew-submit/last.conf` |

### What it does

- **homebrew/core or your tap:** reads the repository's stars, forks and
  watchers from GitHub, GitLab or Codeberg and checks them against the bar
  `brew audit --new` applies — 75 stars, 30 forks or 30 watchers; **225, 90 or
  90 when you own the repository and submit it yourself**; at least 30 days
  old; not a fork. Then you choose: a pull request to homebrew/core, or your
  own tap (published right away, `brew install <you>/tap/<name>`). Choosing
  core below the bar is warned about. The choice is kept in `.store-submit.conf`
- **the name:** Homebrew's naming rules; another app with the same name in
  homebrew/core (or, for core, a cask) means picking another name. An app
  that is in homebrew/core already, from your repository, is an update
- **Homebrew itself:** yours if `brew` is installed, otherwise Homebrew's own
  container (`ghcr.io/homebrew/brew`) with podman or docker. Files go in and
  out through the container's input and output — no mounts, so user ids and
  SELinux don't matter. Your gh login's token reaches the container only as
  an environment variable of the commands that call GitHub's API, and is
  never saved
- **the formula:** in Homebrew's current style, with its helpers:

  | project | install |
  | --- | --- |
  | Rust | `cargo install *std_cargo_args` (the workspace member that builds the program), `def fetch` with `std_cargo_fetch_args`, `deny_network_access!`; `-sys` crates' libraries added |
  | Go | `go build *std_go_args`, `-X main.version` when `main` has a version variable, `./cmd/<name>`; `def fetch` (`go mod download`) unless vendored |
  | Python | `include Language::Python::Virtualenv`, homebrew/core's current `python@3.x`, `virtualenv_install_with_resources`; every dependency a pinned `resource`, written by `brew update-python-resources` |
  | Node (npm) | `npm install *std_npm_args` and the `bin/` links; `npm run build` first when it's built from the tag |
  | Meson / CMake / Make | `std_meson_args` / `std_cmake_args` / `PREFIX`; pkg-config modules mapped to formulae, `uses_from_macos` and `on_linux` where they belong |

  The source is PyPI's or npm's release when it's published there (Homebrew
  prefers them), else the forge's tarball of the tag, with the sha256 of the
  real download. Every dependency is checked to be a Homebrew formula; the
  description is kept to Homebrew's 80 characters; SPDX licences become
  `any_of:` / `all_of:` / `with:`
- **`test do`:** Homebrew wants a test that uses the app — `--version` alone is
  a "bad test" to its reviewers. The wizard asks for a command and the text
  its output should contain (kept as `brew-test`), and adds a version check
  when the build shows `--version` prints the release
- **build + check:** `brew install --build-from-source` (with
  `HOMEBREW_NO_INSTALL_FROM_API=1`, as the contribution guide asks),
  `brew test`, `brew style --fix`, `brew audit --new --strict --online`. A
  failure is explained (a checksum, a dependency name, network use in the
  offline install step…) with edit / read the log / build again / quit
- **review:** Homebrew takes pull requests made with tools, but a person has to
  review generated code first and answer the reviewers themselves, without
  AI. So a new homebrew/core formula is shown and needs your "yes"; with
  `--yes` the wizard stops there with a to-do list
- **publish to homebrew/core:** your fork (made if missing), homebrew-core's
  latest commit only, sparse (~13 MB), one commit in Homebrew's style —
  `<name> <version> (new formula)` in `Formula/<letter>/` (`Formula/lib/` for
  `lib…`) — pushed with gh, and the pull request with Homebrew's template,
  ticking only what was done, plus the AI/automation disclosure Homebrew asks
  for. Already open pull requests for the name, earlier rejected ones, and
  Homebrew's one-AI-assisted-pull-request-at-a-time rule are checked first
- **publish to your tap:** `<owner>/homebrew-tap` — the app's owner's when you
  can push there, else yours. A new tap starts from `brew tap-new`'s template
  (README and the GitHub Actions that test it), is created with
  `gh repo create` and pushed; an existing one gets the commit
- **updates:** a homebrew/core formula that BrewTestBot bumps by itself
  (autobump, the default for new formulae) is left to it. Otherwise
  `brew bump-formula-pr --write-only` makes the update, it's built and
  checked, and the pull request (`<name> <version>`) goes out as above. In
  your tap the same bump is committed and pushed
- **your own Homebrew is left as it was:** a formula placed in your
  homebrew/core checkout for the checks, its test install and a bump are
  undone when the wizard ends; a dry run puts your tap back too

**Flutter** apps can't be formulae: Homebrew builds formulae from source and
has no Flutter SDK to build with (Flutter is only a macOS cask, which a formula
can't depend on). Homebrew's casks install ready-made builds — a macOS `.app`,
or a Linux AppImage — and this wizard doesn't write casks; on Linux, Flutter
apps go to Flathub or the Snap Store.

The answers it adds to `.store-submit.conf`: `brew-target` (core or tap),
`brew-tap`, `brew-name` and `brew-desc` (only when they differ from `name` and
`description`), `brew-test` and `brew-test-expect`.

### What you need

- `gh`, logged in: homebrew/core's pull requests and taps live on GitHub
- Homebrew, or podman or docker for Homebrew's container (NixOS:
  `virtualisation.podman.enable = true;`) — nixpkgs has no Homebrew to fetch
- the app on GitHub, GitLab, Codeberg or another public git host; for
  homebrew/core also a license and the notability above
