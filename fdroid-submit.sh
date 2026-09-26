#!/usr/bin/env bash
#
# fdroid-submit.sh — interactive wizard for submitting an Android app to F-Droid.
#
# Walks through the process described in:
#   https://f-droid.org/docs/Submitting_to_F-Droid_Quick_Start_Guide/
#   https://f-droid.org/docs/Build_Metadata_Reference/
#
# It detects what it can from your app repo and only asks for the rest, writes
# (or, for an app already in F-Droid, extends) metadata/<applicationId>.yml in
# your fdroiddata fork, validates it with the fdroid CLI, pushes a branch and —
# with glab logged in — opens the merge request.
#
# Nothing leaves your machine without asking first, unless you pass --yes.

set -eu
# NOTE: deliberately no `set -o pipefail` — `cmd | head` would SIGPIPE and abort.

# ------------------------------------------------------------------ arguments
DRYRUN=0
SAVE=1
ASSUME_YES=0   # --yes: take every detected answer, only stop on problems
ASK_ALL=0      # --ask: ask every question, even the ones it can answer itself
RUN_BUILD=0    # --build: run the full `fdroid build` as part of validation
WANT_RFP=0     # --rfp: open an RFP issue without asking
REPO_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fdroid-submit"
CONF="$CONF_DIR/last.conf"

usage() {
  cat <<'USAGE'
fdroid-submit.sh — interactive wizard for getting an Android app into F-Droid.

  -h, --help        show this text
  -y, --yes         use everything it detects and don't ask; stops only on
                    problems. A version update becomes a single command.
      --ask         ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --build       also run the full `fdroid build` (slow)
      --rfp         open a Request For Packaging issue too (new apps)
  -n, --dry-run     do everything except pushing, tagging and opening issues/MRs
      --no-save     do not remember the answers for next time
      --forget      delete the remembered answers and exit

Detects what it can from your app's git checkout and only asks for the rest,
writes metadata/<applicationId>.yml into your fdroiddata fork, validates it,
pushes a branch and — with glab logged in — opens the merge request.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -n|--dry-run) DRYRUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --ask)        ASK_ALL=1 ;;
    --repo)       REPO_ARG="${2-}"; shift ;;
    --build)      RUN_BUILD=1 ;;
    --rfp)        WANT_RFP=1 ;;
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

# This is a wizard: without someone to answer, there is nothing sensible to do.
# Bailing out on EOF keeps a required question from spinning forever when stdin
# runs dry (a closed pipe, a background run).
readline() {  # readline VAR — false on EOF
  IFS= read -r "$1" && return 0
  printf '\n' >&2
  die "end of input — this script needs an interactive terminal"
}

# ask VAR "question" "default"   — empty default means required
ask() {
  local __var="$1" __q="$2" __def="${3-}" __in=""
  if [ "$ASSUME_YES" = 1 ]; then
    [ -n "$__def" ] || die "--yes: nothing to answer \"$__q\" with — run once without --yes"
    printf -v "$__var" '%s' "$__def"; ok "$__q: $__def"; return 0
  fi
  while :; do
    if [ -n "$__def" ]; then
      printf '   %s%s%s [%s]: ' "$B" "$__q" "$R" "$__def" >&2
    else
      printf '   %s%s%s: ' "$B" "$__q" "$R" >&2
    fi
    readline __in
    [ -z "$__in" ] && __in="$__def"
    if [ -z "$__in" ]; then printf '   %sthis one is required%s\n' "$YLW" "$R" >&2; continue; fi
    break
  done
  printf -v "$__var" '%s' "$__in"
}

ask_opt() {  # like ask, but blank is allowed and means "omit this field"
  local __var="$1" __q="$2" __def="${3-}" __in=""
  if [ "$ASSUME_YES" = 1 ]; then printf -v "$__var" '%s' "$__def"; return 0; fi
  printf '   %s%s%s%s: ' "$B" "$__q" "$R" "${__def:+ [$__def]}" >&2
  readline __in
  [ -z "$__in" ] && __in="$__def"
  printf -v "$__var" '%s' "$__in"
}

confirm() {  # confirm "question" [default y|n] — --yes takes the default
  local q="$1" def="${2:-n}" a=""
  if [ "$ASSUME_YES" = 1 ]; then
    [ "$def" = y ] && return 0
    warn "$q — no (the safe answer; run without --yes to choose)"; return 1
  fi
  local hint="[y/N]"; [ "$def" = y ] && hint="[Y/n]"
  printf '   %s%s%s %s ' "$B" "$q" "$R" "$hint" >&2
  readline a
  [ -z "$a" ] && a="$def"
  case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# go "question" — for the actions that leave your machine (push, tag, MR, RFP):
# asked with Yes as the default; --yes answers it.
go() {
  if [ "$ASSUME_YES" = 1 ]; then ok "$1 — yes (--yes)"; return 0; fi
  confirm "$1" y
}

# auto VAR "label" "detected value" — take what was detected without asking
# (shown as a ✓ line); ask only when nothing was detected, or with --ask.
auto() {
  local __var="$1" __label="$2" __val="${3-}"
  if [ "$ASK_ALL" = 0 ] && [ -n "$__val" ]; then
    printf -v "$__var" '%s' "$__val"; ok "$__label: $__val"
  else
    ask "$__var" "$__label" "$__val"
  fi
}

auto_opt() {  # like auto, for optional fields: blank is fine and not asked
  local __var="$1" __label="$2" __val="${3-}"
  if [ "$ASK_ALL" = 0 ]; then
    printf -v "$__var" '%s' "$__val"; [ -n "$__val" ] && ok "$__label: $__val"
    return 0
  fi
  ask_opt "$__var" "$__label" "$__val"
}

# ---------------------------------------------------------------- scratch space
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fdroid-submit.XXXXXX")"
KEEP_WORK=0
cleanup() {
  if [ "$KEEP_WORK" = 1 ]; then
    printf '   %sleft behind: %s%s\n' "$DIM" "$WORK" "$R"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# ------------------------------------------------------- remembered answers
# Written by this script only, as `SAVED_X=<shell-quoted>` lines.
SAVED_REPO=""; SAVED_SUBDIR=""; SAVED_LICENSE=""; SAVED_CATSEL=""
SAVED_AUTHORNAME=""; SAVED_AUTHOREMAIL=""; SAVED_AUTHORSITE=""; SAVED_WEBSITE=""
SAVED_GLUSER=""; SAVED_FORKURL=""; SAVED_FDROIDDATA=""; SAVED_JDK=""
SAVED_FDROIDSERVER=""; SAVED_CATSEL_APP=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi

save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  # A run only answers some questions (an update asks no categories, license
  # or author): keep what was remembered for everything it didn't answer.
  local catsel="${SAVED_CATSEL:-}" catapp="${SAVED_CATSEL_APP:-}"
  if [ -n "${CATSEL:-}" ]; then catsel="$CATSEL"; catapp="${APPID:-}"; fi
  {
    printf '# written by fdroid-submit.sh — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n'         "${REPO:-${SAVED_REPO:-}}"
    printf 'SAVED_SUBDIR=%q\n'       "${SUBDIR:-${SAVED_SUBDIR:-}}"
    printf 'SAVED_LICENSE=%q\n'      "${LICENSE:-${SAVED_LICENSE:-}}"
    printf 'SAVED_CATSEL=%q\n'       "$catsel"
    printf 'SAVED_CATSEL_APP=%q\n'   "$catapp"
    printf 'SAVED_AUTHORNAME=%q\n'   "${AUTHORNAME:-${SAVED_AUTHORNAME:-}}"
    printf 'SAVED_AUTHOREMAIL=%q\n'  "${AUTHOREMAIL:-${SAVED_AUTHOREMAIL:-}}"
    printf 'SAVED_AUTHORSITE=%q\n'   "${AUTHORSITE:-${SAVED_AUTHORSITE:-}}"
    printf 'SAVED_WEBSITE=%q\n'      "${WEBSITE:-${SAVED_WEBSITE:-}}"
    printf 'SAVED_GLUSER=%q\n'       "${GLUSER:-${SAVED_GLUSER:-}}"
    printf 'SAVED_FORKURL=%q\n'      "${FORKURL:-${SAVED_FORKURL:-}}"
    printf 'SAVED_FDROIDDATA=%q\n'   "${FDROIDDATA:-${SAVED_FDROIDDATA:-}}"
    printf 'SAVED_JDK=%q\n'          "${JDK:-${SAVED_JDK:-}}"
    printf 'SAVED_FDROIDSERVER=%q\n' "${FDROIDSERVER_DIR:-${SAVED_FDROIDSERVER:-}}"
  } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  chmod 600 "$CONF" 2>/dev/null || true
}

# ------------------------------------------------------------------- fdroid CLI
# The wizard never installs fdroidserver itself. It uses the one you have:
# `fdroid` on PATH, or a source checkout of fdroidserver (run the way
# fdroiddata's CI runs master: PATH and PYTHONPATH pointed at the checkout).
# If there is neither, it says how to install one and waits for you.
RUNNER=""
FDROIDSERVER_DIR=""

fdroid_checkout_runs() {  # fdroid_checkout_runs <dir>
  PATH="$1:$PATH" PYTHONPATH="$1${PYTHONPATH:+:$PYTHONPATH}" \
    "$1/fdroid" --version >/dev/null 2>&1
}

find_fdroid() {  # sets RUNNER; false if nothing usable was found
  local d ver
  if have fdroid; then
    ver="$(fdroid --version 2>/dev/null | tail -1)"
    RUNNER=path; ok "fdroid ${ver:+$ver }on PATH ($(command -v fdroid))"
    return 0
  fi
  for d in "${FDROIDSERVER:-}" "${SAVED_FDROIDSERVER:-}" \
           "$HOME/Opt/fdroidserver" "$HOME/opt/fdroidserver" "$HOME/fdroidserver" \
           "$HOME/src/fdroidserver" "$HOME/Projects/fdroidserver"; do
    [ -n "$d" ] || continue
    d="${d/#\~/$HOME}"
    [ -f "$d/fdroid" ] || continue
    if fdroid_checkout_runs "$d"; then
      RUNNER=checkout; FDROIDSERVER_DIR="$d"
      ver="$(PATH="$d:$PATH" PYTHONPATH="$d" "$d/fdroid" --version 2>/dev/null | tail -1)"
      ok "fdroidserver checkout ${ver:+$ver }at $d"
      return 0
    fi
    warn "found $d, but it doesn't run — are its Python dependencies installed?"
  done
  return 1
}

detect_runner() {
  find_fdroid && return 0
  warn "fdroidserver is not installed (or not in the places this wizard looks)"
  say "It validates the metadata before you open the merge request. Install it"
  say "yourself, whichever way suits you — for example:"
  note "  nix:            nix profile install nixpkgs#fdroidserver   (or add it to your config)"
  note "  Debian/Ubuntu:  sudo apt install fdroidserver"
  note "  like F-Droid CI: git clone https://gitlab.com/fdroid/fdroidserver.git ~/Opt/fdroidserver"
  note "                  (runs from the checkout; its Python dependencies must be installed)"
  while :; do
    say "r) check again   p) give the path to a checkout   s) skip validation   q) quit"
    ask FDCHOICE "Choice" "r"
    case "$FDCHOICE" in
      r|R) find_fdroid && return 0; warn "still not found" ;;
      p|P) ask FDROIDSERVER "Path to the fdroidserver checkout" "$HOME/Opt/fdroidserver"
           find_fdroid && return 0 ;;
      s|S) RUNNER=none; warn "validation will be skipped — the maintainers' CI will still run it"
           return 0 ;;
      q|Q) exit 0 ;;
      *)   warn "r, p, s or q" ;;
    esac
  done
}

frun() {  # frun <fdroid args...>   — run inside $FDROIDDATA
  case "$RUNNER" in
    path)     ( cd "$FDROIDDATA" && fdroid "$@" ) ;;
    checkout) ( cd "$FDROIDDATA" && \
                PATH="$FDROIDSERVER_DIR:$PATH" \
                PYTHONPATH="$FDROIDSERVER_DIR${PYTHONPATH:+:$PYTHONPATH}" \
                "$FDROIDSERVER_DIR/fdroid" "$@" ) ;;
    none)     warn "skipped: fdroid $*"; return 0 ;;
  esac
}

# =============================================================== 0. orientation
cat <<BANNER

  ${B}F-Droid submission wizard${R}

  Five stages:
    1. your app repo      — what F-Droid needs to know, plus the usual pitfalls
    2. fdroiddata fork    — clone it, branch off current upstream master
    3. metadata           — write (or extend) metadata/<appid>.yml
    4. validate           — fdroid readmeta / rewritemeta / lint / build
    5. push               — branch pushed, merge request opened

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: everything except the final push"

[ "$ASSUME_YES" = 1 ] && note "--yes: using everything detected; stopping only on problems"
# New app or version update is decided later, from upstream fdroiddata itself.
IS_UPDATE=0

detect_runner

# ============================================================== 1. the app repo
step "1/5  Your app repository"

# The app repo: --repo, else the git repo you run this from (unless that's
# this script's own), else the one from last time.
SELF_REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || true)"
HERE_REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ "$HERE_REPO" = "$SELF_REPO" ] && HERE_REPO=""
REPO_GUESS="${REPO_ARG:-${HERE_REPO:-${SAVED_REPO:-}}}"
while :; do
  if [ -n "$REPO_ARG" ]; then REPO="$REPO_ARG"
  else auto REPO "App repository" "$REPO_GUESS"; fi
  REPO="${REPO/#\~/$HOME}"
  [ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] && break
  [ -n "$REPO_ARG" ] && die "$REPO is not a git checkout"
  warn "$REPO is not a git checkout"; REPO_GUESS=""
  ask REPO "Path to the app's git checkout" ""
  REPO="${REPO/#\~/$HOME}"
  [ -d "$REPO/.git" ] && break
done
REPO="$(cd "$REPO" && pwd)"

# --- Flutter? Its Android project lives under <flutter dir>/android, the
# version lives in pubspec.yaml, and F-Droid needs a different build recipe.
FLUTTER_DIR=""
for p in "$REPO/pubspec.yaml" "$REPO"/*/pubspec.yaml "$REPO"/*/*/pubspec.yaml; do
  [ -f "$p" ] || continue
  d="$(dirname "$p")"
  grep -qE '^[[:space:]]+sdk:[[:space:]]*flutter' "$p" || continue
  [ -f "$d/android/app/build.gradle.kts" ] || [ -f "$d/android/app/build.gradle" ] || continue
  FLUTTER_DIR="${d#"$REPO"}"; FLUTTER_DIR="${FLUTTER_DIR#/}"; FLUTTER_DIR="${FLUTTER_DIR:-.}"
  break
done
if [ -n "$FLUTTER_DIR" ]; then
  ok "Flutter app in ${FLUTTER_DIR}/"
  FLUTTER_ANDROID="$FLUTTER_DIR/android/app"; FLUTTER_ANDROID="${FLUTTER_ANDROID#./}"
fi

# --- subdir (the gradle module that produces the APK)
SUBDIR_GUESS=""
for cand in "${SAVED_SUBDIR:-}" "${FLUTTER_ANDROID:-}" app mobile android .; do
  [ -n "$cand" ] || continue
  for gf in build.gradle.kts build.gradle; do
    if [ -f "$REPO/$cand/$gf" ] && grep -qE 'applicationId|namespace' "$REPO/$cand/$gf" 2>/dev/null; then
      SUBDIR_GUESS="$cand"; break 2
    fi
  done
done
GRADLE_FILE=""
FIRST=1
while :; do
  if [ "$FIRST" = 1 ]; then auto SUBDIR "Gradle module" "$SUBDIR_GUESS"
  else ask SUBDIR "Gradle module subdirectory (the one with applicationId)" "${SUBDIR_GUESS:-app}"; fi
  FIRST=0
  SUBDIR="${SUBDIR#./}"; SUBDIR="${SUBDIR%/}"
  for gf in build.gradle.kts build.gradle; do
    [ -f "$REPO/$SUBDIR/$gf" ] && GRADLE_FILE="$REPO/$SUBDIR/$gf" && break
  done
  [ -n "$GRADLE_FILE" ] && break
  [ "$ASSUME_YES" = 1 ] && die "no build.gradle(.kts) in $SUBDIR/"
  warn "no build.gradle(.kts) in $SUBDIR/"
  # An easy slip: typing the application ID here (it is asked next).
  if printf '%s' "$SUBDIR" | grep -qE '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'; then
    note "that looks like an application ID — this asks for a folder; the ID comes next"
  fi
done
[ "$ASK_ALL" = 1 ] && ok "gradle file: ${GRADLE_FILE#"$REPO"/}"

# --- detect identity and version
# Handles both Kotlin DSL (`applicationId = "x"`) and Groovy (`applicationId "x"`),
# ignores // comments, and takes the first hit. References like Flutter's
# `flutter.versionCode` are not values and are skipped.
gval() {
  sed -e 's,//.*,,' "$GRADLE_FILE" \
    | grep -Eo "(^|[^A-Za-z_.])$1[[:space:]]*(=[[:space:]]*)?[\"']?[A-Za-z0-9_.-]+" \
    | sed -E "s/.*$1[[:space:]]*(=[[:space:]]*)?[\"']?//" \
    | grep -v '^flutter\.' \
    | sed -n 1p
}
APPID_GUESS="$(gval applicationId)"
[ -n "$APPID_GUESS" ] || APPID_GUESS="$(gval namespace)"
VNAME_GUESS="$(gval versionName)"
VCODE_GUESS="$(gval versionCode)"

# Flutter: `version: 1.2.3+45` in pubspec.yaml is versionName+versionCode.
if [ -n "$FLUTTER_DIR" ] && [ -z "$VNAME_GUESS$VCODE_GUESS" ]; then
  PUBSPEC_VERSION="$(sed -nE "s/^version:[[:space:]]*[\"']?([^\"'[:space:]]+).*/\\1/p" \
                      "$REPO/$FLUTTER_DIR/pubspec.yaml" | sed -n 1p)"
  VNAME_GUESS="${PUBSPEC_VERSION%%+*}"
  case "$PUBSPEC_VERSION" in *+*) VCODE_GUESS="${PUBSPEC_VERSION#*+}" ;; esac
fi

while :; do
  auto APPID "Application ID" "$APPID_GUESS"
  printf '%s' "$APPID" | grep -qE '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$' && break
  [ "$ASSUME_YES" = 1 ] && die "'$APPID' is not a valid application ID"
  warn "'$APPID' is not a valid application ID (e.g. com.example.app)"
  APPID_GUESS=""
done
auto VNAME "versionName" "$VNAME_GUESS"
while :; do
  auto VCODE "versionCode" "$VCODE_GUESS"
  case "$VCODE" in ''|*[!0-9]*) [ "$ASSUME_YES" = 1 ] && die "versionCode '$VCODE' is not a plain integer"
                                warn "versionCode must be a plain integer"; VCODE_GUESS="" ;; *) break ;; esac
done

# --- tag: F-Droid builds the tag — so it must exist, be pushed, and hold
# exactly this application ID and version. The wizard sorts that out itself.
# The URL as configured: `remote get-url` would apply url.*.insteadOf rewrites,
# which say nothing about where the project lives on the web.
ORIGIN="$(git -C "$REPO" config --get remote.origin.url 2>/dev/null || echo "")"
GRADLE_REL="${GRADLE_FILE#"$REPO"/}"
PUB_REL=""
if [ -n "$FLUTTER_DIR" ]; then
  PUB_REL="pubspec.yaml"; [ "$FLUTTER_DIR" != "." ] && PUB_REL="$FLUTTER_DIR/pubspec.yaml"
fi
ref_appid() {  # ref_appid <git ref> — applicationId in the gradle file at that ref
  git -C "$REPO" show "$1:$GRADLE_REL" 2>/dev/null | sed -e 's,//.*,,' \
    | grep -Eo "(^|[^A-Za-z_.])applicationId[[:space:]]*(=[[:space:]]*)?[\"'][A-Za-z0-9_.]+" \
    | sed -E "s/.*applicationId[[:space:]]*(=[[:space:]]*)?[\"']//" | sed -n 1p
}
ref_version() {  # ref_version <git ref> — pubspec `name+code` at that ref (Flutter)
  [ -n "$PUB_REL" ] || return 0
  git -C "$REPO" show "$1:$PUB_REL" 2>/dev/null \
    | sed -nE "s/^version:[[:space:]]*[\"']?([^\"'[:space:]]+).*/\\1/p" | sed -n 1p
}
ref_matches() {  # ref_matches <ref> — true if it builds $APPID at $VNAME+$VCODE
  local a v
  a="$(ref_appid "$1")"; v="$(ref_version "$1")"
  { [ -z "$a" ] || [ "$a" = "$APPID" ]; } && { [ -z "$v" ] || [ "$v" = "$VNAME+$VCODE" ]; }
}
tag_on_remote() {
  [ -n "$ORIGIN" ] && git -C "$REPO" ls-remote --tags --exit-code origin "refs/tags/$1" >/dev/null 2>&1
}

# Prefer an existing v<version> or <version> tag; else the usual v<version>.
TAG_GUESS="v$VNAME"
for t in "v$VNAME" "$VNAME"; do
  if git -C "$REPO" rev-parse -q --verify "refs/tags/$t" >/dev/null 2>&1; then TAG_GUESS="$t"; break; fi
done
auto TAG "Release tag" "$TAG_GUESS"

HEAD_SHORT="$(git -C "$REPO" rev-parse --short HEAD)"
if ! git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  warn "there is no tag $TAG yet"
  if ! ref_matches HEAD; then
    die "HEAD ($HEAD_SHORT) doesn't build $APPID $VNAME+$VCODE either — commit the release first"
  fi
  if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
    warn "you have uncommitted changes; the tag only covers what is committed"
  fi
  if [ "$DRYRUN" = 1 ]; then
    warn "dry run — would tag HEAD ($HEAD_SHORT) as $TAG and push it"
  elif go "Tag HEAD ($HEAD_SHORT) as $TAG and push it to origin?"; then
    git -C "$REPO" tag "$TAG" HEAD
    git -C "$REPO" push -q origin "refs/tags/$TAG" || die "could not push tag $TAG"
    ok "tagged and pushed $TAG"
  else
    die "F-Droid needs the release tag — create and push $TAG, then re-run"
  fi
elif ! ref_matches "$TAG"; then
  # The classic slip: a tag made before the last change (ID, version…).
  warn "tag $TAG builds '$(ref_appid "$TAG")' $(ref_version "$TAG"), not '$APPID' $VNAME+$VCODE"
  if ref_matches HEAD && [ "$DRYRUN" = 0 ] \
     && confirm "Move $TAG to HEAD ($HEAD_SHORT) and force-push it? (only if it isn't published yet)" n; then
    git -C "$REPO" tag -f "$TAG" HEAD >/dev/null
    git -C "$REPO" push -q -f origin "refs/tags/$TAG" || die "could not push tag $TAG"
    ok "moved $TAG to $HEAD_SHORT"
  else
    die "tag $TAG doesn't hold this release — move it or bump the version"
  fi
elif ! tag_on_remote "$TAG"; then
  warn "tag $TAG is not on origin yet — F-Droid would not find it"
  if [ "$DRYRUN" = 1 ]; then
    warn "dry run — would push tag $TAG"
  elif go "Push tag $TAG to origin?"; then
    git -C "$REPO" push -q origin "refs/tags/$TAG" || die "could not push tag $TAG"
    ok "pushed $TAG"
  else
    die "push the tag first: git push origin $TAG"
  fi
else
  ok "tag $TAG is pushed and holds $APPID $VNAME+$VCODE"
fi
# fdroiddata wants the full commit hash in `commit:`, not the tag name.
COMMIT="$(git -C "$REPO" rev-list -n1 "$TAG" 2>/dev/null || true)"
[ -n "$COMMIT" ] || COMMIT="$TAG"

# --- URLs from the git remote
WEB_GUESS=""
case "$ORIGIN" in
  git@*)     WEB_GUESS="https://$(echo "$ORIGIN" | sed 's/^git@//; s/:/\//; s/\.git$//')" ;;
  ssh://*)   WEB_GUESS="https://$(echo "$ORIGIN" | sed 's,^ssh://\(git@\)\?,,; s,:[0-9]*/,/,; s/\.git$//')" ;;
  https://*) WEB_GUESS="${ORIGIN%.git}" ;;
esac
[ -n "$WEB_GUESS" ] || warn "no usable 'origin' remote — you will have to type the URLs"

# ----------------------------------------------------- 1b. common MR blockers
step "Pitfall check"
BLOCKERS=0
PROPRIETARY_PUB=""

# Binaries committed to the repo: F-Droid builds from source only.
BINFILES="$(git -C "$REPO" ls-files \
  | grep -Ei '\.(jar|aar|so|apk|aab|dex|keystore|jks|p12)$' \
  | grep -v 'gradle/wrapper/gradle-wrapper.jar' | head -10 || true)"
if [ -n "$BINFILES" ]; then
  warn "prebuilt binaries are tracked in git — maintainers will ask about these:"
  printf '%s\n' "$BINFILES" | sed "s/^/       /"
  BLOCKERS=$((BLOCKERS+1))
else
  ok "no stray prebuilt binaries tracked"
fi

# Proprietary dependencies: the usual cause of a NonFreeDep anti-feature or a reject.
PROPRIETARY="$(git -C "$REPO" grep -lEi \
  'com\.google\.android\.gms|com\.google\.firebase|crashlytics|play-services|com\.google\.mlkit|billingclient|appcenter|com\.google\.android\.play' \
  -- '*.gradle' '*.gradle.kts' '*.toml' 2>/dev/null | head -5 || true)"
if [ -n "$PROPRIETARY" ]; then
  warn "possible proprietary dependencies referenced in:"
  printf '%s\n' "$PROPRIETARY" | sed "s/^/       /"
  note "these usually need removing, or an AntiFeature such as NonFreeDep"
  BLOCKERS=$((BLOCKERS+1))
else
  ok "no obvious proprietary dependencies"
fi

# Release builds signed with the debug key (the Flutter template does this).
# F-Droid wants an unsigned APK to sign itself, and Play rejects debug keys.
if sed -e 's,//.*,,' "$GRADLE_FILE" \
     | grep -qE 'signingConfig[[:space:]]*=?[[:space:]]*signingConfigs\.(getByName\("debug"\)|debug)([^A-Za-z0-9_]|$)'; then
  warn "the release build is signed with the debug key (${GRADLE_FILE#"$REPO"/})"
  note "make the release signingConfig conditional on your key being present,"
  note "so builds without it — like F-Droid's — come out unsigned"
  BLOCKERS=$((BLOCKERS+1))
fi

if [ -n "$FLUTTER_DIR" ]; then
  PUBSPEC="$REPO/$FLUTTER_DIR/pubspec.yaml"
  # Plugins that pull in Google Play services / Firebase / ads.
  PROPRIETARY_PUB="$(grep -oE '^[[:space:]]+(firebase_[a-z_]+|google_mobile_ads|google_sign_in|google_ml_kit[a-z_]*|in_app_purchase|in_app_review|play_integrity[a-z_]*|google_maps_flutter|flutter_facebook_[a-z_]+):' \
                      "$PUBSPEC" 2>/dev/null | tr -d ' :' | tr '\n' ' ' || true)"
  if [ -n "${PROPRIETARY_PUB// /}" ]; then
    warn "Flutter plugins that usually mean proprietary code: $PROPRIETARY_PUB"
    note "these usually need removing, or an AntiFeature such as NonFreeDep"
    BLOCKERS=$((BLOCKERS+1))
  else
    ok "no obvious proprietary Flutter plugins"
  fi
  # F-Droid pins one Flutter release per build; a dev/beta SDK constraint
  # means no stable Flutter can build the tag.
  if sed -n '/^environment:/,/^[^[:space:]]/p' "$PUBSPEC" | grep -qE 'sdk:.*[0-9]-[0-9A-Za-z]'; then
    warn "pubspec.yaml requires a pre-release Dart SDK — only a dev/master Flutter builds it"
    note "F-Droid maintainers expect a stable Flutter release; relax the 'sdk:' constraint"
    BLOCKERS=$((BLOCKERS+1))
  fi
fi

# Store listing: F-Droid reads it from the app repo, not from the .yml.
FASTLANE="$REPO/fastlane/metadata/android/en-US"
if [ -d "$FASTLANE" ] || [ -d "$REPO/metadata/en-US" ] || [ -d "$REPO/$SUBDIR/src/main/play" ] \
   || { [ -n "$FLUTTER_DIR" ] && [ -d "$REPO/$FLUTTER_DIR/fastlane/metadata/android/en-US" ]; }; then
  ok "store listing (fastlane/triple-t metadata) found in the repo"
else
  warn "no fastlane metadata — your F-Droid listing will have no description"
  note "F-Droid reads it from the app repo at the build tag, not from the .yml"
  if confirm "Create fastlane/metadata/android/en-US now?" y; then
    while :; do
      ask SUMMARY "Short description (max 80 chars)" ""
      [ "${#SUMMARY}" -le 80 ] && break
      warn "that is ${#SUMMARY} characters — F-Droid's limit is 80"
    done
    ask FULLDESC "Full description (one line is fine, edit the file later)" "$SUMMARY"
    mkdir -p "$FASTLANE"
    printf '%s\n' "$SUMMARY"  > "$FASTLANE/short_description.txt"
    printf '%s\n' "$FULLDESC" > "$FASTLANE/full_description.txt"
    ok "wrote ${FASTLANE#"$REPO"/}/{short,full}_description.txt"
    warn "commit these and move the tag '$TAG' onto that commit — F-Droid only"
    warn "sees what is in the tagged revision"
    BLOCKERS=$((BLOCKERS+1))
  fi
fi

[ "$BLOCKERS" = 0 ] || { echo; confirm "Carry on despite the above?" y || exit 1; }

# ========================================================== 2. fdroiddata fork
step "2/5  Your fdroiddata fork"
# Who you are on GitLab: glab knows, if it's logged in.
GL_ME=""
if have glab && glab auth status --hostname gitlab.com >/dev/null 2>&1; then
  GL_ME="$(glab api user 2>/dev/null | grep -Eo '"username"[[:space:]]*:[[:space:]]*"[^"]+"' \
           | sed -n 1p | sed -E 's/.*"([^"]+)"$/\1/')"
fi
auto GLUSER "GitLab user" "${GL_ME:-${SAVED_GLUSER:-}}"
FORK_GUESS="git@gitlab.com:$GLUSER/fdroiddata.git"
# a remembered URL only counts if it belongs to this user
case "${SAVED_FORKURL:-}" in *[:/]"$GLUSER"/*) FORK_GUESS="$SAVED_FORKURL" ;; esac
auto FORKURL "Fork" "$FORK_GUESS"
# Always asked (Enter takes the default): the clone is large, so where it goes
# is yours to pick. --yes takes the default.
ask FDROIDDATA "Local clone of fdroiddata" "${SAVED_FDROIDDATA:-$HOME/fdroiddata}"
FDROIDDATA="${FDROIDDATA/#\~/$HOME}"
case "$FDROIDDATA" in /*) ;; *) FDROIDDATA="$PWD/$FDROIDDATA" ;; esac
FDROIDDATA="${FDROIDDATA%/}"

# The usual first-run failure is a fork that doesn't exist yet, which git only
# reports as "project not found or no permission". Forks of fdroiddata are
# public, so GitLab's API can tell us up front.
fork_path() {  # namespace/project from a gitlab.com clone URL, or nothing
  printf '%s' "$1" | sed -nE 's#^(git@gitlab\.com:|https://gitlab\.com/|ssh://git@gitlab\.com/)##p' \
    | sed -E 's#\.git$##'
}
check_fork() {
  local p code
  p="$(fork_path "$FORKURL")"
  [ -n "$p" ] && have curl || return 0
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "${GITLAB_API_ROOT:-https://gitlab.com/api/v4}/projects/$(printf '%s' "$p" | sed 's#/#%2F#g')" || echo 000)"
  case "$code" in
    200) ok "fork found: gitlab.com/$p"; return 0 ;;
    404) warn "there is no gitlab.com/$p yet"
         note "fork it (namespace $GLUSER): https://gitlab.com/fdroid/fdroiddata/-/forks/new"
         note "a fork this size can take a few minutes to appear"
         return 1 ;;
    *)   note "could not check the fork (HTTP $code) — trying anyway"; return 0 ;;
  esac
}

# Creating the fork: with glab when it's logged in, else GitLab's API with
# $GITLAB_TOKEN. GitLab copies the repo in the background, so wait for it.
GL_API="${GITLAB_API_ROOT:-https://gitlab.com/api/v4}"
# where upstream fdroiddata is cloned from (overridable for testing)
FDROIDDATA_UPSTREAM="${FDROIDDATA_UPSTREAM:-https://gitlab.com/fdroid/fdroiddata.git}"
glab_ready() { have glab && glab auth status --hostname gitlab.com >/dev/null 2>&1; }

gitlab_get() {  # gitlab_get <api path> — authenticated GET, JSON on stdout
  if glab_ready; then glab api "$1" 2>/dev/null || true
  elif [ -n "${GITLAB_TOKEN:-}" ]; then
    curl -s --max-time 20 -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GL_API/$1" || true
  fi
}

json_str() {  # json_str <key> — first "key":"value" in the JSON on stdin
  grep -Eo "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed -n 1p | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/'
}

create_fork() {  # asks GitLab to fork fdroid/fdroiddata into your namespace
  local code
  if glab_ready; then
    glab api --method POST "projects/fdroid%2Ffdroiddata/fork" >/dev/null 2>&1 \
      || { warn "glab could not start the fork"; return 1; }
  else
    code="$(curl -s -o "$WORK/fork.json" -w '%{http_code}' --max-time 30 -X POST \
      -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GL_API/projects/fdroid%2Ffdroiddata/fork" || echo 000)"
    case "$code" in
      2*) ;;
      *) warn "GitLab answered HTTP $code — the fork was not created"
         note "the token needs the 'api' scope"; return 1 ;;
    esac
  fi
  ok "fork requested"
}

wait_for_fork() {  # wait_for_fork <namespace/project> — until GitLab finishes copying
  local p="$1" s i
  say "GitLab is copying fdroiddata — this usually takes a few minutes…"
  for ((i = 0; i < 90; i++)); do  # ~15 minutes
    s="$(gitlab_get "projects/$(printf '%s' "$p" | sed 's#/#%2F#g')" | json_str import_status)"
    case "$s" in
      finished) printf '\n' >&2; ok "fork ready: gitlab.com/$p"; return 0 ;;
      failed)   printf '\n' >&2; warn "GitLab reports the fork failed — delete it on GitLab and retry"
                return 1 ;;
    esac
    printf '.' >&2; sleep 10
  done
  printf '\n' >&2; warn "still not ready after 15 minutes"; return 1
}

ensure_fork() {
  local p me
  check_fork && return 0
  p="$(fork_path "$FORKURL")"
  if [ -n "$p" ]; then
    if have glab && ! glab_ready && [ -z "${GITLAB_TOKEN:-}" ]; then
      note "glab is installed but not logged in to gitlab.com"
      if confirm "Log in with glab now, so it can create the fork?" y; then
        glab auth login --hostname gitlab.com || warn "glab login did not finish"
      fi
    fi
    if glab_ready || [ -n "${GITLAB_TOKEN:-}" ]; then
      # A fork lands in the logged-in account; it must be the one in the URL.
      me="$(gitlab_get user | json_str username)"
      if [ -n "$me" ] && [ "$me" != "${p%%/*}" ]; then
        warn "logged in to GitLab as '$me', but the fork URL is for '${p%%/*}' — not creating it"
      elif confirm "Create the fork gitlab.com/$p now?" y; then
        create_fork && wait_for_fork "$p" && return 0
      fi
    fi
  fi
  until check_fork; do
    confirm "Check again?" y || exit 0
  done
}

if [ -d "$FDROIDDATA/.git" ]; then
  ok "reusing $FDROIDDATA"
else
  ensure_fork
  # fdroiddata is huge; a full clone of the fork over SSH can be cut off
  # midway. The wizard only needs upstream to branch from and the fork to push
  # one branch to: so clone upstream over HTTPS (no login) with history but
  # no file contents (they load as needed), and add the fork as `origin`.
  say "cloning fdroiddata from upstream over HTTPS (history only — a minute or two)…"
  if ! git clone --filter=blob:none -o upstream "$FDROIDDATA_UPSTREAM" "$FDROIDDATA"; then
    die "could not clone $FDROIDDATA_UPSTREAM — check your connection and re-run"
  fi
  git -C "$FDROIDDATA" remote add origin "$FORKURL"
  ok "cloned; your fork is 'origin' (for pushing), fdroid's repo is 'upstream'"
fi

git -C "$FDROIDDATA" remote get-url upstream >/dev/null 2>&1 || \
  git -C "$FDROIDDATA" remote add upstream "$FDROIDDATA_UPSTREAM"
say "fetching upstream…"
git -C "$FDROIDDATA" fetch --quiet upstream || die "could not fetch upstream fdroiddata"

UPBRANCH=master
git -C "$FDROIDDATA" rev-parse -q --verify "refs/remotes/upstream/$UPBRANCH" >/dev/null 2>&1 || UPBRANCH=main
BASE="upstream/$UPBRANCH"
ok "base: $BASE ($(git -C "$FDROIDDATA" rev-parse --short "$BASE"))"

# --- new app or update? the fork's own state does not decide this, upstream does
EXISTING=""
if git -C "$FDROIDDATA" cat-file -e "$BASE:metadata/$APPID.yml" 2>/dev/null; then
  EXISTING="$BASE:metadata/$APPID.yml"
  IS_UPDATE=1
  ok "$APPID is already in F-Droid — this is a version update"
else
  ok "$APPID is not in F-Droid yet — this is a new app"
fi

# A half-finished earlier run leaves changes behind that would block the checkout.
# Leftovers from an earlier run of this wizard for this same app (a dry run
# leaves the file behind) are reset without asking; anything else is asked.
DIRTY="$(git -C "$FDROIDDATA" status --porcelain --untracked-files=no | awk '{print $NF}')"
if [ -n "$DIRTY" ] && [ "$DIRTY" = "metadata/$APPID.yml" ]; then
  git -C "$FDROIDDATA" reset -q --hard
  note "reset the leftover metadata/$APPID.yml from an earlier run"
fi
if ! git -C "$FDROIDDATA" diff --quiet || ! git -C "$FDROIDDATA" diff --cached --quiet; then
  warn "$FDROIDDATA has uncommitted changes:"
  git -C "$FDROIDDATA" --no-pager diff --stat HEAD | sed 's/^/       /'
  if confirm "Discard them (this clone is only a scratch area)?" n; then
    git -C "$FDROIDDATA" reset -q --hard
  else
    die "commit or stash them first"
  fi
fi

# Branching off upstream (not off whatever the fork happened to be on) keeps the
# merge request to a single file change.
BRANCH="$APPID"
[ "$IS_UPDATE" = 1 ] && BRANCH="$APPID-$VCODE"
git -C "$FDROIDDATA" checkout -q -B "$BRANCH" "$BASE" || die "could not create branch $BRANCH"
ok "branch: $BRANCH (off $BASE)"

# ================================================================ 3. metadata
step "3/5  Metadata"

# --- the build entry, needed in both modes -----------------------------------
# F-Droid builds in a clean container; extra setup goes in 'sudo:' lines.
if [ "$ASK_ALL" = 1 ]; then
  ask_opt JDK "JDK to install in the build container (blank = use the image default)" "${SAVED_JDK:-17}"
else
  JDK="${SAVED_JDK:-17}"
fi
case "$JDK" in ''|*[!0-9]*) JDK="" ;; esac
[ -n "$JDK" ] && ok "build container JDK: $JDK"

# Offer the product flavours declared in the gradle file, if any.
# (plain POSIX awk — no gawk-only 3-argument match(), Debian's awk is mawk)
FLAVOURS="$(awk '
  /productFlavors[[:space:]]*\{/ { depth = 1; next }
  depth > 0 {
    line = $0
    name = line
    sub(/^[[:space:]]*/, "", name)
    sub(/^create\("/, "", name)
    if (name ~ /^[A-Za-z][A-Za-z0-9_]*("\))?[[:space:]]*\{/) {
      sub(/("\))?[[:space:]]*\{.*/, "", name)
      print name
    }
    depth += gsub(/\{/, "{", line); depth -= gsub(/\}/, "}", line)
    if (depth <= 0) exit
  }' "$GRADLE_FILE" 2>/dev/null | tr '\n' ' ' || true)"
[ -n "${FLAVOURS// /}" ] && note "product flavours found: $FLAVOURS"
GRADLEFLAVOUR=""
if [ -n "${FLAVOURS// /}" ] || [ "$ASK_ALL" = 1 ]; then
  ask_opt GRADLEFLAVOUR "Gradle flavour (blank = the default variant)" ""
fi

# --- Flutter: which Flutter F-Droid builds with, and one APK per CPU type
FLUTTERREF=""; FL_PIN=""; ABISPLIT=0; FL_RM=""
if [ -n "$FLUTTER_DIR" ]; then
  FL_GUESS=""
  # A version pinned in the Flutter project lets F-Droid's metadata read it at
  # build time (flutter@stable + checkout), so auto-updates follow your pin.
  if [ -f "$REPO/$FLUTTER_DIR/.fvmrc" ]; then
    FL_GUESS="$(sed -nE 's/.*"flutter"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$REPO/$FLUTTER_DIR/.fvmrc" | sed -n 1p)"
    [ -n "$FL_GUESS" ] && FL_PIN=".fvmrc"
  elif [ -f "$REPO/$FLUTTER_DIR/.fvm/fvm_config.json" ]; then
    FL_GUESS="$(sed -nE 's/.*"flutterSdkVersion"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$REPO/$FLUTTER_DIR/.fvm/fvm_config.json" | sed -n 1p)"
  fi
  for tv in "$REPO/.tool-versions" "$REPO/$FLUTTER_DIR/.tool-versions"; do
    [ -z "$FL_GUESS" ] && [ -f "$tv" ] && \
      FL_GUESS="$(awk '$1 == "flutter" { sub(/-stable$/, "", $2); print $2; exit }' "$tv")"
  done
  if [ -z "$FL_GUESS" ] && have flutter; then
    FL_JSON="$(flutter --version --machine 2>/dev/null || true)"
    FL_GUESS="$(printf '%s' "$FL_JSON" | sed -nE 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | sed -n 1p)"
    FL_REV="$(printf '%s' "$FL_JSON" | sed -nE 's/.*"frameworkRevision"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | sed -n 1p)"
    # A pre-release version string is not a tag on flutter/flutter; the
    # commit it was built from is a ref F-Droid can check out.
    case "$FL_GUESS" in *-*) [ -n "${FL_REV:-}" ] && FL_GUESS="$FL_REV" ;; esac
  fi
  auto FLUTTERREF "Flutter version" "$FL_GUESS"
  if ! printf '%s' "$FLUTTERREF" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    warn "'$FLUTTERREF' is not a stable Flutter release"
    note "maintainers strongly prefer a stable tag; build and test the app on one"
    FL_PIN=""   # can't read a commit hash back from .fvmrc reliably
  fi
  [ -n "$FL_PIN" ] && [ "$(printf '%s' "$FL_GUESS")" != "$FLUTTERREF" ] && FL_PIN=""
  [ -n "$FL_PIN" ] && ok "F-Droid will read the Flutter version from $FLUTTER_DIR/$FL_PIN"

  # F-Droid asks for per-ABI APKs when the universal one is big (it is for
  # Flutter: every engine is inside). Flutter numbers split APKs itself as
  # 1000 * ABI + versionCode (arm32 1, arm64 2, x86_64 4).
  ABISPLIT=1
  if [ "$ASK_ALL" = 1 ]; then
    confirm "Build one APK per CPU type (smaller downloads; F-Droid asks for it)?" y || ABISPLIT=0
  fi
  [ "$ABISPLIT" = 1 ] && ok "one APK per CPU type: armeabi-v7a, arm64-v8a, x86_64"

  # Platform folders F-Droid doesn't need are removed before the build.
  for pd in ios linux macos web windows; do
    [ -d "$REPO/$FLUTTER_DIR/$pd" ] || continue
    if [ "$FLUTTER_DIR" = "." ]; then FL_RM="$FL_RM $pd"; else FL_RM="$FL_RM $FLUTTER_DIR/$pd"; fi
  done
fi

emit_entry() {  # emit_entry <versionCode> [<target platform> <abi>] — one Builds: item
  local vc="$1" tp="${2-}" abi="${3-}" apk flavor_flag="" f
  printf "  - versionName: '%s'\n" "$VNAME"
  printf '    versionCode: %s\n' "$vc"
  printf '    commit: %s\n' "$COMMIT"
  if [ -n "$FLUTTER_DIR" ]; then
    # build commands run inside subdir, so that is the Flutter project itself
    [ "$FLUTTER_DIR" != "." ] && printf '    subdir: %s\n' "$FLUTTER_DIR"
  else
    [ "$SUBDIR" != "." ] && printf '    subdir: %s\n' "$SUBDIR"
  fi
  if [ -n "$JDK" ]; then
    printf '    sudo:\n'
    printf '      - apt-get update\n'
    printf '      - apt-get install -y openjdk-%s-jdk-headless\n' "$JDK"
    printf '      - update-java-alternatives -a\n'
  fi
  if [ -z "$FLUTTER_DIR" ]; then
    printf '    gradle:\n'
    printf "      - '%s'\n" "${GRADLEFLAVOUR:-yes}"
    return
  fi
  # fdroiddata's Flutter recipe (templates/build-flutter.yml)
  apk="app"; [ -n "$abi" ] && apk="$apk-$abi"
  [ -n "$GRADLEFLAVOUR" ] && { apk="$apk-$GRADLEFLAVOUR"; flavor_flag=" --flavor $GRADLEFLAVOUR"; }
  printf '    output: build/app/outputs/flutter-apk/%s-release.apk\n' "$apk"
  printf '    srclibs:\n'
  if [ -n "$FL_PIN" ]; then printf '      - flutter@stable\n'; else printf '      - flutter@%s\n' "$FLUTTERREF"; fi
  if [ -n "$FL_RM" ]; then
    printf '    rm:\n'
    for f in $FL_RM; do printf '      - %s\n' "$f"; done
  fi
  printf '    prebuild:\n'
  if [ -n "$FL_PIN" ]; then
    printf '      - flutterVersion=$(sed -n -E '"'"'s/.*"flutter"[[:space:]]*:[[:space:]]*"([^"]+)".*/\\1/p'"'"' %s)\n' "$FL_PIN"
    printf "      - '[[ \$flutterVersion ]]'\n"
    printf '      - git -C $$flutter$$ checkout -f $flutterVersion\n'
  fi
  printf '      - export PUB_CACHE=$(pwd)/.pub-cache\n'
  printf '      - $$flutter$$/bin/flutter config --no-analytics\n'
  printf '      - $$flutter$$/bin/flutter pub get --enforce-lockfile\n'
  printf '    scandelete:\n'
  if [ "$FLUTTER_DIR" = "." ]; then printf '      - .pub-cache\n'; else printf '      - %s/.pub-cache\n' "$FLUTTER_DIR"; fi
  printf '    build:\n'
  printf '      - export PUB_CACHE=$(pwd)/.pub-cache\n'
  if [ -n "$tp" ]; then
    printf '      - $$flutter$$/bin/flutter build apk --release --split-per-abi --target-platform=%s%s\n' "$tp" "$flavor_flag"
  else
    printf '      - $$flutter$$/bin/flutter build apk --release%s\n' "$flavor_flag"
  fi
}

BUILD_BLOCK="$WORK/build.yml"
if [ "$ABISPLIT" = 1 ]; then
  VCODES="$((1000 + VCODE)) $((2000 + VCODE)) $((4000 + VCODE))"
  CUR_VCODE="$((4000 + VCODE))"
  {
    emit_entry "$((1000 + VCODE))" android-arm armeabi-v7a; printf '\n'
    emit_entry "$((2000 + VCODE))" android-arm64 arm64-v8a; printf '\n'
    emit_entry "$((4000 + VCODE))" android-x64 x86_64
  } > "$BUILD_BLOCK"
else
  VCODES="$VCODE"; CUR_VCODE="$VCODE"
  emit_entry "$VCODE" > "$BUILD_BLOCK"
fi

YML="$WORK/$APPID.yml"

if [ "$IS_UPDATE" = 1 ]; then
  # ---------- update: keep the upstream file, add one build, bump CurrentVersion
  git -C "$FDROIDDATA" show "$EXISTING" > "$YML"
  for vc in $VCODES; do
    if grep -qE "^[[:space:]]+versionCode: $vc\$" "$YML"; then
      die "versionCode $vc is already in metadata/$APPID.yml — nothing to do"
    fi
  done
  if grep -q '^Builds:' "$YML"; then
    awk -v bf="$BUILD_BLOCK" '
      BEGIN { while ((getline l < bf) > 0) blk = blk l "\n" }
      /^Builds:[[:space:]]*$/ { inb = 1; print; next }
      inb && /^[^[:space:]#]/ { printf "%s\n", blk; inb = 0; print; next }
      { print }
      END { if (inb) printf "%s", blk }
    ' "$YML" > "$YML.new" && mv "$YML.new" "$YML"
  else
    { printf '\nBuilds:\n'; cat "$BUILD_BLOCK"; } >> "$YML"
  fi
  # CurrentVersion drives what F-Droid offers as the latest release.
  if grep -q '^CurrentVersion:' "$YML"; then
    # not `sed -i`: that needs an argument on BSD/macOS sed and none on GNU
    sed -E "s|^CurrentVersion:.*|CurrentVersion: '$VNAME'|; s|^CurrentVersionCode:.*|CurrentVersionCode: $CUR_VCODE|" \
      "$YML" > "$YML.new" && mv "$YML.new" "$YML"
  else
    printf "\nCurrentVersion: '%s'\nCurrentVersionCode: %s\n" "$VNAME" "$CUR_VCODE" >> "$YML"
  fi
  ok "added versionCode(s) $VCODES to the existing metadata"
else
  # ---------- new app: ask for everything the entry needs
  # --- license
  LIC_GUESS="${SAVED_LICENSE:-}"
  if [ -z "$LIC_GUESS" ]; then
    for f in LICENSE LICENSE.md LICENSE.txt LICENCE LICENCE.md COPYING COPYING.md; do
      [ -f "$REPO/$f" ] || continue
      # Only the head: the GPL-3.0 text itself mentions the Affero license
      # (section 13), so matching the whole file calls every GPL app AGPL.
      head -n 30 "$REPO/$f" > "$WORK/license.head"
      LH="$WORK/license.head"
      if   grep -qi "GNU AFFERO GENERAL PUBLIC LICENSE" "$LH"; then LIC_GUESS="AGPL-3.0-only"
      elif grep -qi "GNU LESSER GENERAL PUBLIC LICENSE" "$LH"; then LIC_GUESS="LGPL-3.0-only"
      elif grep -qi "GNU GENERAL PUBLIC LICENSE" "$LH"; then
        if grep -q "Version 3" "$LH"; then LIC_GUESS="GPL-3.0-only"; else LIC_GUESS="GPL-2.0-only"; fi
      elif grep -qi "Apache License" "$LH";        then LIC_GUESS="Apache-2.0"
      elif grep -qi "MIT License" "$LH";           then LIC_GUESS="MIT"
      elif grep -qi "Mozilla Public License" "$LH"; then LIC_GUESS="MPL-2.0"
      elif grep -qi "Redistribution and use in source" "$LH"; then LIC_GUESS="BSD-3-Clause"
      elif grep -qi "This is free and unencumbered" "$LH"; then LIC_GUESS="Unlicense"
      fi
      [ -n "$LIC_GUESS" ] && { ok "license looks like $LIC_GUESS (from $f)"; break; }
    done
  fi
  [ -n "$LIC_GUESS" ] || note "SPDX identifier, e.g. GPL-3.0-only, Apache-2.0, MIT, AGPL-3.0-only"
  auto LICENSE "License" "$LIC_GUESS"

  # --- categories
  CATS_ALL="Connectivity Development Games Graphics Internet Money Multimedia Navigation Phone&SMS Reading Science&Education Security Sports&Health System Theming Time Writing"
  CATS_MAX="$(echo "$CATS_ALL" | wc -w)"
  # Only a person can pick these; after the first run they're remembered.
  # (remembered per app — another app's categories are no guess for this one)
  CATSEL=""
  [ "${SAVED_CATSEL_APP:-}" = "$APPID" ] && CATSEL="${SAVED_CATSEL:-}"
  if [ -z "$CATSEL" ] || [ "$ASK_ALL" = 1 ]; then
    [ "$ASSUME_YES" = 1 ] && [ -z "$CATSEL" ] && die "--yes: pick the categories once in a normal run first"
    say "Categories (pick one or more by number, space separated):"
    i=1; for c in $CATS_ALL; do printf '     %2d) %s\n' "$i" "${c//&/ & }"; i=$((i+1)); done
  fi
  while :; do
    if [ -z "$CATSEL" ] || [ "$ASK_ALL" = 1 ]; then ask CATSEL "Numbers" "$CATSEL"; fi
    CATEGORIES=""; BADSEL=""
    for n in $CATSEL; do
      case "$n" in ''|*[!0-9]*) BADSEL="$n"; break ;; esac
      [ "$n" -ge 1 ] && [ "$n" -le "$CATS_MAX" ] || { BADSEL="$n"; break; }
      c="$(echo "$CATS_ALL" | awk -v k="$n" '{print $k}')"
      CATEGORIES="$CATEGORIES${CATEGORIES:+|}${c//&/ & }"
    done
    [ -z "$BADSEL" ] && [ -n "$CATEGORIES" ] && break
    warn "'${BADSEL:-}' is not one of 1-$CATS_MAX"; CATSEL=""
  done
  ok "categories: ${CATEGORIES//|/, }"

  # --- urls
  auto SOURCE  "SourceCode"   "$WEB_GUESS"
  auto REPOURL "Repo" "${WEB_GUESS:+$WEB_GUESS.git}"
  case "$REPOURL" in *.git) ;; *) warn "Repo usually ends in .git — fdroid lint will say so" ;; esac
  auto_opt ISSUES    "IssueTracker"  "${WEB_GUESS:+$WEB_GUESS/issues}"
  auto_opt CHANGELOG "Changelog"     "${WEB_GUESS:+$WEB_GUESS/releases}"
  auto_opt WEBSITE   "WebSite" "${SAVED_WEBSITE:-}"

  # --- author
  # fdroiddata requires an AuthorName (any name, it needn't be your real one).
  auto AUTHORNAME "AuthorName" "${SAVED_AUTHORNAME:-$(git -C "$REPO" config user.name 2>/dev/null || echo "")}"
  auto_opt AUTHOREMAIL "AuthorEmail" "${SAVED_AUTHOREMAIL:-$(git -C "$REPO" config user.email 2>/dev/null || echo "")}"
  auto_opt AUTHORSITE  "AuthorWebSite" "${SAVED_AUTHORSITE:-}"

  # --- flags
  REQROOT=false
  if [ "$ASK_ALL" = 1 ]; then confirm "Does the app require root?" n && REQROOT=true; fi

  # --- anti-features
  AF_ALL="Ads Tracking NonFreeNet NonFreeAdd NonFreeDep NonFreeAssets UpstreamNonFree NoSourceSince KnownVuln"
  ANTIFEATURES=""
  # Asked when the pitfall check found proprietary bits, or with --ask.
  AF_ASK=0
  [ -n "${PROPRIETARY:-}${PROPRIETARY_PUB// /}" ] && AF_ASK=1
  [ "$ASK_ALL" = 1 ] && AF_ASK=1
  [ "$AF_ASK" = 0 ] && ok "anti-features: none (no ads, trackers or non-free dependencies found)"
  if [ "$AF_ASK" = 1 ] && confirm "Declare any anti-features (ads, tracking, non-free deps…)?" n; then
    i=1; for a in $AF_ALL; do printf '     %2d) %s\n' "$i" "$a"; i=$((i+1)); done
    AF_MAX=$((i-1))
    ask_opt AFSEL "Numbers (space separated, blank for none)" ""
    for n in $AFSEL; do
      case "$n" in ''|*[!0-9]*) continue ;; esac
      [ "$n" -ge 1 ] && [ "$n" -le "$AF_MAX" ] || continue
      a="$(echo "$AF_ALL" | awk -v k="$n" '{print $k}')"
      ANTIFEATURES="$ANTIFEATURES${ANTIFEATURES:+|}$a"
    done
    [ -n "$ANTIFEATURES" ] && ok "anti-features: ${ANTIFEATURES//|/, }"
  fi

  # --- publishing mode
  MODE=1; BINARIES=""; SIGNKEY=""
  if [ "$ASK_ALL" = 0 ]; then
    ok "publishing: F-Droid builds and signs (--ask to set up reproducible builds)"
  else
  step "Publishing mode"
  say "  1) ${B}F-Droid builds and signs${R}  — F-Droid compiles from source and signs with"
  say "     its own key. Simplest. Users get F-Droid's signature, so an app already"
  say "     installed from your GitHub APK cannot update to it."
  say "  2) ${B}Reproducible build${R}         — F-Droid rebuilds from source, checks the result"
  say "     matches your signed APK, and ships YOUR APK. Keeps your signature."
  say "     Needs Binaries: and AllowedAPKSigningKeys."
  ask MODE "Which?" "1"

  if [ "$MODE" = "2" ]; then
    note "use %v where the version goes, e.g. .../releases/download/v%v/App-%v.apk"
    # Name the file after the project, not the local checkout's folder.
    ask BINARIES "Binaries URL pattern" "${WEB_GUESS:+$WEB_GUESS/releases/download/v%v/${WEB_GUESS##*/}-%v.apk}"
    say "The signing certificate SHA-256 of your release APK is needed."
    if confirm "Extract it from a local APK now?" y; then
      ask APKPATH "Path to your signed release APK" ""
      APKPATH="${APKPATH/#\~/$HOME}"
      if [ ! -f "$APKPATH" ]; then
        warn "no such file: $APKPATH"
      else
        AS=""
        if have apksigner; then AS="apksigner"
        elif [ -n "${ANDROID_HOME:-}" ]; then
          cand="$(ls -d "$ANDROID_HOME"/build-tools/*/ 2>/dev/null | tail -1)"
          [ -n "$cand" ] && [ -f "$cand/lib/apksigner.jar" ] && AS="java -jar $cand/lib/apksigner.jar"
        fi
        if [ -n "$AS" ]; then
          SIGNKEY="$($AS verify --print-certs "$APKPATH" 2>/dev/null \
                     | awk '/SHA-256 digest/ {print $NF; exit}')"
        fi
        # keytool ships with any JDK and reads the APK's signature block too
        if [ -z "$SIGNKEY" ] && have keytool; then
          SIGNKEY="$(keytool -printcert -jarfile "$APKPATH" 2>/dev/null \
                     | awk '/SHA256:/ {print $2; exit}' | tr -d ':' | tr 'A-Z' 'a-z')"
        fi
        [ -n "$SIGNKEY" ] && ok "signing key: $SIGNKEY" || warn "could not read it automatically"
      fi
    fi
    [ -n "$SIGNKEY" ] || ask SIGNKEY "AllowedAPKSigningKeys (SHA-256, lowercase hex)" ""
    [ "$ABISPLIT" = 1 ] && note "with one APK per CPU type, use %c (versionCode) in the Binaries pattern too"
  fi
  fi

  # --- auto-update: derived from how the tag relates to the versionName
  case "$TAG" in
    "$VNAME")   AUM="Version" ;;
    "v$VNAME")  AUM="Version v%v" ;;
    *)          AUM="" ;;
  esac
  if [ -z "$AUM" ]; then
    warn "tag '$TAG' does not look like '$VNAME' or 'v$VNAME'"
    note "AutoUpdateMode needs the tag pattern, e.g. 'Version release-%v'"
    ask_opt AUM "AutoUpdateMode (blank = None, metadata updated by hand)" "None"
    AUM="${AUM:-None}"
  fi

  # --- assemble yaml
  # NOTE: versionName/CurrentVersion/gradle are quoted on purpose. Unquoted, YAML reads
  # 'yes' as boolean true and a versionName like 1.0 as a float. `fdroid rewritemeta`
  # normalises the file afterwards anyway.
  {
    printf 'Categories:\n'
    old_ifs="$IFS"; IFS='|'
    for c in $CATEGORIES; do printf '  - %s\n' "$c"; done
    IFS="$old_ifs"
    printf 'License: %s\n' "$LICENSE"
    [ -n "$AUTHORNAME" ]  && printf 'AuthorName: %s\n' "$AUTHORNAME"
    [ -n "$AUTHOREMAIL" ] && printf 'AuthorEmail: %s\n' "$AUTHOREMAIL"
    [ -n "$AUTHORSITE" ]  && printf 'AuthorWebSite: %s\n' "$AUTHORSITE"
    [ -n "$WEBSITE" ]     && printf 'WebSite: %s\n' "$WEBSITE"
    printf 'SourceCode: %s\n' "$SOURCE"
    [ -n "$ISSUES" ]      && printf 'IssueTracker: %s\n' "$ISSUES"
    [ -n "$CHANGELOG" ]   && printf 'Changelog: %s\n' "$CHANGELOG"
    printf '\n'
    if [ -n "$ANTIFEATURES" ]; then
      printf 'AntiFeatures:\n'
      old_ifs="$IFS"; IFS='|'
      for a in $ANTIFEATURES; do printf '  - %s\n' "$a"; done
      IFS="$old_ifs"
      printf '\n'
    fi
    printf 'RepoType: git\n'
    printf 'Repo: %s\n' "$REPOURL"
    [ "$REQROOT" = true ] && printf 'RequiresRoot: true\n'
    [ -n "$BINARIES" ]    && printf 'Binaries: %s\n' "$BINARIES"
    printf '\n'
    printf 'Builds:\n'
    cat "$BUILD_BLOCK"
    printf '\n'
    [ -n "$SIGNKEY" ] && printf 'AllowedAPKSigningKeys: %s\n\n' "$SIGNKEY"
    printf 'AutoUpdateMode: %s\n' "$AUM"
    printf 'UpdateCheckMode: Tags\n'
    # Split APKs: the codes Flutter gives them, derived from pubspec's code.
    if [ "$ABISPLIT" = 1 ]; then
      printf 'VercodeOperation:\n'
      printf "  - '%%c + 1000'\n  - '%%c + 2000'\n  - '%%c + 4000'\n"
    fi
    # The checker reads versions from gradle, where Flutter only has
    # references; point it at pubspec.yaml's `version: name+code` instead.
    if [ -n "$FLUTTER_DIR" ]; then
      UCD_FILE="pubspec.yaml"; [ "$FLUTTER_DIR" != "." ] && UCD_FILE="$FLUTTER_DIR/pubspec.yaml"
      printf 'UpdateCheckData: %s|version:\\s.+\\+(\\d+)|.|version:\\s(.+)\\+\n' "$UCD_FILE"
    fi
    printf "CurrentVersion: '%s'\n" "$VNAME"
    printf 'CurrentVersionCode: %s\n' "$CUR_VCODE"
  } > "$YML"
fi

step "metadata/$APPID.yml"
if [ "$IS_UPDATE" = 1 ]; then
  # the file is long by now — only the added lines are interesting
  git -C "$FDROIDDATA" --no-pager diff --no-index --no-color -- \
    <(git -C "$FDROIDDATA" show "$EXISTING") "$YML" 2>/dev/null \
    | tail -n +5 | sed "s/^/   /" || true
else
  printf '%s' "$DIM"; sed 's/^/   | /' "$YML"; printf '%s' "$R"
fi
if ! confirm "Looks right?" y; then
  KEEP_WORK=1
  say "Edit it yourself at: $YML"
  die "stopped"
fi

mkdir -p "$FDROIDDATA/metadata"
cp "$YML" "$FDROIDDATA/metadata/$APPID.yml"
YMLSUM="$(cksum < "$FDROIDDATA/metadata/$APPID.yml")"
ok "wrote $FDROIDDATA/metadata/$APPID.yml"
save_answers

# ================================================================ 4. validate
step "4/5  Validation"
if [ "$RUNNER" = none ]; then
  warn "no fdroidserver — skipping readmeta/rewritemeta/lint"
  warn "the maintainers' CI will run these anyway, so expect to fix what it reports"
else
  VALID_FAIL=""
  say "fdroid readmeta";           frun readmeta             || VALID_FAIL="$VALID_FAIL readmeta"
  say "fdroid rewritemeta $APPID"; frun rewritemeta "$APPID" || VALID_FAIL="$VALID_FAIL rewritemeta"
  say "fdroid lint $APPID";        frun lint "$APPID"        || VALID_FAIL="$VALID_FAIL lint"
  if [ "$YMLSUM" != "$(cksum < "$FDROIDDATA/metadata/$APPID.yml")" ]; then
    note "rewritemeta reformatted the file — that is normal"
  fi
  # The full build is the best predictor of acceptance, but slow (Android SDK,
  # the whole toolchain): only with --build, or when asked for with --ask.
  if [ "$RUN_BUILD" = 1 ] || { [ "$ASK_ALL" = 1 ] && confirm "Run 'fdroid build -v -l $APPID' now (slow)?" n; }; then
    say "fdroid build -v -l $APPID"
    frun build -v -l "$APPID" || VALID_FAIL="$VALID_FAIL build"
  else
    note "full build skipped (--build to run it; F-Droid's CI builds it anyway)"
  fi
  if [ -n "$VALID_FAIL" ]; then
    warn "failed:$VALID_FAIL — maintainers' CI would reject this as it is"
    confirm "Push it anyway?" n || { KEEP_WORK=1; die "fix the metadata at $FDROIDDATA/metadata/$APPID.yml and re-run"; }
  else
    ok "metadata validates"
  fi
fi

# The app's display name, for titles: the fastlane title, else the ID.
APPNAME="$(for f in "$REPO/fastlane/metadata/android/en-US/title.txt" \
                   ${FLUTTER_DIR:+"$REPO/$FLUTTER_DIR/fastlane/metadata/android/en-US/title.txt"}; do
             [ -f "$f" ] && { sed -n 1p "$f"; break; }; done)"
APPNAME="${APPNAME:-$APPID}"

# ================================================== 4b. RFP issue (optional)
# Filled from F-Droid's own template (gitlab.com/fdroid/rfp, the Default issue
# template) with the answers above. Opened with glab if it's logged in, else
# GitLab's API with $GITLAB_TOKEN, else as a pre-filled page in the browser
# for you to check and submit. `gh` can't help: the RFP tracker is on GitLab.
RFP_URL=""
RFP_REF=""
GITLAB_API_ROOT="${GITLAB_API_ROOT:-https://gitlab.com/api/v4}"
RFP_PROJECT="fdroid/rfp"

urlencode() {  # percent-encode every byte except RFC 3986 unreserved ones
  local LC_ALL=C s="$1" out="" c hex i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      # bytes above 0x7F can come back sign-extended (FFFF…E2); the last
      # two hex digits are the byte either way
      *) printf -v hex '%02X' "'$c"; out+="%${hex: -2}" ;;
    esac
  done
  printf '%s' "$out"
}

fastlane_text() {  # fastlane_text <file> — first match in the usual places
  local f
  for f in "$REPO/fastlane/metadata/android/en-US/$1" \
           ${FLUTTER_DIR:+"$REPO/$FLUTTER_DIR/fastlane/metadata/android/en-US/$1"}; do
    [ -f "$f" ] && { cat "$f"; return 0; }
  done
  return 1
}

RFP_WANTED=0
if [ "$IS_UPDATE" = 0 ]; then
  if [ "$WANT_RFP" = 1 ]; then RFP_WANTED=1
  elif [ "$ASK_ALL" = 1 ]; then confirm "Open an RFP issue for this app on gitlab.com/$RFP_PROJECT?" n && RFP_WANTED=1
  else note "no RFP issue (optional when you send the metadata yourself; --rfp to open one)"
  fi
fi
if [ "$RFP_WANTED" = 1 ]; then
  step "Request For Packaging issue"
  if :; then
    auto RFP_NAME "App name" "$APPNAME"
    RFP_SUMMARY="$(fastlane_text short_description.txt 2>/dev/null | sed -n 1p || true)"
    [ -n "$RFP_SUMMARY" ] || RFP_SUMMARY="${SUMMARY:-}"
    auto RFP_SUMMARY "Summary" "$RFP_SUMMARY"
    RFP_DESC="$(fastlane_text full_description.txt 2>/dev/null || true)"
    [ -n "$RFP_DESC" ] || RFP_DESC="${FULLDESC:-$RFP_SUMMARY}"
    auto RFP_WHY "Why it belongs in F-Droid" \
      "I'm the developer; the metadata merge request is ready to go."

    RFP_BODY="$WORK/rfp.md"
    {
      printf '<!-- filled in by fdroid-submit.sh from the RFP template -->\n\n'
      printf '```yaml\n'
      printf 'Categories:\n'
      old_ifs="$IFS"; IFS='|'
      for c in $CATEGORIES; do printf ' - %s\n' "$c"; done
      IFS="$old_ifs"
      printf 'License: %s\n' "$LICENSE"
      printf 'AuthorName: %s\n' "${AUTHORNAME:-}"
      printf 'AuthorEmail: %s\n' "${AUTHOREMAIL:-}"
      printf 'AuthorWebSite: %s\n' "${AUTHORSITE:-}"
      printf 'WebSite: %s\n' "${WEBSITE:-}"
      printf 'SourceCode: %s\n' "$SOURCE"
      printf 'IssueTracker: %s\n' "${ISSUES:-}"
      printf 'AutoName: %s\n' "$RFP_NAME"
      printf 'RepoType: git\n'
      printf 'Repo: %s\n' "$REPOURL"
      printf '```\n\n'
      printf '### Why should it be included?\n\n%s\n\n' "$RFP_WHY"
      printf '### Summary\n\n%s\n\n' "$RFP_SUMMARY"
      printf '### Description\n\n%s\n\n' "$RFP_DESC"
      printf 'Metadata: `metadata/%s.yml` on branch `%s` of %s.\n' "$APPID" "$BRANCH" "$FORKURL"
    } > "$RFP_BODY"

    say "Title: $RFP_NAME"
    printf '%s' "$DIM"; sed 's/^/   | /' "$RFP_BODY"; printf '%s' "$R"

    if [ "$DRYRUN" = 1 ]; then
      warn "dry run — not opening the issue"
    elif have glab && glab auth status --hostname gitlab.com >/dev/null 2>&1; then
      say "opening it with glab…"
      RFP_URL="$(glab issue create -R "$RFP_PROJECT" --title "$RFP_NAME" \
                   --description "$(cat "$RFP_BODY")" --yes 2>&1 \
                 | grep -Eo 'https://[^ ]+/-/issues/[0-9]+' | tail -1 || true)"
      [ -n "$RFP_URL" ] || warn "glab did not report an issue URL — check $RFP_PROJECT"
    elif [ -n "${GITLAB_TOKEN:-}" ]; then
      say "opening it through the GitLab API…"
      RFP_STATUS="$(curl -sS -o "$WORK/rfp.json" -w '%{http_code}' \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        --data-urlencode "title=$RFP_NAME" \
        --data-urlencode "description@$RFP_BODY" \
        "$GITLAB_API_ROOT/projects/$(urlencode "$RFP_PROJECT")/issues" || echo 000)"
      case "$RFP_STATUS" in
        2*) RFP_URL="$(grep -Eo 'https://[^"]+/-/issues/[0-9]+' "$WORK/rfp.json" | sed -n 1p)" ;;
        *)  warn "GitLab answered HTTP $RFP_STATUS — the issue was not created"
            note "the token needs the 'api' scope" ;;
      esac
    else
      # No CLI or token: GitLab's new-issue page takes the title and text as
      # query parameters, so you only have to check them and press Create.
      NEWURL="https://gitlab.com/$RFP_PROJECT/-/issues/new?issue%5Btitle%5D=$(urlencode "$RFP_NAME")&issue%5Bdescription%5D=$(urlencode "$(cat "$RFP_BODY")")"
      say "No glab login or GITLAB_TOKEN — opening a pre-filled issue in your browser."
      note "check it and press 'Create issue' (sign in to GitLab first if asked)"
      if have xdg-open; then xdg-open "$NEWURL" >/dev/null 2>&1 &
      elif have open; then open "$NEWURL" >/dev/null 2>&1 &
      else note "open this link:"; printf '   %s\n' "$NEWURL"
      fi
      ask_opt RFP_URL "Paste the issue's URL once created (blank to skip)" ""
    fi
    if [ -n "$RFP_URL" ]; then
      ok "RFP issue: $RFP_URL"
      RFP_REF="$RFP_PROJECT#${RFP_URL##*/}"
    fi
  fi
fi

# ==================================================================== 5. push
step "5/5  Commit and push"
git -C "$FDROIDDATA" add "metadata/$APPID.yml"
git -C "$FDROIDDATA" --no-pager diff --cached --stat

if git -C "$FDROIDDATA" diff --cached --quiet; then
  die "nothing staged — metadata/$APPID.yml is identical to upstream"
fi
CHANGED="$(git -C "$FDROIDDATA" diff --cached --name-only | wc -l)"
[ "$CHANGED" = 1 ] || warn "$CHANGED files staged — an MR should normally touch only one"

# fdroiddata's titles: "New app: <name>", and updates name the version.
if [ "$IS_UPDATE" = 1 ]; then
  MSG="Update $APPNAME to $VNAME"
else
  MSG="New app: $APPNAME"
fi
auto COMMITMSG "Commit message" "$MSG"

# The merge request text: fdroiddata's own template, with the boxes this
# wizard has actually checked ticked, and the RFP linked.
mr_description() {
  local tpl="App inclusion.md" line
  [ "$IS_UPDATE" = 1 ] && tpl="App update.md"
  if [ "$IS_UPDATE" = 1 ]; then
    printf 'Update %s to %s (versionCode %s).\n\n' "$APPNAME" "$VNAME" "$VCODES"
  else
    printf 'New app: **%s** — %s\n\n' "$APPNAME" "${RFP_SUMMARY:-$(fastlane_text short_description.txt 2>/dev/null | sed -n 1p || true)}"
    printf 'Submitted by the app'"'"'s author.\n\n'
  fi
  [ -n "$RFP_REF" ] && printf 'Closes %s\n\n' "$RFP_REF"
  git -C "$FDROIDDATA" show "$BASE:.gitlab/merge_request_templates/$tpl" 2>/dev/null \
    | while IFS= read -r line; do
        case "$line" in
          "* [ ] Metadata must be put in"*|"* [ ] Metadata must use LF"*|"* [ ] Please only submit one app"*|\
          "* [ ] The \`commit\` field should be the full hash"*|"* [ ] An AuthorName must be added"*)
            line="* [x] ${line#\* \[ \] }" ;;
          "* [ ] Metadata must be a valid YAML file"*)
            [ "$RUNNER" != none ] && [ -z "${VALID_FAIL:-}" ] && line="* [x] ${line#\* \[ \] }" ;;
          "* [ ] Releases are tagged and auto update is enabled"*)
            [ "${AUM:-None}" != None ] && line="* [x] ${line#\* \[ \] }" ;;
          "* [ ] Setup abi split"*)
            [ "$ABISPLIT" = 1 ] && line="* [x] ${line#\* \[ \] }" ;;
          "* [ ] The upstream app source code repo contains the app metadata"*)
            fastlane_text short_description.txt >/dev/null 2>&1 && line="* [x] ${line#\* \[ \] }" ;;
        esac
        printf '%s\n' "$line"
      done
}

if [ "$DRYRUN" = 1 ]; then
  warn "dry run — not committing, pushing or opening a merge request"
  note "$FDROIDDATA (branch $BRANCH)"
  exit 0
fi
if ! go "Commit and push to $FORKURL ($BRANCH)?"; then
  say "Nothing pushed. The branch and file are ready at:"
  note "$FDROIDDATA (branch $BRANCH)"
  exit 0
fi
# A fresh clone may have no identity of its own; use the app repo's.
ID_ARGS=()
if [ -z "$(git -C "$FDROIDDATA" config user.email 2>/dev/null || true)" ]; then
  ID_ARGS=(-c "user.name=$(git -C "$REPO" config user.name 2>/dev/null || echo "${AUTHORNAME:-fdroid-submit}")"
           -c "user.email=$(git -C "$REPO" config user.email 2>/dev/null || echo "${AUTHOREMAIL:-nobody@example.com}")")
fi
git -C "$FDROIDDATA" "${ID_ARGS[@]}" commit -q -m "$COMMITMSG"
# A re-run for the same app/version replaces the branch it pushed before.
if ! git -C "$FDROIDDATA" push -q -f -u origin "$BRANCH"; then
  warn "could not push to $FORKURL"
  note "check with: ssh -T git@gitlab.com   (it should greet @$GLUSER), then re-run"
  die "push failed"
fi
ok "pushed $BRANCH"

MR_URL=""
if glab_ready && go "Open the merge request on fdroid/fdroiddata?"; then
  mr_description > "$WORK/mr.md"
  MR_OUT="$(glab mr create -R fdroid/fdroiddata -H "$(fork_path "$FORKURL")" \
              -s "$BRANCH" -b "$UPBRANCH" -t "$COMMITMSG" \
              -d "$(cat "$WORK/mr.md")" --allow-collaboration -y 2>&1 || true)"
  MR_URL="$(printf '%s\n' "$MR_OUT" | grep -Eo 'https://[^ ]+/-/merge_requests/[0-9]+' | tail -1 || true)"
  if [ -n "$MR_URL" ]; then
    ok "merge request: $MR_URL"
  else
    warn "glab did not open the merge request:"
    printf '%s\n' "$MR_OUT" | tail -5 | sed 's/^/       /'
  fi
fi
if [ -z "$MR_URL" ]; then
  MRURL="https://gitlab.com/$GLUSER/fdroiddata/-/merge_requests/new?merge_request%5Bsource_branch%5D=$BRANCH&merge_request%5Btarget_branch%5D=$UPBRANCH"
  [ -n "$RFP_REF" ] && MRURL="$MRURL&merge_request%5Bdescription%5D=$(urlencode "Closes $RFP_REF")"
  say "${B}Open the merge request:${R} $MRURL"
  note "target fdroid/fdroiddata, branch $UPBRANCH, title \"$COMMITMSG\""
fi
[ -n "$RFP_REF" ] && note "it links the RFP issue ($RFP_REF)"
note "expect roughly 24-48 hours from merge until the app appears in F-Droid"
