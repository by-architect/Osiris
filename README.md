# store-submit.sh

One script for publishing an app: to F-Droid and Google Play for Android, and
to Linux — NixOS (nixpkgs), Arch (AUR), Flathub, the Snap Store and Ubuntu
(Launchpad PPA) — from one set of answers.

- `store-submit.sh` — asks which store(s), checks what each needs from the
  app and what this machine has, then runs that store's wizard
- `store-submit.sh fdroid|play|linux [options]` — one store's wizard directly
- `store-submit.sh nix|aur|flathub|snap|ppa [options]` — one Linux distro's wizard directly
  (each takes `--help`)

Each wizard runs in a process of its own, so running one directly or from the
picker behaves the same. Remembered answers stay in
`~/.config/storepublisher/playstore/` for Google Play and
`~/.config/{store-submit,fdroid-submit,nixpkgs-submit,aur-submit,flathub-submit,snap-submit,ppa-submit}/`
for the rest;
what the Linux packages say about the app is in `.store-submit.conf` in the
app's own repository.

## The store picker: `store-submit.sh`

```bash
cd ~/path/to/your-app
~/path/to/store-submit.sh                         # asks where to publish
~/path/to/store-submit.sh -s fdroid,play --check  # only the checks
~/path/to/store-submit.sh -s play -- --track beta # args after -- go to the wizard
```

| flag | effect |
| --- | --- |
| `-s`, `--store LIST` | `fdroid`, `play`, `linux`, comma-separated, or `all` (`nix` or `aur` = `linux` with that distro) |
| `-d`, `--distros LIST` | for `linux`: the distros (`nix`, `aur`, `flathub`, `snap`, `ppa`), skipping the checkbox list |
| `--repo PATH` | the app's checkout (default: the git repo you run it in) |
| `-c`, `--check` | run the checks, start no wizard |
| `-y`, `-n`, `--no-save` | passed on to the wizard(s); `--yes` needs `--store` |
| `--list`, `--forget` | list the stores / forget the remembered choice |

- **the app:** project type (Android, Flutter, Rust, Go, Node, Python…),
  application ID and version, git remote and tags, license, fastlane metadata;
  then per store — e.g. a signed release build and service account key for
  Play, proprietary dependencies for F-Droid, a Linux target and lock files
  for the Linux distros, a name Arch doesn't ship already for the AUR
- **this machine:** OS and package manager, and each tool the store's wizard
  runs, required (✗ stops the run) or optional (!), with an install command for
  your package manager
- **F-Droid's GitLab side:** glab login or `$GITLAB_TOKEN`, git new enough
  (2.22+) for the blob-less fdroiddata clone, whether a clone is already there
  to reuse, `ssh` for pushing to a `git@gitlab.com:` fork, a git identity for
  the fdroiddata commit, and a warning when `$FDROIDDATA_UPSTREAM` is set

Picking **Linux** opens a checkbox list of distributions (↑/↓, Space, `a` for
all, Enter; numbers when there's no terminal). Fedora is listed as coming
later.

Adding a store is a line in `STORES`, a `needs_<id>` and a `tools_<id>`
function, a `wizard_<id>` function, and its id in the direct-run `case` just
above the picker. Adding a Linux distro is the same with a line in `DISTROS`.

## F-Droid: `store-submit.sh fdroid`

Gets an Android app into F-Droid, or a new version of it: writes the
`metadata/<applicationId>.yml` entry, validates it, pushes a branch to your
`fdroiddata` fork and — with `glab` logged in — opens the merge request.

```bash
cd ~/path/to/your-app
~/path/to/store-submit.sh fdroid        # first time: a few questions
~/path/to/store-submit.sh fdroid --yes  # every release after: one command
```

| flag | effect |
| --- | --- |
| `-y`, `--yes` | use everything detected, ask nothing; stops only on problems |
| `--ask` | ask every question, including the ones it can answer itself |
| `--repo PATH` | the app's checkout (default: the git repo you run it in) |
| `--build` | also run the full `fdroid build` (slow) |
| `--rfp` | also open a Request For Packaging issue (new apps) |
| `-n`, `--dry-run` | no tagging, pushing, issues or merge requests |
| `--no-save` | don't remember the answers |
| `--forget` | delete the remembered answers and exit |

### What it works out by itself

Detected values are shown as `✓` lines instead of questions:

- **the app:** the repo you run it in, the Gradle module, application ID,
  versionName and versionCode (from `pubspec.yaml` for Flutter)
- **the release tag** `v<version>`: created on HEAD and pushed if missing,
  pushed if only local, and checked to hold exactly this ID and version; a
  stale tag can be moved (asked, never automatic)
- **new app or update**, from upstream fdroiddata
- **GitLab:** your username from `glab`, the fork (created if missing); where
  to put the local fdroiddata clone is always asked, with the last path (or
  `~/fdroiddata`) as the default
- **the metadata:** source/issue/changelog URLs from the git remote,
  AuthorName from git config, the Flutter version from `.fvmrc`, no
  anti-features unless the pitfall check found proprietary bits
- **validation:** `readmeta`, `rewritemeta` and `lint` run on their own; a
  failure stops the run before anything is pushed
- **the merge request:** title in fdroiddata's format (`New app: <name>`,
  `Update <name> to <version>`), fdroiddata's own template as the description
  with the checklist items it verified ticked, opened with `glab`

What it asks: the **categories** (the first time for each app — remembered
after); the **license** and the **AuthorEmail**, each with what it found as
the default and where it came from (the license from `LICENSE`, with GPL's
"only" or "or later" read from the notices in your source files; the email
from `git config user.email` — Enter keeps it, `-` leaves it out, since it
becomes public); "Looks right?" for the metadata, and before each action that leaves
your machine (tag push, branch push, merge request). `--yes` answers those;
it never force-pushes and stops where only a person can decide (categories
for a new app, a missing store listing, failing validation).

### fdroiddata's rules it follows

Taken from fdroiddata's merge request checklist and `templates/`:

- `commit:` is the tag's **full commit hash**, not the tag name
- an **AuthorName** is always set
- Flutter apps get **one APK per CPU type** (armeabi-v7a, arm64-v8a, x86_64)
  with Flutter's own versionCodes (1000/2000/4000 + code) and a matching
  `VercodeOperation`, so auto-updates keep working
- the Flutter version is read from the app's `.fvmrc` at build time
  (`flutter@stable` + checkout), `pub get --enforce-lockfile`, and unused
  platform folders (`ios`, `web`…) are removed before the build
- `AutoUpdateMode` and `UpdateCheckData` are set so F-Droid picks up new tags

### New app or update

The wizard looks up `metadata/<appid>.yml` on current upstream master and picks
the right mode by itself:

- **new app** — writes the whole file.
- **update** — keeps the upstream file untouched apart from appending this
  release's `Builds:` entries and bumping `CurrentVersion`/`CurrentVersionCode`.
  It refuses if those versionCodes are already there, and shows you the diff.

The branch is always cut from `upstream/master` (`<appid>` for a new app,
`<appid>-<versionCode>` for an update), so the merge request is a single-file
change no matter what state your fork was left in. A leftover
`metadata/<appid>.yml` from an earlier run is reset automatically.

### Pitfall check

Before anything is written, the app repo is checked for the things that most
often stall a merge request:

- the release tag missing from the **remote** (F-Droid builds the published tag)
- a tag that doesn't hold the **application ID and version** being submitted
  (e.g. tagged before the ID was changed) — F-Droid would build the wrong thing
- prebuilt binaries tracked in git (`.jar`, `.aar`, `.so`, `.apk`, `.keystore`…)
- proprietary dependencies (Play Services, Firebase, Crashlytics, billing…),
  and for Flutter apps the plugins that pull them in (`firebase_*`,
  `google_mobile_ads`, `in_app_purchase`…)
- a release build signed with the **debug key** (the Flutter template does
  this) — F-Droid needs builds without your key to come out unsigned
- for Flutter apps, a **pre-release Dart SDK** constraint in `pubspec.yaml`,
  which only a dev/master Flutter can build
- no fastlane metadata, which means an F-Droid listing with no description —
  it offers to create `fastlane/metadata/android/en-US/` for you

### Flutter apps

A Flutter project anywhere in the repo's top two levels (a `pubspec.yaml` that
depends on the Flutter SDK, with `android/app/` beside it) is recognised:

- the Gradle module defaults to `<flutter dir>/android/app`
- versionName and versionCode come from `pubspec.yaml` (`version: 1.2.3+45`),
  since the Gradle file only holds `flutter.versionName`/`flutter.versionCode`
- the build entries follow fdroiddata's Flutter template instead of
  `gradle: yes` (see "fdroiddata's rules it follows" above); a flavour you
  pick is passed as `--flavor`
- the Flutter version is read from `.fvmrc`, `.fvm/fvm_config.json` or
  `.tool-versions`, else from the local `flutter --version`. A pre-release (a
  master/beta build) is offered as its commit hash, with a warning — F-Droid
  maintainers expect a stable tag
- new apps get `UpdateCheckData` pointing at `pubspec.yaml`, so F-Droid's update
  checker can read versions from it

### What you need beforehand

- a **GitLab account** with a fork of <https://gitlab.com/fdroid/fdroiddata> —
  once per account, reused for every app and update (each submission is a
  branch in it). If it's missing, the wizard creates it with `glab` (offering
  `glab auth login` first) or GitLab's API with `$GITLAB_TOKEN`, then waits for
  GitLab to finish copying; without either it links the fork page. It won't
  fork into an account other than the one in the fork URL.
  The local copy is cloned from **upstream over HTTPS** with history only
  (`--filter=blob:none`; files load as needed), with your fork added as the
  `origin` it pushes to — a full SSH clone of a repo this size tends to be cut
  off midway.
- the release **tag pushed** to your app's repository

### RFP issue (optional)

A Request For Packaging issue isn't required when you send the metadata
yourself — F-Droid's quick start guide calls that merge request the best way
in. For new apps, `--rfp` (or answering yes under `--ask`) opens one after the
metadata is written, filled from F-Droid's RFP template with your answers (categories,
license, URLs) plus the summary and description from your fastlane listing.
It uses the first of these that works:

1. **`glab`**, if it is logged in to gitlab.com
2. **GitLab's API**, with a personal access token in `$GITLAB_TOKEN` (`api` scope)
3. **your browser**: a pre-filled new-issue page opens; check it and press
   *Create issue*, then paste its URL back

`gh` can't be used here: the RFP tracker is on GitLab, not GitHub. The issue
is linked from the merge request (`Closes fdroid/rfp#N`) so it closes on merge.
`--dry-run` shows the issue but never opens it.

### fdroid CLI

The script runs `readmeta`, `rewritemeta`, `lint` and optionally `build`. It
**never installs fdroidserver itself** — it uses the one you have:

1. `fdroid` on `$PATH` (a distro or nix package)
2. a source checkout of fdroidserver: `$FDROIDSERVER`, the path remembered from
   last time, or `~/Opt/fdroidserver`, `~/fdroidserver`, `~/src/fdroidserver`,
   `~/Projects/fdroidserver`. It runs it the way fdroiddata's CI runs master —
   `PATH` and `PYTHONPATH` pointed at the checkout — so its Python dependencies
   have to be installed.

If neither is there, it says how to install one and waits: check again, give a
checkout's path, skip validation (the maintainers' CI still runs it), or quit.

fdroiddata's CI lints with fdroidserver **master**, so a checkout of master
(`git clone https://gitlab.com/fdroid/fdroidserver.git`) matches it most
closely; distro packages can be a release or two behind.

### Publishing modes

The wizard asks which you want:

1. **F-Droid builds and signs** — simplest. F-Droid compiles from source and signs
   with its own key, so an app installed from your own APK cannot update to it.
2. **Reproducible build** — F-Droid rebuilds from source, verifies the result matches
   your signed APK, and ships yours. Keeps your signature. Adds `Binaries:` and
   `AllowedAPKSigningKeys:`, and reads the fingerprint straight out of a local APK
   with `apksigner` or `keytool`.

### References

- <https://f-droid.org/docs/Submitting_to_F-Droid_Quick_Start_Guide/>
- <https://f-droid.org/docs/Build_Metadata_Reference/>

## Google Play: `store-submit.sh play`

Uploads a release to **Google Play** through the Play Developer API
(androidpublisher v3) — the same endpoints Play Console itself uses.

```bash
./store-submit.sh play                # the wizard
./store-submit.sh play --dry-run      # upload + validate, then throw the edit away
./store-submit.sh play --yes --track internal --rollout 0.1 --key ~/sa.json   # CI
./store-submit.sh play --help
```

| flag | effect |
| --- | --- |
| `-n`, `--dry-run` | insert the edit, upload, validate, then delete it |
| `-y`, `--yes` | take the defaults and commit without asking (CI) |
| `--key FILE` | service account JSON key (or `$PLAY_SERVICE_ACCOUNT_JSON`) |
| `--package ID` | application id; detected from gradle otherwise |
| `--artifact FILE` | the `.aab` or `.apk`; found under `build/outputs/` (or Flutter's `build/app/outputs/`) otherwise |
| `--track NAME` | `internal`, `alpha`, `beta`, `production`, or a closed track |
| `--rollout F` | staged rollout fraction, `0 < F <= 1` |
| `--draft` | upload as a draft release instead of releasing it |
| `--notes FILE` | release notes; fastlane changelogs are used otherwise |
| `--mapping FILE` | R8/ProGuard `mapping.txt`; auto-detected otherwise |
| `--no-review` | commit with `changesNotSentForReview=true` |
| `--no-save`, `--forget` | control `~/.config/storepublisher/playstore/last.conf` |

One API *edit* per run, committed only at the very end:

```
edits.insert → bundles.upload → deobfuscationFiles.upload
             → tracks.update → edits.validate → edits.commit
```

Nothing reaches Google Play until you confirm; `--dry-run` stops after validate,
and any run that fails part-way deletes its edit instead of leaving it open.

### What it needs

- a **service account JSON key** in `~/.config/storepublisher/playstore/service-account.json`
  (or passed with `--key`, or in `$PLAY_SERVICE_ACCOUNT_JSON`). A key in that
  location is picked up without being asked for. Set one up once:
  1. enable the *Google Play Android Developer API* for a Cloud project —
     <https://console.cloud.google.com/apis/library/androidpublisher.googleapis.com>
  2. create a service account, then *Keys → Add key → Create new key → JSON* —
     <https://console.cloud.google.com/iam-admin/serviceaccounts>
  3. invite that account's email in Play Console under *Users and permissions*
     and grant it release access to the app —
     <https://play.google.com/console/users-and-permissions>
     (it then appears under <https://play.google.com/console/api-access>)

  Google's walkthrough: <https://developers.google.com/android-publisher/getting_started>
- the app **already created in Play Console**, with its store listing filled in.
  The API cannot create an app or its listing — do the first release by hand,
  everything after that with this script
- a **signed** `.aab`/`.apk` (the script warns if it finds no signature block)

Release notes are read from the same layout F-Droid uses, so both scripts share
one source of truth:

```
fastlane/metadata/android/<locale>/changelogs/<versionCode>.txt
```

Every locale with a changelog for that versionCode is sent. In Flutter repos
that keep `fastlane/` inside the Flutter project instead of the repo root, it is
found there too.

Authentication is a signed JWT swapped for an access token (`openssl` +
`curl`), so there is no SDK or `gcloud` to install — only `curl`, `openssl`
and `python3`.

### References

- <https://developers.google.com/android-publisher/edits>
- <https://developers.google.com/android-publisher/api-ref/rest>

## Linux: `store-submit.sh linux`

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

With Flathub, the Snap Store or the PPA among the distros, their questions —
the Flathub app ID, the snap name, whether the app uses the internet (asked
once for both), your Launchpad account, PPA and Ubuntu releases — are part of
step 2 too.

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
~/path/to/store-submit.sh linux                        # pick distros, answer once, publish
~/path/to/store-submit.sh linux --distros nix,aur -n   # a dry run of both
```

## nixpkgs: `store-submit.sh nix`

Gets an app into [nixpkgs](https://github.com/NixOS/nixpkgs) — what Nix and
NixOS install from — or ships a new version of one that's already there:
writes `pkgs/by-name/<xx>/<name>/package.nix`, builds it, checks it the way
nixpkgs reviewers do, and opens the pull request.

```bash
cd ~/path/to/your-app
~/path/to/store-submit.sh nix             # new package or update: it works out which
~/path/to/store-submit.sh nix --dry-run   # everything up to the commits, nothing pushed
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

## Arch (AUR): `store-submit.sh aur`

Publishes an app to the [AUR](https://aur.archlinux.org), or ships a new
version of one already there, following Arch's
[AUR submission guidelines](https://wiki.archlinux.org/title/AUR_submission_guidelines)
and [package guidelines](https://manual.archlinux.page/package-guidelines/).

```bash
~/path/to/store-submit.sh aur            # new package or update: it works out which
~/path/to/store-submit.sh aur --dry-run  # everything up to the commit, nothing pushed
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

## Flathub: `store-submit.sh flathub`

Prepares an app for [Flathub](https://flathub.org), or an update of one
already there — everything **up to the pull request, which you open
yourself**. Flathub's [Generative AI policy](https://docs.flathub.org/docs/for-app-authors/requirements#generative-ai-policy)
says tools must not open or automate submission pull requests, so the wizard
ends with your to-do list and a link that opens the pull request form with
the branch and title filled in.

```bash
~/path/to/store-submit.sh flathub            # new app or update: it works out which
~/path/to/store-submit.sh flathub --dry-run  # build and check; your fork isn't touched
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

## Snap Store: `store-submit.sh snap`

Publishes an app to the [Snap Store](https://snapcraft.io), or a new version,
following [Snapcraft's documentation](https://ubuntu.com/docs/snapcraft/stable/how-to/publishing/).
The Snap Store has no rule against automated uploads; instead it reviews
every new snap and revision before it's public, so the wizard publishes by
itself and tells you when a release waits for that review.

```bash
~/path/to/store-submit.sh snap            # new snap or update
~/path/to/store-submit.sh snap --dry-run  # build it; register and upload nothing
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

## Ubuntu (Launchpad PPA): `store-submit.sh ppa`

Ubuntu and the distributions built on it — Linux Mint, Pop!_OS, Zorin,
elementary — are the most used Linux desktops. Their App Center is the Snap
Store (above); for `apt`, the way a developer publishes directly is a
[Launchpad PPA](https://launchpad.net/ubuntu/+ppas):
`sudo add-apt-repository ppa:you/app && sudo apt install app`. (Debian's own
archive needs a Debian developer to sponsor each upload, so it can't be
automated.) Launchpad's rules ask only for an open-source license and signed,
source-only uploads; it builds the binaries itself.

```bash
~/path/to/store-submit.sh ppa            # new package or a new version
~/path/to/store-submit.sh ppa --dry-run  # make and test-build; don't sign or upload
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
