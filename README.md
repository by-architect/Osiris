# scripts

Two release wizards for the same Android app: one for F-Droid, one for Google Play.

## fdroid-submit.sh

Interactive wizard for submitting an Android app to F-Droid — it produces the
`metadata/<applicationId>.yml` entry and pushes a branch to your `fdroiddata`
fork, ready for a merge request.

```bash
./fdroid-submit.sh            # the wizard
./fdroid-submit.sh --dry-run  # everything except the final push
./fdroid-submit.sh --help
```

| flag | effect |
| --- | --- |
| `-n`, `--dry-run` | stops short of `git commit` / `git push` |
| `--no-save` | don't remember the answers |
| `--forget` | delete the remembered answers and exit |

It asks about everything it cannot work out for itself, and auto-detects:
application ID, versionName, versionCode, the Gradle module, product flavours,
the latest tag, the license, and the project URLs from the git remote. Answers
that stay the same between runs (fork URL, GitLab user, license, categories…)
are remembered in `~/.config/fdroid-submit/last.conf` and offered as defaults.

Five stages: app repo → fdroiddata fork → metadata → validate → push.
Nothing is pushed without confirming first.

### New app or update

The wizard looks up `metadata/<appid>.yml` on current upstream master and picks
the right mode by itself:

- **new app** — asks for license, categories, URLs, author, anti-features and the
  publishing mode, and writes the whole file.
- **update** — keeps the upstream file untouched apart from appending one
  `Builds:` entry and bumping `CurrentVersion`/`CurrentVersionCode`. It refuses
  if that versionCode is already there, and shows you the diff rather than the
  whole file.

The branch is always cut from `upstream/master` (`<appid>` for a new app,
`<appid>-<versionCode>` for an update), so the merge request is a single-file
change no matter what state your fork was left in.

### Pitfall check

Before anything is written, the app repo is checked for the things that most
often stall a merge request:

- the release tag missing from the **remote** (F-Droid builds the published tag)
- prebuilt binaries tracked in git (`.jar`, `.aar`, `.so`, `.apk`, `.keystore`…)
- proprietary dependencies (Play Services, Firebase, Crashlytics, billing…)
- no fastlane metadata, which means an F-Droid listing with no description —
  it offers to create `fastlane/metadata/android/en-US/` for you

### What you need beforehand

- a **GitLab account** with a fork of <https://gitlab.com/fdroid/fdroiddata>
- an **RFP issue** opened at <https://gitlab.com/fdroid/rfp/-/issues> (new apps only)
- the release **tag pushed** to your app's repository

### fdroid CLI

The script runs `readmeta`, `rewritemeta`, `lint` and optionally `build`. It looks
for the CLI in this order:

1. `fdroid` on `$PATH`
2. `nix-shell -p fdroidserver` — works out of the box on this machine
3. the `registry.gitlab.com/fdroid/fdroidserver` image, via podman or docker
   (run as your own uid, so nothing comes back root-owned)

If none are present it still writes the metadata and skips validation.

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
| `--artifact FILE` | the `.aab` or `.apk`; found under `build/outputs/` otherwise |
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

Every locale with a changelog for that versionCode is sent.

Authentication is a signed JWT swapped for an access token (`openssl` +
`curl`), so there is no SDK or `gcloud` to install — only `curl`, `openssl`
and `python3`.

### References

- <https://developers.google.com/android-publisher/edits>
- <https://developers.google.com/android-publisher/api-ref/rest>

