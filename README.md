# scripts

Release wizards for publishing an app: F-Droid and Google Play for Android,
nixpkgs for Nix and NixOS, and `store-submit.sh` in front of them to pick where
the app goes.

## store-submit.sh

The one to start with. It asks which store(s) to publish to, checks what that
store needs from the app and what this machine has, then runs the store's own
wizard in the app's checkout.

```bash
cd ~/path/to/your-app
~/path/to/store-submit.sh                         # asks where to publish
~/path/to/store-submit.sh -s fdroid,play --check  # only the checks
~/path/to/store-submit.sh -s play -- --track beta # args after -- go to the wizard
```

| flag | effect |
| --- | --- |
| `-s`, `--store LIST` | `fdroid`, `play`, `nix`, `aur`, comma-separated, or `all` |
| `--repo PATH` | the app's checkout (default: the git repo you run it in) |
| `-c`, `--check` | run the checks, start no wizard |
| `-y`, `-n`, `--no-save` | passed on to the wizard(s); `--yes` needs `--store` |
| `--list`, `--forget` | list the stores / forget the remembered choice |

- **the app:** project type (Android, Flutter, Rust, Go, Node, Python…),
  application ID and version, git remote and tags, license, fastlane metadata;
  then per store — e.g. a signed release build and service account key for
  Play, proprietary dependencies for F-Droid, lock files for Nixpkgs
- **this machine:** OS and package manager, and each tool the store's wizard
  runs, required (✗ stops the run) or optional (!), with an install command for
  your package manager
- **F-Droid's GitLab side:** glab login or `$GITLAB_TOKEN`, git new enough
  (2.22+) for the blob-less fdroiddata clone, whether a clone is already there
  to reuse, `ssh` for pushing to a `git@gitlab.com:` fork, a git identity for
  the fdroiddata commit, and a warning when `$FDROIDDATA_UPSTREAM` is set

The AUR only has the checks so far. Adding a store is a line in
`STORES`, a `needs_<id>` and a `tools_<id>` function, and its wizard script.

## fdroid-submit.sh

Gets an Android app into F-Droid, or a new version of it: writes the
`metadata/<applicationId>.yml` entry, validates it, pushes a branch to your
`fdroiddata` fork and — with `glab` logged in — opens the merge request.

```bash
cd ~/path/to/your-app
~/path/to/fdroid-submit.sh            # first time: a few questions
~/path/to/fdroid-submit.sh --yes      # every release after: one command
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
- **the metadata:** license from `LICENSE`, source/issue/changelog URLs from
  the git remote, AuthorName/Email from git config, the Flutter version from
  `.fvmrc`, no anti-features unless the pitfall check found proprietary bits
- **validation:** `readmeta`, `rewritemeta` and `lint` run on their own; a
  failure stops the run before anything is pushed
- **the merge request:** title in fdroiddata's format (`New app: <name>`,
  `Update <name> to <version>`), fdroiddata's own template as the description
  with the checklist items it verified ticked, opened with `glab`

What it asks: the **categories** (the first time for each app — remembered
after), "Looks right?" for the metadata, and before each action that leaves
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

## play-submit.sh

Uploads a release to **Google Play** through the Play Developer API
(androidpublisher v3) — the same endpoints Play Console itself uses.

```bash
./play-submit.sh                      # the wizard
./play-submit.sh --dry-run            # upload + validate, then throw the edit away
./play-submit.sh --yes --track internal --rollout 0.1 --key ~/sa.json   # CI
./play-submit.sh --help
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
| `--no-save`, `--forget` | control `~/.config/play-submit/last.conf` |

One API *edit* per run, committed only at the very end:

```
edits.insert → bundles.upload → deobfuscationFiles.upload
             → tracks.update → edits.validate → edits.commit
```

Nothing reaches Google Play until you confirm; `--dry-run` stops after validate,
and any run that fails part-way deletes its edit instead of leaving it open.

### What it needs

- a **service account JSON key**: enable the *Google Play Android Developer API*
  in Google Cloud, create a service account, download a JSON key, then invite
  that account's email in Play Console under *Users and permissions* and grant
  it release access to the app
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

## nixpkgs-submit.sh

Gets an app into [nixpkgs](https://github.com/NixOS/nixpkgs) — what Nix and
NixOS install from — or ships a new version of one that's already there:
writes `pkgs/by-name/<xx>/<name>/package.nix`, builds it, checks it the way
nixpkgs reviewers do, and opens the pull request.

```bash
cd ~/path/to/your-app
~/path/to/nixpkgs-submit.sh             # new package or update: it works out which
~/path/to/nixpkgs-submit.sh --dry-run   # everything up to the commits, nothing pushed
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
