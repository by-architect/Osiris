# scripts

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
