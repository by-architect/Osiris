#!/usr/bin/env bash
#
# play-submit.sh — push an Android release to Google Play from the command line.
#
# Uses the Google Play Developer API (androidpublisher v3):
#   https://developers.google.com/android-publisher/edits
#   https://developers.google.com/android-publisher/api-ref/rest
#
# One "edit" per run, the way the API wants it:
#   edits.insert → bundles/apks.upload → tracks.update → edits.validate → edits.commit
#
# Nothing reaches Google Play until you confirm the commit, and --dry-run stops
# after validate and throws the edit away.
#
# What this cannot do: create the app or its store listing. The package has to
# exist in Play Console already, with the listing filled in and one release made
# by hand. After that, this ships builds to it.

set -eu

# ------------------------------------------------------------------ arguments
DRYRUN=0
ASSUME_YES=0
SAVE=1
TRACK=""
ROLLOUT=""
STATUS=""
KEYFILE="${PLAY_SERVICE_ACCOUNT_JSON:-}"
PKG=""
ARTIFACT=""
NOTESFILE=""
MAPPING=""
NOREVIEW=0
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/play-submit"
CONF="$CONF_DIR/last.conf"
# Override for testing against a mock; leave unset to talk to Google.
API_ROOT="${PLAY_API_ROOT:-https://androidpublisher.googleapis.com}"

usage() {
  cat <<'USAGE'
play-submit.sh — upload an Android release to Google Play (Publisher API v3).

  -h, --help           show this text
  -n, --dry-run        insert the edit, upload, validate — then delete it
  -y, --yes            take the defaults and commit without asking; for CI
      --key FILE       service account JSON key
      --package ID     application id, e.g. com.example.app
      --artifact FILE  the .aab or .apk to upload
      --track NAME     internal | alpha | beta | production | <closed track>
      --rollout F      staged rollout fraction, 0 < F <= 1 (implies inProgress)
      --draft          upload as a draft release instead of releasing it
      --notes FILE     release notes for en-US (default: fastlane changelogs)
      --mapping FILE   ProGuard/R8 mapping.txt to attach
      --no-review      commit with changesNotSentForReview=true
      --no-save        do not remember the answers for next time
      --forget         delete the remembered answers and exit

Anything not given is asked for. The app must already exist in Play Console.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -n|--dry-run) DRYRUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --key)        KEYFILE="${2-}"; shift ;;
    --package)    PKG="${2-}"; shift ;;
    --artifact)   ARTIFACT="${2-}"; shift ;;
    --track)      TRACK="${2-}"; shift ;;
    --rollout)    ROLLOUT="${2-}"; shift ;;
    --draft)      STATUS=draft ;;
    --notes)      NOTESFILE="${2-}"; shift ;;
    --mapping)    MAPPING="${2-}"; shift ;;
    --no-review)  NOREVIEW=1 ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF"; printf 'forgot %s\n' "$CONF"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- presentation
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'
else
  B=""; DIM=""; R=""; GRN=""; YLW=""; RED=""; CYN=""
fi
step()  { printf '\n%s━━ %s %s\n' "$B$CYN" "$*" "$R"; }
say()   { printf '   %s\n' "$*"; }
note()  { printf '   %s%s%s\n' "$DIM" "$*" "$R"; }
warn()  { printf '   %s! %s%s\n' "$YLW" "$*" "$R"; }
ok()    { printf '   %s✓ %s%s\n' "$GRN" "$*" "$R"; }
die()   { printf '\n%sERROR: %s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

readline() {  # readline VAR — refuses to spin on a closed stdin
  IFS= read -r "$1" && return 0
  printf '\n' >&2
  die "end of input — this script needs an interactive terminal (or use --yes)"
}

ask() {
  local __var="$1" __q="$2" __def="${3-}" __in=""
  while :; do
    if [ "$ASSUME_YES" = 1 ] && [ -n "$__def" ]; then printf -v "$__var" '%s' "$__def"; return 0; fi
    if [ -n "$__def" ]; then printf '   %s%s%s [%s]: ' "$B" "$__q" "$R" "$__def" >&2
    else printf '   %s%s%s: ' "$B" "$__q" "$R" >&2; fi
    readline __in
    [ -z "$__in" ] && __in="$__def"
    if [ -z "$__in" ]; then printf '   %sthis one is required%s\n' "$YLW" "$R" >&2; continue; fi
    break
  done
  printf -v "$__var" '%s' "$__in"
}

ask_opt() {
  local __var="$1" __q="$2" __def="${3-}" __in=""
  if [ "$ASSUME_YES" = 1 ]; then printf -v "$__var" '%s' "$__def"; return 0; fi
  printf '   %s%s%s%s: ' "$B" "$__q" "$R" "${__def:+ [$__def]}" >&2
  readline __in
  [ -z "$__in" ] && __in="$__def"
  printf -v "$__var" '%s' "$__in"
}

confirm() {
  local q="$1" def="${2:-n}" a=""
  [ "$ASSUME_YES" = 1 ] && { case "$def" in y) return 0 ;; *) return 1 ;; esac; }
  local hint="[y/N]"; [ "$def" = y ] && hint="[Y/n]"
  printf '   %s%s%s %s ' "$B" "$q" "$R" "$hint" >&2
  readline a
  [ -z "$a" ] && a="$def"
  case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- scratch space
# The service account's private key passes through here, so keep it to ourselves.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/play-submit.XXXXXX")"
chmod 700 "$WORK"
EDIT_ID=""
COMMITTED=0
cleanup() {
  # An edit left open is harmless (it expires) but tidy up anyway.
  if [ -n "$EDIT_ID" ] && [ "$COMMITTED" = 0 ] && [ -n "${TOKEN:-}" ]; then
    curl -sS -o /dev/null -X DELETE \
      -H "Authorization: Bearer $TOKEN" \
      "$API_ROOT/androidpublisher/v3/applications/$PKG/edits/$EDIT_ID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------- remembered answers
SAVED_REPO=""; SAVED_SUBDIR=""; SAVED_PKG=""; SAVED_KEYFILE=""; SAVED_TRACK=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  {
    printf '# written by play-submit.sh — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n'    "${REPO:-}"
    printf 'SAVED_SUBDIR=%q\n'  "${SUBDIR:-}"
    printf 'SAVED_PKG=%q\n'     "${PKG:-}"
    printf 'SAVED_KEYFILE=%q\n' "${KEYFILE:-}"
    printf 'SAVED_TRACK=%q\n'   "${TRACK:-}"
  } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  chmod 600 "$CONF" 2>/dev/null || true
}

# --------------------------------------------------------------------- json
jget() {  # jget FILE dotted.path — prints the value, or nothing if absent
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in sys.argv[2].split('.'):
    if isinstance(d, list):
        try: d = d[int(k)]
        except Exception: d = None
    elif isinstance(d, dict):
        d = d.get(k)
    else:
        d = None
    if d is None:
        break
if d is not None:
    print(d if isinstance(d, str) else json.dumps(d))
PY
}

# ----------------------------------------------------------------- http calls
API_STATUS=""
API_BODY=""
api() {  # api METHOD PATH [body-file]   — 0 on 2xx, body in $API_BODY
  local method="$1" path="$2" body="${3-}"
  API_BODY="$WORK/resp.json"
  if [ -n "$body" ]; then
    API_STATUS="$(curl -sS -o "$API_BODY" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      --data-binary "@$body" "$API_ROOT$path")"
  else
    API_STATUS="$(curl -sS -o "$API_BODY" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $TOKEN" "$API_ROOT$path")"
  fi
  case "$API_STATUS" in 2*) return 0 ;; esac
  return 1
}

api_fail() {  # api_fail "what was being done"
  local msg
  msg="$(jget "$API_BODY" error.message)"
  printf '\n%sERROR: %s (HTTP %s)%s\n' "$RED" "$1" "$API_STATUS" "$R" >&2
  if [ -n "$msg" ]; then
    printf '%s       %s%s\n' "$RED" "$msg" "$R" >&2
  else
    sed 's/^/       /' "$API_BODY" >&2 | head -20
  fi
  case "$API_STATUS" in
    401|403) note "the service account needs to be invited in Play Console under" >&2
             note "Users and permissions, with release access to this app" >&2 ;;
    404)     note "check the package name — the app must already exist in Play Console" >&2 ;;
  esac
  exit 1
}

# ================================================================ 0. preflight
cat <<BANNER

  ${B}Google Play release uploader${R}

  Five stages:
    1. credentials   — service account key, access token
    2. the release   — package, artifact, track
    3. edit          — upload the bundle and the mapping file
    4. track         — release notes, rollout, status
    5. commit        — validate, then send it (or --dry-run and throw it away)

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: the edit is validated and then deleted"

for t in curl openssl python3; do
  have "$t" || die "$t is required but not installed"
done

# ============================================================= 1. credentials
step "1/5  Credentials"
if [ -z "$KEYFILE" ] && [ -f "${SAVED_KEYFILE:-/nonexistent}" ]; then KEYFILE="$SAVED_KEYFILE"; fi
if [ -z "$KEYFILE" ]; then
  say "A service account JSON key is needed. Once, in the console:"
  note "1. Google Cloud: enable the 'Google Play Android Developer API'"
  note "2. create a service account there and download a JSON key"
  note "3. Play Console → Users and permissions → Invite user → the service"
  note "   account's email → grant release access to this app"
  note "4. give it a few minutes to propagate"
  ask KEYFILE "Path to the service account JSON key" "$CONF_DIR/service-account.json"
fi
KEYFILE="${KEYFILE/#\~/$HOME}"
[ -f "$KEYFILE" ] || die "no such file: $KEYFILE"

SA_EMAIL="$(jget "$KEYFILE" client_email)"
TOKEN_URI="$(jget "$KEYFILE" token_uri)"
[ -n "$TOKEN_URI" ] || TOKEN_URI="https://oauth2.googleapis.com/token"
[ -n "$SA_EMAIL" ] || die "$KEYFILE does not look like a service account key (no client_email)"
# only the owner should be able to read a private key: perms must end in 00
KEYPERM="$(stat -c '%a' "$KEYFILE" 2>/dev/null || stat -f '%Lp' "$KEYFILE" 2>/dev/null || echo '')"
case "$KEYPERM" in
  ''|*00) ;;
  *) warn "$KEYFILE is mode $KEYPERM — others can read your private key; chmod 600 it" ;;
esac
ok "service account: $SA_EMAIL"

# --- sign a JWT and swap it for an access token (RS256, per Google's docs)
python3 - "$KEYFILE" > "$WORK/key.pem" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["private_key"], end="")
PY
chmod 600 "$WORK/key.pem"
[ -s "$WORK/key.pem" ] || die "no private_key in $KEYFILE"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
NOW="$(date +%s)"
JWT_HEAD="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
JWT_CLAIM="$(printf '{"iss":"%s","scope":"https://www.googleapis.com/auth/androidpublisher","aud":"%s","iat":%s,"exp":%s}' \
  "$SA_EMAIL" "$TOKEN_URI" "$NOW" "$((NOW + 3600))" | b64url)"
JWT_SIG="$(printf '%s.%s' "$JWT_HEAD" "$JWT_CLAIM" | openssl dgst -sha256 -sign "$WORK/key.pem" | b64url)"
rm -f "$WORK/key.pem"

curl -sS -o "$WORK/token.json" -w '%{http_code}' -X POST "$TOKEN_URI" \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
  --data-urlencode "assertion=$JWT_HEAD.$JWT_CLAIM.$JWT_SIG" > "$WORK/token.code" || true
TOKEN="$(jget "$WORK/token.json" access_token)"
if [ -z "$TOKEN" ]; then
  warn "could not get an access token (HTTP $(cat "$WORK/token.code"))"
  ERRD="$(jget "$WORK/token.json" error_description)"
  [ -n "$ERRD" ] && note "$ERRD"
  die "authentication failed"
fi
ok "access token acquired"

# ============================================================== 2. the release
step "2/5  The release"

ask REPO "Path to the app's git checkout (for versions and changelogs)" "${SAVED_REPO:-$PWD}"
REPO="${REPO/#\~/$HOME}"
[ -d "$REPO" ] || die "no such directory: $REPO"
REPO="$(cd "$REPO" && pwd)"

# Flutter keeps its Android project under <flutter dir>/android and writes
# its outputs to <flutter dir>/build/app/outputs (same detection as fdroid-submit.sh).
FLUTTER_DIR=""
for p in "$REPO/pubspec.yaml" "$REPO"/*/pubspec.yaml "$REPO"/*/*/pubspec.yaml; do
  [ -f "$p" ] || continue
  d="$(dirname "$p")"
  grep -qE '^[[:space:]]+sdk:[[:space:]]*flutter' "$p" || continue
  [ -f "$d/android/app/build.gradle.kts" ] || [ -f "$d/android/app/build.gradle" ] || continue
  FLUTTER_DIR="${d#"$REPO"}"; FLUTTER_DIR="${FLUTTER_DIR#/}"; FLUTTER_DIR="${FLUTTER_DIR:-.}"
  break
done
FLUTTER_ANDROID=""
if [ -n "$FLUTTER_DIR" ]; then
  FLUTTER_ANDROID="$FLUTTER_DIR/android/app"; FLUTTER_ANDROID="${FLUTTER_ANDROID#./}"
  ok "Flutter app in ${FLUTTER_DIR}/"
fi

SUBDIR_GUESS=""
for cand in "${SAVED_SUBDIR:-}" "$FLUTTER_ANDROID" app mobile android .; do
  [ -n "$cand" ] || continue
  for gf in build.gradle.kts build.gradle; do
    if [ -f "$REPO/$cand/$gf" ]; then SUBDIR_GUESS="$cand"; break 2; fi
  done
done
SUBDIR="${SUBDIR_GUESS:-app}"
GRADLE_FILE=""
for gf in build.gradle.kts build.gradle; do
  [ -f "$REPO/$SUBDIR/$gf" ] && GRADLE_FILE="$REPO/$SUBDIR/$gf" && break
done

gval() {  # same detection as fdroid-submit.sh: Kotlin or Groovy DSL, no comments
  [ -n "$GRADLE_FILE" ] || return 0
  sed -e 's,//.*,,' "$GRADLE_FILE" \
    | grep -Eo "(^|[^A-Za-z_.])$1[[:space:]]*(=[[:space:]]*)?[\"']?[A-Za-z0-9_.-]+" \
    | sed -E "s/.*$1[[:space:]]*(=[[:space:]]*)?[\"']?//" \
    | grep -v '^flutter\.' \
    | sed -n 1p
}

if [ -z "$PKG" ]; then
  PKG_GUESS="${SAVED_PKG:-$(gval applicationId)}"
  [ -n "$PKG_GUESS" ] || PKG_GUESS="$(gval namespace)"
  while :; do
    ask PKG "Package name (application id)" "$PKG_GUESS"
    printf '%s' "$PKG" | grep -qE '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$' && break
    warn "'$PKG' is not a valid application id"
    PKG_GUESS=""
  done
fi
ok "package: $PKG"

# --- artifact: prefer the App Bundle, that is what Play wants
if [ -z "$ARTIFACT" ]; then
  ART_GUESS=""
  FL_OUT=""
  [ -n "$FLUTTER_DIR" ] && FL_OUT="$REPO/$FLUTTER_DIR/build/app/outputs"
  for pat in "$REPO/$SUBDIR/build/outputs/bundle/release"/*.aab \
             "$REPO/$SUBDIR/build/outputs/apk/release"/*.apk \
             "$REPO/build/outputs/bundle/release"/*.aab \
             ${FL_OUT:+"$FL_OUT/bundle/release"/*.aab} \
             ${FL_OUT:+"$FL_OUT/flutter-apk/app-release.apk"}; do
    [ -f "$pat" ] || continue
    if [ -z "$ART_GUESS" ] || [ "$pat" -nt "$ART_GUESS" ]; then ART_GUESS="$pat"; fi
  done
  [ -n "$ART_GUESS" ] && note "found $(basename "$ART_GUESS") ($(date -r "$ART_GUESS" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'unknown date'))"
  ask ARTIFACT "Path to the .aab or .apk to upload" "$ART_GUESS"
fi
ARTIFACT="${ARTIFACT/#\~/$HOME}"
[ -f "$ARTIFACT" ] || die "no such file: $ARTIFACT"
case "$ARTIFACT" in
  *.aab) KIND=bundles ;;
  *.apk) KIND=apks ;;
  *) die "expected a .aab or .apk, got $(basename "$ARTIFACT")" ;;
esac
ok "artifact: $(basename "$ARTIFACT") ($(du -h "$ARTIFACT" | cut -f1))"

# An unsigned artifact is rejected by the API with a confusing message.
if have unzip; then
  if ! unzip -l "$ARTIFACT" 2>/dev/null | grep -qE 'META-INF/.*\.(RSA|DSA|EC|SF)$'; then
    warn "no signature block found — Play only accepts artifacts signed with your upload key"
    confirm "Upload it anyway?" n || exit 1
  else
    ok "artifact is signed"
  fi
fi

# --- track
if [ -z "$TRACK" ]; then
  say "Tracks: internal (fastest), alpha, beta, production, or a closed track name."
  ask TRACK "Track" "${SAVED_TRACK:-internal}"
fi
if [ "$TRACK" = production ]; then
  warn "production — this goes to real users once Google finishes review"
  [ "$ASSUME_YES" = 1 ] || confirm "Sure?" n || exit 1
fi

# --- rollout / status
if [ -n "$ROLLOUT" ]; then
  python3 -c 'import sys; f=float(sys.argv[1]); sys.exit(0 if 0 < f <= 1 else 1)' "$ROLLOUT" 2>/dev/null \
    || die "--rollout must be between 0 and 1 (0.1 = 10% of users)"
  [ -n "$STATUS" ] && die "--rollout and --draft are mutually exclusive"
  STATUS=inProgress
fi
[ -n "$STATUS" ] || STATUS=completed

# ==================================================================== 3. edit
step "3/5  Uploading"

printf '{}' > "$WORK/empty.json"
api POST "/androidpublisher/v3/applications/$PKG/edits" "$WORK/empty.json" || api_fail "could not open an edit"
EDIT_ID="$(jget "$API_BODY" id)"
[ -n "$EDIT_ID" ] || die "the API returned no edit id"
ok "edit $EDIT_ID opened"

say "uploading $(basename "$ARTIFACT")…"
UP_STATUS="$(curl --progress-bar -o "$WORK/upload.json" -w '%{http_code}' \
  -X POST -T "$ARTIFACT" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/octet-stream' \
  "$API_ROOT/upload/androidpublisher/v3/applications/$PKG/edits/$EDIT_ID/$KIND?uploadType=media")"
printf '\n' >&2
case "$UP_STATUS" in
  2*) ;;
  *) API_STATUS="$UP_STATUS"; API_BODY="$WORK/upload.json"; api_fail "upload failed" ;;
esac
VCODE="$(jget "$WORK/upload.json" versionCode)"
[ -n "$VCODE" ] || die "the API accepted the upload but returned no versionCode"
ok "uploaded — versionCode $VCODE"

# --- mapping file, so crashes are readable in Play Console
if [ -z "$MAPPING" ]; then
  for m in "$REPO/$SUBDIR/build/outputs/mapping/release/mapping.txt" \
           "$REPO/$SUBDIR/build/outputs/mapping/releaseRelease/mapping.txt" \
           ${FLUTTER_DIR:+"$REPO/$FLUTTER_DIR/build/app/outputs/mapping/release/mapping.txt"}; do
    [ -f "$m" ] && { MAPPING="$m"; break; }
  done
  if [ -n "$MAPPING" ]; then
    confirm "Attach $(basename "$(dirname "$MAPPING")")/mapping.txt (deobfuscates crash reports)?" y || MAPPING=""
  fi
fi
if [ -n "$MAPPING" ]; then
  MAPPING="${MAPPING/#\~/$HOME}"
  [ -f "$MAPPING" ] || die "no such file: $MAPPING"
  MAP_STATUS="$(curl -sS -o "$WORK/mapping.json" -w '%{http_code}' \
    -X POST -T "$MAPPING" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/octet-stream' \
    "$API_ROOT/upload/androidpublisher/v3/applications/$PKG/edits/$EDIT_ID/apks/$VCODE/deobfuscationFiles/proguard?uploadType=media")"
  case "$MAP_STATUS" in
    2*) ok "mapping file attached" ;;
    *)  warn "mapping upload failed (HTTP $MAP_STATUS) — carrying on without it" ;;
  esac
fi

MAPPING_NAME=none
[ -n "$MAPPING" ] && MAPPING_NAME="$(basename "$MAPPING")"

# =================================================================== 4. track
step "4/5  Track and release notes"

# Release notes come from the same fastlane layout F-Droid reads, keyed by
# versionCode: fastlane/metadata/android/<locale>/changelogs/<versionCode>.txt
NOTES_JSON="$WORK/notes.json"
printf '[]' > "$NOTES_JSON"
if [ -n "$NOTESFILE" ]; then
  NOTESFILE="${NOTESFILE/#\~/$HOME}"
  [ -f "$NOTESFILE" ] || die "no such file: $NOTESFILE"
  python3 - "$NOTESFILE" > "$NOTES_JSON" <<'PY'
import json, sys
print(json.dumps([{"language": "en-US", "text": open(sys.argv[1]).read().strip()}]))
PY
  ok "release notes from $(basename "$NOTESFILE")"
else
  FL="$REPO/fastlane/metadata/android"
  # Flutter projects sometimes keep fastlane inside the Flutter dir.
  if [ ! -d "$FL" ] && [ -n "$FLUTTER_DIR" ] && [ -d "$REPO/$FLUTTER_DIR/fastlane/metadata/android" ]; then
    FL="$REPO/$FLUTTER_DIR/fastlane/metadata/android"
  fi
  FOUND=0
  if [ -d "$FL" ]; then
    : > "$WORK/notes.list"
    for d in "$FL"/*/changelogs/"$VCODE".txt; do
      [ -f "$d" ] || continue
      lang="$(basename "$(dirname "$(dirname "$d")")")"
      printf '%s\t%s\n' "$lang" "$d" >> "$WORK/notes.list"
      FOUND=$((FOUND+1))
    done
  fi
  if [ "$FOUND" -gt 0 ]; then
    python3 - "$WORK/notes.list" > "$NOTES_JSON" <<'PY'
import json, sys
out = []
for line in open(sys.argv[1]):
    lang, path = line.rstrip("\n").split("\t", 1)
    out.append({"language": lang, "text": open(path).read().strip()})
print(json.dumps(out))
PY
    ok "release notes for $FOUND locale(s) from fastlane/…/changelogs/$VCODE.txt"
  else
    note "no fastlane/metadata/android/<locale>/changelogs/$VCODE.txt found"
    ask_opt NOTESTEXT "Release notes for en-US (blank to ship without any)" ""
    if [ -n "$NOTESTEXT" ]; then
      python3 - "$NOTESTEXT" > "$NOTES_JSON" <<'PY'
import json, sys
print(json.dumps([{"language": "en-US", "text": sys.argv[1]}]))
PY
    fi
  fi
fi

python3 - "$VCODE" "$STATUS" "${ROLLOUT:-}" "$NOTES_JSON" > "$WORK/track.json" <<'PY'
import json, sys
vcode, status, rollout, notes_path = sys.argv[1:5]
release = {"versionCodes": [vcode], "status": status}
if rollout:
    release["userFraction"] = float(rollout)
notes = json.load(open(notes_path))
if notes:
    release["releaseNotes"] = notes
print(json.dumps({"releases": [release]}))
PY

api PUT "/androidpublisher/v3/applications/$PKG/edits/$EDIT_ID/tracks/$TRACK" "$WORK/track.json" \
  || api_fail "could not set the $TRACK track"
ok "track $TRACK -> versionCode $VCODE ($STATUS${ROLLOUT:+, ${ROLLOUT} of users})"

# ================================================================== 5. commit
step "5/5  Validate and commit"

api POST "/androidpublisher/v3/applications/$PKG/edits/$EDIT_ID:validate" "$WORK/empty.json" \
  || api_fail "validation failed — nothing was committed"
ok "the edit validates"

cat <<SUMMARY

   ${B}About to commit:${R}
     package      $PKG
     versionCode  $VCODE
     artifact     $(basename "$ARTIFACT")
     track        $TRACK
     status       $STATUS${ROLLOUT:+  (rollout ${ROLLOUT})}
     notes        $(python3 -c 'import json,sys; n=json.load(open(sys.argv[1])); print(", ".join(x["language"] for x in n) or "none")' "$NOTES_JSON")
     mapping      $MAPPING_NAME

SUMMARY

if [ "$DRYRUN" = 1 ]; then
  warn "dry run — deleting the edit, nothing was published"
  exit 0
fi

if [ "$ASSUME_YES" = 0 ] && ! confirm "Commit this to Google Play?" n; then
  say "Not committed. The edit will be discarded."
  exit 0
fi

COMMIT_PATH="/androidpublisher/v3/applications/$PKG/edits/$EDIT_ID:commit"
[ "$NOREVIEW" = 1 ] && COMMIT_PATH="$COMMIT_PATH?changesNotSentForReview=true"
api POST "$COMMIT_PATH" "$WORK/empty.json" || api_fail "commit failed"
COMMITTED=1
save_answers

ok "committed"
cat <<DONE

   ${B}Done.${R} versionCode $VCODE is on the $TRACK track.
   https://play.google.com/console/u/0/developers

   Review takes anywhere from a few hours to a few days; internal testing
   is usually available within minutes.

DONE
