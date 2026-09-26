#!/usr/bin/env bash
#
# store-submit.sh — publish an app to F-Droid, Google Play or nixpkgs.
#
#   store-submit.sh                 asks where the app is going, checks what
#                                   that store needs from the app and what this
#                                   machine has, then runs the store's wizard
#   store-submit.sh fdroid [opts]   the F-Droid wizard directly
#   store-submit.sh play   [opts]   the Google Play wizard directly
#   store-submit.sh nix    [opts]   the nixpkgs wizard directly
#   (each takes --help; AUR has the checks only, no wizard yet)
#
# Layout: the three wizards come first, each as one function (wizard_<id>),
# then the store picker. A wizard always runs in a process of its own (the
# picker starts `store-submit.sh <id>`), so its variables, traps and exits
# stay its own, exactly as when they were separate scripts. Their bodies are
# deliberately not indented: their here-documents must start at column 0.
#
# Adding a store: one line in STORES, a needs_<id> and a tools_<id> function,
# and a wizard_<id> function.

set -eu

# ##########################################################################
#   F-Droid wizard — store-submit.sh fdroid [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_fdroid() {
#
# store-submit.sh fdroid — interactive wizard for submitting an Android app to F-Droid.
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
store-submit.sh fdroid — interactive wizard for getting an Android app into F-Droid.

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
      --forget-app  forget one app: its answers and what was already pushed

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
    --forget)     rm -rf "$CONF" "$CONF_DIR/apps"; printf 'forgot %s and every app\n' "$CONF"; exit 0 ;;
    --forget-app) FORGET_APP="${2-}"; shift
                  [ -n "$FORGET_APP" ] || { printf 'which app? --forget-app <applicationId>\n' >&2; exit 2; }
                  rm -f "$CONF_DIR/apps/$FORGET_APP.conf"
                  printf 'forgot %s\n' "$CONF_DIR/apps/$FORGET_APP.conf"; exit 0 ;;
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
  # nothing detected? then what this app answered last time is the default
  [ -n "$__def" ] || __def="$(recall "$__var")"
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
  remember "$__var" "$__in"
}

ask_opt() {  # like ask, but blank is allowed and means "omit this field";
             # with a default, Enter keeps it and "-" leaves the field out
  local __var="$1" __q="$2" __def="${3-}" __in=""
  [ -n "$__def" ] || __def="$(recall "$__var")"
  if [ "$ASSUME_YES" = 1 ]; then printf -v "$__var" '%s' "$__def"; return 0; fi
  printf '   %s%s%s%s: ' "$B" "$__q" "$R" "${__def:+ [$__def, - for none]}" >&2
  readline __in
  [ -z "$__in" ] && __in="$__def"
  [ "$__in" = - ] && __in=""
  printf -v "$__var" '%s' "$__in"
  remember "$__var" "$__in"
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
  [ -n "$__val" ] || __val="$(recall "$__var")"
  if [ "$ASK_ALL" = 0 ] && [ -n "$__val" ]; then
    printf -v "$__var" '%s' "$__val"; ok "$__label: $__val"; remember "$__var" "$__val"
  else
    ask "$__var" "$__label" "$__val"
  fi
}

auto_opt() {  # like auto, for optional fields: blank is fine and not asked
  local __var="$1" __label="$2" __val="${3-}"
  [ -n "$__val" ] || __val="$(recall "$__var")"
  if [ "$ASK_ALL" = 0 ]; then
    printf -v "$__var" '%s' "$__val"; remember "$__var" "$__val"
    [ -n "$__val" ] && ok "$__label: $__val"
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
SAVED_FDROIDSERVER=""; SAVED_CATSEL_APP=""; SAVED_LICENSE_APP=""
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
  local lic="${SAVED_LICENSE:-}" licapp="${SAVED_LICENSE_APP:-}"
  if [ -n "${LICENSE:-}" ]; then lic="$LICENSE"; licapp="${APPID:-}"; fi
  {
    printf '# written by store-submit.sh fdroid — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n'         "${REPO:-${SAVED_REPO:-}}"
    printf 'SAVED_SUBDIR=%q\n'       "${SUBDIR:-${SAVED_SUBDIR:-}}"
    printf 'SAVED_LICENSE=%q\n'      "$lic"
    printf 'SAVED_LICENSE_APP=%q\n'  "$licapp"
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

# ------------------------------------------------- what this app answered last
# $CONF_DIR/apps/<appid>.conf holds every answer this app has been given, plus
# the milestones that leave your machine (tag pushed, branch pushed, merge
# request, release). A re-run walks all five sections again — that is the point,
# they check each other — but every question comes back with last time's answer
# as its default, and every finished step is recognised instead of redone.
declare -A MEM=()
APP_STATE=""
state_load() {  # state_load <appid>
  local f="$CONF_DIR/apps/$1.conf" k
  APP_STATE="$f"
  [ -f "$f" ] || return 0
  declare -A REM=()
  # shellcheck disable=SC1090
  . "$f" || { warn "could not read $f"; return 0; }
  # anything already answered in this run wins over the file
  for k in "${!REM[@]}"; do
    [ -v "MEM[$k]" ] || MEM["$k"]="${REM[$k]}"
  done
}
state_save() {
  { [ "$SAVE" = 1 ] && [ -n "$APP_STATE" ]; } || return 0
  local k
  mkdir -p "${APP_STATE%/*}"
  {
    printf '# store-submit.sh fdroid — remembered for %s\n' "${APPID:-?}"
    printf '# delete this file, or run --forget-app, to start the app afresh\n'
    for k in "${!MEM[@]}"; do printf 'REM[%s]=%q\n' "$k" "${MEM[$k]}"; done
  } > "$APP_STATE.tmp" && mv "$APP_STATE.tmp" "$APP_STATE"
  chmod 600 "$APP_STATE" 2>/dev/null || true
}
remember() { MEM["$1"]="$2"; state_save; }
recall()   { printf '%s' "${MEM[$1]:-}"; }
done_with() { [ -n "${MEM[ST_$1]:-}" ]; }

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
# Everything from here on is answered per app, and remembered per app.
state_load "$APPID"
if done_with TAG || done_with BRANCH || done_with MR || done_with RELEASE; then
  step "Where you left off"
  if done_with RUN;     then note "last run: $(recall ST_RUN)"; fi
  if done_with TAG;     then ok "tag pushed: $(recall ST_TAG)"; fi
  if done_with BRANCH;  then ok "branch on your fork: $(recall ST_BRANCH)"; fi
  if done_with MR;      then ok "merge request: $(recall ST_MR)"; fi
  if done_with RELEASE; then ok "release published: $(recall ST_RELEASE)"; fi
  note "each question below offers last time's answer; Enter keeps it"
  note "anything already done is checked, not repeated — and can be redone"
fi
remember ST_RUN "$(date '+%Y-%m-%d %H:%M')"

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
remote_tag_sha() {  # what origin's copy of the tag points at (tag object, as local rev-parse gives)
  [ -n "$ORIGIN" ] || return 0
  git -C "$REPO" ls-remote origin "refs/tags/$1" 2>/dev/null | awk 'NR==1 {print $1}'
}

# --- the release itself
# F-Droid builds a tag and sees only what that tag holds, so the version bump
# and the "what's new" text have to be in the commit *before* it is tagged.
# Offered when the source version is already tagged and work has moved on: the
# commits since then cannot reach anyone without a new version.
log_notes() {  # log_notes <since-ref> — "- subject" lines, newest last
  if [ -n "$1" ]; then
    git -C "$REPO" log --reverse --no-merges --pretty=format:'- %s' "$1..HEAD"
  else
    git -C "$REPO" log --reverse --no-merges --pretty=format:'- %s' -20
  fi
  printf '\n'
}

# where the version lives, and what the next one would be
VER_FILE=""; VER_KIND=""
if [ -n "$PUB_REL" ] && [ -f "$REPO/$PUB_REL" ]; then VER_FILE="$REPO/$PUB_REL"; VER_KIND=pubspec
elif [ -n "$GRADLE_FILE" ] && [ -n "$(gval versionName)" ]; then VER_FILE="$GRADLE_FILE"; VER_KIND=gradle
fi
next_vname() {  # bump the last component: 0.1.0 -> 0.1.1
  printf '%s' "$1" | awk -F. -v OFS=. '{ $NF = $NF + 1; print }'
}

CUR_TAGGED=0
for t in "v$VNAME" "$VNAME"; do
  git -C "$REPO" rev-parse -q --verify "refs/tags/$t" >/dev/null 2>&1 && { CUR_TAGGED=1; break; }
done
LASTTAG="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null || true)"
AHEAD=0
[ -n "$LASTTAG" ] && AHEAD="$(git -C "$REPO" rev-list --count "$LASTTAG..HEAD" 2>/dev/null || echo 0)"

if [ "$CUR_TAGGED" = 1 ] && [ "$AHEAD" -gt 0 ] && [ -n "$VER_FILE" ] && [ "$DRYRUN" = 0 ]; then
  warn "$AHEAD commit(s) since $LASTTAG, but ${VER_FILE#"$REPO"/} still says $VNAME+$VCODE"
  note "that version is already tagged, so those commits cannot be released as it"
  if confirm "Bump the version and make the release commit?" n; then
    ask NEW_VNAME "New versionName" "$(next_vname "$VNAME")"
    ask NEW_VCODE "New versionCode" "$((VCODE + 1))"

    # --- what's new: F-Droid shows changelogs/<versionCode>.txt from the repo
    FL_BASE="$REPO/fastlane/metadata/android/en-US"
    [ -n "$FLUTTER_DIR" ] && [ "$FLUTTER_DIR" != "." ] \
      && [ -d "$REPO/$FLUTTER_DIR/fastlane" ] && FL_BASE="$REPO/$FLUTTER_DIR/fastlane/metadata/android/en-US"
    NOTES="$WORK/release-notes.txt"
    log_notes "$LASTTAG" > "$NOTES"
    say "Release notes, from the $AHEAD commit(s) since $LASTTAG:"
    printf '%s' "$DIM"; sed 's/^/   | /' "$NOTES"; printf '%s' "$R"
    if [ "$ASSUME_YES" = 0 ] && confirm "Edit them before committing?" n; then
      "${EDITOR:-${VISUAL:-vi}}" "$NOTES" || warn "editor exited non-zero — using the text as it stands"
    fi
    mkdir -p "$FL_BASE/changelogs"
    # With an ABI split, F-Droid publishes 1000/2000/4000 + versionCode, and
    # looks for a changelog named after the code it actually publishes. Which
    # split is used is settled later, so write every name it might look for —
    # the ones that never exist are simply ignored.
    CL_CODES="$NEW_VCODE"
    [ -n "$FLUTTER_DIR" ] && CL_CODES="$NEW_VCODE $((1000 + NEW_VCODE)) $((2000 + NEW_VCODE)) $((4000 + NEW_VCODE))"
    for c in $CL_CODES; do cp "$NOTES" "$FL_BASE/changelogs/$c.txt"; done
    ok "wrote ${FL_BASE#"$REPO"/}/changelogs/{$(echo "$CL_CODES" | tr ' ' ',')}.txt"

    # --- the bump itself
    case "$VER_KIND" in
      pubspec)
        awk -v v="$NEW_VNAME+$NEW_VCODE" 'BEGIN{done=0}
          !done && /^version:[[:space:]]/ { print "version: " v; done=1; next } { print }' \
          "$VER_FILE" > "$VER_FILE.new" && mv "$VER_FILE.new" "$VER_FILE" ;;
      gradle)
        awk -v n="$NEW_VNAME" -v c="$NEW_VCODE" 'BEGIN{dn=0;dc=0}
          !dn && sub(/versionName[[:space:]]*=?[[:space:]]*"[^"]*"/, "versionName = \"" n "\"") { dn=1 }
          !dc && sub(/versionCode[[:space:]]*=?[[:space:]]*[0-9]+/, "versionCode = " c) { dc=1 }
          { print }' "$VER_FILE" > "$VER_FILE.new" && mv "$VER_FILE.new" "$VER_FILE" ;;
    esac
    git -C "$REPO" --no-pager diff --stat -- "${VER_FILE#"$REPO"/}" | sed 's/^/     /'
    git -C "$REPO" --no-pager diff -- "${VER_FILE#"$REPO"/}" | grep -E '^[-+]version|^[-+].*version(Name|Code)' | sed 's/^/     /'

    auto RELMSG "Commit message" "Release $NEW_VNAME+$NEW_VCODE"
    if go "Commit the bump and the changelog?"; then
      git -C "$REPO" add -- "${VER_FILE#"$REPO"/}" "${FL_BASE#"$REPO"/}/changelogs"
      git -C "$REPO" commit -q -m "$RELMSG" || die "the release commit failed"
      HEAD_SHORT="$(git -C "$REPO" rev-parse --short HEAD)"
      ok "committed $RELMSG ($HEAD_SHORT)"
      VNAME="$NEW_VNAME"; VCODE="$NEW_VCODE"
      if go "Push the commit to origin?"; then
        git -C "$REPO" push origin HEAD || warn "could not push — the tag push below will fail too"
      fi
    else
      git -C "$REPO" checkout -- "${VER_FILE#"$REPO"/}" 2>/dev/null || true
      warn "reverted the version bump; the changelog files are left in place"
    fi
  fi
fi

# Prefer an existing v<version> or <version> tag; else the usual v<version>.
TAG_GUESS="v$VNAME"
for t in "v$VNAME" "$VNAME"; do
  if git -C "$REPO" rev-parse -q --verify "refs/tags/$t" >/dev/null 2>&1; then TAG_GUESS="$t"; break; fi
done
auto TAG "Release tag" "$TAG_GUESS"

HEAD_SHORT="$(git -C "$REPO" rev-parse --short HEAD)"
TAG_MOVED=0
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
    git -C "$REPO" push origin "refs/tags/$TAG" || die "could not push tag $TAG"
    ok "tagged and pushed $TAG"
    TAG_MOVED=1; remember ST_TAG "$TAG"
  else
    die "F-Droid needs the release tag — create and push $TAG, then re-run"
  fi
elif ! ref_matches "$TAG"; then
  # The classic slip: a tag made before the last change (ID, version…).
  warn "tag $TAG builds '$(ref_appid "$TAG")' $(ref_version "$TAG"), not '$APPID' $VNAME+$VCODE"
  if ref_matches HEAD && [ "$DRYRUN" = 0 ] \
     && confirm "Move $TAG to HEAD ($HEAD_SHORT) and force-push it? (only if it isn't published yet)" n; then
    git -C "$REPO" tag -f "$TAG" HEAD >/dev/null
    git -C "$REPO" push -f origin "refs/tags/$TAG" || die "could not push tag $TAG"
    ok "moved $TAG to $HEAD_SHORT"
    TAG_MOVED=1; remember ST_TAG "$TAG"
  else
    die "tag $TAG doesn't hold this release — move it or bump the version"
  fi
elif ! tag_on_remote "$TAG"; then
  warn "tag $TAG is not on origin yet — F-Droid would not find it"
  if [ "$DRYRUN" = 1 ]; then
    warn "dry run — would push tag $TAG"
  elif go "Push tag $TAG to origin?"; then
    git -C "$REPO" push origin "refs/tags/$TAG" || die "could not push tag $TAG"
    ok "pushed $TAG"
    remember ST_TAG "$TAG"
  else
    die "push the tag first: git push origin $TAG"
  fi
elif [ -n "$(remote_tag_sha "$TAG")" ] \
     && [ "$(remote_tag_sha "$TAG")" != "$(git -C "$REPO" rev-parse "$TAG" 2>/dev/null)" ]; then
  # Your local tag was moved but origin still has the old one. F-Droid builds
  # origin's copy, so this is the one that decides what gets built.
  warn "origin's $TAG is not your $TAG"
  note "origin: $(remote_tag_sha "$TAG" | cut -c1-12)   local: $(git -C "$REPO" rev-parse "$TAG" | cut -c1-12)"
  if [ "$DRYRUN" = 1 ]; then
    warn "dry run — would delete $TAG on origin and push yours"
  elif go "Delete $TAG on origin and push yours in its place?"; then
    git -C "$REPO" push origin ":refs/tags/$TAG" || die "could not delete $TAG on origin"
    git -C "$REPO" push origin "refs/tags/$TAG"  || die "could not push $TAG"
    ok "replaced $TAG on origin"
    TAG_MOVED=1; remember ST_TAG "$TAG"
  else
    die "F-Droid would build origin's $TAG, which is not this release"
  fi
else
  ok "tag $TAG is pushed and holds $APPID $VNAME+$VCODE"
  remember ST_TAG "$TAG"
fi
# fdroiddata wants the full commit hash in `commit:`, not the tag name.
COMMIT="$(git -C "$REPO" rev-list -n1 "$TAG" 2>/dev/null || true)"
[ -n "$COMMIT" ] || COMMIT="$TAG"

# --- a published release on the forge
# The metadata's Changelog: field points at the releases page, and a tag alone
# does not put anything there. Offered once the tag is pushed, because that is
# what a release is made from.
FORGE=""; FORGE_CLI=""
case "$ORIGIN" in
  *github.com[:/]*) FORGE=github; have gh   && gh auth status   >/dev/null 2>&1 && FORGE_CLI=gh ;;
  *gitlab.com[:/]*) FORGE=gitlab; have glab && glab auth status --hostname gitlab.com >/dev/null 2>&1 && FORGE_CLI=glab ;;
esac
release_exists() {
  case "$FORGE_CLI" in
    gh)   ( cd "$REPO" && gh release view "$TAG" >/dev/null 2>&1 ) ;;
    glab) ( cd "$REPO" && glab release view "$TAG" >/dev/null 2>&1 ) ;;
    *)    return 1 ;;
  esac
}
if [ "$DRYRUN" = 0 ] && [ -n "$FORGE_CLI" ]; then
  NEED_RELEASE=1
  if release_exists; then
    remember ST_RELEASE "$TAG"
    if [ "$TAG_MOVED" = 1 ]; then
      # the release still names the tag, but the tag is a different commit now
      warn "$FORGE has a release for $TAG, and the tag moved in this run"
      if go "Delete that release and publish it again from the new tag?"; then
        case "$FORGE_CLI" in
          gh)   ( cd "$REPO" && gh release delete "$TAG" --yes ) >/dev/null 2>&1 || warn "could not delete the release" ;;
          glab) ( cd "$REPO" && glab release delete "$TAG" --yes ) >/dev/null 2>&1 || warn "could not delete the release" ;;
        esac
        if release_exists; then
          warn "the old release is still there — publish by hand"
          NEED_RELEASE=0
        fi
      else
        NEED_RELEASE=0
      fi
    else
      ok "$FORGE already has a release for $TAG"
      NEED_RELEASE=0
    fi
  fi
  if [ "$NEED_RELEASE" = 1 ]; then
    if ! release_exists; then
      warn "$TAG is a tag, but $FORGE has no release for it"
    fi
    note "your Changelog: URL points at the releases page, which is empty until one exists"
    if go "Publish a release for $TAG on $FORGE?"; then
      RELNOTES="$WORK/forge-notes.txt"
      # prefer the changelog F-Droid will show, so both say the same thing
      if [ -n "${FL_BASE:-}" ] && [ -f "$FL_BASE/changelogs/$VCODE.txt" ]; then
        cp "$FL_BASE/changelogs/$VCODE.txt" "$RELNOTES"
      else
        PREVTAG="$(git -C "$REPO" describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
        if [ -n "$PREVTAG" ]; then
          git -C "$REPO" log --reverse --no-merges --pretty=format:'- %s' "$PREVTAG..$TAG" > "$RELNOTES"
        else
          git -C "$REPO" log --reverse --no-merges --pretty=format:'- %s' -20 "$TAG" > "$RELNOTES"
        fi
        printf '\n' >> "$RELNOTES"
      fi
      printf '%s' "$DIM"; sed 's/^/   | /' "$RELNOTES"; printf '%s' "$R"
      REL_OUT=""
      case "$FORGE_CLI" in
        gh)   REL_OUT="$( cd "$REPO" && gh release create "$TAG" --title "$TAG" \
                            --notes-file "$RELNOTES" 2>&1 || true )" ;;
        glab) REL_OUT="$( cd "$REPO" && glab release create "$TAG" --name "$TAG" \
                            --notes "$(cat "$RELNOTES")" 2>&1 || true )" ;;
      esac
      if release_exists; then
        ok "release published: ${WEB_GUESS:+$WEB_GUESS/releases/tag/$TAG}"
        remember ST_RELEASE "$TAG"
      else
        warn "$FORGE_CLI did not publish the release:"
        printf '%s\n' "$REL_OUT" | tail -5 | sed 's/^/       /'
        [ -n "$WEB_GUESS" ] && note "do it by hand: $WEB_GUESS/releases/new?tag=$TAG"
      fi
    fi
  fi
elif [ -n "$FORGE" ] && [ "$DRYRUN" = 0 ]; then
  note "no $FORGE CLI logged in — a release for $TAG would have to be published by hand"
fi

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

# Screenshots and icon: optional, but a listing without them looks abandoned.
# Same fastlane tree, same rule — F-Droid only sees what the build tag holds.
IMGDIR=""
for d in "$FASTLANE/images" \
         ${FLUTTER_DIR:+"$REPO/$FLUTTER_DIR/fastlane/metadata/android/en-US/images"}; do
  [ -d "$d" ] && { IMGDIR="$d"; break; }
done
SHOTS=0
[ -n "$IMGDIR" ] && SHOTS="$(find "$IMGDIR" -type f \
  \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -path '*creenshots/*' 2>/dev/null | wc -l)"
if [ "${SHOTS:-0}" -gt 0 ]; then
  ok "$SHOTS screenshot(s) in ${IMGDIR#"$REPO"/}"
  [ -f "$IMGDIR/icon.png" ] || note "no images/icon.png — F-Droid falls back to the app's launcher icon"
else
  warn "no screenshots — your F-Droid listing will show none"
  note "PNGs go in fastlane/metadata/android/en-US/images/phoneScreenshots/,"
  note "alongside icon.png and featureGraphic.png; commit them under the build tag"
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
# what this app used last time beats a guess at where the clone might live
FD_DEF="${SAVED_FDROIDDATA:-$(recall FDROIDDATA)}"
ask FDROIDDATA "Local clone of fdroiddata" "${FD_DEF:-$HOME/fdroiddata}"
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

# glab works out which project it is acting on partly from the current
# directory's git remotes, even when -R and -H name the projects. The wizard's
# own cwd is the app's checkout, whose remote is usually GitHub, and glab then
# gives up with "None of the git remotes configured for this repository point
# to a known GitLab host. Configured remotes: github.com". Run it from the
# fdroiddata clone instead: both of its remotes are gitlab.com, and the branch
# being proposed actually exists there.
glab_fd() {
  if [ -d "${FDROIDDATA:-}/.git" ]; then
    ( cd "$FDROIDDATA" && glab "$@" )
  else
    glab "$@"
  fi
}

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
  CLONE_T0=$SECONDS
  if ! git clone --filter=blob:none -o upstream "$FDROIDDATA_UPSTREAM" "$FDROIDDATA"; then
    die "could not clone $FDROIDDATA_UPSTREAM — check your connection and re-run"
  fi
  git -C "$FDROIDDATA" remote add origin "$FORKURL"
  ok "cloned in $((SECONDS - CLONE_T0))s; your fork is 'origin' (for pushing), fdroid's repo is 'upstream'"
fi

git -C "$FDROIDDATA" remote get-url upstream >/dev/null 2>&1 || \
  git -C "$FDROIDDATA" remote add upstream "$FDROIDDATA_UPSTREAM"
say "fetching upstream (git prints its own progress below)…"
FETCH_T0=$SECONDS
git -C "$FDROIDDATA" fetch upstream || die "could not fetch upstream fdroiddata"
ok "fetched upstream ($((SECONDS - FETCH_T0))s)"

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
# Earlier attempts leave branches behind on the fork — a different versionCode,
# an abandoned try, a rejected merge request. They confuse nobody but you, and
# GitLab keeps offering to open merge requests from them.
if [ "$DRYRUN" = 0 ]; then
  STALE="$(git -C "$FDROIDDATA" ls-remote --heads origin "$APPID*" 2>/dev/null \
            | sed -n 's,.*refs/heads/,,p' | grep -vx "$BRANCH" || true)"
  if [ -n "$STALE" ]; then
    warn "older branches for this app on your fork:"
    printf '%s\n' "$STALE" | sed 's/^/       /'
    note "delete them only once their merge requests are closed or merged"
    if confirm "Delete them from your fork?" n; then
      for b in $STALE; do
        if git -C "$FDROIDDATA" push origin --delete "$b" >/dev/null 2>&1; then
          ok "deleted $b"
        else
          warn "could not delete $b"
        fi
      done
    fi
  fi
fi

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
  # --- license: always asked, with what the repo says as the default.
  # Remembered answers only count for the same app.
  LIC_GUESS=""; LIC_FROM=""
  if [ "${SAVED_LICENSE_APP:-}" = "$APPID" ] && [ -n "${SAVED_LICENSE:-}" ]; then
    LIC_GUESS="$SAVED_LICENSE"; LIC_FROM="your answer last time"
  fi
  if [ -z "$LIC_GUESS" ]; then
    for f in LICENSE LICENSE.md LICENSE.txt LICENCE LICENCE.md COPYING COPYING.md; do
      [ -f "$REPO/$f" ] || continue
      # Only the head: the GPL-3.0 text itself mentions the Affero license
      # (section 13), so matching the whole file calls every GPL app AGPL.
      head -n 30 "$REPO/$f" > "$WORK/license.head"
      LH="$WORK/license.head"
      GNU=""
      if   grep -qi "GNU AFFERO GENERAL PUBLIC LICENSE" "$LH"; then GNU="AGPL-3.0"
      elif grep -qi "GNU LESSER GENERAL PUBLIC LICENSE" "$LH"; then
        if grep -q "Version 2.1" "$LH"; then GNU="LGPL-2.1"; else GNU="LGPL-3.0"; fi
      elif grep -qi "GNU GENERAL PUBLIC LICENSE" "$LH"; then
        if grep -q "Version 3" "$LH"; then GNU="GPL-3.0"; else GNU="GPL-2.0"; fi
      elif grep -qi "Apache License" "$LH";        then LIC_GUESS="Apache-2.0"
      elif grep -qi "MIT License" "$LH";           then LIC_GUESS="MIT"
      elif grep -qi "Mozilla Public License" "$LH"; then LIC_GUESS="MPL-2.0"
      elif grep -qi "Redistribution and use in source" "$LH"; then LIC_GUESS="BSD-3-Clause"
      elif grep -qi "This is free and unencumbered" "$LH"; then LIC_GUESS="Unlicense"
      fi
      if [ -n "$GNU" ]; then
        # The license text is the same for "-only" and "-or-later"; the
        # difference is in the notices in the source files.
        if git -C "$REPO" grep -qi "any later version" -- ':!LICENSE*' ':!LICENCE*' ':!COPYING*' 2>/dev/null; then
          LIC_GUESS="$GNU-or-later"; LIC_FROM="$f; source files say \"any later version\""
        else
          LIC_GUESS="$GNU-only"; LIC_FROM="$f; no \"any later version\" notice in the source"
        fi
      elif [ -n "$LIC_GUESS" ]; then
        LIC_FROM="$f"
      fi
      [ -n "$LIC_GUESS" ] && break
    done
  fi
  if [ -n "$LIC_GUESS" ]; then
    note "license from $LIC_FROM — Enter keeps it, or type another SPDX id"
    case "$LIC_GUESS" in *GPL*) note "(GPL-3.0-only and GPL-3.0-or-later are different licenses: pick the one you mean)" ;; esac
  else
    note "no license found — SPDX identifier, e.g. GPL-3.0-only, Apache-2.0, MIT, AGPL-3.0-only"
  fi
  ask LICENSE "License" "$LIC_GUESS"

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
  # The email is published in fdroiddata: always asked, never assumed.
  if [ -n "${SAVED_AUTHOREMAIL:-}" ]; then MAIL_GUESS="$SAVED_AUTHOREMAIL"; MAIL_FROM="your answer last time"
  else MAIL_GUESS="$(git -C "$REPO" config user.email 2>/dev/null || echo "")"; MAIL_FROM="your git identity (git config user.email)"; fi
  [ -n "$MAIL_GUESS" ] && note "email from $MAIL_FROM — it will be public in fdroiddata; Enter keeps it, - leaves it out"
  ask_opt AUTHOREMAIL "AuthorEmail" "$MAIL_GUESS"
  [ -n "$AUTHOREMAIL" ] && ok "AuthorEmail: $AUTHOREMAIL" || ok "no AuthorEmail"
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

  # --- auto-update
  # fdroiddata's schema allows only None, Version, or "Version +suffix"
  # (schemas/metadata.json: ^(None|Version( \+.+)?)$). The old tag-pattern form
  # "Version v%v" is gone: with UpdateCheckMode Tags, fdroidserver reuses the
  # tag it actually found, whatever that tag is called.
  AUM_RE='^(None|Version( \+.+)?)$'
  AUM="Version"
  case "$TAG" in
    "$VNAME"|"v$VNAME") ;;
    *)
      warn "tag '$TAG' is neither '$VNAME' nor 'v$VNAME'"
      note "UpdateCheckMode: Tags takes the newest tag whatever it is called, so"
      note "'Version' still works; answer None to update the metadata by hand"
      while :; do
        ask_opt AUM "AutoUpdateMode (Version, None, or 'Version +suffix')" "Version"
        AUM="${AUM:-None}"
        printf '%s' "$AUM" | grep -qE "$AUM_RE" && break
        warn "fdroiddata's schema only accepts None, Version, or 'Version +suffix'"
      done ;;
  esac

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
  # fdroidserver complains about this on every single command it runs.
  if [ -f "$FDROIDDATA/config.yml" ]; then
    case "$(stat -c '%a' "$FDROIDDATA/config.yml" 2>/dev/null || echo 600)" in
      *00) ;;
      *) chmod 600 "$FDROIDDATA/config.yml" && note "chmod 600 config.yml (fdroidserver insists)" ;;
    esac
  fi

  # readmeta takes no app argument: it parses every metadata/*.yml in the clone.
  # So an unrelated upstream entry — typically one written for a newer
  # fdroidserver than the one installed here — fails it, which says nothing
  # about our file. Only count it when the complaint names our app.
  say "fdroid readmeta"
  if ! frun readmeta > "$WORK/readmeta.log" 2>&1; then
    sed 's/^/     /' "$WORK/readmeta.log"
    if grep -Fq "$APPID" "$WORK/readmeta.log"; then
      VALID_FAIL="$VALID_FAIL readmeta"
    else
      warn "readmeta tripped over another app in fdroiddata, not $APPID"
      note "an upstream entry your fdroidserver is too old to parse — not your problem"
      note "rewritemeta and lint below only look at your app, so trust those"
    fi
  fi
  say "fdroid rewritemeta $APPID"; frun rewritemeta "$APPID" || VALID_FAIL="$VALID_FAIL rewritemeta"
  say "fdroid lint $APPID";        frun lint "$APPID"        || VALID_FAIL="$VALID_FAIL lint"

  # fdroiddata's CI validates every changed file against schemas/metadata.json
  # before anything else. lint does not do this, so a file that passes lint can
  # still be rejected minutes later; run the same check here.
  SCHEMA="$FDROIDDATA/schemas/metadata.json"
  if [ ! -f "$SCHEMA" ]; then
    note "no schemas/metadata.json in the clone — skipping the schema check"
  elif have check-jsonschema; then
    say "check-jsonschema metadata/$APPID.yml"
    ( cd "$FDROIDDATA" && check-jsonschema --schemafile schemas/metadata.json \
        "metadata/$APPID.yml" ) || VALID_FAIL="$VALID_FAIL schema"
  elif python3 -c 'import jsonschema, yaml' 2>/dev/null; then
    say "validating against schemas/metadata.json (python jsonschema)"
    python3 - "$SCHEMA" "$FDROIDDATA/metadata/$APPID.yml" <<'PYSCHEMA' || VALID_FAIL="$VALID_FAIL schema"
import json, sys, jsonschema, yaml
schema = json.load(open(sys.argv[1]))
doc = yaml.safe_load(open(sys.argv[2]))
errors = sorted(jsonschema.Draft7Validator(schema).iter_errors(doc), key=lambda e: list(e.path))
for e in errors:
    print("   $." + ".".join(str(p) for p in e.path) + ": " + e.message)
sys.exit(1 if errors else 0)
PYSCHEMA
  else
    note "no check-jsonschema — CI validates against schemas/metadata.json, you cannot"
    note "install it with: pipx install check-jsonschema   (or nix profile install nixpkgs#check-jsonschema)"
  fi
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
      printf '<!-- filled in by store-submit.sh fdroid from the RFP template -->\n\n'
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
      RFP_URL="$(glab_fd issue create -R "$RFP_PROJECT" --title "$RFP_NAME" \
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

# fdroiddata is a very large repo and the first push to a fresh fork can send a
# lot of history. Dropping -q is the whole trick: git then reports its own
# progress on a terminal. Foreground on purpose, so an SSH key passphrase or a
# host-key prompt can still reach you.
say "pushing $BRANCH to your fork — the slowest step here."
note "fdroiddata is huge; the first push to a new fork can take a few minutes."
note "git's own progress follows; leave it be until it finishes."
PUSH_T0=$SECONDS
# A re-run for the same app/version replaces the branch it pushed before.
if ! git -C "$FDROIDDATA" push -f -u origin "$BRANCH"; then
  warn "could not push to $FORKURL"
  note "check with: ssh -T git@gitlab.com   (it should greet @$GLUSER), then re-run"
  die "push failed"
fi
ok "pushed $BRANCH ($((SECONDS - PUSH_T0))s)"
remember ST_BRANCH "$BRANCH"

# A re-run pushes the same branch again, and GitLab updates any open merge
# request from it by itself. Creating a second one is impossible and reporting
# a failure would be wrong, so look first.
existing_mr() {
  gitlab_get "projects/fdroid%2Ffdroiddata/merge_requests?state=opened&source_branch=$(urlencode "$BRANCH")" \
    | grep -Eo 'https://[^"]*/-/merge_requests/[0-9]+' | head -1
}
MR_URL=""
MR_OPEN="$(existing_mr || true)"
if [ -n "$MR_OPEN" ]; then
  MR_URL="$MR_OPEN"
  ok "a merge request from $BRANCH is already open — the push above updated it"
  ok "$MR_URL"
  remember ST_MR "$MR_URL"
  note "CI re-runs on the new commit; nothing else to do here"
elif glab_ready && go "Open the merge request on fdroid/fdroiddata?"; then
  mr_description > "$WORK/mr.md"
  MR_OUT="$(glab_fd mr create -R fdroid/fdroiddata -H "$(fork_path "$FORKURL")" \
              -s "$BRANCH" -b "$UPBRANCH" -t "$COMMITMSG" \
              -d "$(cat "$WORK/mr.md")" --allow-collaboration -y 2>&1 || true)"
  MR_URL="$(printf '%s\n' "$MR_OUT" | grep -Eo 'https://[^ ]+/-/merge_requests/[0-9]+' | tail -1 || true)"
  if [ -n "$MR_URL" ]; then
    ok "merge request: $MR_URL"
    remember ST_MR "$MR_URL"
  else
    warn "glab did not open the merge request:"
    printf '%s\n' "$MR_OUT" | tail -5 | sed 's/^/       /'
    note "to retry by hand: cd $FDROIDDATA && glab mr create -R fdroid/fdroiddata \\"
    note "     -H $(fork_path "$FORKURL") -s $BRANCH -b $UPBRANCH -t \"$COMMITMSG\""
    note "the link below does the same thing in a browser"
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
}

# ##########################################################################
#   Google Play wizard — store-submit.sh play [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_play() {
#
# store-submit.sh play — push an Android release to Google Play from the command line.
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
store-submit.sh play — upload an Android release to Google Play (Publisher API v3).

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
    printf '# written by store-submit.sh play — safe to delete (or run --forget)\n'
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
# its outputs to <flutter dir>/build/app/outputs (same detection as store-submit.sh fdroid).
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

gval() {  # same detection as store-submit.sh fdroid: Kotlin or Groovy DSL, no comments
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
}

# ##########################################################################
#   shared by the Linux wizards — linux_common (helpers) and linux_app (the
#   "Your app" stage); bodies unindented like the wizards'
# ##########################################################################
linux_common() {
# Shared by the Linux wizards (linux, nix, aur): presentation, questions, the
# scratch directory and small helpers. Call it once, after the wizard has
# parsed its options; $WIZ_NAME names the scratch directory.

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
bad()   { printf '   %s✗ %s%s\n' "$RED" "$*" "$R"; }
die()   { printf '\n%sERROR: %s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

# This is a wizard: without someone to answer, there is nothing sensible to do.
readline() {  # readline VAR — dies on EOF instead of spinning
  IFS= read -r "$1" && return 0
  printf '\n' >&2
  die "end of input — this script needs an interactive terminal (or --yes)"
}

# ask VAR "question" "default"   — empty default means required
ask() {
  local __var="$1" __q="$2" __def="${3-}" __in=""
  if [ "$ASSUME_YES" = 1 ]; then
    [ -n "$__def" ] || die "--yes: nothing to answer \"$__q\" with — run once without --yes"
    printf -v "$__var" '%s' "$__def"; ok "$__q: $__def"; return 0
  fi
  while :; do
    if [ -n "$__def" ]; then printf '   %s%s%s [%s]: ' "$B" "$__q" "$R" "$__def" >&2
    else printf '   %s%s%s: ' "$B" "$__q" "$R" >&2; fi
    readline __in
    [ -z "$__in" ] && __in="$__def"
    if [ -z "$__in" ]; then printf '   %sthis one is required%s\n' "$YLW" "$R" >&2; continue; fi
    break
  done
  printf -v "$__var" '%s' "$__in"
}

ask_opt() {  # like ask, but blank is allowed; "-" clears a default
  local __var="$1" __q="$2" __def="${3-}" __in=""
  if [ "$ASSUME_YES" = 1 ]; then printf -v "$__var" '%s' "$__def"; return 0; fi
  printf '   %s%s%s%s: ' "$B" "$__q" "$R" "${__def:+ [$__def, - for none]}" >&2
  readline __in
  [ -z "$__in" ] && __in="$__def"
  [ "$__in" = - ] && __in=""
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

# go "question" — for the actions that leave your machine (tag, fork, push, PR):
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

# ---------------------------------------------------------------- scratch space
WORK="$(mktemp -d "${TMPDIR:-/tmp}/$WIZ_NAME.XXXXXX")"
KEEP_WORK=0
BG_PID=""
cleanup() {
  # a build or clone running under the progress line must not outlive us
  [ -n "$BG_PID" ] && kill "$BG_PID" 2>/dev/null || true
  if [ "$KEEP_WORK" = 1 ]; then
    printf '   %slogs kept in %s%s\n' "$DIM" "$WORK" "$R"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# run_logged <log> "label" cmd... — runs cmd with its output in <log>, showing
# a one-line live view of the latest output line; returns cmd's exit status.
run_logged() {
  local log="$1" label="$2" rc=0 line width i=0 spin='|/-\'
  shift 2
  : > "$log"
  if [ ! -t 1 ]; then
    say "$label…"
    "$@" >"$log" 2>&1 || rc=$?
    return "$rc"
  fi
  "$@" >"$log" 2>&1 &
  BG_PID=$!
  width=$(( $(tput cols 2>/dev/null || echo 80) - ${#label} - 10 ))
  [ "$width" -gt 10 ] || width=10
  while kill -0 "$BG_PID" 2>/dev/null; do
    line="$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' | tr '\t' ' ' | cut -c1-"$width")"
    printf '\r\033[K   %s %s%s%s %s%s%s' "${spin:i%4:1}" "$B" "$label" "$R" "$DIM" "$line" "$R"
    i=$((i + 1))
    sleep 0.25
  done
  wait "$BG_PID" || rc=$?
  BG_PID=""
  printf '\r\033[K'
  return "$rc"
}

# nix_str <text> — escaped for use inside a "…" Nix string
nix_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\${/\\${/g'; }

NIX_FLAKES=0
# tool <nixpkgs attr> <command> [args...] — run a command, fetched from nixpkgs
# when it isn't installed, so a missing helper never stops the wizard.
tool() {
  local attr="$1" cmd="$2" p d
  shift
  # a different `yq` (the Python one) doesn't take yq-go's arguments
  if have "$cmd" && { [ "$cmd" != yq ] || yq --version 2>&1 | grep -q mikefarah; }; then "$@"; return; fi
  for d in $(nix_tool_paths "$attr"); do
    [ -x "$d/bin/$cmd" ] && { p="$d"; break; }
  done
  [ -n "${p:-}" ] || { printf 'could not get %s from nixpkgs\n' "$attr" >&2; return 127; }
  shift
  "$p/bin/$cmd" "$@"
}
nix_tool_paths() {  # nix_tool_paths <attr> — its store paths, built/fetched if needed
  if [ "$NIX_FLAKES" = 1 ]; then nix build --no-link --print-out-paths "nixpkgs#$1" 2>/dev/null
  elif nix-instantiate --find-file nixpkgs >/dev/null 2>&1; then nix-build '<nixpkgs>' -A "$1" --no-out-link 2>/dev/null
  else nix-build "${NIXPKGS:?}" -A "$1" --no-out-link 2>/dev/null; fi
}

gh_ready() { gh auth status --hostname github.com >/dev/null 2>&1; }

{ nix config show experimental-features 2>/dev/null || nix show-config 2>/dev/null; } \
  | grep -qw flakes && NIX_FLAKES=1

# --- the hand-off: what a person has to finish (stores that don't take
# automated submissions). Shown as a boxed to-do list, kept in the cache, and
# passed up to `store-submit.sh linux` for its summary.
handoff_add() { printf '%s\n' "$*" >> "$WORK/handoff.txt"; }
handoff_show() {  # handoff_show "title" [link]
  local title="$1" link="${2-}" n=0 l out
  out="${XDG_CACHE_HOME:-$HOME/.cache}/store-submit/todo-$WIZ_NAME.txt"
  mkdir -p "$(dirname "$out")"
  { printf '%s\n' "$title"
    [ -f "$WORK/handoff.txt" ] && awk '{ printf "  %d. %s\n", NR, $0 }' "$WORK/handoff.txt"
    [ -n "$link" ] && printf '\n  %s\n' "$link"; } > "$out"
  printf '\n   %s┏━━ %s%s\n' "$B$YLW" "$title" "$R"
  if [ -f "$WORK/handoff.txt" ]; then
    while IFS= read -r l; do n=$((n + 1)); printf '   %s┃%s %d. %s\n' "$YLW" "$R" "$n" "$l"; done < "$WORK/handoff.txt"
  fi
  [ -n "$link" ] && printf '   %s┃%s\n   %s┃%s    %s%s%s\n' "$YLW" "$R" "$YLW" "$R" "$B" "$link" "$R"
  printf '   %s┗━━%s %s(also in %s)%s\n\n' "$YLW" "$R" "$DIM" "$out" "$R"
  if [ -n "${SS_HANDOFF_DIR:-}" ]; then mkdir -p "$SS_HANDOFF_DIR"; cp "$out" "$SS_HANDOFF_DIR/$WIZ_NAME.txt"; fi
}

# --- the shared config: one set of answers about the app, used by every
# distro. A plain `key = value` file in the app's repository (read, never
# executed), so it can be edited by hand and committed with the app.
cfg_get() {  # cfg_get <key> — its value, or nothing
  [ -n "${LINUX_CONF:-}" ] && [ -f "$LINUX_CONF" ] || return 0
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" "$LINUX_CONF" | tail -1
}
cfg_set() {  # cfg_set <key> <value> — update or add a line; blank values are left out
  local f="$LINUX_CONF" k="$1" v="$2"
  [ -f "$f" ] || {
    printf '# store-submit.sh — what the Linux packages say about this app.\n'
    printf '# One set of answers for every distro; edit freely, commit it with the app.\n'
    printf '# The version and release tag come from each release, not from here.\n\n'
  } > "$f"
  if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$f"; then
    awk -v k="$k" -v v="$v" '$0 ~ "^[[:space:]]*" k "[[:space:]]*=" { if (v != "") print k " = " v; next } { print }' "$f" > "$f.new" && mv "$f.new" "$f"
  elif [ -n "$v" ]; then
    printf '%s = %s\n' "$k" "$v" >> "$f"
  fi
}
}

linux_app() {
# "Your app" — the stage every Linux wizard starts with: works out the app,
# asks what it can't, makes sure the release tag is pushed, and keeps the
# answers in the shared config. $1 is the step label. Sets the globals the
# wizards build on (REPO, KIND, VERSION, PNAME, TAG, SPDX, DESC, …).
step "$1"

# The app repo: --repo, else the git repo you run this from (unless that's
# this script's own), else the one from last time.
SELF_REPO="$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel 2>/dev/null || true)"
HERE_REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ "$HERE_REPO" = "$SELF_REPO" ] && HERE_REPO=""
REPO_GUESS="${REPO_ARG:-${HERE_REPO:-${SAVED_REPO:-}}}"
FIRST=1
while :; do
  if [ -n "$REPO_ARG" ]; then REPO="$REPO_ARG"
  elif [ "$FIRST" = 1 ]; then auto REPO "App repository" "$REPO_GUESS"
  else ask REPO "Path to the app's git checkout" ""; fi
  FIRST=0
  REPO="${REPO/#\~/$HOME}"
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 && break
  [ -n "$REPO_ARG" ] || [ "$ASSUME_YES" = 1 ] && die "$REPO is not a git checkout"
  warn "$REPO is not a git checkout"
done
REPO="$(cd "$REPO" && git rev-parse --show-toplevel)"

# --- the shared config: answers from last time (or from another distro's run)
LINUX_CONF="${LINUX_CONF:-$REPO/.store-submit.conf}"
[ -f "$LINUX_CONF" ] && ok "config: ${LINUX_CONF#"$REPO"/} — its answers are used as they are"

# --- where does it live? The distros fetch the source from there.
# The URL as configured: `remote get-url` would apply url.*.insteadOf rewrites.
ORIGIN="$(git -C "$REPO" config --get remote.origin.url 2>/dev/null || true)"
[ -n "$ORIGIN" ] || die "no 'origin' remote — Linux distributions build from a public repository: push yours and add it as origin"
HOST="$(printf '%s' "$ORIGIN" | sed -E 's#^[a-z+]+://##; s#^[^@/]+@##; s#[:/].*##')"
SLUG="$(printf '%s' "$ORIGIN" | sed -E 's#^[a-z+]+://##; s#^[^@/]+@##; s#^[^:/]+(:[0-9]+)?[:/]##; s#\.git$##; s#/$##')"
OWNER="${SLUG%/*}"; REPONAME="${SLUG##*/}"
WEB="https://$HOST/$SLUG"
case "$HOST" in
  github.com)   FORGE=github;   FETCHER=fetchFromGitHub ;;
  gitlab.com)   FORGE=gitlab;   FETCHER=fetchFromGitLab ;;
  codeberg.org) FORGE=codeberg; FETCHER=fetchFromCodeberg ;;
  *)            FORGE=git;      FETCHER=fetchgit ;;
esac
ok "source: $WEB"

# --- what the forge knows: public or not, description, homepage, license
FORGE_PRIVATE=""; FORGE_DESC=""; FORGE_HOME=""; FORGE_SPDX=""
forge_json() {
  case "$FORGE" in
    github)   if have gh && gh_ready; then gh api "repos/$SLUG" 2>/dev/null
              else curl -sf --max-time 20 "https://api.github.com/repos/$SLUG"; fi ;;
    gitlab)   curl -sf --max-time 20 "https://gitlab.com/api/v4/projects/$(printf '%s' "$SLUG" | sed 's#/#%2F#g')?license=true" ;;
    codeberg) curl -sf --max-time 20 "https://codeberg.org/api/v1/repos/$SLUG" ;;
    *)        return 1 ;;
  esac
}
if forge_json > "$WORK/forge.json" 2>/dev/null && [ -s "$WORK/forge.json" ]; then
  FORGE_PRIVATE="$(tool jq jq -r '(.private // (.visibility != null and .visibility != "public")) | tostring' < "$WORK/forge.json" 2>/dev/null || true)"
  FORGE_DESC="$(tool jq jq -r '.description // ""' < "$WORK/forge.json" 2>/dev/null || true)"
  FORGE_HOME="$(tool jq jq -r '(.homepage // .website // "")' < "$WORK/forge.json" 2>/dev/null || true)"
  FORGE_SPDX="$(tool jq jq -r '(.license.spdx_id // .license.key // "")' < "$WORK/forge.json" 2>/dev/null || true)"
  [ "$FORGE_PRIVATE" = true ] && die "$WEB is private — distros can only build public sources; make it public first"
  ok "the repository is public"
elif [ "$FORGE" != git ]; then
  if [ "$FORGE" = gitlab ] || [ "$FORGE" = codeberg ]; then
    die "$WEB can't be reached anonymously — distros can only build public sources (is it private?)"
  fi
  warn "could not read $WEB from GitHub's API; carrying on with what the checkout says"
fi

# --- what kind of project? Flutter first: its version lives in pubspec.yaml.
FLUTTER_DIR=""
for p in "$REPO/pubspec.yaml" "$REPO"/*/pubspec.yaml "$REPO"/*/*/pubspec.yaml; do
  [ -f "$p" ] || continue
  grep -qE '^[[:space:]]+sdk:[[:space:]]*flutter' "$p" || continue
  d="$(dirname "$p")"
  FLUTTER_DIR="${d#"$REPO"}"; FLUTTER_DIR="${FLUTTER_DIR#/}"; FLUTTER_DIR="${FLUTTER_DIR:-.}"
  break
done
KIND_GUESS=""
if   [ -n "$FLUTTER_DIR" ];             then KIND_GUESS=flutter
elif [ -f "$REPO/Cargo.toml" ];         then KIND_GUESS=rust
elif [ -f "$REPO/go.mod" ];             then KIND_GUESS=go
elif [ -f "$REPO/package.json" ];       then KIND_GUESS=node
elif [ -f "$REPO/pyproject.toml" ];     then KIND_GUESS=python
elif [ -f "$REPO/meson.build" ];        then KIND_GUESS=meson
elif [ -f "$REPO/CMakeLists.txt" ];     then KIND_GUESS=cmake
elif [ -f "$REPO/Makefile" ];           then KIND_GUESS="make"
fi
[ -n "$(cfg_get build-system)" ] && KIND_GUESS="$(cfg_get build-system)"
[ -n "$KIND_GUESS" ] || note "could not tell the build system — one of: flutter rust go node python meson cmake make"
FIRST=1
while :; do
  if [ "$FIRST" = 1 ]; then auto KIND "Build system" "$KIND_GUESS"
  else ask KIND "Build system (flutter rust go node python meson cmake make)" ""; fi
  FIRST=0
  case "$KIND" in flutter|rust|go|node|python|meson|cmake|make) break ;; esac
  [ "$ASSUME_YES" = 1 ] && die "unknown build system '$KIND'"
  warn "one of: flutter rust go node python meson cmake make"
done
[ "$KIND" = flutter ] && [ -z "$FLUTTER_DIR" ] && die "no Flutter project (pubspec.yaml with the Flutter SDK) found in $REPO"
PROOT="."; [ "$KIND" = flutter ] && PROOT="$FLUTTER_DIR"
pp() { if [ "$PROOT" = . ]; then printf '%s' "$1"; else printf '%s/%s' "$PROOT" "$1"; fi; }

# at <ref> <path> — a file as it is at a git ref ("." = the working tree)
at() {
  if [ "$1" = . ]; then cat "$REPO/$2" 2>/dev/null
  else git -C "$REPO" show "$1:$2" 2>/dev/null; fi
}

# toml_get <section> <key> — a plain `key = "value"` from [section] (TOML on stdin)
toml_get() {
  awk -v sec="[$1]" -v key="$2" '
    /^[[:space:]]*\[/ { cur = $0; gsub(/[[:space:]]/, "", cur); next }
    cur == sec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
      if (v ~ /^"/) { sub(/^"/, "", v); sub(/".*$/, "", v) }
      print v; exit
    }'
}

# version_at <ref> / name_at <ref> — from the project's own manifest
version_at() {
  local v=""
  case "$KIND" in
    flutter) v="$(at "$1" "$(pp pubspec.yaml)" | sed -nE "s/^version:[[:space:]]*[\"']?([^\"'[:space:]+]+).*/\\1/p" | sed -n 1p)" ;;
    rust)    v="$(at "$1" Cargo.toml | toml_get package version)"
             case "$v" in ''|'{'*|true) v="$(at "$1" Cargo.toml | toml_get workspace.package version)" ;; esac ;;
    node)    v="$(at "$1" package.json | tool jq jq -r '.version // ""' 2>/dev/null || true)" ;;
    python)  v="$(at "$1" pyproject.toml | toml_get project version)" ;;
    meson)   v="$(at "$1" meson.build | tr '\n' ' ' | grep -oE "project\([^)]*\)" | head -1 \
                  | grep -oE "version[[:space:]]*:[[:space:]]*'[0-9][^']*'" | sed -E "s/.*'([^']*)'/\\1/")" ;;
    cmake)   v="$(at "$1" CMakeLists.txt | tr '\n' ' ' | grep -oiE "project\([^)]*VERSION[[:space:]]+[0-9][^[:space:])]*" | head -1 \
                  | sed -E 's/.*[[:space:]]([0-9][^[:space:])]*)$/\1/')" ;;
  esac
  printf '%s' "$v"
}
name_at() {
  local n=""
  case "$KIND" in
    flutter) n="" ;;   # pubspec names are Dart identifiers; the repo name reads better
    rust)    n="$(at "$1" Cargo.toml | toml_get package name)" ;;
    node)    n="$(at "$1" package.json | tool jq jq -r '.name // ""' 2>/dev/null | sed 's#^@[^/]*/##' || true)" ;;
    python)  n="$(at "$1" pyproject.toml | toml_get project name)" ;;
    meson)   n="$(at "$1" meson.build | tr '\n' ' ' | grep -oE "project\([[:space:]]*'[^']+'" | head -1 | sed -E "s/.*'([^']+)'/\\1/")" ;;
    cmake)   n="$(at "$1" CMakeLists.txt | grep -oiE "project\([[:space:]]*[A-Za-z0-9_.+-]+" | head -1 | sed -E 's/.*\([[:space:]]*//')" ;;
  esac
  printf '%s' "${n:-$REPONAME}"
}

# --- version: the manifest's, else the latest tag
LAST_TAG="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null || true)"
VERSION_GUESS="$(version_at . || true)"
VERSION_FROM_TAG=0
if [ -z "$VERSION_GUESS" ] && [ -n "$LAST_TAG" ]; then
  VERSION_GUESS="${LAST_TAG#v}"; VERSION_FROM_TAG=1
fi
FIRST=1
while :; do
  if [ "$FIRST" = 1 ]; then auto VERSION "Version" "$VERSION_GUESS"; else ask VERSION "Version" ""; fi
  FIRST=0
  case "$VERSION" in [0-9]*) break ;; esac
  [ "$ASSUME_YES" = 1 ] && die "version '$VERSION' must start with a digit (the distros' rule)"
  warn "a package version must start with a digit, e.g. 1.2.3"
done

# --- the name: lowercase, as the distros require; nixpkgs' attribute is the same
# (with a leading _ if it starts with a digit)
PNAME_GUESS="$(cfg_get name)"
[ -n "$PNAME_GUESS" ] || PNAME_GUESS="$(name_at . | tr 'A-Z' 'a-z' | tr ' ' '-')"
FIRST=1
while :; do
  if [ "$FIRST" = 1 ]; then auto PNAME "Package name" "$PNAME_GUESS"; else ask PNAME "Package name" "$PNAME_GUESS"; fi
  FIRST=0
  printf '%s' "$PNAME" | grep -qE '^[a-z0-9][a-z0-9_-]*$' && break
  [ "$ASSUME_YES" = 1 ] && die "'$PNAME' is not a valid package name (lowercase letters, digits, - and _)"
  warn "lowercase letters, digits, - and _ only (distros forbid uppercase; . and + can't be nixpkgs attribute names)"
  PNAME_GUESS="$(printf '%s' "$PNAME" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n-' '-')"
done
ATTR="$PNAME"; case "$ATTR" in [0-9]*) ATTR="_$ATTR" ;; esac

# --- the release tag: the packages fetch it, so it must exist, be pushed, and
# hold exactly this version. The wizard sorts that out itself.
tag_on_remote() { git -C "$REPO" ls-remote --tags --exit-code origin "refs/tags/$1" >/dev/null 2>&1; }
ref_matches() {  # ref_matches <ref> — true if that ref declares $VERSION (or declares none)
  local v; v="$(version_at "$1" || true)"
  [ -z "$v" ] || [ "$VERSION_FROM_TAG" = 1 ] || [ "$v" = "$VERSION" ]
}
TAG_GUESS="v$VERSION"
for t in "v$VERSION" "$VERSION"; do
  if git -C "$REPO" rev-parse -q --verify "refs/tags/$t" >/dev/null 2>&1 || tag_on_remote "$t"; then
    TAG_GUESS="$t"; break
  fi
done
[ "$VERSION_FROM_TAG" = 1 ] && TAG_GUESS="$LAST_TAG"
auto TAG "Release tag" "$TAG_GUESS"

# a tag that only exists on origin (made on the web) is fetched first
if ! git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 && tag_on_remote "$TAG"; then
  git -C "$REPO" fetch -q origin "refs/tags/$TAG:refs/tags/$TAG" || die "could not fetch tag $TAG from origin"
fi
HEAD_SHORT="$(git -C "$REPO" rev-parse --short HEAD)"
if ! git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  warn "there is no tag $TAG yet"
  ref_matches HEAD || die "HEAD ($HEAD_SHORT) says version $(version_at HEAD), not $VERSION — commit the release first"
  [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] && \
    warn "you have uncommitted changes; the tag only covers what is committed"
  if [ "$DRYRUN" = 1 ]; then
    warn "dry run — would tag HEAD ($HEAD_SHORT) as $TAG and push it; reading HEAD for now"
    note "without the tag online the source can't be fetched: the dry run stops before building"
    TAG_REF=HEAD; DRY_NO_TAG=1
  elif go "Tag HEAD ($HEAD_SHORT) as $TAG and push it to origin?"; then
    git -C "$REPO" tag "$TAG" HEAD
    git -C "$REPO" push origin "refs/tags/$TAG" || die "could not push tag $TAG"
    ok "tagged and pushed $TAG"
  else
    die "the packages need the release tag — create and push $TAG, then re-run"
  fi
elif ! ref_matches "$TAG"; then
  # The classic slip: a tag made before the version bump.
  die "tag $TAG says version $(version_at "$TAG"), not $VERSION — tag the release commit, or bump the version"
elif ! tag_on_remote "$TAG"; then
  warn "tag $TAG is not on origin yet — the packages would not find it"
  if [ "$DRYRUN" = 1 ]; then
    warn "dry run — would push tag $TAG"
  elif go "Push tag $TAG to origin?"; then
    git -C "$REPO" push origin "refs/tags/$TAG" || die "could not push tag $TAG"
    ok "pushed $TAG"
  else
    die "push the tag first: git push origin $TAG"
  fi
else
  ok "tag $TAG is pushed and holds $VERSION"
fi
TAG_REF="${TAG_REF:-$TAG}"
# The Nix expression for the tag, relative to the version when it can be.
case "$TAG" in
  "v$VERSION") TAG_EXPR='"v${finalAttrs.version}"'; TAG_INTERP='v${finalAttrs.version}' ;;
  "$VERSION")  TAG_EXPR='finalAttrs.version';       TAG_INTERP='${finalAttrs.version}' ;;
  *)           TAG_EXPR="\"$(nix_str "$TAG")\"";      TAG_INTERP="$(nix_str "$TAG")" ;;
esac

# Everything below is read from the tag: that is what the distros will build.
git -C "$REPO" ls-tree -r --name-only "$TAG_REF" > "$WORK/tree.txt"
in_tree() { grep -qxF "$1" "$WORK/tree.txt"; }
in_tree_re() { grep -qE "$1" "$WORK/tree.txt"; }

# --- what the build needs from the tagged source
BLOCKERS=0
blocker() { bad "$*"; BLOCKERS=$((BLOCKERS + 1)); }
case "$KIND" in
  flutter)
    in_tree "$(pp pubspec.lock)" || blocker "no $(pp pubspec.lock) in $TAG — commit it (the builds pin every Dart package from it)"
    if in_tree "$(pp linux/CMakeLists.txt)"; then ok "Flutter Linux desktop target: $(pp linux/)"
    else blocker "no Linux desktop target in $TAG — run 'flutter create --platforms=linux .' in $PROOT, commit, and release again"; fi ;;
  rust)   in_tree Cargo.lock || blocker "no Cargo.lock in $TAG — commit it (the builds use exactly those crates)" ;;
  node)   in_tree package-lock.json || blocker "no package-lock.json in $TAG — this wizard packages npm projects; commit the lock file" ;;
  go)     in_tree go.mod || blocker "no go.mod in $TAG" ;;
  python) in_tree pyproject.toml || blocker "no pyproject.toml in $TAG — the Python builds need it" ;;
esac
[ "$BLOCKERS" -gt 0 ] && die "$BLOCKERS thing(s) above must be in the release first"

# --- license: the forge's answer, the manifest's, or recognised from the text
license_from_text() {
  local t; t="$(for f in LICENSE LICENSE.md LICENSE.txt COPYING COPYING.md LICENCE; do at "$TAG_REF" "$f"; done | head -c 20000)"
  case "$t" in
    *"GNU AFFERO GENERAL PUBLIC LICENSE"*"Version 3"*)   printf 'AGPL-3.0' ;;
    *"GNU LESSER GENERAL PUBLIC LICENSE"*"Version 3"*)   printf 'LGPL-3.0' ;;
    *"GNU LESSER GENERAL PUBLIC LICENSE"*"Version 2.1"*) printf 'LGPL-2.1' ;;
    *"GNU GENERAL PUBLIC LICENSE"*"Version 3"*)          printf 'GPL-3.0' ;;
    *"GNU GENERAL PUBLIC LICENSE"*"Version 2"*)          printf 'GPL-2.0' ;;
    *"Mozilla Public License Version 2.0"*|*"Mozilla Public License, version 2.0"*) printf 'MPL-2.0' ;;
    *"Apache License"*"Version 2.0"*)                    printf 'Apache-2.0' ;;
    *"Permission is hereby granted, free of charge"*)    printf 'MIT' ;;
    *"Redistribution and use in source and binary forms"*"Neither the name"*) printf 'BSD-3-Clause' ;;
    *"Redistribution and use in source and binary forms"*) printf 'BSD-2-Clause' ;;
    *"Permission to use, copy, modify, and/or distribute"*) printf 'ISC' ;;
    *"This is free and unencumbered software"*)          printf 'Unlicense' ;;
  esac
}
SPDX_GUESS="$(cfg_get license)"
if [ -z "$SPDX_GUESS" ]; then
case "$FORGE_SPDX" in ''|NOASSERTION|other) ;; *) SPDX_GUESS="$FORGE_SPDX" ;; esac
if [ -z "$SPDX_GUESS" ]; then
  case "$KIND" in
    rust)   SPDX_GUESS="$(at "$TAG_REF" Cargo.toml | toml_get package license)" ;;
    node)   SPDX_GUESS="$(at "$TAG_REF" package.json | tool jq jq -r '.license // ""' 2>/dev/null || true)" ;;
    python) SPDX_GUESS="$(at "$TAG_REF" pyproject.toml | toml_get project license)" ;;
  esac
  case "$SPDX_GUESS" in '{'*) SPDX_GUESS="" ;; esac
fi
[ -n "$SPDX_GUESS" ] || SPDX_GUESS="$(license_from_text || true)"
# GPL-family ids without -only/-or-later (GitHub reports them this way) are
# ambiguous, and the distros have a different license for each: settle it.
case "$SPDX_GUESS" in
  GPL-2.0|GPL-3.0|LGPL-2.1|LGPL-3.0|AGPL-3.0)
    LATER=only
    git -C "$REPO" grep -qi "any later version" "$TAG_REF" -- ':!LICENSE*' ':!COPYING*' ':!LICENCE*' 2>/dev/null && LATER=or-later
    note "$SPDX_GUESS comes in two kinds; source headers suggest -$LATER"
    if [ "$ASSUME_YES" = 1 ]; then SPDX_GUESS="$SPDX_GUESS-$LATER"
    else
      ask LATER "  \"$SPDX_GUESS-only\" or \"$SPDX_GUESS-or-later\"? (only / or-later)" "$LATER"
      case "$LATER" in or-later|later|l*) SPDX_GUESS="$SPDX_GUESS-or-later" ;; *) SPDX_GUESS="$SPDX_GUESS-only" ;; esac
    fi ;;
esac
fi
[ -n "$SPDX_GUESS" ] || warn "no license found — distros treat software without one as unfree; add a LICENSE file"
auto SPDX "License (SPDX)" "$SPDX_GUESS"

# --- description, following pkgs/README.md's rules for meta.description
clean_desc() {
  printf '%s' "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//; s/[.!。]+$//; s/^(A|An|The) //' \
    | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }'
}
desc_problems() {  # desc_problems <description> — one line per rule it breaks
  local d="$1" first
  [ -n "$d" ] || { echo "it is empty"; return; }
  first="$(printf '%s' "$d" | cut -c1)"
  [ "$first" = "$(printf '%s' "$first" | tr 'a-z' 'A-Z')" ] || echo "it should start with a capital letter"
  printf '%s' "$d" | grep -qE '^(A|An|The) ' && echo "it should not start with an article (A, An, The)"
  printf '%s' "$d" | grep -qE '[.!?,;:]$' && echo "it should not end with punctuation"
  printf '%s' "$d" | grep -qiE "(^|[^a-z0-9])$(printf '%s' "$PNAME" | sed 's/[.+]/\\&/g')([^a-z0-9]|$)" \
    && echo "it should not mention the package name ($PNAME)"
  printf '%s' "$d" | grep -qE '[.!?] [A-Z]' && echo "it should be a single sentence"
  [ "${#d}" -le 100 ] || echo "it is long (${#d} characters) — keep it to a short sentence"
}
DESC_RAW="$(cfg_get description)"
[ -n "$DESC_RAW" ] || DESC_RAW="$FORGE_DESC"
if [ -z "$DESC_RAW" ]; then
  case "$KIND" in
    flutter) DESC_RAW="$(at "$TAG_REF" "$(pp pubspec.yaml)" | sed -nE "s/^description:[[:space:]]*[\"']?([^\"']*)[\"']?[[:space:]]*$/\\1/p" | sed -n 1p)" ;;
    rust)    DESC_RAW="$(at "$TAG_REF" Cargo.toml | toml_get package description)" ;;
    node)    DESC_RAW="$(at "$TAG_REF" package.json | tool jq jq -r '.description // ""' 2>/dev/null || true)" ;;
    python)  DESC_RAW="$(at "$TAG_REF" pyproject.toml | toml_get project description)" ;;
  esac
  # Flutter's template description isn't one
  case "$DESC_RAW" in "A new Flutter project"*) DESC_RAW="" ;; esac
fi
DESC_GUESS="$(clean_desc "$DESC_RAW")"
FIRST=1
while :; do
  if [ "$FIRST" = 1 ] && [ -n "$DESC_GUESS" ] && [ -z "$(desc_problems "$DESC_GUESS")" ]; then
    auto DESC "Description" "$DESC_GUESS"
  else
    [ "$ASSUME_YES" = 1 ] && die "--yes: the description needs a person — run once without --yes"
    note "one short factual sentence: capitalised, no article or package name, no final period"
    ask DESC "Description" "$DESC_GUESS"
  fi
  FIRST=0
  PROBS="$(desc_problems "$DESC")"
  [ -z "$PROBS" ] && break
  printf '%s\n' "$PROBS" | while read -r l; do warn "description: $l"; done
  DESC_GUESS="$(clean_desc "$DESC")"
  # what's left can't be fixed mechanically (e.g. it names the package): your call
  [ "$DESC_GUESS" = "$DESC" ] && confirm "Keep it anyway?" n && break
done

HOME_GUESS="$WEB"
case "$FORGE_HOME" in https://*) HOME_GUESS="$FORGE_HOME" ;; esac
[ -n "$(cfg_get homepage)" ] && HOME_GUESS="$(cfg_get homepage)"
auto HOMEPAGE "Homepage" "$HOME_GUESS"

# --- changelog: a CHANGELOG file at the tag, else the forge's release page
CHANGELOG=""; CHANGELOG_REAL=""
for f in CHANGELOG.md CHANGELOG CHANGES.md NEWS.md; do
  in_tree "$f" || continue
  case "$FORGE" in
    github)   CHANGELOG="$WEB/blob/$TAG_INTERP/$f";   CHANGELOG_REAL="$WEB/blob/$TAG/$f" ;;
    gitlab)   CHANGELOG="$WEB/-/blob/$TAG_INTERP/$f"; CHANGELOG_REAL="$WEB/-/blob/$TAG/$f" ;;
    codeberg) CHANGELOG="$WEB/src/tag/$TAG_INTERP/$f"; CHANGELOG_REAL="$WEB/src/tag/$TAG/$f" ;;
  esac
  break
done
if [ -z "$CHANGELOG" ] && [ "$FORGE" = github ] && gh api "repos/$SLUG/releases/tags/$TAG" >/dev/null 2>&1; then
  CHANGELOG="$WEB/releases/tag/$TAG_INTERP"; CHANGELOG_REAL="$WEB/releases/tag/$TAG"
fi
[ -n "$CHANGELOG_REAL" ] && ok "changelog: $CHANGELOG_REAL"

# --- the main program, for meta.mainProgram (checked against the build later)
MAIN_GUESS=""
case "$KIND" in
  flutter) MAIN_GUESS="$(at "$TAG_REF" "$(pp linux/CMakeLists.txt)" | sed -nE 's/^[[:space:]]*set\(BINARY_NAME[[:space:]]+"([^"]+)".*/\1/p' | sed -n 1p)" ;;
  rust)    MAIN_GUESS="$(at "$TAG_REF" Cargo.toml | awk '/^\[\[bin\]\]/{b=1;next} /^\[/{b=0} b && /^name[[:space:]]*=/{gsub(/.*=[[:space:]]*"|".*/,"");print;exit}')"
           [ -n "$MAIN_GUESS" ] || MAIN_GUESS="$(at "$TAG_REF" Cargo.toml | toml_get package name)" ;;
  go)      if [ "$(grep -cE '^cmd/[^/]+/main\.go$' "$WORK/tree.txt")" = 1 ]; then
             MAIN_GUESS="$(grep -E '^cmd/[^/]+/main\.go$' "$WORK/tree.txt" | cut -d/ -f2)"
           else
             MAIN_GUESS="$(at "$TAG_REF" go.mod | sed -nE 's/^module[[:space:]]+([^[:space:]]+).*/\1/p' | sed -E 's#.*/##; s#^v[0-9]+$##')"
           fi ;;
  node)    MAIN_GUESS="$(at "$TAG_REF" package.json | tool jq jq -r 'if (.bin|type) == "string" then (.name|sub("^@[^/]*/";"")) elif (.bin|type) == "object" then (.bin|keys[0]) else "" end' 2>/dev/null || true)" ;;
  python)  MAIN_GUESS="$(at "$TAG_REF" pyproject.toml | awk '/^\[project\.scripts\]/{s=1;next} /^\[/{s=0} s && /=/{sub(/[[:space:]]*=.*/,""); gsub(/"/,""); print; exit}')" ;;
esac
[ -n "$MAIN_GUESS" ] || MAIN_GUESS="$PNAME"
[ -n "$(cfg_get main-program)" ] && MAIN_GUESS="$(cfg_get main-program)"

# --- you, as the maintainer: nixpkgs' maintainer list and the PKGBUILD's
# "# Maintainer:" line are public, so these are asked (once — then the
# config has them).
MAINT_NAME="$(cfg_get maintainer-name)"; MAINT_EMAIL="$(cfg_get maintainer-email)"
if [ -n "$MAINT_NAME" ] && [ -n "$MAINT_EMAIL" ] && [ "$ASK_ALL" = 0 ]; then
  ok "maintainer: $MAINT_NAME <$MAINT_EMAIL>"
else
  G="${MAINT_NAME:-${SAVED_HANDLE_NAME:-${GH_NAME:-$(git -C "$REPO" config user.name 2>/dev/null || true)}}}"
  note "your name and email go into the packages as their maintainer — both are public"
  ask MAINT_NAME "Maintainer name" "$G"
  G="${MAINT_EMAIL:-${SAVED_HANDLE_EMAIL:-$(git -C "$REPO" config user.email 2>/dev/null || true)}}"
  [ -n "$G" ] && note "email from ${MAINT_EMAIL:+the config}${MAINT_EMAIL:-your git identity (git config user.email)} — Enter keeps it, - leaves it out"
  ask_opt MAINT_EMAIL "Maintainer email" "$G"
fi

# --- keep the answers for every distro and every next release
if [ "${SAVE:-1}" = 1 ]; then
  BEFORE="$(cat "$LINUX_CONF" 2>/dev/null || true)"
  cfg_set name "$PNAME"; cfg_set build-system "$KIND"; cfg_set description "$DESC"
  cfg_set license "$SPDX"; cfg_set homepage "$HOMEPAGE"; cfg_set main-program "$MAIN_GUESS"
  cfg_set maintainer-name "$MAINT_NAME"; cfg_set maintainer-email "$MAINT_EMAIL"
  if [ "$BEFORE" != "$(cat "$LINUX_CONF")" ]; then
    ok "answers saved to ${LINUX_CONF#"$REPO"/} — every distro uses them; edit it any time"
    git -C "$REPO" ls-files --error-unmatch "$LINUX_CONF" >/dev/null 2>&1 \
      || note "(commit it with the app to keep it, or add it to .gitignore)"
  fi
fi
}

# ##########################################################################
#   nixpkgs wizard — store-submit.sh nix [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_nix() {
#
# store-submit.sh nix — get an app into nixpkgs (the package set Nix and NixOS
# install from), or ship a new version of one that is already there.
#
# Follows nixpkgs' own guides:
#   https://github.com/NixOS/nixpkgs/blob/master/pkgs/README.md
#   https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/README.md
#   https://github.com/NixOS/nixpkgs/blob/master/CONTRIBUTING.md
#
# It detects the project and writes pkgs/by-name/<xx>/<name>/package.nix (a
# package already in nixpkgs is bumped with nix-update instead), fills in every
# hash by building, checks the result the way reviewers do, adds you to the
# maintainer list the first time, and opens the pull request with gh.
#
# nixpkgs requires a person to review generated code and the use of automation
# to be disclosed (CONTRIBUTING.md, "Automation/AI policy"): the wizard shows
# you the whole change and asks you to review it, and says in the pull request
# how the package was made.
#
# Nothing leaves your machine without asking first, unless you pass --yes.

set -eu
# NOTE: deliberately no `set -o pipefail` — `cmd | head` would SIGPIPE and abort.

# ------------------------------------------------------------------ arguments
DRYRUN=0
SAVE=1
ASSUME_YES=0   # --yes: take every detected answer, only stop on problems
ASK_ALL=0      # --ask: ask every question, even the ones it can answer itself
RUN_REVIEW=0   # --review: run nixpkgs-review without asking
DRAFT=0        # --draft: open the pull request as a draft
REPO_ARG=""
NIXPKGS_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nixpkgs-submit"
CONF="$CONF_DIR/last.conf"
UPSTREAM_SLUG="NixOS/nixpkgs"
# where nixpkgs is cloned from (overridable for testing)
UPSTREAM_URL="${NIXPKGS_UPSTREAM:-https://github.com/$UPSTREAM_SLUG.git}"
# named in the pull request, as nixpkgs' automation policy asks
TOOL_URL="https://github.com/by-architect/StoreHelper"

usage() {
  cat <<'USAGE'
store-submit.sh nix — get an app into nixpkgs, or update it there.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask; stops only on
                      problems. A new package is then opened as a draft pull
                      request, since nixpkgs wants you to review it first.
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --nixpkgs PATH  your nixpkgs checkout (default: asked, ~/nixpkgs)
      --config FILE   the shared answers (default: .store-submit.conf in the repo)
      --review        also run nixpkgs-review (slow: evaluates nixpkgs twice)
      --draft         open the pull request as a draft
  -n, --dry-run       build, check and commit locally; push nothing
      --no-save       do not remember the answers for next time
      --forget        delete the remembered answers and exit

Detects what it can from your app's checkout, writes (or updates) its
package in your nixpkgs checkout, builds it, checks it, and opens the pull
request against NixOS/nixpkgs.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -n|--dry-run) DRYRUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --ask)        ASK_ALL=1 ;;
    --repo)       REPO_ARG="${2-}"; shift ;;
    --nixpkgs)    NIXPKGS_ARG="${2-}"; shift ;;
    --config)     LINUX_CONF="${2-}"; shift ;;
    --review)     RUN_REVIEW=1 ;;
    --draft)      DRAFT=1 ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF"; printf 'forgot %s\n' "$CONF"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WIZ_NAME=nixpkgs-submit
linux_common

# ------------------------------------------------------- remembered answers
# Written by this script only, as `SAVED_X=<shell-quoted>` lines.
SAVED_REPO=""; SAVED_NIXPKGS=""; SAVED_HANDLE_NAME=""; SAVED_HANDLE_EMAIL=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  {
    printf '# written by store-submit.sh nix — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n'         "${REPO:-${SAVED_REPO:-}}"
    printf 'SAVED_NIXPKGS=%q\n'      "${NIXPKGS:-${SAVED_NIXPKGS:-}}"
    printf 'SAVED_HANDLE_NAME=%q\n'  "${M_NAME:-${SAVED_HANDLE_NAME:-}}"
    printf 'SAVED_HANDLE_EMAIL=%q\n' "${M_EMAIL:-${SAVED_HANDLE_EMAIL:-}}"
  } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  chmod 600 "$CONF" 2>/dev/null || true
}

# ------------------------------------------------------------------- helpers

# fake_hash <letter> — a well-formed placeholder hash. Every field gets its own
# letter, so a "hash mismatch" names exactly the field it belongs to.
fake_hash() { printf 'sha256-%sAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "$1"; }

# fake_hashes <all|git> — in an existing package.nix, swap the source and
# dependency hashes (or only Flutter's gitHashes) for distinct placeholders;
# the build loop then fills in the real ones. Patches' hashes are left alone.
fake_hashes() {
  local f="$WT/$FILE"
  awk -v what="$1" -v L="LMNOPQRSTUVWXYZ" -v A="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" '
    function fake() { n++; return "\"sha256-" substr(L, n, 1) A "=\"" }
    /^  src = /            { insrc = 1 }
    /^  gitHashes = \{/    { ingit = 1 }
    ingit && /= "sha256-/ { sub(/"sha256-[^"]*"/, fake()) }
    /^  gitHashes\.[^ ]+ = "sha256-/ { sub(/"sha256-[^"]*"/, fake()) }
    what == "all" && insrc && /^    hash = "sha256-/ { sub(/"sha256-[^"]*"/, fake()) }
    what == "all" && /^  (cargoHash|vendorHash|npmDepsHash) = "sha256-/ { sub(/"sha256-[^"]*"/, fake()) }
    insrc && /^  };/ { insrc = 0 }
    ingit && /^  };/ { ingit = 0 }
    { print }' "$f" > "$f.new" && mv "$f.new" "$f"
}

in_wt() { ( cd "$WT" && "$@" ); }

# nixpkgs as CI sees it: without your ~/.config/nixpkgs config and overlays
PKGS='(import ./. { config = { }; overlays = [ ]; })'
NIXARGS=(--arg config '{ }' --arg overlays '[ ]')

# neval <expr> — evaluate in the nixpkgs worktree, JSON out ("" on failure,
# with the error in $WORK/eval.err)
neval() { ( cd "$WT" && nix-instantiate --eval --strict --json -E "$1" 2>"$WORK/eval.err" ) || true; }
neval_str() { neval "$1" | sed -e 's/^"//' -e 's/"$//'; }


# =============================================================== 0. orientation
cat <<BANNER

  ${B}nixpkgs submission wizard${R}

  Seven stages:
    1. your app          — what nixpkgs needs to know, and the release tag
    2. GitHub + nixpkgs  — your fork, a checkout, new package or update
    3. maintainer        — you in maintainer-list.nix (first time only)
    4. package           — package.nix written (or bumped with nix-update)
    5. build + check     — hashes filled in by building, then reviewers' checks
    6. review + commit   — you read the change; commits in nixpkgs' format
    7. pull request      — branch pushed to your fork, PR opened

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: everything up to the commits; nothing is pushed"
[ "$ASSUME_YES" = 1 ] && note "--yes: using everything detected; stopping only on problems"

for t in git nix-build nix-instantiate nix-shell; do
  have "$t" || die "$t is missing — this needs Nix: https://nixos.org/download"
done
have gh || die "gh (GitHub CLI) is missing — it makes the fork and the pull request. Install it, e.g.: nix profile install nixpkgs#gh"

# Nix itself must work before anything else: a stopped daemon shows up here
# rather than as a confusing build failure later.
if ! SYSTEM="$(nix-instantiate --eval --json -E 'builtins.currentSystem' 2>"$WORK/nix.err")"; then
  sed 's/^/     /' "$WORK/nix.err" | tail -5
  die "Nix can't evaluate anything — is the nix-daemon running? (systemctl status nix-daemon)"
fi
SYSTEM="$(printf '%s' "$SYSTEM" | tr -d '"')"
ok "Nix $(nix --version 2>/dev/null | sed 's/.* //') on $SYSTEM"
{ nix config show experimental-features 2>/dev/null || nix show-config 2>/dev/null; } \
  | grep -qw flakes && NIX_FLAKES=1

if ! gh_ready; then
  warn "gh is not logged in to GitHub"
  [ "$ASSUME_YES" = 1 ] && die "run 'gh auth login' first"
  if confirm "Log in now (gh auth login)?" y; then gh auth login --hostname github.com || true; fi
  gh_ready || die "still not logged in — run 'gh auth login', then re-run"
fi
GH_USER="$(gh api user --jq .login 2>/dev/null || true)"
[ -n "$GH_USER" ] || die "could not ask GitHub who you are (gh api user) — check your connection"
GH_ID="$(gh api user --jq .id)"
GH_NAME="$(gh api user --jq '.name // ""' 2>/dev/null || true)"
ok "GitHub: $GH_USER (id $GH_ID)"

linux_app "1/7  Your app"

# ======================================================= 2. GitHub + nixpkgs
step "2/7  Your nixpkgs fork and checkout"

# --- the fork: usually <you>/nixpkgs; else any fork of NixOS/nixpkgs you own
FORK_NAME=""
if [ "$(gh api "repos/$GH_USER/nixpkgs" --jq 'select(.fork) | .parent.full_name' 2>/dev/null || true)" = "$UPSTREAM_SLUG" ]; then
  FORK_NAME=nixpkgs
else
  FORK_NAME="$(gh repo list "$GH_USER" --fork --limit 1000 --json name,parent \
    --jq ".[] | select(.parent.owner.login == \"NixOS\" and .parent.name == \"nixpkgs\") | .name" 2>/dev/null | head -1 || true)"
fi
if [ -z "$FORK_NAME" ]; then
  warn "you have no fork of $UPSTREAM_SLUG yet — the pull request comes from one"
  if [ "$DRYRUN" = 1 ]; then
    warn "dry run — would fork $UPSTREAM_SLUG to $GH_USER/nixpkgs"; FORK_NAME=nixpkgs
  elif go "Fork $UPSTREAM_SLUG to $GH_USER/nixpkgs (master branch only)?"; then
    gh repo fork "$UPSTREAM_SLUG" --clone=false --default-branch-only >"$WORK/fork.log" 2>&1 \
      || gh repo fork "$UPSTREAM_SLUG" --clone=false >"$WORK/fork.log" 2>&1 \
      || { sed 's/^/     /' "$WORK/fork.log"; die "GitHub refused the fork — try https://github.com/$UPSTREAM_SLUG/fork, then re-run"; }
    # gh names the fork it made (or the one that already existed)
    FORK_NAME="$(grep -oE "$GH_USER/[A-Za-z0-9._-]+" "$WORK/fork.log" | head -1 | cut -d/ -f2)"
    FORK_NAME="${FORK_NAME:-nixpkgs}"
    # GitHub copies it in the background; wait until it answers.
    for _ in $(seq 1 60); do
      gh api "repos/$GH_USER/$FORK_NAME" >/dev/null 2>&1 && break
      sleep 3
    done
    gh api "repos/$GH_USER/$FORK_NAME" >/dev/null 2>&1 || die "the fork didn't appear after 3 minutes — check https://github.com/$GH_USER?tab=repositories and re-run"
    ok "forked: https://github.com/$GH_USER/$FORK_NAME"
  else
    die "a fork is needed for the pull request"
  fi
else
  ok "fork: https://github.com/$GH_USER/$FORK_NAME"
fi
FORK_URL="https://github.com/$GH_USER/$FORK_NAME.git"

# --- the checkout: always asked (it's big — where it goes is yours to pick)
is_nixpkgs() { [ -f "$1/.version" ] && [ -d "$1/pkgs/by-name" ] && git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }
while :; do
  if [ -n "$NIXPKGS_ARG" ]; then NIXPKGS="$NIXPKGS_ARG"
  else ask NIXPKGS "Local nixpkgs checkout" "${SAVED_NIXPKGS:-$HOME/nixpkgs}"; fi
  NIXPKGS="${NIXPKGS/#\~/$HOME}"
  case "$NIXPKGS" in /*) ;; *) NIXPKGS="$PWD/$NIXPKGS" ;; esac
  NIXPKGS="${NIXPKGS%/}"
  if is_nixpkgs "$NIXPKGS"; then ok "reusing $NIXPKGS"; break; fi
  if [ ! -e "$NIXPKGS" ] || [ -z "$(ls -A "$NIXPKGS" 2>/dev/null)" ]; then
    # A shallow clone of master: ~200 MB instead of several GB, and all a
    # branch for one pull request needs. A dropped connection just retries.
    while ! run_logged "$WORK/clone.log" "cloning nixpkgs (latest master only, a few minutes)" \
        git clone --depth 1 --single-branch --branch master --progress -o upstream "$UPSTREAM_URL" "$NIXPKGS"; do
      rm -rf "$NIXPKGS"
      tail -n 3 "$WORK/clone.log" | sed 's/^/     /'
      warn "the clone was cut off — usually a network hiccup"
      [ "$ASSUME_YES" = 1 ] || confirm "Try again?" y || die "no nixpkgs checkout"
    done
    git -C "$NIXPKGS" remote add origin "$FORK_URL"
    is_nixpkgs "$NIXPKGS" || die "$NIXPKGS doesn't look like nixpkgs after cloning"
    ok "cloned into $NIXPKGS; your fork is 'origin', NixOS/nixpkgs is 'upstream'"
    break
  fi
  [ -n "$NIXPKGS_ARG" ] && die "$NIXPKGS exists and isn't a nixpkgs checkout"
  warn "$NIXPKGS exists and isn't a nixpkgs checkout — pick another path"
  SAVED_NIXPKGS=""
done

# --- remotes: whatever names you use; the missing ones are added
remote_for() {  # remote_for <owner/repo> <url> — the remote pointing at it
  local r u
  for r in $(git -C "$NIXPKGS" remote); do
    u="$(git -C "$NIXPKGS" config --get "remote.$r.url" || true)"
    if [ "$u" = "$2" ] || printf '%s' "$u" | grep -qiE "github\.com[:/]$1(\.git)?/?$"; then
      printf '%s' "$r"; return 0
    fi
  done
  return 1
}
free_remote() {  # free_remote <preferred> — that name, or a variant not in use
  local n="$1" i=2
  while git -C "$NIXPKGS" remote | grep -qxF "$n"; do n="$1$i"; i=$((i + 1)); done
  printf '%s' "$n"
}
UP="$(remote_for "$UPSTREAM_SLUG" "$UPSTREAM_URL" || true)"
if [ -z "$UP" ]; then UP="$(free_remote upstream)"; git -C "$NIXPKGS" remote add "$UP" "$UPSTREAM_URL"; ok "added remote $UP → $UPSTREAM_SLUG"; fi
FK="$(remote_for "$GH_USER/$FORK_NAME" "$FORK_URL" || true)"
if [ -z "$FK" ]; then FK="$(free_remote fork)"; git -C "$NIXPKGS" remote add "$FK" "$FORK_URL"; ok "added remote $FK → $GH_USER/$FORK_NAME"; fi

# --- current master, to branch from
SHALLOW="$(git -C "$NIXPKGS" rev-parse --is-shallow-repository 2>/dev/null || echo false)"
FETCH_ARGS=(); [ "$SHALLOW" = true ] && FETCH_ARGS=(--depth 1)
while ! run_logged "$WORK/fetch.log" "fetching the latest nixpkgs master" \
    git -C "$NIXPKGS" fetch "${FETCH_ARGS[@]+"${FETCH_ARGS[@]}"}" "$UP" "+refs/heads/master:refs/remotes/$UP/master"; do
  tail -n 3 "$WORK/fetch.log" | sed 's/^/     /'
  warn "the fetch failed — usually a network hiccup"
  [ "$ASSUME_YES" = 1 ] || confirm "Try again?" y || die "could not fetch nixpkgs master"
done
BASE="$UP/master"
ok "master at $(git -C "$NIXPKGS" rev-parse --short "$BASE") ($(git -C "$NIXPKGS" log -1 --format=%cr "$BASE"))"

# --- a work tree to build the branch in: the checkout itself when it's clean,
# otherwise a separate worktree, so your own work in progress is never touched.
TMPBR="nixpkgs-submit-wip"
if [ -z "$(git -C "$NIXPKGS" status --porcelain --untracked-files=no)" ]; then
  WT="$NIXPKGS"
  PREV_BRANCH="$(git -C "$NIXPKGS" symbolic-ref --short -q HEAD || true)"
  git -C "$WT" checkout -q -B "$TMPBR" "$BASE" || die "could not check out $BASE in $WT"
  [ -n "$PREV_BRANCH" ] && [ "$PREV_BRANCH" != "$TMPBR" ] && note "(your checkout was on $PREV_BRANCH)"
else
  WT="${NIXPKGS}-worktrees/nixpkgs-submit"
  warn "$NIXPKGS has uncommitted changes — working in $WT instead, yours stay untouched"
  if [ -e "$WT/.git" ]; then git -C "$WT" checkout -q -f -B "$TMPBR" "$BASE"
  else mkdir -p "$(dirname "$WT")"; git -C "$NIXPKGS" worktree add -q -f -B "$TMPBR" "$WT" "$BASE"; fi
fi

# --- new package, or an update? An existing attribute has to be the same
# software (same source) — otherwise the name is taken and needs changing.
SHARD="$(printf '%s' "$ATTR" | cut -c1-2 | tr 'A-Z' 'a-z')"
MODE=new; FILE=""
while :; do
  SHARD="$(printf '%s' "$ATTR" | cut -c1-2 | tr 'A-Z' 'a-z')"
  PKGDIR="pkgs/by-name/$SHARD/$ATTR"
  EXISTS="$(neval "let p = import ./. { config.allowAliases = false; overlays = [ ]; }; in p ? \"$ATTR\"")"
  case "$EXISTS" in
    true|false) ;;
    *) tail -n 8 "$WORK/eval.err" | sed 's/^/     /'
       die "nixpkgs doesn't evaluate in $WT — can't tell whether $ATTR exists" ;;
  esac
  if [ "$EXISTS" != true ]; then MODE=new; FILE="$PKGDIR/package.nix"; break; fi
  SRCURL="$(neval_str "let p = $PKGS.\"$ATTR\"; in (p.src.url or p.src.gitRepoUrl or p.meta.homepage or \"\")")"
  if printf '%s' "$SRCURL" | grep -qiF "$SLUG"; then
    MODE=update
    POS="$(neval_str "$PKGS.\"$ATTR\".meta.position or \"\"")"
    FILE="${POS%:*}"; FILE="${FILE#"$WT"/}"
    [ -f "$WT/$FILE" ] || die "can't find where $ATTR is defined (meta.position: $POS)"
    break
  fi
  warn "nixpkgs already has a different '$ATTR' (${SRCURL:-no source URL}) — the name is taken"
  [ "$ASSUME_YES" = 1 ] && die "pick another package name (run without --yes)"
  ask ATTR "Another attribute name" "$ATTR-${OWNER##*/}"
  ATTR="$(printf '%s' "$ATTR" | tr 'A-Z' 'a-z')"; PNAME="$ATTR"
done

if [ "$MODE" = update ]; then
  OLD_VERSION="$(neval_str "$PKGS.\"$ATTR\".version")"
  ok "$ATTR is in nixpkgs at $OLD_VERSION ($FILE) — this is an update"
  [ "$OLD_VERSION" = "$VERSION" ] && die "nixpkgs already has $ATTR $VERSION — nothing to do"
  if [ "$(printf '%s\n%s\n' "$OLD_VERSION" "$VERSION" | sort -V | tail -1)" != "$VERSION" ]; then
    die "$VERSION is older than nixpkgs' $OLD_VERSION"
  fi
  BRANCH="$ATTR-$VERSION"
else
  ok "$ATTR is new to nixpkgs → $FILE"
  BRANCH="$ATTR-init"
fi
if git -C "$NIXPKGS" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null 2>&1; then
  n="$(git -C "$NIXPKGS" rev-list --count "$BASE..$BRANCH" 2>/dev/null || echo 0)"
  note "$BRANCH from an earlier run ($n commit(s)) is started over from current master"
fi
git -C "$WT" branch -M "$TMPBR" "$BRANCH"
ok "branch $BRANCH, from master"

# --- someone may be on it already: an open PR, or a packaging request to close
OPEN_PRS="$(gh search prs "$ATTR" --repo "$UPSTREAM_SLUG" --state open --match title --limit 30 --json number,title,url \
  --jq ".[] | select(.title | test(\"^$ATTR:\")) | \"#\(.number) \(.title)  \(.url)\"" 2>/dev/null || true)"
if [ -n "$OPEN_PRS" ]; then
  warn "there are open pull requests for $ATTR already:"
  printf '%s\n' "$OPEN_PRS" | sed 's/^/       /'
  confirm "Carry on anyway?" n || { note "worth a look first — maybe review or help that one"; exit 0; }
fi
CLOSES=""
if [ "$MODE" = new ]; then
  CLOSES="$(gh search issues "Package request $PNAME" --repo "$UPSTREAM_SLUG" --state open --match title --limit 10 --json number,title \
    --jq ".[] | select(.title | ascii_downcase | contains(\"$PNAME\")) | .number" 2>/dev/null | head -1 || true)"
  [ -n "$CLOSES" ] && ok "open package request #$CLOSES will be closed by this PR"
fi

# ============================================================== 3. maintainer
step "3/7  Maintainer"
ML="maintainers/maintainer-list.nix"
find_handle() {
  awk -v u="$(printf '%s' "$GH_USER" | tr 'A-Z' 'a-z')" -v id="$GH_ID" '
    /^  [^ #].* = \{$/ { h = $1; gsub(/"/, "", h) }
    /^    github = "/ { g = $0; sub(/^    github = "/, "", g); sub(/".*/, "", g); if (tolower(g) == u) { print h; exit } }
    /^    githubId = / { i = $0; gsub(/[^0-9]/, "", i); if (i == id) { print h; exit } }
  ' "$WT/$ML"
}
HANDLE="$(find_handle || true)"
ADD_MAINTAINER=0
if [ -n "$HANDLE" ]; then
  ok "you are in the maintainer list as '$HANDLE'"
elif [ "$MODE" = update ]; then
  note "you aren't in the maintainer list; an update doesn't need you to be"
else
  say "New packages need a maintainer, and you're not in $ML yet."
  note "This adds you, in its own commit (\"maintainers: add …\"), as nixpkgs asks."
  HANDLE="$GH_USER"; case "$HANDLE" in [0-9]*) HANDLE="_$HANDLE" ;; esac
  # the handle may belong to someone else already
  while grep -qE "^  \"?$HANDLE\"? = \{" "$WT/$ML"; do
    warn "the handle '$HANDLE' is taken by someone else"
    ask HANDLE "Handle to use" "$HANDLE-gh"
  done
  ok "handle: $HANDLE (github $GH_USER, id $GH_ID)"
  M_NAME="$MAINT_NAME"; M_EMAIL="$MAINT_EMAIL"
  ok "as: $M_NAME${M_EMAIL:+ <$M_EMAIL>} (the maintainer from stage 1)"
  ADD_MAINTAINER=1
fi

insert_maintainer() {
  local f="$WT/$ML" entry="$WORK/entry.nix"
  {
    printf '  %s = {\n' "$HANDLE"
    printf '    name = "%s";\n' "$(nix_str "$M_NAME")"
    [ -n "$M_EMAIL" ] && printf '    email = "%s";\n' "$(nix_str "$M_EMAIL")"
    printf '    github = "%s";\n' "$GH_USER"
    printf '    githubId = %s;\n' "$GH_ID"
    printf '  };\n'
  } > "$entry"
  # The list is kept sorted, case-insensitively (keep-sorted, enforced by CI).
  LC_ALL=C awk -v key="$(printf '%s' "$HANDLE" | tr 'A-Z' 'a-z')" -v entry="$entry" '
    function flush(  l) { while ((getline l < entry) > 0) print l; close(entry); done = 1 }
    /# keep-sorted start/ { sorted = 1; print; next }
    /# keep-sorted end/   { if (sorted && !done) flush(); sorted = 0; print; next }
    sorted && !done && /^  [^ #].* = \{$/ { k = $1; gsub(/"/, "", k); if (tolower(k) > key) flush() }
    { print }
  ' "$f" > "$f.new" && mv "$f.new" "$f"
  [ "$(neval "(import ./$ML).\"$HANDLE\".githubId")" = "$GH_ID" ] \
    || die "adding you to $ML went wrong — it doesn't evaluate to your entry"
  ok "added to $ML"
}
[ "$ADD_MAINTAINER" = 1 ] && insert_maintainer

# ============================================================== 4. package
step "4/7  The package"

PKG_FILES=()   # paths (relative to $WT) that belong to the package commit

# spdx_attr <SPDX id> — the lib.licenses attribute for it ("" if none)
spdx_attr() {
  neval "let lib = import ./lib; in builtins.attrNames (lib.filterAttrs (n: v: (v.spdxId or null) == \"$1\" && !(v.deprecated or false)) lib.licenses)" \
    | tr -d '[]" ' | cut -d, -f1
}
license_expr() {  # "MIT OR Apache-2.0" → with lib.licenses; [ mit asl20 ]
  local ids a attrs=() id
  ids="$(printf '%s' "$1" | tr '()' '  ' | sed -E 's/ (OR|AND|WITH) / /g; s/ or / /g; s#/# #g')"
  for id in $ids; do
    a="$(spdx_attr "$id")"
    [ -n "$a" ] || { printf 'UNKNOWN:%s' "$id"; return 0; }
    attrs+=("$a")
  done
  if [ "${#attrs[@]}" = 1 ]; then printf 'lib.licenses.%s' "${attrs[0]}"
  else printf 'with lib.licenses; [ %s ]' "${attrs[*]}"; fi
}

# pkg-config module / program → nixpkgs attribute. A short table of the usual
# ones, then nix-locate when it's installed, then an attribute of the same name.
pc_attr() {
  local n="$1" a=""
  case "$n" in
    gtk4) a=gtk4 ;; gtk+-3.0) a=gtk3 ;; libadwaita-1) a=libadwaita ;;
    glib-2.0|gio-2.0|gobject-2.0|gio-unix-2.0) a=glib ;;
    json-glib-1.0) a=json-glib ;; libsoup-3.0) a=libsoup_3 ;; webkitgtk-6.0) a=webkitgtk_6_0 ;;
    webkit2gtk-4.1) a=webkitgtk_4_1 ;; gtksourceview-5) a=gtksourceview5 ;;
    sqlite3) a=sqlite ;; openssl|libssl|libcrypto) a=openssl ;; libcurl) a=curl ;; zlib) a=zlib ;;
    x11) a=libx11 ;; wayland-client|wayland-server|wayland-cursor) a=wayland ;; xkbcommon) a=libxkbcommon ;;
    dbus-1) a=dbus ;; libpulse|libpulse-simple) a=libpulseaudio ;; alsa) a=alsa-lib ;;
    libxml-2.0) a=libxml2 ;; cairo) a=cairo ;; pango|pangocairo) a=pango ;;
    gdk-pixbuf-2.0) a=gdk-pixbuf ;; fontconfig) a=fontconfig ;; freetype2) a=freetype ;;
    libpng) a=libpng ;; libjpeg) a=libjpeg ;; sdl2) a=SDL2 ;; sdl3) a=sdl3 ;; vulkan) a=vulkan-loader ;;
    libsystemd) a=systemd ;; libudev) a=udev ;; libsecret-1) a=libsecret ;; libnotify) a=libnotify ;;
    gstreamer-1.0) a=gst_all_1.gstreamer ;; gstreamer-plugins-base-1.0) a=gst_all_1.gst-plugins-base ;;
    libportal|libportal-gtk4) a=libportal-gtk4 ;; epoxy) a=libepoxy ;; libdrm) a=libdrm ;; gl) a=libGL ;;
    libarchive) a=libarchive ;; libzstd) a=zstd ;; liblzma) a=xz ;; libpcre2-8) a=pcre2 ;;
  esac
  if [ -z "$a" ] && have nix-locate; then
    a="$(nix-locate --top-level --minimal --whole-name "/lib/pkgconfig/$n.pc" 2>/dev/null | sed 's/\.[a-z]*$//' | sort -u | head -1 || true)"
  fi
  if [ -z "$a" ] && [ "$(neval "$PKGS ? \"$n\"")" = true ]; then a="$n"; fi
  printf '%s' "$a"
}
prog_attr() {
  local n="$1" a=""
  case "$n" in
    desktop-file-validate|update-desktop-database) a=desktop-file-utils ;;
    appstreamcli) a=appstream ;; appstream-util) a=appstream-glib ;;
    glib-compile-resources|glib-compile-schemas|gdbus-codegen|glib-mkenums) a=glib ;;
    msgfmt|xgettext|msgmerge) a=gettext ;; gtk4-update-icon-cache|gtk4-builder-tool) a=gtk4 ;;
    gtk-update-icon-cache) a=gtk3 ;; protoc) a=protobuf ;; makeinfo) a=texinfo ;;
    wayland-scanner) a="wayland-scanner" ;; pkg-config|pkgconf) a="pkg-config" ;; python|python3) a=python3 ;;
    cmake|ninja|meson|perl|git|sassc|itstool|blueprint-compiler|rustc|cargo|go|nodejs|npm) a="$n" ;;
  esac
  if [ -z "$a" ] && have nix-locate; then
    a="$(nix-locate --top-level --minimal --whole-name "/bin/$n" 2>/dev/null | sed 's/\.[a-z]*$//' | sort -u | head -1 || true)"
  fi
  if [ -z "$a" ] && [ "$(neval "$PKGS ? \"$n\"")" = true ]; then a="$n"; fi
  printf '%s' "$a"
}
py_attr() {  # py_attr <distribution name> — its python3Packages attribute, if packaged
  local n; n="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr '_.' '--')"
  [ "$(neval "$PKGS.python3Packages ? \"$n\"")" = true ] && printf '%s' "$n"
}

# --- small editors for package.nix, for the automatic fixes and the build loop
add_arg() {  # add_arg <function argument>
  local f="$WT/$FILE" a="${1%%.*}"
  grep -qE "^  $a,$" "$f" && return 0
  awk -v a="$a" '!done && /^}:$/ { print "  " a ","; done = 1 } { print }' "$f" > "$f.new" && mv "$f.new" "$f"
}
add_to_list() {  # add_to_list <attribute> <item> — into `attribute = [ … ];`, created if missing
  local f="$WT/$FILE" key="$1" item="$2"
  grep -qE "^  $key = \[.*[[:space:]]$(printf '%s' "$item" | sed 's/[.]/\\./g')[[:space:]]" "$f" && return 0
  grep -qE "^    $(printf '%s' "$item" | sed 's/[.]/\\./g')$" "$f" && grep -qE "^  $key = \[$" "$f" && return 0
  if grep -qE "^  $key = \[$" "$f"; then
    awk -v k="$key" -v i="$item" '{ print } !done && $0 == "  " k " = [" { print "    " i; done = 1 }' "$f" > "$f.new"
  elif grep -qE "^  $key = \[ .* \];$" "$f"; then
    awk -v k="$key" -v i="$item" '!done && index($0, "  " k " = [ ") == 1 { sub(/ \];$/, " " i " ];"); done = 1 } { print }' "$f" > "$f.new"
  else
    awk -v k="$key" -v i="$item" '
      !done && (/^  passthru/ || /^  meta = \{$/) { print "  " k " = [ " i " ];"; print ""; done = 1 }
      { print }' "$f" > "$f.new"
  fi
  mv "$f.new" "$f"
  add_arg "$item"
}
set_attr_line() {  # set_attr_line <attribute> <nix value> — replace or add `attribute = value;`
  local f="$WT/$FILE" key="$1" val="$2"
  if grep -qE "^  $key = " "$f"; then
    awk -v k="$key" -v v="$val" 'index($0, "  " k " = ") == 1 { print "  " k " = " v ";"; next } { print }' "$f" > "$f.new"
  else
    awk -v k="$key" -v v="$val" '!done && (/^  passthru/ || /^  meta = \{$/) { print "  " k " = " v ";"; print ""; done = 1 } { print }' "$f" > "$f.new"
  fi
  mv "$f.new" "$f"
}

if [ "$MODE" = update ]; then
  # ---------------------------------------------------------------- update
  # nix-update is nixpkgs' standard updater (exempt from the automation
  # policy's review rule): new version, src hash and dependency hashes.
  PKG_FILES+=("$FILE")
  if run_logged "$WORK/nix-update.log" "nix-update $ATTR → $VERSION" \
      in_wt tool nix-update nix-update --version "$VERSION" "$ATTR"; then
    grep -q "\"$VERSION\"" "$WT/$FILE" || die "nix-update ran, but $FILE doesn't mention $VERSION — see $WORK/nix-update.log"
    ok "nix-update bumped $ATTR to $VERSION"
    UPDATED_WITH=nix-update
  else
    tail -n 8 "$WORK/nix-update.log" | sed 's/^/     /'
    warn "nix-update couldn't do it — bumping the version and letting the build fill the hashes"
    sed -i -E "0,/version = \"$(printf '%s' "$OLD_VERSION" | sed 's/[.]/\\./g')\";/s//version = \"$VERSION\";/" "$WT/$FILE"
    grep -q "version = \"$VERSION\";" "$WT/$FILE" || die "can't find version = \"$OLD_VERSION\"; in $FILE — update it by hand"
    fake_hashes all
    UPDATED_WITH=wizard
  fi
  # Flutter: the lock file lives next to the package and has to follow, and
  # the git dependencies' hashes with it.
  PKG_DIR_REL="$(dirname "$FILE")"
  if [ "$KIND" = flutter ] && [ -f "$WT/$PKG_DIR_REL/pubspec.lock.json" ]; then
    at "$TAG_REF" "$(pp pubspec.lock)" | tool yq-go yq eval --output-format=json --prettyPrint - > "$WT/$PKG_DIR_REL/pubspec.lock.json" \
      || die "could not convert pubspec.lock to JSON"
    PKG_FILES+=("$PKG_DIR_REL/pubspec.lock.json")
    ok "pubspec.lock.json regenerated from $TAG"
    fake_hashes git
  fi
else
  # ------------------------------------------------------------- new package
  mkdir -p "$WT/$PKGDIR"
  PKG_FILES+=("$FILE")

  # license → lib.licenses
  LICENSE_EXPR=""
  while :; do
    LICENSE_EXPR="$(license_expr "$SPDX")"
    case "$LICENSE_EXPR" in
      UNKNOWN:*) warn "nixpkgs has no license with SPDX id '${LICENSE_EXPR#UNKNOWN:}'"
                 [ "$ASSUME_YES" = 1 ] && die "fix the license (SPDX id) and re-run"
                 note "SPDX ids look like MIT, Apache-2.0, GPL-3.0-or-later — https://spdx.org/licenses/"
                 ask SPDX "License (SPDX)" "" ;;
      *) break ;;
    esac
  done
  ok "license: $LICENSE_EXPR"

  ARGS=(lib); NATIVE=(); INPUTS=(); BODY="$WORK/body.nix"; : > "$BODY"
  PLATFORMS=""
  HASH_SRC="$(fake_hash B)"
  src_block() {
    case "$FORGE" in
      git)
        printf '  src = fetchgit {\n    url = "%s";\n    tag = %s;\n    hash = "%s";\n  };\n' \
          "$(printf '%s' "$ORIGIN" | sed -E 's#^[^@/]+@([^:]+):#https://\1/#')" "$TAG_EXPR" "$HASH_SRC" ;;
      *)
        printf '  src = %s {\n    owner = "%s";\n    repo = "%s";\n    tag = %s;\n    hash = "%s";\n  };\n' \
          "$FETCHER" "$OWNER" "$REPONAME" "$TAG_EXPR" "$HASH_SRC" ;;
    esac
  }
  ARGS+=("$FETCHER")

  case "$KIND" in
    rust)
      BUILDER="rustPlatform.buildRustPackage"; ARGS+=(rustPlatform)
      printf '  cargoHash = "%s";\n\n' "$(fake_hash C)" >> "$BODY"
      # -sys crates that link a system library: add it up front
      for crate in $(at "$TAG_REF" Cargo.lock | sed -nE 's/^name = "([a-z0-9_-]+-sys)"$/\1/p' | sort -u); do
        case "$crate" in
          openssl-sys)    NATIVE+=(pkg-config); INPUTS+=(openssl) ;;
          alsa-sys)       NATIVE+=(pkg-config); INPUTS+=(alsa-lib) ;;
          libdbus-sys)    NATIVE+=(pkg-config); INPUTS+=(dbus) ;;
          libudev-sys)    NATIVE+=(pkg-config); INPUTS+=(udev) ;;
          gtk4-sys)       NATIVE+=(pkg-config wrapGAppsHook4); INPUTS+=(gtk4) ;;
          gtk-sys)        NATIVE+=(pkg-config wrapGAppsHook3); INPUTS+=(gtk3) ;;
          libadwaita-sys) INPUTS+=(libadwaita) ;;
          webkit2gtk-sys) NATIVE+=(pkg-config); INPUTS+=(webkitgtk_4_1) ;;
        esac
      done ;;
    go)
      BUILDER="buildGoModule"; ARGS+=(buildGoModule)
      if in_tree_re '^vendor/modules\.txt$' || ! in_tree go.sum; then printf '  vendorHash = null;\n\n' >> "$BODY"
      else printf '  vendorHash = "%s";\n\n' "$(fake_hash D)" >> "$BODY"; fi
      LDFLAGS='"-s"'
      if git -C "$REPO" grep -qE '^[[:space:]]*(var[[:space:]]+)?version[[:space:]]+(=|string)' "$TAG_REF" -- main.go 'cmd/*/main.go' 2>/dev/null; then
        LDFLAGS="$LDFLAGS \"-X main.version=\${finalAttrs.version}\""
      fi
      printf '  ldflags = [ %s ];\n\n' "$LDFLAGS" >> "$BODY" ;;
    node)
      BUILDER="buildNpmPackage"; ARGS+=(buildNpmPackage)
      printf '  npmDepsHash = "%s";\n\n' "$(fake_hash E)" >> "$BODY"
      if [ -z "$(at "$TAG_REF" package.json | tool jq jq -r '.scripts.build // ""' 2>/dev/null || true)" ]; then
        printf '  # package.json has no build script\n  dontNpmBuild = true;\n\n' >> "$BODY"
      fi ;;
    python)
      BUILDER="python3Packages.buildPythonApplication"; ARGS+=(python3Packages)
      PYP="$WORK/pyproject.toml"; at "$TAG_REF" pyproject.toml > "$PYP"
      # [build-system] requires and [project] dependencies, names only
      tool python3 python3 - "$PYP" > "$WORK/pydeps" <<'PY' || die "could not read pyproject.toml"
import re, sys
try:
    import tomllib
except ImportError:
    sys.exit("python 3.11 or newer is needed to read pyproject.toml")
d = tomllib.load(open(sys.argv[1], "rb"))
name = lambda s: re.match(r"[A-Za-z0-9._-]+", s.strip()).group(0)
for r in d.get("build-system", {}).get("requires", []):
    print("build", name(r))
for r in d.get("project", {}).get("dependencies", []):
    if ";" in r and "extra ==" in r:
        continue
    print("dep", name(r))
PY
      BUILD_SYS=(); DEPS=(); MISSING_PY=()
      while read -r kind dname; do
        a="$(py_attr "$dname" || true)"
        [ -n "$a" ] || { MISSING_PY+=("$dname"); continue; }
        if [ "$kind" = build ]; then BUILD_SYS+=("python3Packages.$a"); else DEPS+=("python3Packages.$a"); fi
      done < "$WORK/pydeps"
      if [ "${#MISSING_PY[@]}" -gt 0 ]; then
        bad "not in nixpkgs yet: ${MISSING_PY[*]}"
        die "those Python packages have to be packaged in nixpkgs first (each is its own pull request)"
      fi
      printf '  pyproject = true;\n\n' > "$WORK/pyhead"
      printf '  build-system = [ %s ];\n\n' "${BUILD_SYS[*]:-python3Packages.setuptools}" >> "$BODY"
      [ "${#DEPS[@]}" -gt 0 ] && printf '  dependencies = [\n%s\n  ];\n\n' "$(printf '    %s\n' "${DEPS[@]}")" >> "$BODY"
      MOD="$(grep -E '^(src/)?[A-Za-z_][A-Za-z0-9_]*/__init__\.py$' "$WORK/tree.txt" | grep -v '^tests\?/' | head -1 | sed -E 's#^src/##; s#/__init__\.py$##')"
      [ -n "$MOD" ] && printf '  pythonImportsCheck = [ "%s" ];\n\n' "$MOD" >> "$BODY" ;;
    meson|cmake|make)
      BUILDER="stdenv.mkDerivation"; ARGS+=(stdenv); PLATFORMS="lib.platforms.linux"
      PCS=""
      case "$KIND" in
        meson) NATIVE+=(meson ninja pkg-config)
               PCS="$(at "$TAG_REF" meson.build; for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done)"
               PCS="$(printf '%s' "$PCS" | grep -oE "dependency\([[:space:]]*'[^']+'" | sed -E "s/.*'([^']+)'/\\1/" | sort -u)" ;;
        cmake) NATIVE+=(cmake)
               # pkg_check_modules(PREFIX [REQUIRED …] mod1>=1.0 mod2): the modules
               PCS="$(at "$TAG_REF" CMakeLists.txt | tr '\n' ' ' | grep -oE 'pkg_check_modules\([^)]*\)' \
                      | sed -E 's/^pkg_check_modules\(//; s/\)$//' \
                      | awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^(REQUIRED|QUIET|IMPORTED_TARGET|GLOBAL|NO_CMAKE_PATH|NO_CMAKE_ENVIRONMENT_PATH)$/) { m = $i; sub(/[<>=].*/, "", m); if (m != "") print m } }' \
                      | sort -u)"
               [ -n "$PCS" ] && NATIVE+=(pkg-config) ;;
        make)  printf '  makeFlags = [ "PREFIX=${placeholder "out"}" ];\n\n' >> "$BODY" ;;
      esac
      for pc in $PCS; do
        case "$pc" in threads|m|dl|rt|dependency) continue ;; esac
        a="$(pc_attr "$pc" || true)"
        if [ -n "$a" ]; then INPUTS+=("$a"); else warn "no nixpkgs package found for dependency '$pc' — the build will say if it's needed"; fi
        case "$pc" in gtk4|libadwaita-1) NATIVE+=(wrapGAppsHook4 desktop-file-utils) ;; gtk+-3.0) NATIVE+=(wrapGAppsHook3) ;; esac
      done ;;
    flutter)
      # Flutter version: the project's pin (.fvmrc and friends), else the
      # installed one, mapped to nixpkgs' flutterXYY; else the default flutter.
      FV="$( { at "$TAG_REF" "$(pp .fvmrc)" | sed -nE 's/.*"flutter"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'
               at "$TAG_REF" "$(pp .fvm/fvm_config.json)" | sed -nE 's/.*"flutterSdkVersion"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'
               at "$TAG_REF" "$(pp .tool-versions)" | sed -nE 's/^flutter[[:space:]]+([0-9][^[:space:]-]*).*/\1/p'; } | sed -n 1p)"
      [ -n "$FV" ] || FV="$(flutter --version 2>/dev/null | sed -nE 's/^Flutter ([0-9]+\.[0-9]+).*/\1/p' | sed -n 1p || true)"
      FLUTTER_ATTR=flutter
      if [ -n "$FV" ]; then
        cand="flutter$(printf '%s' "$FV" | sed -E 's/^([0-9]+)\.([0-9]+).*/\1\2/')"
        if grep -qE "^  $cand = " "$WT/pkgs/top-level/all-packages.nix"; then FLUTTER_ATTR="$cand"
        else warn "nixpkgs has no $cand (the project pins Flutter $FV) — using the default flutter"; fi
      fi
      auto FLUTTER_ATTR "Flutter in nixpkgs" "$FLUTTER_ATTR"
      BUILDER="$FLUTTER_ATTR.buildFlutterApplication"; ARGS+=("$FLUTTER_ATTR"); PLATFORMS="lib.platforms.linux"
      [ "$PROOT" != . ] && printf '  sourceRoot = "${finalAttrs.src.name}/%s";\n\n' "$PROOT" >> "$BODY"
      # nixpkgs pins every Dart package from the lock file, as JSON
      at "$TAG_REF" "$(pp pubspec.lock)" | tool yq-go yq eval --output-format=json --prettyPrint - > "$WT/$PKGDIR/pubspec.lock.json" \
        || die "could not convert pubspec.lock to JSON"
      [ "$(tool jq jq '.packages | length' < "$WT/$PKGDIR/pubspec.lock.json")" -gt 0 ] || die "pubspec.lock.json came out empty"
      PKG_FILES+=("$PKGDIR/pubspec.lock.json")
      ok "pubspec.lock.json written from $TAG"
      printf '  pubspecLock = lib.importJSON ./pubspec.lock.json;\n\n' >> "$BODY"
      GITDEPS="$(tool jq jq -r '.packages | to_entries[] | select(.value.source == "git") | .key' < "$WT/$PKGDIR/pubspec.lock.json")"
      if [ -n "$GITDEPS" ]; then
        printf '  gitHashes = {\n' >> "$BODY"
        i=0
        for dep in $GITDEPS; do
          i=$((i + 1))
          printf '    %s = "%s";\n' "$dep" "$(fake_hash "$(printf '%s' KLMNOPQRSTUVWXYZ | cut -c$i)")" >> "$BODY"
        done
        printf '  };\n\n' >> "$BODY"
      fi
      # a desktop entry and icon, so it shows up in the app menu
      TITLE="$(at "$TAG_REF" "$(pp linux/runner/my_application.cc)" | sed -nE 's/.*(gtk_header_bar_set_title|gtk_window_set_title)\([^,]+,[[:space:]]*"([^"]+)".*/\2/p' | sed -n 1p)"
      [ -n "$TITLE" ] || TITLE="$PNAME"
      ICON="$(grep -E "^$( [ "$PROOT" = . ] || printf '%s/' "$PROOT")(assets/.*(icon|logo|launcher)[^/]*\.png|linux/.*\.png|android/app/src/main/res/mipmap-xxxhdpi/ic_launcher\.png)$" "$WORK/tree.txt" \
             | awk '{ print (/assets\//) ? 1 : (/linux\//) ? 2 : 3, $0 }' | sort -n | head -1 | cut -d' ' -f2- || true)"
      ICON="${ICON#"$PROOT"/}"
      ARGS+=(makeDesktopItem copyDesktopItems)
      {
        printf '  desktopItems = [\n    (makeDesktopItem {\n'
        printf '      name = "%s";\n      exec = "%s";\n' "$MAIN_GUESS" "$MAIN_GUESS"
        [ -n "$ICON" ] && printf '      icon = "%s";\n' "$MAIN_GUESS"
        printf '      desktopName = "%s";\n      comment = "%s";\n' "$(nix_str "$TITLE")" "$(nix_str "$DESC")"
        printf '      categories = [ "Utility" ];\n    })\n  ];\n\n'
        printf '  nativeBuildInputs = [ copyDesktopItems ];\n\n'
        if [ -n "$ICON" ]; then
          printf "  postInstall = ''\n    install -Dm644 %s \$out/share/pixmaps/%s.png\n  '';\n\n" "$ICON" "$MAIN_GUESS"
        fi
      } >> "$BODY"
      [ -n "$ICON" ] && ok "desktop entry \"$TITLE\" with icon $ICON" || warn "no icon found — the desktop entry has none"
      ;;
  esac

  # passthru.updateScript: lets nixpkgs' update bot (r-ryantm) open update PRs
  # for you. Flutter also regenerates the lock file, like nixpkgs' own examples.
  if [ "$KIND" = flutter ]; then
    ARGS+=(runCommand yq-go nix-update-script _experimental-update-script-combinators)
    UPDATE_BLOCK="  passthru = {
    pubspecSource =
      runCommand \"pubspec.lock.json\"
        {
          inherit (finalAttrs) src;
          nativeBuildInputs = [ yq-go ];
        }
        ''
          yq eval --output-format=json --prettyPrint \$src/$(pp pubspec.lock) > \"\$out\"
        '';
    updateScript = _experimental-update-script-combinators.sequence [
      (nix-update-script { })
      (
        (_experimental-update-script-combinators.copyAttrOutputToFile \"$ATTR.pubspecSource\" ./pubspec.lock.json)
        // {
          supportedFeatures = [ ];
        }
      )
    ];
  };
"
  else
    ARGS+=(nix-update-script)
    UPDATE_BLOCK="  passthru.updateScript = nix-update-script { };
"
  fi

  uniq_list() { printf '%s\n' "$@" | awk 'NF && !seen[$0]++'; }
  {
    printf '{\n'
    # the function's arguments: builders, fetcher, and the top-level name of
    # every input (gst_all_1.gstreamer → gst_all_1)
    { uniq_list "${ARGS[@]}"
      printf '%s\n' "${NATIVE[@]+"${NATIVE[@]}"}" "${INPUTS[@]+"${INPUTS[@]}"}" | sed 's/\..*//'; } \
      | awk 'NF && !seen[$0]++ { print "  " $0 "," }'
    printf '}:\n\n%s (finalAttrs: {\n' "$BUILDER"
    printf '  pname = "%s";\n  version = "%s";\n' "$PNAME" "$VERSION"
    [ -f "$WORK/pyhead" ] && cat "$WORK/pyhead" || printf '\n'
    src_block
    printf '\n'
    cat "$BODY"
    if [ "${#NATIVE[@]}" -gt 0 ] && ! grep -q '^  nativeBuildInputs = ' "$BODY"; then
      printf '  nativeBuildInputs = [\n%s\n  ];\n\n' "$(uniq_list "${NATIVE[@]}" | sed 's/^/    /')"
    fi
    if [ "${#INPUTS[@]}" -gt 0 ]; then
      printf '  buildInputs = [\n%s\n  ];\n\n' "$(uniq_list "${INPUTS[@]}" | sed 's/^/    /')"
    fi
    printf '%s\n' "$UPDATE_BLOCK"
    printf '  meta = {\n'
    printf '    description = "%s";\n' "$(nix_str "$DESC")"
    printf '    homepage = "%s";\n' "$(nix_str "$HOMEPAGE")"
    [ -n "$CHANGELOG" ] && printf '    changelog = "%s";\n' "$CHANGELOG"
    printf '    license = %s;\n' "$LICENSE_EXPR"
    printf '    maintainers = with lib.maintainers; [ %s ];\n' "$HANDLE"
    printf '    mainProgram = "%s";\n' "$MAIN_GUESS"
    [ -n "$PLATFORMS" ] && printf '    platforms = %s;\n' "$PLATFORMS"
    printf '  };\n})\n'
  } > "$WT/$FILE"
  nix-instantiate --parse "$WT/$FILE" >/dev/null 2>"$WORK/parse.err" \
    || { cat "$WORK/parse.err"; KEEP_WORK=1; die "the generated package.nix doesn't parse — this is a bug in the wizard"; }
  ok "wrote $FILE ($BUILDER)"
fi

if [ "${DRY_NO_TAG:-0}" = 1 ]; then
  echo; sed 's/^/     /' "$WT/$FILE"; echo
  warn "dry run stops here: tag $TAG isn't online, so nixpkgs can't fetch the source to build it"
  note "the draft is in $WT/$FILE; push the tag and run without -n"
  exit 0
fi

# ============================================================ 5. build + check
step "5/7  Build and check"
note "the first build fills in each hash (a placeholder fails with the real value)"

BUILD_LOG="$WORK/build.log"
RESULT="$WORK/result"
build() { ( cd "$WT" && nix-build "${NIXARGS[@]}" -A "$ATTR" -o "$RESULT" ); }

# fix_hash — a "hash mismatch" for one of our placeholders (or a hash that went
# stale): put the real value in its place. False if it wasn't that.
fix_hash() {
  local spec got f field
  spec="$(grep -oE 'specified:[[:space:]]+sha256-[A-Za-z0-9+/]{43}=' "$BUILD_LOG" | head -1 | sed -E 's/.*[[:space:]]//')"
  got="$(grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/]{43}=' "$BUILD_LOG" | head -1 | sed -E 's/.*[[:space:]]//')"
  [ -n "$spec" ] && [ -n "$got" ] || return 1
  for f in "${PKG_FILES[@]}"; do
    grep -qF "$spec" "$WT/$f" || continue
    field="$(grep -F "$spec" "$WT/$f" | head -1 | sed -E 's/^[[:space:]]*([A-Za-z0-9_.-]+)[[:space:]]*=.*/\1/')"
    sed -i "s#$spec#$got#" "$WT/$f"
    ok "filled in ${field:-a hash}: $got"
    return 0
  done
  bad "hash mismatch in $(grep -oE "derivation '[^']+'" "$BUILD_LOG" | head -1) — not a hash this wizard wrote"
  return 1
}

# autofix — the build failures with an unambiguous fix: apply it and say so.
FIXED=" "
autofix() {
  local n a crate
  # Go module without dependencies
  if grep -qE "vendor folder is empty|please set 'vendorHash = null'|vendorHash = null" "$BUILD_LOG" && [ "$KIND" = go ]; then
    set_attr_line vendorHash null; ok "no Go dependencies to vendor: vendorHash = null"; return 0
  fi
  # a pkg-config / meson / CMake dependency that isn't there
  n="$(grep -oE "(Package '[^']+',? required by|No package '[^']+' found|Dependency \"[^\"]+\" not found|Run-time dependency [^ ]+ found: NO)" "$BUILD_LOG" \
        | head -1 | sed -E "s/^Package '([^']+)'.*/\1/; s/^No package '([^']+)'.*/\1/; s/^Dependency \"([^\"]+)\".*/\1/; s/^Run-time dependency ([^ ]+).*/\1/")"
  if [ -n "$n" ] && [ "${FIXED#* lib:$n }" = "$FIXED" ]; then
    FIXED="${FIXED}lib:$n "
    a="$(pc_attr "$n" || true)"
    if [ -n "$a" ]; then
      add_to_list buildInputs "$a"; add_to_list nativeBuildInputs pkg-config
      ok "the build needs '$n': added $a to buildInputs"; return 0
    fi
    bad "the build needs the library '$n', and no nixpkgs package for it was found"
    have nix-locate || note "installing nix-index (nix-locate) lets the wizard search every package for it"
    return 1
  fi
  # a program the build runs
  n="$(grep -oE "(Program '[^']+' not found|[A-Za-z0-9._+-]+: command not found|Could not find \`[a-z0-9_-]+\`|failed to find tool \"[a-z0-9_-]+\")" "$BUILD_LOG" \
        | head -1 | sed -E "s/^Program '([^']+)'.*/\1/; s/: command not found$//; s/^Could not find \`([^\`]+)\`.*/\1/; s/^failed to find tool \"([^\"]+)\".*/\1/")"
  if [ -n "$n" ] && [ "${FIXED#* prog:$n }" = "$FIXED" ]; then
    FIXED="${FIXED}prog:$n "
    a="$(prog_attr "$n" || true)"
    if [ -n "$a" ]; then add_to_list nativeBuildInputs "$a"; ok "the build runs '$n': added $a to nativeBuildInputs"; return 0; fi
    bad "the build runs '$n', and no nixpkgs package provides it"
    return 1
  fi
  # Rust -sys crates the table above didn't know
  crate="$(grep -oE 'failed to run custom build command for `[a-z0-9_-]+-sys' "$BUILD_LOG" | head -1 | sed 's/.*`//')"
  if [ -n "$crate" ] && [ "${FIXED#* sys:$crate }" = "$FIXED" ]; then
    FIXED="${FIXED}sys:$crate "
    add_to_list nativeBuildInputs pkg-config
    ok "$crate needs pkg-config: added it (a missing library shows up next)"; return 0
  fi
  # Python: runtime dependencies the check says are missing
  if [ "$KIND" = python ]; then
    local added=0
    for n in $(sed -nE 's/^[[:space:]]+- ([A-Za-z0-9._-]+) not installed.*/\1/p' "$BUILD_LOG" | sort -u); do
      a="$(py_attr "$n" || true)"
      [ -n "$a" ] || { bad "the app needs Python package '$n', which isn't in nixpkgs yet"; return 1; }
      add_to_list dependencies "python3Packages.$a"; ok "added python3Packages.$a to dependencies"
      FIXED="${FIXED}py:$n "; added=1
    done
    [ "$added" = 1 ] && return 0
  fi
  # Flutter: the project needs a newer Dart SDK than this Flutter has
  if [ "$KIND" = flutter ] && grep -qE "The current Dart SDK version is|requires SDK version" "$BUILD_LOG" \
     && [ "${FIXED#* flutter }" = "$FIXED" ] && [ "${FLUTTER_ATTR:-flutter}" != flutter ]; then
    FIXED="${FIXED}flutter "
    sed -i "s/\b$FLUTTER_ATTR\b/flutter/g" "$WT/$FILE"; FLUTTER_ATTR=flutter
    ok "the pinned Flutter is too old for this project's Dart SDK: switched to nixpkgs' current flutter"; return 0
  fi
  return 1
}

FAILED_TESTS=()
explain_failure() {
  local l="$BUILD_LOG"
  FAILED_TESTS=()
  if grep -qE "unable to download|HTTP error 404|cannot download|Couldn't resolve host|Could not resolve host" "$l"; then
    bad "the source couldn't be downloaded"
    note "is tag $TAG pushed, and $WEB public? Is the network up?"
  elif grep -qE "^error: (undefined variable|attribute '[^']+' missing|syntax error|called with unexpected argument|function '[^']+' called without required argument)" "$l"; then
    bad "package.nix doesn't evaluate:"
    grep -E "^error: " "$l" | head -3 | sed 's/^/       /'
    grep -oE "at $WT/[^:]+:[0-9]+" "$l" | head -1 | sed "s#$WT/#       at #"
  elif grep -qE "test result: FAILED|^--- FAIL: |^FAILED [^ ]+::|[0-9]+ failed" "$l"; then
    bad "the build works, but tests fail inside the Nix build sandbox"
    note "the sandbox has no network and an empty HOME — tests that need either fail there"
    while IFS= read -r t; do [ -n "$t" ] && FAILED_TESTS+=("$t"); done < <(
      { sed -nE 's/^test ([^ ]+) \.\.\. FAILED$/\1/p' "$l"
        sed -nE 's/^--- FAIL: ([^ ]+) .*/\1/p' "$l"
        sed -nE 's/^FAILED [^:]+::([^ ]+).*/\1/p' "$l"; } | sort -u | head -20)
    [ "${#FAILED_TESTS[@]}" -gt 0 ] && note "failing: ${FAILED_TESTS[*]}"
  elif grep -qE "No space left on device" "$l"; then
    bad "the disk is full — free some space (nix-collect-garbage -d) and build again"
  elif grep -qE "is not available on the requested hostPlatform|not supported on" "$l"; then
    bad "the package (or a dependency) isn't available on $SYSTEM"
  else
    bad "the build failed:"
  fi
  printf '   %s── last lines of the build log ──%s\n' "$DIM" "$R"
  grep -vE '^\s*$' "$l" | tail -n 15 | cut -c1-200 | sed 's/^/     /'
}

skip_tests() {
  local reason
  note "nixpkgs reviewers ask why tests are skipped: say it in a comment"
  ask reason "Why do they fail?" "they need network access, which the Nix build sandbox doesn't have"
  case "$KIND" in
    rust)   set_attr_line checkFlags "[ $(printf '"--skip=%s" ' "${FAILED_TESTS[@]}")]" ;;
    go)     set_attr_line checkFlags "[ \"-skip=^($(IFS='|'; printf '%s' "${FAILED_TESTS[*]}"))\$\" ]" ;;
    python) set_attr_line disabledTests "[ $(printf '"%s" ' "${FAILED_TESTS[@]}")]" ;;
    *)      set_attr_line doCheck false ;;
  esac
  sed -i -E "0,/^  (checkFlags|disabledTests|doCheck) = /s//  # $(printf '%s' "$reason" | sed 's/[#&/]/\\&/g')\n&/" "$WT/$FILE"
  ok "skipping ${#FAILED_TESTS[@]} test(s), with the reason in a comment"
}

ATTEMPT=0
while :; do
  ATTEMPT=$((ATTEMPT + 1))
  [ "$ATTEMPT" -le 30 ] || { KEEP_WORK=1; die "still failing after 30 builds — the log is in $BUILD_LOG"; }
  if run_logged "$BUILD_LOG" "building $ATTR (build $ATTEMPT — a first build can take a while)" build; then
    ok "built: $(readlink "$RESULT")"
    break
  fi
  fix_hash && continue
  autofix && continue
  explain_failure
  [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "stopped — the build needs a person (log: $BUILD_LOG)"; }
  while :; do
    [ "${#FAILED_TESTS[@]}" -gt 0 ] && say "t) skip those failing tests, with a comment saying why"
    say "e) edit $FILE (in ${EDITOR:-vi}), then build again"
    say "l) read the whole build log      r) build again as it is      q) quit"
    ask CHOICE "Choice" "e"
    case "$CHOICE" in
      t|T) [ "${#FAILED_TESTS[@]}" -gt 0 ] && { skip_tests; break; } ;;
      e|E) "${EDITOR:-vi}" "$WT/$FILE"
           nix-instantiate --parse "$WT/$FILE" >/dev/null 2>"$WORK/parse.err" && break
           cat "$WORK/parse.err" | head -5; warn "that doesn't parse — edit again" ;;
      l|L) "${PAGER:-less}" "$BUILD_LOG" || cat "$BUILD_LOG" ;;
      r|R) break ;;
      q|Q) note "your work is in $WT (branch $BRANCH); re-run to pick it up again"; exit 1 ;;
    esac
  done
done
OUT="$(readlink "$RESULT")"

# --- the programs it installs; meta.mainProgram must name one of them
BINS="$(find "$OUT/bin" -maxdepth 1 \( -type f -o -type l \) -perm -u+x -printf '%f\n' 2>/dev/null | sort || true)"
NBINS="$(printf '%s' "$BINS" | grep -c . || true)"
MAIN=""
if [ "$NBINS" = 0 ]; then
  warn "it installs no programs (nothing in bin/)"
  [ "$MODE" = new ] && sed -i '/^    mainProgram = /d' "$WT/$FILE"
elif printf '%s\n' "$BINS" | grep -qxF "$MAIN_GUESS"; then
  MAIN="$MAIN_GUESS"; ok "installs: $(printf '%s' "$BINS" | tr '\n' ' ')"
elif [ "$NBINS" = 1 ]; then
  MAIN="$BINS"; ok "installs: $MAIN"
else
  say "It installs: $(printf '%s' "$BINS" | tr '\n' ' ')"
  ask MAIN "Which one is the main program? (- for none)" "$(printf '%s' "$BINS" | head -1)"
  [ "$MAIN" = - ] && MAIN=""
fi
if [ "$MODE" = new ] && [ -n "$MAIN" ] && [ "$MAIN" != "$MAIN_GUESS" ]; then
  sed -i -E "s/^(    mainProgram = )\"[^\"]*\";/\1\"$MAIN\";/" "$WT/$FILE"
  ok "mainProgram = \"$MAIN\""
elif [ "$MODE" = new ] && [ -z "$MAIN" ]; then
  sed -i '/^    mainProgram = /d' "$WT/$FILE"
fi

# --- run it. A command-line program that prints its version gets nixpkgs'
# versionCheckHook, so every future build checks that too. A GUI app is
# started for you to look at.
TESTED_BIN=0
GUI=0; [ "$KIND" = flutter ] && GUI=1
grep -qE 'wrapGAppsHook|copyDesktopItems' "$WT/$FILE" && GUI=1
if [ -n "$MAIN" ] && [ "$GUI" = 0 ]; then
  VOUT="$(timeout 10 "$OUT/bin/$MAIN" --version </dev/null 2>&1 || true)"
  if printf '%s' "$VOUT" | grep -qF "$VERSION"; then
    ok "$MAIN --version → $(printf '%s' "$VOUT" | head -1 | cut -c1-60)"
    TESTED_BIN=1
    if [ "$MODE" = new ] && ! grep -q versionCheckHook "$WT/$FILE"; then
      if [ "$KIND" = python ]; then add_to_list nativeCheckInputs versionCheckHook
      else add_to_list nativeInstallCheckInputs versionCheckHook; set_attr_line doInstallCheck true; fi
      if run_logged "$BUILD_LOG" "building again with versionCheckHook" build; then
        ok "versionCheckHook added: nixpkgs now checks \`$MAIN --version\` on every build"
      else
        warn "versionCheckHook didn't pass in the sandbox — leaving it out"
        sed -i -E '/versionCheckHook/d; /^  doInstallCheck = true;$/d; /^  nativeInstallCheckInputs = \[ *\];$/d' "$WT/$FILE"
        run_logged "$BUILD_LOG" "building again without it" build || die "the build broke after removing versionCheckHook — log: $BUILD_LOG"
      fi
    fi
  elif timeout 10 "$OUT/bin/$MAIN" --help </dev/null >/dev/null 2>&1; then
    ok "$MAIN --help runs"; TESTED_BIN=1
  else
    warn "$MAIN --version / --help didn't work — try it yourself: $OUT/bin/$MAIN"
  fi
elif [ -n "$MAIN" ] && [ "$ASSUME_YES" = 0 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  if confirm "Start $MAIN now to check it works? (close it to carry on)" y; then
    "$OUT/bin/$MAIN" >"$WORK/run.log" 2>&1 || true
    confirm "Did it work?" y && TESTED_BIN=1
    [ "$TESTED_BIN" = 1 ] || { tail -n 20 "$WORK/run.log" | sed 's/^/     /'; warn "worth fixing before submitting — its output is above"; }
  fi
fi

# --- format exactly the way nixpkgs' CI checks it (treefmt from the pinned
# nixpkgs in shell.nix: nixfmt, keep-sorted for the maintainer list…)
drv() { (cd "$WT" && nix-instantiate "${NIXARGS[@]}" -A "$ATTR" 2>/dev/null) | tail -1 || true; }
DRV_BEFORE="$(drv)"
FMT_FILES=("${PKG_FILES[@]}"); [ "$ADD_MAINTAINER" = 1 ] && FMT_FILES+=("$ML")
treefmt_files() { nix-shell --run "treefmt $(printf '%q ' "$@")"; }
if run_logged "$WORK/fmt.log" "formatting with nixpkgs' treefmt (first time: fetches the pinned tools)" \
    in_wt treefmt_files "${FMT_FILES[@]}"; then
  ok "formatted like nixpkgs' CI (treefmt)"
  FORMATTED=1
else
  tail -n 6 "$WORK/fmt.log" | sed 's/^/     /'
  warn "treefmt failed — falling back to plain nixfmt"
  if in_wt tool nixfmt nixfmt "${FMT_FILES[@]}" >"$WORK/fmt.log" 2>&1; then ok "formatted with nixfmt"; FORMATTED=1
  else FORMATTED=0; warn "not formatted — CI will complain; run 'nix-shell --run treefmt' in $WT"; fi
fi
for f in "${FMT_FILES[@]}"; do
  case "$f" in
    *.nix)  nix-instantiate --parse "$WT/$f" >/dev/null 2>&1 || die "$f doesn't parse after formatting" ;;
    *.json) tool jq jq empty "$WT/$f" 2>/dev/null || die "$f isn't valid JSON after formatting" ;;
  esac
done
DRV_AFTER="$(drv)"
if [ -n "$DRV_BEFORE" ] && [ "$DRV_BEFORE" != "$DRV_AFTER" ]; then
  run_logged "$BUILD_LOG" "formatting changed the build — building again" build || die "the build broke after formatting — log: $BUILD_LOG"
fi

# --- the reviewers' checklist (pkgs/README.md, "Reviewing contributions")
CHECKS_OK=1
check() { if [ "$1" = ok ]; then ok "$2"; else bad "$2"; CHECKS_OK=0; fi; }
META="$(neval "let p = $PKGS.\"$ATTR\"; in { d = p.meta.description or \"\"; l = (p.meta.license or null) != null; m = builtins.length (p.meta.maintainers or [ ]); mp = p.meta.mainProgram or \"\"; av = p.meta.available or false; }")"
jqm() { printf '%s' "$META" | tool jq jq -r "$1"; }
[ -n "$META" ] || die "can't evaluate $ATTR's meta — something is wrong with the package"
MD="$(jqm .d)"
check "$([ -z "$(desc_problems "$MD")" ] && echo ok)" "meta.description fits the rules"
check "$([ "$(jqm .l)" = true ] && echo ok)" "meta.license is set"
if [ "$MODE" = new ]; then
  check "$([ "$(jqm .m)" -gt 0 ] && echo ok)" "meta.maintainers is set"
  [ -n "$MAIN" ] && check "$([ "$(jqm .mp)" = "$MAIN" ] && echo ok)" "meta.mainProgram names $MAIN, which it installs"
  check "$([ "$FILE" = "pkgs/by-name/$SHARD/$ATTR/package.nix" ] && echo ok)" "path fits pkgs/by-name ($FILE)"
  check "$(printf '%s' "$PNAME" | grep -qE '^[a-z0-9][a-z0-9_.+-]*$' && echo ok)" "name is lowercase ($PNAME)"
fi
check "$(case "$VERSION" in [0-9]*) echo ok ;; esac)" "version starts with a digit ($VERSION)"
check "$([ "$(jqm .av)" = true ] && echo ok)" "available on $SYSTEM"
check "$(grep -qE 'fetchFromGitHub|fetchFromGitLab|fetchFromCodeberg|fetchgit|fetchurl' "$WT/$FILE" && echo ok)" "source fetched from upstream with a nixpkgs fetcher"
check "$([ "$FORMATTED" = 1 ] && echo ok)" "formatted with nixpkgs' formatter"
if [ "$ADD_MAINTAINER" = 1 ]; then
  check "$([ "$(neval "(import ./$ML).\"$HANDLE\".github")" = "\"$GH_USER\"" ] && echo ok)" "$ML has your entry"
fi
[ "$CHECKS_OK" = 1 ] || { [ "$ASSUME_YES" = 1 ] && die "checks failed (✗ above)"; confirm "Some checks failed (✗). Carry on anyway?" n || exit 1; }

# --- nixpkgs-review: builds everything the change touches, as reviewers do
REVIEW_RAN=0
if [ "$RUN_REVIEW" = 1 ] || { [ "$ASSUME_YES" = 0 ] && [ "$MODE" = update ] \
     && confirm "Run nixpkgs-review too? (builds everything that depends on $ATTR; slow)" n; }; then
  if run_logged "$WORK/review.log" "nixpkgs-review (evaluates nixpkgs twice — several minutes)" \
      in_wt tool nixpkgs-review nixpkgs-review wip --no-shell; then
    ok "nixpkgs-review passed"; REVIEW_RAN=1
  else
    tail -n 12 "$WORK/review.log" | sed 's/^/     /'
    warn "nixpkgs-review found problems — see above"
    confirm "Carry on anyway?" n || exit 1
  fi
fi

# ========================================================== 6. review + commit
step "6/7  Review and commit"
git -C "$WT" add -- "${PKG_FILES[@]}"
[ "$ADD_MAINTAINER" = 1 ] && git -C "$WT" add -- "$ML"
git -C "$WT" --no-pager diff --cached --stat | sed 's/^/   /'

# nixpkgs' automation policy: generated code needs a person who reviewed it.
# nix-update (an update) is standard community automation and exempt.
REVIEWED=0
if [ "$MODE" = update ] && [ "${UPDATED_WITH:-}" = nix-update ]; then
  REVIEWED=1
  [ "$ASSUME_YES" = 0 ] && { git -C "$WT" --no-pager diff --cached --color=auto -- "${PKG_FILES[@]}" | head -80; }
elif [ "$ASSUME_YES" = 1 ]; then
  warn "--yes: nobody has reviewed the generated package — the PR is opened as a draft"
  note "review it, then mark it ready: nixpkgs requires a person to review generated code"
  DRAFT=1
else
  say "nixpkgs asks that a person reviews generated code before it's submitted"
  say "(CONTRIBUTING.md, \"Automation/AI policy\"). Here is the whole change:"
  echo
  git -C "$WT" diff --cached --color=auto
  echo
  if confirm "Have you read it, and do you stand behind it?" n; then
    REVIEWED=1
  else
    note "edit it in $WT and re-run, or carry on as a draft PR and review it there"
    confirm "Open it as a draft pull request instead?" y || exit 1
    DRAFT=1
  fi
fi

# the commits carry your identity; a fresh clone may not have one
ID_ARGS=()
if [ -z "$(git -C "$WT" config user.email 2>/dev/null || true)" ]; then
  ID_ARGS=(-c "user.name=$(git -C "$REPO" config user.name 2>/dev/null || printf '%s' "${M_NAME:-$GH_USER}")"
           -c "user.email=$(git -C "$REPO" config user.email 2>/dev/null || printf '%s+%s@users.noreply.github.com' "$GH_ID" "$GH_USER")")
fi
gcommit() { git -C "$WT" "${ID_ARGS[@]+"${ID_ARGS[@]}"}" commit -q "$@"; }

if [ "$ADD_MAINTAINER" = 1 ]; then
  gcommit -m "maintainers: add $HANDLE" -- "$ML"
  ok "committed: maintainers: add $HANDLE"
fi
if [ "$MODE" = new ]; then
  TITLE_MSG="$ATTR: init at $VERSION"
  gcommit -m "$TITLE_MSG" -- "${PKG_FILES[@]}"
else
  TITLE_MSG="$ATTR: $OLD_VERSION -> $VERSION"
  if [ -n "$CHANGELOG_REAL" ]; then gcommit -m "$TITLE_MSG" -m "Changelog: $CHANGELOG_REAL" -- "${PKG_FILES[@]}"
  else gcommit -m "$TITLE_MSG" -- "${PKG_FILES[@]}"; fi
fi
ok "committed: $TITLE_MSG"
[ -z "$(git -C "$WT" status --porcelain --untracked-files=no -- "${PKG_FILES[@]}")" ] || die "something was left uncommitted in $WT"
NCOMMITS="$(git -C "$WT" rev-list --count "$BASE..HEAD")"

save_answers
if [ "$DRYRUN" = 1 ]; then
  warn "dry run — stopping before the push"
  note "branch $BRANCH ($NCOMMITS commit(s)) is ready in $WT"
  exit 0
fi

# ========================================================== 7. pull request
step "7/7  Pull request"
go "Push $BRANCH to $GH_USER/$FORK_NAME and open the pull request?" || { note "branch $BRANCH is committed in $WT"; exit 0; }

# Bring the fork's master up to date first: then the push only sends the new
# commits (fast, and fine from a shallow checkout).
if run_logged "$WORK/sync.log" "syncing your fork with NixOS/nixpkgs" gh repo sync "$GH_USER/$FORK_NAME" --branch master; then
  ok "fork synced"
else
  warn "couldn't sync the fork ($(tail -n 1 "$WORK/sync.log")) — pushing anyway"
fi

# gh does the authentication for an https remote: no SSH key needed
push_branch() {
  git -C "$WT" -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    push -f "$FK" "HEAD:refs/heads/$BRANCH"
}
while ! run_logged "$WORK/push.log" "pushing $BRANCH" push_branch; do
  tail -n 4 "$WORK/push.log" | sed 's/^/     /'
  if grep -q "workflow" "$WORK/push.log"; then
    warn "GitHub wants the 'workflow' permission for this push"
    confirm "Grant it now (gh auth refresh -s workflow)?" y && gh auth refresh -h github.com -s workflow && continue
  elif grep -qE "shallow update not allowed|did not receive expected object" "$WORK/push.log"; then
    warn "your fork is behind NixOS/nixpkgs and couldn't be synced — sync it on https://github.com/$GH_USER/$FORK_NAME"
  else
    warn "the push failed — usually the network, or gh's login expired (gh auth status)"
  fi
  [ "$ASSUME_YES" = 0 ] && confirm "Try again?" y || die "not pushed; the branch is committed in $WT"
done
REMOTE_HEAD="$(git -C "$WT" ls-remote "$FK" "refs/heads/$BRANCH" | cut -f1)"
[ "$REMOTE_HEAD" = "$(git -C "$WT" rev-parse HEAD)" ] || die "the fork's $BRANCH doesn't match what was pushed"
ok "pushed: https://github.com/$GH_USER/$FORK_NAME/tree/$BRANCH"

# --- the pull request: nixpkgs' own template, with what was verified ticked
PR_URL="$(gh pr list -R "$UPSTREAM_SLUG" --head "$BRANCH" --author "@me" --state open --json url --jq '.[0].url // ""' 2>/dev/null || true)"
if [ -n "$PR_URL" ]; then
  ok "updated the open pull request: $PR_URL"
else
  BODY="$WORK/pr.md"
  {
    if [ "$MODE" = new ]; then
      printf '%s\n\nHomepage: %s\n' "$MD" "$HOMEPAGE"
    else
      printf 'Update %s from %s to %s.\n' "$ATTR" "$OLD_VERSION" "$VERSION"
      [ -n "$CHANGELOG_REAL" ] && printf '\nChangelog: %s\n' "$CHANGELOG_REAL"
    fi
    [ -n "$CLOSES" ] && printf '\nCloses #%s\n' "$CLOSES"
    printf '\n'
    TPL="$WT/.github/PULL_REQUEST_TEMPLATE.md"
    if [ -f "$TPL" ]; then
      # tick only what this run actually did or verified
      TICK=(-e "s/^\\([[:space:]]*\\)- \\[ \\] $SYSTEM\$/\\1- [x] $SYSTEM/")
      [ "$REVIEW_RAN" = 1 ] && TICK+=(-e 's/^- \[ \] Ran `nixpkgs-review`/- [x] Ran `nixpkgs-review`/')
      [ "$TESTED_BIN" = 1 ] && TICK+=(-e 's/^- \[ \] Tested basic functionality/- [x] Tested basic functionality/')
      [ "$CHECKS_OK" = 1 ]  && TICK+=(-e 's/^- \[ \] Fits \[CONTRIBUTING\.md\]/- [x] Fits [CONTRIBUTING.md]/')
      [ "$REVIEWED" = 1 ]   && TICK+=(-e 's/^- \[ \] Follows the \[automation\/AI policy\]/- [x] Follows the [automation\/AI policy]/')
      sed "${TICK[@]}" "$TPL"
    else
      printf -- '- Built on %s\n' "$SYSTEM"
    fi
    printf '\n---\n\n'
    if [ "$MODE" = update ] && [ "${UPDATED_WITH:-}" = nix-update ]; then
      printf 'Updated with `nix-update`, run by [store-submit.sh](%s); built and checked locally.\n' "$TOOL_URL"
    else
      printf 'Automation disclosure: `package.nix` was generated by [store-submit.sh](%s), a deterministic script (no AI involved when it runs) that detects the project, fills in hashes by building, and formats with treefmt.' "$TOOL_URL"
      [ "$REVIEWED" = 1 ] && printf ' I reviewed the result before submitting.\n' || printf ' Not reviewed yet — this stays a draft until it is.\n'
    fi
  } > "$BODY"
  DRAFT_ARG=(); [ "$DRAFT" = 1 ] && DRAFT_ARG=(--draft)
  if ! PR_URL="$(gh pr create -R "$UPSTREAM_SLUG" --base master --head "$GH_USER:$BRANCH" \
        --title "$TITLE_MSG" --body-file "$BODY" "${DRAFT_ARG[@]+"${DRAFT_ARG[@]}"}" 2>"$WORK/pr.err")"; then
    sed 's/^/     /' "$WORK/pr.err" | tail -5
    KEEP_WORK=1
    die "gh couldn't open the pull request — the text is in $BODY; open it on https://github.com/$UPSTREAM_SLUG/compare/master...$GH_USER:$FORK_NAME:$BRANCH"
  fi
  PR_URL="$(printf '%s' "$PR_URL" | grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' | tail -1)"
  [ "$(gh pr view "$PR_URL" --json state --jq .state 2>/dev/null || true)" = OPEN ] || die "the pull request doesn't show as open: $PR_URL"
  if [ "$DRAFT" = 1 ]; then ok "pull request opened (draft): $PR_URL"; else ok "pull request opened: $PR_URL"; fi
fi

# ================================================================ summary
printf '\n   %sDone.%s %s\n   %s\n\n   What happens now:\n' "$B" "$R" "$TITLE_MSG" "$PR_URL"
say "  • CI builds it and checks the formatting and the package structure."
say "  • A reviewer looks at it; answer their comments on the PR (re-running"
say "    this wizard pushes changes to the same branch)."
[ "$DRAFT" = 1 ] && say "  • It is a ${B}draft${R}: review it, then press \"Ready for review\" on GitHub."
if [ "$ADD_MAINTAINER" = 1 ]; then
  say "  • After the merge GitHub emails you an invite to NixOS/nixpkgs-maintainers."
  say "    ${B}Accept it within a week${R} — it expires."
fi
say "  • Updates: nixpkgs' bot (r-ryantm) opens update PRs for new tags; or run"
say "    this wizard again after your next release."
echo
}

# ##########################################################################
#   Linux distributions — the list, and a checkbox picker for it
# ##########################################################################
# id|name|wizard (blank = not written yet)|what publishing there means
DISTROS="nix|NixOS / Nix (nixpkgs)|wizard_nix|a package in nixpkgs, through a pull request
aur|Arch Linux (AUR)|wizard_aur|a PKGBUILD in the Arch User Repository
deb|Debian / Ubuntu||coming later
fedora|Fedora (COPR)||coming later
flathub|Flathub (every distro)|wizard_flathub|prepared up to the pull request; you open it"

distro_field() {  # distro_field <id> <1=id 2=name 3=wizard 4=description>
  printf '%s\n' "$DISTROS" | awk -F'|' -v id="$1" -v f="$2" '$1 == id { print $f }'
}
distro_items() {  # the list as multi_select lines: id|label|selectable|note
  printf '%s\n' "$DISTROS" | awk -F'|' '{ print $1 "|" $2 "|" ($3 != "" ? 1 : 0) "|" $4 }'
}

# multi_select VAR "<id|label|selectable|note lines>" "<preselected ids>"
# A checkbox list: ↑/↓ (or j/k) move, Space toggles, a toggles all, a digit
# toggles that line, Enter confirms. Lines that aren't selectable are shown
# dimmed and can't be picked. Without a terminal it reads numbers or ids
# instead. VAR gets the chosen ids, space-separated.
multi_select() {
  local __var="$1" __pre=" ${3:-} " __ids=() __labels=() __on=() __notes=() __sel=()
  local id label en note i n cur=0 key rest count all msg="" in tok ok_ids
  while IFS='|' read -r id label en note; do
    [ -n "$id" ] || continue
    __ids+=("$id"); __labels+=("$label"); __on+=("$en"); __notes+=("$note")
    case "$__pre" in *" $id "*) [ "$en" = 1 ] && __sel+=(1) || __sel+=(0) ;; *) __sel+=(0) ;; esac
  done <<EOF
$2
EOF
  n=${#__ids[@]}
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    # no terminal to draw on: numbers (or ids), space or comma separated
    for ((i = 0; i < n; i++)); do
      if [ "${__on[$i]}" = 1 ]; then printf '   %s%d)%s %-28s %s%s%s\n' "$B" $((i + 1)) "$R" "${__labels[$i]}" "$DIM" "${__notes[$i]}" "$R"
      else printf '   %s%d) %-28s %s%s\n' "$DIM" $((i + 1)) "${__labels[$i]}" "${__notes[$i]}" "$R"; fi
    done
    local def=""
    for ((i = 0; i < n; i++)); do [ "${__sel[$i]}" = 1 ] && def="$def${def:+ }$((i + 1))"; done
    while :; do
      printf '   %sPick one or more%s%s: ' "$B" "$R" "${def:+ [$def]}" >&2
      IFS= read -r in || { printf '\n' >&2; printf '\n%sERROR: end of input%s\n' "$RED" "$R" >&2; exit 1; }
      [ -n "$in" ] || in="$def"
      ok_ids=""; msg=""
      for tok in $(printf '%s' "$in" | tr ',' ' '); do
        i=-1
        case "$tok" in
          *[!0-9]*) for ((j = 0; j < n; j++)); do [ "${__ids[$j]}" = "$tok" ] && i=$j; done ;;
          *)        i=$((tok - 1)) ;;
        esac
        if [ "$i" -lt 0 ] || [ "$i" -ge "$n" ]; then msg="no such choice: $tok"; break; fi
        [ "${__on[$i]}" = 1 ] || { msg="${__labels[$i]} is not available yet"; break; }
        case " $ok_ids " in *" ${__ids[$i]} "*) ;; *) ok_ids="$ok_ids${ok_ids:+ }${__ids[$i]}" ;; esac
      done
      [ -z "$msg" ] && [ -n "$ok_ids" ] && break
      printf '   %s! %s%s\n' "$YLW" "${msg:-pick at least one}" "$R" >&2
    done
    printf -v "$__var" '%s' "$ok_ids"
    return 0
  fi
  # the checkbox list
  printf '\033[?25l'
  local drawn=0
  while :; do
    [ "$drawn" = 1 ] && printf '\033[%dA' $((n + 2))
    drawn=1
    for ((i = 0; i < n; i++)); do
      local mark="  " box="[ ]"
      [ "$i" = "$cur" ] && mark="${CYN}›${R} "
      [ "${__sel[$i]}" = 1 ] && box="${GRN}[x]${R}"
      if [ "${__on[$i]}" = 1 ]; then
        printf '\r\033[K   %s%s %-28s %s%s%s\n' "$mark" "$box" "${__labels[$i]}" "$DIM" "${__notes[$i]}" "$R"
      else
        printf '\r\033[K   %s%s[ ] %-28s %s%s\n' "$mark" "$DIM" "${__labels[$i]}" "${__notes[$i]}" "$R"
      fi
    done
    printf '\r\033[K   %s↑/↓ move · Space select · a all · Enter confirm%s\n' "$DIM" "$R"
    printf '\r\033[K   %s%s%s\n' "$YLW" "$msg" "$R"
    msg=""
    IFS= read -rsn1 key || key=q
    case "$key" in
      $'\e') rest=""; IFS= read -rsn2 -t 0.05 rest || true
             case "$rest" in '[A') cur=$(( (cur + n - 1) % n )) ;; '[B') cur=$(( (cur + 1) % n )) ;; esac ;;
      k) cur=$(( (cur + n - 1) % n )) ;;
      j) cur=$(( (cur + 1) % n )) ;;
      ' ') if [ "${__on[$cur]}" = 1 ]; then __sel[$cur]=$(( 1 - __sel[cur] )); else msg="${__labels[$cur]} is not available yet"; fi ;;
      [1-9]) i=$((key - 1))
             if [ "$i" -lt "$n" ] && [ "${__on[$i]}" = 1 ]; then __sel[$i]=$(( 1 - __sel[i] )); cur=$i
             elif [ "$i" -lt "$n" ]; then msg="${__labels[$i]} is not available yet"; fi ;;
      a|A) all=1
           for ((i = 0; i < n; i++)); do [ "${__on[$i]}" = 1 ] && [ "${__sel[$i]}" = 0 ] && all=0; done
           for ((i = 0; i < n; i++)); do [ "${__on[$i]}" = 1 ] && __sel[$i]=$(( 1 - all )); done ;;
      '') count=0; for ((i = 0; i < n; i++)); do count=$((count + __sel[i])); done
          [ "$count" -gt 0 ] && break
          msg="pick at least one (Space selects)" ;;
      q|Q) printf '\033[?25h'; printf '\n'; exit 1 ;;
    esac
  done
  printf '\033[?25h'
  ok_ids=""
  for ((i = 0; i < n; i++)); do [ "${__sel[$i]}" = 1 ] && ok_ids="$ok_ids${ok_ids:+ }${__ids[$i]}"; done
  printf -v "$__var" '%s' "$ok_ids"
}

# ##########################################################################
#   Linux wizard — store-submit.sh linux [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_linux() {
#
# store-submit.sh linux — publish one app to several Linux distributions:
# pick the distros, answer the questions about the app once (they're kept in
# .store-submit.conf in the app's repository), then each distro's wizard runs
# with those answers, one after the other.

set -eu

DRYRUN=0
SAVE=1
ASSUME_YES=0
ASK_ALL=0
REPO_ARG=""
DISTROS_ARG=""
CONFIG_ARG=""
ID_ARG=""

usage() {
  cat <<'USAGE'
store-submit.sh linux — publish an app to several Linux distributions at once.

  -h, --help           show this text
  -d, --distros LIST   distros to publish to, skipping the question:
                       nix, aur, flathub — comma-separated, or "all"
      --repo PATH      the app's git checkout (default: the repo you run it in)
      --config FILE    the shared answers (default: .store-submit.conf in the repo)
  -y, --yes            passed to each distro's wizard
      --ask            ask every question about the app again
  -n, --dry-run        passed to each distro's wizard: nothing is published
      --no-save        don't write the answers to the config

The questions about the app are asked once; every distro uses the answers.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -d|--distros) DISTROS_ARG="${2-}"; shift ;;
    --repo)       REPO_ARG="${2-}"; shift ;;
    --config)     CONFIG_ARG="${2-}"; shift ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --ask)        ASK_ALL=1 ;;
    -n|--dry-run) DRYRUN=1 ;;
    --no-save)    SAVE=0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WIZ_NAME=linux-submit
linux_common
SELF="$(readlink -f "$0")"

cat <<BANNER

  ${B}Linux distributions${R}

  Three stages:
    1. distros    — where the app goes (as many as you like)
    2. your app   — asked once, kept in .store-submit.conf for every distro
    3. publish    — each distro's own wizard, with those answers

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: nothing is published"

# ------------------------------------------------------------- 1. distros
step "1/3  Distros"
# the config (if there is one yet) remembers the distros picked last time
PRE_REPO="${REPO_ARG:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PRE_CONF="${CONFIG_ARG:-$PRE_REPO/.store-submit.conf}"
PRESET="$(LINUX_CONF="$PRE_CONF" cfg_get distros)"
if [ -n "$DISTROS_ARG" ]; then
  CHOSEN=""
  for d in $(printf '%s' "$DISTROS_ARG" | tr ',' ' '); do
    [ "$d" = all ] && { CHOSEN="$(printf '%s\n' "$DISTROS" | awk -F'|' '$3 != "" { printf "%s ", $1 }')"; break; }
    [ -n "$(distro_field "$d" 1)" ] || die "no such distro: $d (one of: $(printf '%s\n' "$DISTROS" | cut -d'|' -f1 | tr '\n' ' '))"
    [ -n "$(distro_field "$d" 3)" ] || die "$(distro_field "$d" 2) is not available yet"
    CHOSEN="$CHOSEN $d"
  done
  CHOSEN="$(printf '%s' "$CHOSEN" | xargs)"
else
  [ "$ASSUME_YES" = 1 ] && [ -z "$PRESET" ] && die "--yes needs --distros (or a config that names them)"
  if [ "$ASSUME_YES" = 1 ]; then CHOSEN="$PRESET"
  else
    say "Which distributions? One set of answers is used for all of them."
    multi_select CHOSEN "$(distro_items)" "$PRESET"
  fi
fi
for d in $CHOSEN; do ok "$(distro_field "$d" 2)"; done

# ------------------------------------------------------------- 2. the app
LINUX_CONF="${CONFIG_ARG:-}"
[ -n "$LINUX_CONF" ] && case "$LINUX_CONF" in /*) ;; *) LINUX_CONF="$PWD/$LINUX_CONF" ;; esac
linux_app "2/3  Your app — asked once, for every distro"
case " $CHOSEN " in *" flathub "*) flathub_questions ;; esac
[ "$SAVE" = 1 ] && cfg_set distros "$CHOSEN"

# ------------------------------------------------------------- 3. publish
step "3/3  Publish"
FWD=(--repo "$REPO" --config "$LINUX_CONF")
export SS_HANDOFF_DIR="$WORK/handoff"
[ "$ASSUME_YES" = 1 ] && FWD+=(--yes)
[ "$DRYRUN" = 1 ]     && FWD+=(--dry-run)
[ "$SAVE" = 0 ]       && FWD+=(--no-save)
RESULTS=""
set -- $CHOSEN
TOTAL=$#; n=0
for d in "$@"; do
  n=$((n + 1))
  name="$(distro_field "$d" 2)"
  printf '\n%s━━ %s (%d/%d): store-submit.sh %s %s%s\n' "$B$CYN" "$name" "$n" "$TOTAL" "$d" "${FWD[*]}" "$R"
  # its own process, like every wizard: its traps and exits stay its own
  rc=0
  ( cd "$REPO" && bash "$SELF" "$d" "${FWD[@]}" ) || rc=$?
  if [ "$rc" = 0 ]; then
    RESULTS="$RESULTS$d|ok|"$'\n'
  else
    RESULTS="$RESULTS$d|fail|$rc"$'\n'
    if [ "$n" -lt "$TOTAL" ]; then
      warn "$name stopped (exit $rc)"
      [ "$ASSUME_YES" = 1 ] || confirm "Carry on with the other distro(s)?" y || break
    fi
  fi
done

printf '\n   %sSummary%s\n' "$B" "$R"
FAILED=0
while IFS='|' read -r d res rc; do
  [ -n "$d" ] || continue
  if [ "$res" = ok ]; then ok "$(distro_field "$d" 2)"
  else bad "$(distro_field "$d" 2) — stopped (exit $rc); run it again with: store-submit.sh $d"; FAILED=1; fi
done <<EOF
$RESULTS
EOF
for d in "$@"; do
  printf '%s' "$RESULTS" | grep -q "^$d|" || { note "$(distro_field "$d" 2) — not started"; FAILED=1; }
done
if [ -d "$SS_HANDOFF_DIR" ]; then
  printf '\n   %sStill to do by you%s\n' "$B$YLW" "$R"
  for f in "$SS_HANDOFF_DIR"/*.txt; do
    [ -f "$f" ] || continue
    printf '   %s%s%s\n' "$B" "$(head -1 "$f")" "$R"
    tail -n +2 "$f" | sed 's/^/   /'
  done
fi
echo
[ "$FAILED" = 0 ] || exit 1
}

# ##########################################################################
#   AUR wizard — store-submit.sh aur [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_aur() {
#
# store-submit.sh aur — publish an app to the AUR (Arch User Repository), or
# ship a new version of one that is already there.
#
# Follows Arch's own guides:
#   https://wiki.archlinux.org/title/AUR_submission_guidelines
#   https://manual.archlinux.page/package-guidelines/  (Rust, Go, Python, …)
#
# Writes a PKGBUILD in Arch's current style (a package already on the AUR is
# bumped instead), takes the checksum from the real release tarball, writes
# .SRCINFO, test-builds it in a clean Arch container with namcap, and — after
# you've read it — pushes it to the AUR over SSH.

set -eu

DRYRUN=0
SAVE=1
ASSUME_YES=0
ASK_ALL=0
NO_TEST=0
REPO_ARG=""
KEY_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aur-submit"
CONF="$CONF_DIR/last.conf"
AUR_HOST="aur@aur.archlinux.org"
# where AUR repositories are cloned from and pushed to (overridable for testing)
AUR_GIT="${AUR_GIT_BASE:-ssh://aur@aur.archlinux.org}"
AUR_WEB="https://aur.archlinux.org"
ARCH_IMAGE="${ARCH_IMAGE:-docker.io/archlinux/archlinux:base-devel}"

usage() {
  cat <<'USAGE'
store-submit.sh aur — publish an app to the AUR, or update it there.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask; stops only on
                      problems. A new package still needs you to review it.
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --config FILE   the shared answers (default: .store-submit.conf in the repo)
      --key FILE      the SSH key your AUR account has (default: ~/.ssh/aur)
      --no-test       skip the test build in an Arch container
  -n, --dry-run       write, check and commit locally; push nothing
      --no-save       do not remember the answers for next time
      --forget        delete the remembered answers and exit
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -n|--dry-run) DRYRUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --ask)        ASK_ALL=1 ;;
    --repo)       REPO_ARG="${2-}"; shift ;;
    --config)     LINUX_CONF="${2-}"; shift ;;
    --key)        KEY_ARG="${2-}"; shift ;;
    --no-test)    NO_TEST=1 ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF"; printf 'forgot %s\n' "$CONF"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WIZ_NAME=aur-submit
linux_common

# ------------------------------------------------------- remembered answers
SAVED_REPO=""; SAVED_AUR_KEY=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  {
    printf '# written by store-submit.sh aur — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n'    "${REPO:-${SAVED_REPO:-}}"
    printf 'SAVED_AUR_KEY=%q\n' "${KEY:-${SAVED_AUR_KEY:-}}"
  } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  chmod 600 "$CONF" 2>/dev/null || true
}

# ------------------------------------------------------------------ helpers
# arch_where <package> — "official", "aur" or "" (not packaged), cached per run
arch_where() {
  local c="$WORK/where.cache" r
  r="$(sed -n "s/^$1 //p" "$c" 2>/dev/null | head -1)"
  if [ -z "$r" ]; then
    if curl -sf --max-time 20 "https://archlinux.org/packages/search/json/?name=$1" | grep -q '"pkgname"'; then r=official
    elif curl -sf --max-time 20 "$AUR_WEB/rpc/v5/info?arg[]=$1" | grep -q '"resultcount":[1-9]'; then r=aur
    else r=none; fi
    printf '%s %s\n' "$1" "$r" >> "$c"
  fi
  [ "$r" = none ] || printf '%s' "$r"
}
# pc_arch <pkg-config module> — the Arch package that ships it
pc_arch() {
  case "$1" in
    gtk4) echo gtk4 ;; gtk+-3.0) echo gtk3 ;; libadwaita-1) echo libadwaita ;;
    glib-2.0|gio-2.0|gobject-2.0|gio-unix-2.0) echo glib2 ;; json-glib-1.0) echo json-glib ;;
    libsoup-3.0) echo libsoup3 ;; webkitgtk-6.0) echo webkitgtk-6.0 ;; webkit2gtk-4.1) echo webkit2gtk-4.1 ;;
    gtksourceview-5) echo gtksourceview5 ;; sqlite3) echo sqlite ;; openssl|libssl|libcrypto) echo openssl ;;
    libcurl) echo curl ;; zlib) echo zlib ;; x11) echo libx11 ;; wayland-client|wayland-cursor) echo wayland ;;
    xkbcommon) echo libxkbcommon ;; dbus-1) echo dbus ;; libpulse|libpulse-simple) echo libpulse ;;
    alsa) echo alsa-lib ;; libxml-2.0) echo libxml2 ;; cairo) echo cairo ;; pango|pangocairo) echo pango ;;
    gdk-pixbuf-2.0) echo gdk-pixbuf2 ;; fontconfig) echo fontconfig ;; freetype2) echo freetype2 ;;
    libpng) echo libpng ;; libjpeg) echo libjpeg-turbo ;; sdl2) echo sdl2-compat ;; sdl3) echo sdl3 ;;
    vulkan) echo vulkan-icd-loader ;; libsystemd|libudev) echo systemd-libs ;; libsecret-1) echo libsecret ;;
    libnotify) echo libnotify ;; gstreamer-1.0) echo gstreamer ;; gstreamer-plugins-base-1.0) echo gst-plugins-base-libs ;;
    epoxy) echo libepoxy ;; libarchive) echo libarchive ;; libzstd) echo zstd ;; liblzma) echo xz ;; libpcre2-8) echo pcre2 ;;
    *) echo "$1" ;;
  esac
}
# srcinfo <dir> — the .SRCINFO makepkg would write for <dir>/PKGBUILD. makepkg
# itself is used when it's installed; otherwise the PKGBUILD is read the same
# way makepkg does (sourced in a clean shell), so it works on any distro.
srcinfo() {
  if have makepkg; then ( cd "$1" && makepkg --printsrcinfo ); return; fi
  ( cd "$1" && env -i PATH="$PATH" bash --norc --noprofile -c '
    CARCH=x86_64
    source ./PKGBUILD || exit 1
    f() { local k="$1" v; shift; for v in "$@"; do [ -n "$v" ] && printf "\t%s = %s\n" "$k" "$v"; done; return 0; }
    printf "pkgbase = %s\n" "${pkgbase:-$pkgname}"
    f pkgdesc "${pkgdesc:-}"; f pkgver "$pkgver"; f pkgrel "$pkgrel"; f epoch "${epoch:-}"
    f url "${url:-}"; f install "${install:-}"; f changelog "${changelog:-}"
    f arch "${arch[@]}"; f groups "${groups[@]}"; f license "${license[@]}"
    f checkdepends "${checkdepends[@]}"; f makedepends "${makedepends[@]}"; f depends "${depends[@]}"
    f optdepends "${optdepends[@]}"; f provides "${provides[@]}"; f conflicts "${conflicts[@]}"
    f replaces "${replaces[@]}"; f backup "${backup[@]}"; f options "${options[@]}"
    f source "${source[@]}"; f validpgpkeys "${validpgpkeys[@]}"; f noextract "${noextract[@]}"
    f md5sums "${md5sums[@]}"; f sha1sums "${sha1sums[@]}"; f sha224sums "${sha224sums[@]}"
    f sha256sums "${sha256sums[@]}"; f sha384sums "${sha384sums[@]}"; f sha512sums "${sha512sums[@]}"
    f b2sums "${b2sums[@]}"
    printf "\npkgname = %s\n" "$pkgname"
  ' )
}
# shq <text> — as a double-quoted shell string for the PKGBUILD
shq() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/[\\"$`]/\\&/g')"; }

# =============================================================== 0. orientation
cat <<BANNER

  ${B}AUR submission wizard${R}

  Six stages:
    1. your app     — shared with the other distros (.store-submit.conf)
    2. the AUR      — your SSH key, the package name, new package or update
    3. PKGBUILD     — written (or bumped); checksum from the real tarball
    4. check        — .SRCINFO, and a clean test build in an Arch container
    5. review       — you read the change
    6. publish      — committed and pushed to the AUR

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: everything up to the commit; nothing is pushed"
[ "$ASSUME_YES" = 1 ] && note "--yes: using everything detected; stopping only on problems"
for t in git ssh curl sha256sum tar; do
  have "$t" || die "$t is missing — install it and re-run"
done

# ============================================================== 1. the app
linux_app "1/6  Your app"
# Arch versions can't contain "-" (makepkg splits pkgver-pkgrel on it)
PKGVER="$(printf '%s' "$VERSION" | tr -- '-' '_')"
[ "$PKGVER" != "$VERSION" ] && note "Arch versions can't contain '-': pkgver is $PKGVER"
case "$PKGVER" in *[:/[:space:]]*) die "version '$VERSION' has characters Arch doesn't allow in pkgver (: / space)" ;; esac

# ================================================================= 2. AUR
step "2/6  The AUR"
PKG="$PNAME"

# --- the rules: nothing that Arch already ships
OFFICIAL="$(curl -sf --max-time 20 "https://archlinux.org/packages/search/json/?name=$PKG" || true)"
if printf '%s' "$OFFICIAL" | grep -q '"pkgname"'; then
  REPOS="$(printf '%s' "$OFFICIAL" | tool jq jq -r '[.results[].repo] | unique | join(", ")' 2>/dev/null || echo official)"
  die "Arch already ships '$PKG' in its official repositories ($REPOS) — the AUR doesn't allow duplicates"
fi
[ -n "$OFFICIAL" ] && ok "'$PKG' isn't in Arch's official repositories"

# --- your SSH key: the AUR only takes pushes over SSH
KEY="${KEY_ARG:-${SAVED_AUR_KEY:-}}"
[ -z "$KEY" ] && [ -f "$HOME/.ssh/aur" ] && KEY="$HOME/.ssh/aur"
KEY="${KEY/#\~/$HOME}"
aur_ssh() {
  ssh ${KEY:+-i "$KEY" -o IdentitiesOnly=yes} -o BatchMode=yes -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=accept-new "$AUR_HOST" "$@"
}
export GIT_SSH_COMMAND="ssh ${KEY:+-i $(printf '%q' "$KEY") -o IdentitiesOnly=yes} -o StrictHostKeyChecking=accept-new"
while ! aur_ssh list-repos > "$WORK/repos" 2> "$WORK/ssh.err"; do
  sed 's/^/     /' "$WORK/ssh.err" | tail -3
  if grep -qiE "permission denied|publickey" "$WORK/ssh.err"; then
    warn "the AUR doesn't accept ${KEY:-your default SSH key} yet"
    if [ -z "$KEY" ] || [ ! -f "$KEY" ]; then
      say "Arch recommends a key just for the AUR. The wizard can make one: ~/.ssh/aur"
      [ "$ASSUME_YES" = 1 ] && die "set up your AUR SSH key once without --yes"
      if confirm "Create ~/.ssh/aur now? (ssh-keygen asks for an optional passphrase)" y; then
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        ssh-keygen -t ed25519 -f "$HOME/.ssh/aur" -C "aur $(id -un)@$(uname -n)" || die "ssh-keygen failed"
        KEY="$HOME/.ssh/aur"
        GIT_SSH_COMMAND="ssh -i $(printf '%q' "$KEY") -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
        export GIT_SSH_COMMAND
      fi
    fi
    if [ -n "$KEY" ] && [ -f "$KEY.pub" ]; then
      say "Add this public key to your AUR account:"
      printf '\n     %s\n\n' "$(cat "$KEY.pub")"
    else
      say "Add your SSH public key to your AUR account — the .pub file of the key ssh uses,"
      say "e.g. $(ls "$HOME"/.ssh/id_*.pub 2>/dev/null | head -1 || true)${KEY:+ (or $KEY.pub)}"
    fi
    note "1. log in at $AUR_WEB/login (no account yet? $AUR_WEB/register)"
    note "2. My Account → SSH Public Key → paste it → Update"
    note "   (to use it outside this wizard too: 'Host aur.archlinux.org / IdentityFile ${KEY:-~/.ssh/aur} / User aur' in ~/.ssh/config)"
  else
    warn "couldn't reach the AUR over SSH — the network, or a firewall blocking port 22?"
  fi
  [ "$ASSUME_YES" = 1 ] && die "no SSH access to the AUR"
  confirm "Check again?" y || die "the AUR needs SSH access to publish"
done
ok "the AUR accepts your SSH key${KEY:+ ($KEY)}"

# --- new package, update, or someone else's?
INFO="$(curl -sf --max-time 20 "$AUR_WEB/rpc/v5/info?arg[]=$PKG" || true)"
[ -n "$INFO" ] || die "couldn't ask the AUR about '$PKG' ($AUR_WEB) — check your connection"
MODE=new; OLD_PKGVER=""
if printf '%s' "$INFO" | grep -q '"resultcount":[1-9]'; then
  MAINTAINER="$(printf '%s' "$INFO" | tool jq jq -r '.results[0].Maintainer // ""')"
  AUR_VERSION="$(printf '%s' "$INFO" | tool jq jq -r '.results[0].Version')"
  if grep -qxF "$PKG" "$WORK/repos"; then
    MODE=update; OLD_PKGVER="${AUR_VERSION%-*}"
    ok "'$PKG' is yours on the AUR, at $AUR_VERSION — this is an update"
  elif [ -z "$MAINTAINER" ]; then
    die "'$PKG' is on the AUR but orphaned — adopt it on $AUR_WEB/packages/$PKG (\"Adopt Package\"), then re-run"
  else
    say "'$PKG' is on the AUR, maintained by $MAINTAINER: $AUR_WEB/packages/$PKG"
    note "only its maintainers can push to it — comment there to suggest the update, or ask to co-maintain"
    die "'$PKG' belongs to $MAINTAINER on the AUR"
  fi
else
  ok "'$PKG' is new to the AUR"
fi
if [ "$MODE" = update ]; then
  [ "$OLD_PKGVER" = "$PKGVER" ] && die "the AUR already has $PKG $PKGVER — nothing to do"
  if [ "$(printf '%s\n%s\n' "$OLD_PKGVER" "$PKGVER" | sort -V | tail -1)" != "$PKGVER" ]; then
    die "$PKGVER is older than the AUR's $OLD_PKGVER"
  fi
fi

# --- the AUR repository, in a cache the wizard owns
AURDIR="${XDG_CACHE_HOME:-$HOME/.cache}/store-submit/aur/$PKG"
if [ -d "$AURDIR/.git" ]; then
  git -C "$AURDIR" fetch -q origin 2>/dev/null || true
  if git -C "$AURDIR" rev-parse -q --verify origin/master >/dev/null; then
    git -C "$AURDIR" checkout -q -f -B master origin/master
  fi
  git -C "$AURDIR" clean -qfdx
else
  mkdir -p "$(dirname "$AURDIR")"
  git -c init.defaultBranch=master clone -q "$AUR_GIT/$PKG.git" "$AURDIR" 2>"$WORK/clone.err" \
    || { cat "$WORK/clone.err"; die "couldn't clone $AUR_GIT/$PKG.git"; }
fi
if [ "$MODE" = new ] && [ -f "$AURDIR/PKGBUILD" ]; then
  note "the AUR has history for '$PKG' (a deleted package): building on top of it"
fi
[ "$MODE" = update ] && [ ! -f "$AURDIR/PKGBUILD" ] && die "the AUR repository for $PKG has no PKGBUILD"
ok "AUR repository: $AURDIR"

# ============================================================= 3. PKGBUILD
step "3/6  PKGBUILD"

# --- the source: the forge's tarball of the tag, and its real checksum
case "$TAG" in
  "v$VERSION") TAGX='v${pkgver}' ;;
  "$VERSION")  TAGX='${pkgver}' ;;
  *)           TAGX="$TAG" ;;
esac
[ "$PKGVER" != "$VERSION" ] && TAGX="$TAG"   # pkgver was rewritten: keep the literal tag
tag_url() {  # tag_url <tag> — the tarball URL for that tag
  case "$FORGE" in
    github)   printf 'https://github.com/%s/archive/refs/tags/%s.tar.gz' "$SLUG" "$1" ;;
    gitlab)   printf 'https://gitlab.com/%s/-/archive/%s/%s-%s.tar.gz' "$SLUG" "$1" "$REPONAME" "$1" ;;
    codeberg) printf 'https://codeberg.org/%s/archive/%s.tar.gz' "$SLUG" "$1" ;;
  esac
}
SRC_SUM=SKIP; SRCDIR_X=""
if [ "$FORGE" = git ]; then
  GITURL="$(printf '%s' "$ORIGIN" | sed -E 's#^[^@/]+@([^:]+):#https://\1/#')"
  SOURCE="git+$GITURL#tag=$TAGX"
  SRCDIR_X="$REPONAME"
else
  URL_REAL="$(tag_url "$TAG")"
  SOURCE="\$pkgname-\$pkgver.tar.gz::$(tag_url "$TAGX")"
  if [ "${DRY_NO_TAG:-0}" = 1 ]; then
    warn "dry run and the tag isn't online: no checksum yet"; SRC_SUM=SKIP; SRCDIR_X="$REPONAME-\${pkgver}"
  else
    run_logged "$WORK/download.log" "downloading $URL_REAL" curl -fL --retry 3 -o "$WORK/src.tar.gz" "$URL_REAL" \
      || { tail -n 3 "$WORK/download.log" | sed 's/^/     /'; die "couldn't download $URL_REAL — is tag $TAG pushed?"; }
    SRC_SUM="$(sha256sum "$WORK/src.tar.gz" | cut -d' ' -f1)"
    TOP="$(tar tzf "$WORK/src.tar.gz" | head -1 | cut -d/ -f1)"
    [ -n "$TOP" ] || die "the tarball from $URL_REAL is empty or not a tarball"
    # the directory it unpacks to, written in terms of the version
    if [ "$PKGVER" = "$VERSION" ]; then
      SRCDIR_X="$(printf '%s' "$TOP" | sed -e "s/$(printf '%s' "$VERSION" | sed 's/[.]/\\./g')/\${pkgver}/")"
    else
      SRCDIR_X="$TOP"   # pkgver was rewritten: the directory keeps the real version
    fi
    ok "source: $(basename "$URL_REAL") → $TOP/ (sha256 ${SRC_SUM:0:16}…)"
  fi
fi
SUB=""; [ "$PROOT" != . ] && SUB="/$PROOT"
CDLINE="  cd \"\$_srcdir$SUB\""

if [ "$MODE" = update ]; then
  # ------------------------------------------------------------- update
  P="$AURDIR/PKGBUILD"
  sed -i -E "s/^pkgver=.*/pkgver=$PKGVER/; s/^pkgrel=.*/pkgrel=1/" "$P"
  NSRC="$( (cd "$AURDIR" && env -i PATH="$PATH" bash --norc -c 'source ./PKGBUILD >/dev/null 2>&1; echo ${#source[@]}') )"
  if [ "$NSRC" = 1 ] && [ "$SRC_SUM" != SKIP ]; then
    if grep -q '^sha256sums=' "$P"; then
      sed -i -E "s/^sha256sums=\(.*\)$/sha256sums=('$SRC_SUM')/" "$P"
    elif grep -q '^b2sums=' "$P"; then
      sed -i -E "s/^b2sums=\(.*\)$/b2sums=('$(b2sum "$WORK/src.tar.gz" | cut -d' ' -f1)')/" "$P"
    else
      warn "no sha256sums/b2sums line to update — check the checksums yourself"
    fi
  elif [ "$NSRC" != 1 ]; then
    warn "the PKGBUILD has $NSRC sources — their checksums are refreshed by the test build (updpkgsums)"
    NEED_UPDPKGSUMS=1
  fi
  grep -q "^pkgver=$PKGVER$" "$P" || die "couldn't set pkgver in the PKGBUILD — update it by hand in $AURDIR"
  ok "PKGBUILD bumped: $OLD_PKGVER → $PKGVER, pkgrel=1"
else
  # --------------------------------------------------------- new package
  ARCHS="'x86_64' 'aarch64'"; DEPS=(); MAKEDEPS=(); BUILD=""; CHECK=""; PACKAGE=""; ENVS=""
  case "$KIND" in
    rust)
      MAKEDEPS+=(cargo); DEPS+=(gcc-libs glibc)
      for crate in $(at "$TAG_REF" Cargo.lock | sed -nE 's/^name = "([a-z0-9_-]+-sys)"$/\1/p' | sort -u); do
        case "$crate" in
          openssl-sys) DEPS+=(openssl) ;; alsa-sys) DEPS+=(alsa-lib) ;; libdbus-sys) DEPS+=(dbus) ;;
          libudev-sys) DEPS+=(systemd-libs) ;; gtk4-sys) DEPS+=(gtk4) ;; gtk-sys) DEPS+=(gtk3) ;;
          libadwaita-sys) DEPS+=(libadwaita) ;; webkit2gtk-sys) DEPS+=(webkit2gtk-4.1) ;;
        esac
      done
      PREPARE='  export RUSTUP_TOOLCHAIN=stable
  cargo fetch --locked --target host-tuple'
      BUILD='  export RUSTUP_TOOLCHAIN=stable
  export CARGO_TARGET_DIR=target
  cargo build --frozen --release --all-features'
      CHECK='  export RUSTUP_TOOLCHAIN=stable
  cargo test --frozen --all-features'
      PACKAGE='  find target/release -maxdepth 1 -executable -type f -exec install -Dm0755 -t "$pkgdir/usr/bin/" {} +' ;;
    go)
      MAKEDEPS+=(go); DEPS+=(glibc)
      GOTARGET=.; grep -qE '^cmd/[^/]+/main\.go$' "$WORK/tree.txt" && GOTARGET='./cmd/...'
      PREPARE='  mkdir -p build'
      BUILD="  export CGO_CPPFLAGS=\"\${CPPFLAGS}\"
  export CGO_CFLAGS=\"\${CFLAGS}\"
  export CGO_CXXFLAGS=\"\${CXXFLAGS}\"
  export CGO_LDFLAGS=\"\${LDFLAGS}\"
  export GOPATH=\"\${srcdir}\"
  export GOFLAGS=\"-buildmode=pie -trimpath -ldflags=-linkmode=external -mod=readonly -modcacherw\"
  go build -o build $GOTARGET"
      CHECK='  go test ./...'
      PACKAGE='  install -Dm755 -t "$pkgdir/usr/bin" build/*' ;;
    python)
      ARCHS="'any'"; MAKEDEPS+=(python-build python-installer python-wheel); DEPS+=(python)
      at "$TAG_REF" pyproject.toml > "$WORK/pyproject.toml"
      tool python3 python3 - "$WORK/pyproject.toml" > "$WORK/pydeps" <<'PY' || die "could not read pyproject.toml"
import re, sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
name = lambda s: re.match(r"[A-Za-z0-9._-]+", s.strip()).group(0)
for r in d.get("build-system", {}).get("requires", []):
    print("build", name(r))
for r in d.get("project", {}).get("dependencies", []):
    if not (";" in r and "extra ==" in r):
        print("dep", name(r))
PY
      while read -r k dname; do
        a="python-$(printf '%s' "$dname" | tr 'A-Z' 'a-z' | tr '_.' '--')"
        case "$a" in python-setuptools-scm|python-hatch-vcs) ENVS='  export SETUPTOOLS_SCM_PRETEND_VERSION="$pkgver"' ;; esac
        if [ "$k" = build ]; then MAKEDEPS+=("$a"); else DEPS+=("$a"); fi
      done < "$WORK/pydeps"
      BUILD='  python -m build --wheel --no-isolation'
      PACKAGE='  python -m installer --destdir="$pkgdir" dist/*.whl' ;;
    node)
      ARCHS="'any'"; MAKEDEPS+=(npm); DEPS+=(nodejs)
      NB=""; [ -n "$(at "$TAG_REF" package.json | tool jq jq -r '.scripts.build // ""' 2>/dev/null || true)" ] && NB='
  npm run build'
      BUILD="  npm ci --cache \"\$srcdir/npm-cache\"$NB
  npm pack --pack-destination \"\$srcdir\""
      PACKAGE='  npm install -g --prefix "$pkgdir/usr" --cache "$srcdir/npm-cache" "$srcdir"/*.tgz
  # npm leaves group-writable directories behind
  find "$pkgdir/usr" -type d -exec chmod 755 {} +' ;;
    meson|cmake)
      if [ "$KIND" = meson ]; then
        MAKEDEPS+=(meson)
        PCS="$(for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done \
               | grep -oE "dependency\([[:space:]]*'[^']+'" | sed -E "s/.*'([^']+)'/\\1/" | sort -u)"
        BUILD='  arch-meson "$_srcdir" build
  meson compile -C build'
        CHECK='  meson test -C build --print-errorlogs'
        PACKAGE='  meson install -C build --destdir "$pkgdir"'
      else
        MAKEDEPS+=(cmake)
        PCS="$(at "$TAG_REF" CMakeLists.txt | tr '\n' ' ' | grep -oE 'pkg_check_modules\([^)]*\)' \
               | sed -E 's/^pkg_check_modules\(//; s/\)$//' \
               | awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^(REQUIRED|QUIET|IMPORTED_TARGET|GLOBAL)$/) { m = $i; sub(/[<>=].*/, "", m); if (m != "") print m } }' | sort -u)"
        BUILD='  local cmake_options=(
    -B build
    -S "$_srcdir"
    -W no-author
    -D CMAKE_BUILD_TYPE=None
    -D CMAKE_INSTALL_PREFIX=/usr
  )
  cmake "${cmake_options[@]}"
  cmake --build build'
        CHECK='  ctest --test-dir build --output-on-failure'
        PACKAGE='  DESTDIR="$pkgdir" cmake --install build'
      fi
      [ -n "$PCS" ] && MAKEDEPS+=(pkgconf)
      for pc in $PCS; do
        case "$pc" in threads|m|dl|rt|dependency) continue ;; esac
        DEPS+=("$(pc_arch "$pc")")
      done ;;
    make)
      BUILD='  make PREFIX=/usr'
      PACKAGE='  make PREFIX=/usr DESTDIR="$pkgdir" install' ;;
    flutter)
      MAKEDEPS+=(flutter clang cmake ninja pkgconf); DEPS+=(gtk3)
      BIN="$MAIN_GUESS"
      TITLE="$(at "$TAG_REF" "$(pp linux/runner/my_application.cc)" | sed -nE 's/.*(gtk_header_bar_set_title|gtk_window_set_title)\([^,]+,[[:space:]]*"([^"]+)".*/\2/p' | sed -n 1p)"
      [ -n "$TITLE" ] || TITLE="$PNAME"
      hd() { printf '%s' "$1" | sed -e 's/[\\$`]/\\&/g'; }
      ICON="$(grep -E "^$( [ "$PROOT" = . ] || printf '%s/' "$PROOT")(assets/.*(icon|logo|launcher)[^/]*\.png|linux/.*\.png|android/app/src/main/res/mipmap-xxxhdpi/ic_launcher\.png)$" "$WORK/tree.txt" \
             | awk '{ print (/assets\//) ? 1 : (/linux\//) ? 2 : 3, $0 }' | sort -n | head -1 | cut -d' ' -f2- || true)"
      ICON="${ICON#"$PROOT"/}"
      BUILD='  export PUB_CACHE="$srcdir/pub-cache"
  flutter --disable-analytics >/dev/null 2>&1 || true
  flutter pub get --enforce-lockfile
  flutter build linux --release'
      PACKAGE="  install -dm755 \"\$pkgdir/usr/lib/\$pkgname\" \"\$pkgdir/usr/bin\"
  cp -a build/linux/*/release/bundle/. \"\$pkgdir/usr/lib/\$pkgname/\"
  ln -s \"/usr/lib/\$pkgname/$BIN\" \"\$pkgdir/usr/bin/$BIN\"
  install -Dm644 /dev/stdin \"\$pkgdir/usr/share/applications/\$pkgname.desktop\" <<DESKTOP
[Desktop Entry]
Type=Application
Name=$(hd "$TITLE")
Comment=$(hd "$DESC")
Exec=$BIN
${ICON:+Icon=\$pkgname
}Categories=Utility;
DESKTOP"
      [ -n "$ICON" ] && PACKAGE="$PACKAGE
  install -Dm644 \"$ICON\" \"\$pkgdir/usr/share/pixmaps/\$pkgname.png\""
      ok "desktop entry \"$TITLE\"${ICON:+ with icon $ICON}" ;;
  esac
  [ "$FORGE" = git ] && MAKEDEPS+=(git)
  # licenses Arch doesn't ship as common texts must be installed with the package
  case "$SPDX" in
    *MIT*|*BSD*|*ISC*|*Zlib*|*Unlicense*|*BSL-1.0*)   # (*BSD* covers 0BSD)
      LIC="$(grep -m1 -xE '(LICENSE|LICENSE\.md|LICENSE\.txt|LICENCE|COPYING)' "$WORK/tree.txt" || true)"
      [ -n "$LIC" ] && PACKAGE="$PACKAGE
  install -Dm644 \"\$srcdir/\$_srcdir/$LIC\" \"\$pkgdir/usr/share/licenses/\$pkgname/LICENSE\"" ;;
  esac

  # every dependency must exist in Arch or the AUR
  UNKNOWN=()
  for d in $(printf '%s\n' "${DEPS[@]}" "${MAKEDEPS[@]}" | awk 'NF && !seen[$0]++'); do
    case "$(arch_where "$d")" in
      official) ;;
      aur) note "$d comes from the AUR (users' AUR helper builds it first)" ;;
      *) UNKNOWN+=("$d") ;;
    esac
  done
  [ "${#UNKNOWN[@]}" -gt 0 ] && warn "no Arch or AUR package named: ${UNKNOWN[*]} — the test build will say if they're needed; fix the names in the PKGBUILD"

  arr() { printf '%s\n' "$@" | awk 'NF && !seen[$0]++ { printf "%s'"'"'%s'"'"'", (n++ ? " " : ""), $0 }'; }
  OBF="$(printf '%s' "${MAINT_EMAIL:-}" | sed -e 's/@/ at /' -e 's/\./ dot /g')"
  {
    printf '# Maintainer: %s%s\n\n' "$MAINT_NAME" "${OBF:+ <$OBF>}"
    printf 'pkgname=%s\npkgver=%s\npkgrel=1\n' "$PKG" "$PKGVER"
    printf 'pkgdesc=%s\n' "$(shq "$DESC")"
    printf 'arch=(%s)\n' "$ARCHS"
    printf 'url=%s\n' "$(shq "$HOMEPAGE")"
    printf "license=('%s')\n" "$SPDX"
    [ "${#DEPS[@]}" -gt 0 ] && printf 'depends=(%s)\n' "$(arr "${DEPS[@]}")"
    [ "${#MAKEDEPS[@]}" -gt 0 ] && printf 'makedepends=(%s)\n' "$(arr "${MAKEDEPS[@]}")"
    printf 'source=("%s")\n' "$SOURCE"
    printf "sha256sums=('%s')\n" "$SRC_SUM"
    printf '_srcdir="%s"\n' "$SRCDIR_X"
    [ -n "${PREPARE:-}" ] && printf '\nprepare() {\n%s\n%s\n}\n' "$CDLINE" "$PREPARE"
    printf '\nbuild() {\n%s\n%s%s\n}\n' "$CDLINE" "${ENVS:+$ENVS
}" "$BUILD"
    [ -n "$CHECK" ] && printf '\ncheck() {\n%s\n%s\n}\n' "$CDLINE" "$CHECK"
    printf '\npackage() {\n%s\n%s\n}\n' "$CDLINE" "$PACKAGE"
  } > "$AURDIR/PKGBUILD"
  # meson/cmake build out of the source tree: they start in $srcdir
  if [ "$KIND" = meson ] || [ "$KIND" = cmake ]; then
    sed -i '/^build() {$/,/^}$/{/^  cd "\$_srcdir"$/d;}; /^check() {$/,/^}$/{/^  cd "\$_srcdir"$/d;}; /^package() {$/,/^}$/{/^  cd "\$_srcdir"$/d;}' "$AURDIR/PKGBUILD"
    sed -i 's#"\$srcdir/\$_srcdir/#"$_srcdir/#' "$AURDIR/PKGBUILD"
  fi
  # the PKGBUILD's own license (0BSD, as the AUR guidelines encourage), and a
  # .gitignore that keeps build leftovers out of the AUR repository
  if [ ! -f "$AURDIR/LICENSE" ]; then
    cat > "$AURDIR/LICENSE" <<LICENSE
Copyright $(date +%Y) ${MAINT_NAME}

Permission to use, copy, modify, and/or distribute this software for
any purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE
FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY
DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT
OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
LICENSE
  fi
  [ -f "$AURDIR/.gitignore" ] || printf '*\n!.gitignore\n!PKGBUILD\n!.SRCINFO\n!LICENSE\n' > "$AURDIR/.gitignore"
  ok "wrote PKGBUILD ($KIND), LICENSE (0BSD) and .gitignore"
fi

# ================================================================ 4. check
step "4/6  Check"
bash -n "$AURDIR/PKGBUILD" 2>"$WORK/syntax.err" || { cat "$WORK/syntax.err"; die "the PKGBUILD has a shell syntax error"; }
ok "PKGBUILD is valid shell"

# a clean test build: an Arch container (podman or docker), else makepkg on Arch
RUNTIME=""
for r in podman docker; do
  have "$r" && "$r" info >/dev/null 2>&1 && { RUNTIME="$r"; break; }
done
AURDEPS=""
for d in $( (cd "$AURDIR" && env -i PATH="$PATH" bash --norc -c 'source ./PKGBUILD >/dev/null 2>&1; printf "%s\n" "${depends[@]}" "${makedepends[@]}"') | sed 's/[<>=].*//'); do
  [ "$(arch_where "$d")" = aur ] || continue
  # flutter: the prebuilt SDK is much faster to set up, and provides "flutter"
  [ "$d" = flutter ] && d=flutter-bin
  AURDEPS="$AURDEPS $d"
done
TESTED=0
VCHECK=1; [ "$KIND" = flutter ] && VCHECK=0
BIN_MAIN="$(cfg_get main-program)"; BIN_MAIN="${BIN_MAIN:-$MAIN_GUESS}"
test_build() {
  mkdir -p "$WORK/out"
  "$RUNTIME" run --rm -v "$AURDIR:/pkg:ro" -v "$WORK/out:/out" -e AURDEPS="$AURDEPS" -e MAIN="$BIN_MAIN" -e VCHECK="$VCHECK" \
    -e UPD="${NEED_UPDPKGSUMS:-0}" "$ARCH_IMAGE" bash -c '
    set -e
    pacman -Syu --noconfirm --needed git namcap pacman-contrib >/dev/null
    useradd -m builder
    echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
    cp -r /pkg /home/builder/pkg && chown -R builder: /home/builder/pkg
    for d in $AURDEPS; do
      echo "==> building AUR dependency $d"
      su builder -c "cd ~ && git clone -q https://aur.archlinux.org/$d.git && cd $d && makepkg -si --noconfirm" \
        || { echo "STORE-SUBMIT: the AUR dependency $d did not build"; exit 4; }
    done
    if [ "$UPD" = 1 ]; then su builder -c "cd ~/pkg && updpkgsums"; cp /home/builder/pkg/PKGBUILD /out/PKGBUILD; fi
    echo "==> makepkg"
    su builder -c "cd ~/pkg && makepkg -s --noconfirm" || { echo "STORE-SUBMIT: makepkg failed"; exit 5; }
    echo "==> namcap"
    namcap /home/builder/pkg/PKGBUILD 2>&1 | sed "s/^/NAMCAP: /" || true
    namcap /home/builder/pkg/*.pkg.tar.zst 2>&1 | sed "s/^/NAMCAP: /" || true
    echo "==> files"
    pacman -Qlp /home/builder/pkg/*.pkg.tar.zst | grep -E "/usr/bin/." | sed "s/^/BIN: /" || true
    pacman -U --noconfirm /home/builder/pkg/*.pkg.tar.zst >/dev/null
    if [ -n "$MAIN" ] && [ "$VCHECK" = 1 ]; then
      echo "==> $MAIN --version"
      timeout 10 "$MAIN" --version 2>&1 | sed "s/^/VERSION: /" || echo "STORE-SUBMIT: $MAIN --version failed"
    fi
    echo "STORE-SUBMIT: OK"'
}
if [ "$NO_TEST" = 1 ]; then
  warn "--no-test: not test-built"
elif [ -z "$RUNTIME" ]; then
  warn "no podman or docker here to test-build in a clean Arch container"
  note "install one (e.g. podman) to have every release built before it's published"
else
  say "A clean build in an Arch container catches missing dependencies before users do."
  if [ "$ASSUME_YES" = 1 ] || confirm "Test-build it with $RUNTIME? (first time: ~500 MB download; a few minutes)" y; then
    while :; do
      if run_logged "$WORK/test.log" "test build in an Arch container${AURDEPS:+ (first building:$AURDEPS)}" test_build \
         && grep -q "STORE-SUBMIT: OK" "$WORK/test.log"; then
        ok "built cleanly in Arch"
        if [ -f "$WORK/out/PKGBUILD" ]; then cp "$WORK/out/PKGBUILD" "$AURDIR/PKGBUILD"; ok "checksums refreshed (updpkgsums)"; fi
        grep '^BIN: ' "$WORK/test.log" | sed 's/^BIN: /   installs /' | head -5
        grep '^VERSION: ' "$WORK/test.log" | head -1 | sed 's/^VERSION: /   ✓ --version → /'
        grep -q "STORE-SUBMIT: .* --version failed" "$WORK/test.log" && warn "$BIN_MAIN --version didn't work in the container"
        if grep -q '^NAMCAP: ' "$WORK/test.log"; then
          warn "namcap (Arch's package linter) says:"
          grep '^NAMCAP: ' "$WORK/test.log" | sed 's/^NAMCAP: /       /' | head -15
        else
          ok "namcap has no complaints"
        fi
        TESTED=1
        break
      fi
      if grep -q "target not found" "$WORK/test.log"; then
        bad "a dependency name doesn't exist: $(grep -o 'target not found: [^ ]*' "$WORK/test.log" | head -3 | sed 's/target not found: //' | tr '\n' ' ')"
      elif grep -q "did not pass the validity check" "$WORK/test.log"; then
        bad "a checksum doesn't match the download"
      elif grep -q "the AUR dependency" "$WORK/test.log"; then
        bad "$(grep -o 'the AUR dependency .* did not build' "$WORK/test.log" | head -1)"
      else
        bad "the test build failed"
      fi
      printf '   %s── last lines of the build log ──%s\n' "$DIM" "$R"
      grep -vE '^\s*$' "$WORK/test.log" | tail -n 15 | cut -c1-200 | sed 's/^/     /'
      [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "the test build failed (log: $WORK/test.log)"; }
      say "e) edit the PKGBUILD (in ${EDITOR:-vi}), then build again     l) read the whole log"
      say "r) build again as it is     s) skip the test build     q) quit"
      ask CHOICE "Choice" "e"
      case "$CHOICE" in
        e|E) "${EDITOR:-vi}" "$AURDIR/PKGBUILD" ;;
        l|L) "${PAGER:-less}" "$WORK/test.log" || cat "$WORK/test.log" ;;
        s|S) warn "not test-built"; break ;;
        q|Q) note "your work is in $AURDIR; re-run to pick it up again"; exit 1 ;;
      esac
    done
  fi
fi
[ "${NEED_UPDPKGSUMS:-0}" = 1 ] && [ "$TESTED" = 0 ] && die "the checksums of the extra sources need refreshing (updpkgsums) — only the test build can do that here"

srcinfo "$AURDIR" > "$AURDIR/.SRCINFO" 2>"$WORK/srcinfo.err" \
  || { cat "$WORK/srcinfo.err"; die "couldn't write .SRCINFO from the PKGBUILD"; }
grep -qx "	pkgver = $PKGVER" "$AURDIR/.SRCINFO" && grep -qx "pkgname = $PKG" "$AURDIR/.SRCINFO" \
  || die ".SRCINFO doesn't match the PKGBUILD (pkgname $PKG, pkgver $PKGVER)"
ok ".SRCINFO written"

# ================================================================ 5. review
step "5/6  Review"
git -C "$AURDIR" add -A
git -C "$AURDIR" --no-pager diff --cached --stat | sed 's/^/   /'
echo
git -C "$AURDIR" diff --cached --color=auto -- PKGBUILD
echo
if [ "$MODE" = new ] && [ "$ASSUME_YES" = 1 ]; then
  git -C "$AURDIR" reset -q
  warn "--yes: nobody has read the new PKGBUILD — the AUR asks you to verify carefully before uploading"
  die "run once without --yes to review and publish it (it's ready in $AURDIR)"
fi
if [ "$ASSUME_YES" = 0 ]; then
  confirm "Have you read it, and do you stand behind it?" n \
    || { note "edit it in $AURDIR, then re-run"; exit 1; }
fi

# =============================================================== 6. publish
step "6/6  Publish"
git -C "$AURDIR" config user.name "$MAINT_NAME"
git -C "$AURDIR" config user.email "${MAINT_EMAIL:-$(git -C "$REPO" config user.email 2>/dev/null || echo "$(id -un)@localhost")}"
if [ "$MODE" = new ]; then MSG="Initial upload: $PKG $PKGVER"; else MSG="Update to $PKGVER"; fi
git -C "$AURDIR" commit -q -m "$MSG"
ok "committed: $MSG"
save_answers
if [ "$DRYRUN" = 1 ]; then
  warn "dry run — stopping before the push"
  note "the commit is ready in $AURDIR"
  exit 0
fi
go "Push $PKG $PKGVER to the AUR?" || { note "the commit is ready in $AURDIR"; exit 0; }
while ! run_logged "$WORK/push.log" "pushing to the AUR" git -C "$AURDIR" push origin HEAD:master; do
  tail -n 4 "$WORK/push.log" | sed 's/^/     /'
  grep -qi "srcinfo" "$WORK/push.log" && die "the AUR rejected the .SRCINFO — see above"
  [ "$ASSUME_YES" = 0 ] && confirm "Try again?" y || die "not pushed; the commit is ready in $AURDIR"
done
# the AUR updates its page right away: check it shows this version
LIVE=""
for _ in 1 2 3 4 5 6; do
  LIVE="$(curl -sf --max-time 20 "$AUR_WEB/rpc/v5/info?arg[]=$PKG" | tool jq jq -r '.results[0].Version // ""' 2>/dev/null || true)"
  [ "$LIVE" = "$PKGVER-1" ] && break
  sleep 5
done
if [ "$LIVE" = "$PKGVER-1" ]; then ok "live: $AUR_WEB/packages/$PKG ($LIVE)"
else warn "pushed, but the AUR still shows ${LIVE:-nothing} — check $AUR_WEB/packages/$PKG"; fi

printf '\n   %sDone.%s %s %s is on the AUR.\n   %s/packages/%s\n\n' "$B" "$R" "$PKG" "$PKGVER" "$AUR_WEB" "$PKG"
say "  • People install it with an AUR helper: yay -S $PKG  (or paru -S $PKG)"
say "  • Watch the comments on its AUR page — that's where users report problems."
say "  • Next release: run store-submit.sh aur (or linux) again; it bumps pkgver."
[ "$TESTED" = 1 ] || say "  • It wasn't test-built here: a clean build before the next release is worth it."
echo
}

# ##########################################################################
#   Flathub's questions — the app ID and network access. Part of "Your app"
#   whenever Flathub is among the distros, so a Linux run asks them up front
#   and the config keeps them. Needs linux_common and linux_app's globals.
# ##########################################################################
# fh_default_id — the code-hosting app ID Flathub expects for this repo
fh_default_id() {
  local pre="" owner repo
  case "$FORGE" in github) pre=io.github ;; gitlab) pre=io.gitlab ;; codeberg) pre=page.codeberg ;; *) return 0 ;; esac
  owner="$(printf '%s' "$OWNER" | tr 'A-Z' 'a-z' | tr '/' '.' | sed -E 's/-/_/g; s/(^|\.)([0-9])/\1_\2/g')"
  repo="$(printf '%s' "$REPONAME" | tr '.' '_' | sed -E 's/^([0-9])/_\1/')"
  printf '%s.%s.%s' "$pre" "$owner" "$repo"
}
# fh_id_problems <id> — one line per Flathub app-ID rule it breaks
fh_id_problems() {
  local id="$1" n i last c
  IFS=. read -ra c <<< "$id"
  n=${#c[@]}; last="${c[$((n - 1))]:-}"
  [ "${#id}" -le 255 ] || echo "it is longer than 255 characters"
  [ "$n" -ge 3 ] || echo "it needs at least 3 parts, like tld.vendor.app"
  [ "$n" -le 5 ] || echo "it has more than 5 parts"
  for ((i = 0; i < n - 1; i++)); do
    printf '%s' "${c[$i]}" | grep -qE '^[a-z0-9_]+$' || { echo "'${c[$i]}': the domain parts must be lowercase letters, digits or _"; break; }
  done
  printf '%s' "$last" | grep -qE '^[A-Za-z0-9_-]+$' || echo "'$last': the last part may only have letters, digits, _ and -"
  case "$id" in
    io.github.*|io.gitlab.*|page.codeberg.*|io.frama.*) [ "$n" -ge 4 ] || echo "code-hosting IDs need at least 4 parts" ;;
    com.github.*|com.gitlab.*|org.codeberg.*|org.framagit.*) echo "that prefix is reserved for the hosting platform itself — use io.github. / io.gitlab. / page.codeberg." ;;
    org.gnome.*|org.kde.*|com.system76.*) echo "that prefix is protected — only for those projects' own apps" ;;
  esac
  case "$last" in desktop|app|linux) echo "it must not end in a generic word (.$last)" ;; esac
}
# fh_id_repo_url <id> — the repository a code-hosting ID points at
fh_id_repo_url() {
  local id="$1" host rest owner last
  case "$id" in
    io.github.*) host=github.com; rest="${id#io.github.}" ;;
    io.gitlab.*) host=gitlab.com; rest="${id#io.gitlab.}" ;;
    page.codeberg.*) host=codeberg.org; rest="${id#page.codeberg.}" ;;
    *) return 0 ;;
  esac
  last="${rest##*.}"; owner="${rest%.*}"
  owner="$(printf '%s' "$owner" | tr '.' '/' | sed -E 's#(^|/)_#\1#g; s/_/-/g')"
  last="$(printf '%s' "$last" | sed -E 's/^_([0-9])/\1/')"
  printf 'https://%s/%s/%s' "$host" "$owner" "$last"
}

flathub_questions() {
# --- the app ID: permanent on Flathub (a rename means a new submission)
ID_GUESS="${ID_ARG:-$(cfg_get flathub-id)}"
[ -n "$ID_GUESS" ] || ID_GUESS="$(fh_default_id)"
FIRST=1
while :; do
  if [ "$FIRST" = 1 ] && [ -n "$(cfg_get flathub-id)" ] && [ -z "$ID_ARG" ] && [ "$ASK_ALL" = 0 ]; then
    APP_ID="$ID_GUESS"; ok "app ID: $APP_ID"
  elif [ -n "$ID_ARG" ] && [ "$FIRST" = 1 ]; then
    APP_ID="$ID_ARG"
  else
    [ "$FIRST" = 1 ] && note "the app ID names your app on Flathub for good — a rename means submitting again"
    [ "$FIRST" = 1 ] && [ "$FORGE" != git ] && note "for an app on ${HOST}, Flathub wants $(fh_default_id | cut -d. -f1-2).<owner>.<repo>"
    ask APP_ID "Flathub app ID" "$ID_GUESS"
  fi
  FIRST=0
  PROBS="$(fh_id_problems "$APP_ID")"
  if [ -z "$PROBS" ]; then
    CLAIM="$(fh_id_repo_url "$APP_ID")"
    if [ -z "$CLAIM" ] || curl -sfIL --max-time 20 -o /dev/null "$CLAIM"; then break; fi
    PROBS="it points at $CLAIM, which doesn't exist — Flathub checks that it does"
  fi
  printf '%s\n' "$PROBS" | while read -r l; do warn "app ID: $l"; done
  [ "$ASSUME_YES" = 1 ] && die "fix the app ID (--app-id) and re-run"
  ID_GUESS="$APP_ID"
done
[ -n "${CLAIM:-}" ] && ok "app ID $APP_ID ↔ $CLAIM"
[ "$SAVE" = 1 ] && cfg_set flathub-id "$APP_ID"

# --- network access (a Flatpak permission): guessed from the dependencies
NET="$(cfg_get flathub-network)"
if [ -z "$NET" ]; then
  NET=no
  { at "$TAG_REF" "$(pp pubspec.yaml)"; at "$TAG_REF" Cargo.lock; at "$TAG_REF" package.json; } 2>/dev/null \
    | grep -qiE '(^|[^a-z])(http|dio|web_socket|supabase|firebase|reqwest|hyper|ureq|axios|grpc)([^a-z]|$)' && NET=yes
  if [ "$ASSUME_YES" = 0 ]; then confirm "Does $PNAME use the internet?" "$( [ "$NET" = yes ] && echo y || echo n)" && NET=yes || NET=no; fi
  [ "$SAVE" = 1 ] && cfg_set flathub-network "$NET"
fi
}

# ##########################################################################
#   Flathub wizard — store-submit.sh flathub [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_flathub() {
#
# store-submit.sh flathub — prepare an app for Flathub (or a new version of
# one that's already there), up to the pull request.
#
# Follows Flathub's own documentation:
#   https://docs.flathub.org/docs/for-app-authors/submission
#   https://docs.flathub.org/docs/for-app-authors/requirements
#   https://docs.flathub.org/docs/for-app-authors/metainfo-guidelines
#
# Flathub's policy is that people, not tools, open submission pull requests
# (requirements, "Generative AI policy"). So this wizard does everything up to
# it — checks, metadata, manifest, an offline build like Flathub's, Flathub's
# linter, a branch in your fork — and ends with your to-do list and the link
# that opens the pull request.

set -eu

DRYRUN=0
SAVE=1
ASSUME_YES=0
ASK_ALL=0
REPO_ARG=""
ID_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/flathub-submit"
CONF="$CONF_DIR/last.conf"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/store-submit"
# pinned versions of the community tools Flathub points to
FF_VERSION="0.15.0"                                   # flatpak-flutter
FBT_COMMIT="41c20aa10819cdb2a4f3ca171758a96d1955c018" # flatpak-builder-tools
FLATHUB_REPO="${FLATHUB_REPO:-flathub/flathub}"

usage() {
  cat <<'USAGE'
store-submit.sh flathub — prepare an app for Flathub, or an update of it.
You open the pull request yourself, as Flathub's policy asks: the wizard
ends with the link and your to-do list.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --config FILE   the shared answers (default: .store-submit.conf in the repo)
      --app-id ID     the Flathub app ID (default: from the config, or worked out)
  -n, --dry-run       build and check; don't touch your fork
      --no-save       do not remember the answers for next time
      --forget        delete the remembered answers and exit
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -n|--dry-run) DRYRUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --ask)        ASK_ALL=1 ;;
    --repo)       REPO_ARG="${2-}"; shift ;;
    --config)     LINUX_CONF="${2-}"; shift ;;
    --app-id)     ID_ARG="${2-}"; shift ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF"; printf 'forgot %s\n' "$CONF"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WIZ_NAME=flathub-submit
linux_common

SAVED_REPO=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  { printf '# written by store-submit.sh flathub — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n' "${REPO:-${SAVED_REPO:-}}"; } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}

# ------------------------------------------------------------------ helpers
# fb <command> [args...] — a command from Flathub's own builder, org.flatpak.Builder
fb() { local fbcmd="$1"; shift; flatpak run --command="$fbcmd" org.flatpak.Builder "$@"; }

# fh_py <script args...> — python with the modules the Flathub tools need
# (PyYAML, tomlkit, aiohttp, packaging): from nixpkgs when Nix is here, else a
# private virtualenv in the cache. Nothing is installed system-wide.
fh_py() {
  if python3 -c 'import yaml, tomlkit, aiohttp, packaging' 2>/dev/null; then python3 "$@"; return; fi
  if have nix-shell && nix-instantiate --find-file nixpkgs >/dev/null 2>&1; then
    nix-shell -p "python3.withPackages (p: [ p.pyyaml p.tomlkit p.aiohttp p.packaging ])" \
      --run "$(printf '%q ' python3 "$@")"
    return
  fi
  local v="$CACHE/flathub-tools/venv"
  if [ ! -x "$v/bin/python3" ] || ! "$v/bin/python3" -c 'import yaml, tomlkit, aiohttp, packaging' 2>/dev/null; then
    python3 -m venv "$v" >/dev/null && "$v/bin/pip" install -q pyyaml tomlkit aiohttp packaging >/dev/null \
      || { printf 'could not set up the Python tools in %s\n' "$v" >&2; return 1; }
  fi
  "$v/bin/python3" "$@"
}

# fh_latest <runtime> — its newest stable branch on Flathub
fh_latest() {
  flatpak remote-ls --user flathub --runtime --columns=application,branch 2>/dev/null \
    | awk -v a="$1" '$1 == a { print $2 }' | grep -E '^[0-9]+(\.[0-9]+)?$' | sort -V | tail -1
}
# png_size <file> — "WxH" of a PNG
png_size() { python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(24); print("%dx%d" % struct.unpack(">II", d[16:24])) if d[:8]==b"\x89PNG\r\n\x1a\n" else print("")' "$1" 2>/dev/null; }
# raw_url <path> — a file of the app at the release tag, as a direct link
raw_url() {
  case "$FORGE" in
    github)   printf 'https://raw.githubusercontent.com/%s/%s/%s' "$SLUG" "$TAG" "$1" ;;
    gitlab)   printf '%s/-/raw/%s/%s' "$WEB" "$TAG" "$1" ;;
    codeberg) printf '%s/raw/tag/%s/%s' "$WEB" "$TAG" "$1" ;;
    *)        printf '' ;;
  esac
}
xml_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# =============================================================== 0. orientation
cat <<BANNER

  ${B}Flathub wizard${R}

  Six stages:
    1. your app      — shared with the other distros, plus the Flathub app ID
    2. tools         — Flathub's builder and linter (org.flatpak.Builder)
    3. metadata      — metainfo, desktop file and icon in your app, validated
    4. manifest      — yours, or made with Flathub's community tools
    5. build + lint  — built offline like Flathub does, linted, tried out
    6. hand-off      — a branch in your fork; ${B}you${R} open the pull request

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: your fork is not touched"
for t in git flatpak python3 curl; do
  have "$t" || die "$t is missing — $( [ "$t" = flatpak ] && echo 'on NixOS: services.flatpak.enable = true; elsewhere your package manager has it' || echo 'install it and re-run')"
done

# ============================================================== 1. the app
linux_app "1/6  Your app"

flathub_questions
IDRE="$(printf '%s' "$APP_ID" | sed 's/[.]/\\./g')"

# --- new on Flathub, or an update? Every app there has its own repository.
MODE=new
if curl -sfIL --max-time 20 -o /dev/null "https://github.com/flathub/$APP_ID"; then
  MODE=update; ok "$APP_ID is on Flathub already — this is an update"
else
  ok "$APP_ID is new to Flathub"
fi

# ================================================================= 2. tools
step "2/6  Flathub's tools"
if ! flatpak remotes --user --columns=name 2>/dev/null | grep -qx flathub; then
  flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
    || die "couldn't add the Flathub remote"
  ok "added the Flathub remote (for your user)"
else
  ok "Flathub remote"
fi
if flatpak info org.flatpak.Builder >/dev/null 2>&1; then
  ok "org.flatpak.Builder (Flathub's builder and linter)"
else
  say "Flathub builds and lints with org.flatpak.Builder; it isn't installed yet."
  go "Install it for your user? (a few hundred MB)" || die "the build and the linter need org.flatpak.Builder"
  run_logged "$WORK/builder.log" "installing org.flatpak.Builder" flatpak install --user -y --noninteractive flathub org.flatpak.Builder \
    || { tail -n 5 "$WORK/builder.log" | sed 's/^/     /'; die "couldn't install org.flatpak.Builder"; }
  ok "installed org.flatpak.Builder"
fi
fh_py -c 'import yaml' 2>/dev/null || die "couldn't set up the Python modules the Flathub tools need"
ok "Python tools (PyYAML, tomlkit, aiohttp)"

# ============================================================== 3. metadata
step "3/6  Metadata in your app"
# Flathub wants these in the app's own repository (not in the pull request),
# installed by the build: a metainfo file, a desktop file and an icon.
find_tag() { grep -E "$1" "$WORK/tree.txt" | head -1 || true; }
META="$(find_tag "(^|/)$IDRE\\.(metainfo|appdata)\\.xml(\\.in)?$")"
DESKTOP="$(find_tag "(^|/)$IDRE\\.desktop(\\.in)?$")"
ICON="$(find_tag "(^|/)$IDRE\\.(svg|png)$")"
[ -n "$META" ] && ok "metainfo: $META" || warn "no $APP_ID.metainfo.xml in $TAG"
[ -n "$DESKTOP" ] && ok "desktop file: $DESKTOP" || warn "no $APP_ID.desktop in $TAG"
if [ -n "$ICON" ]; then
  case "$ICON" in
    *.png) at "$TAG_REF" "$ICON" > "$WORK/icon.png"; SZ="$(png_size "$WORK/icon.png")"
           if [ "${SZ%x*}" -ge 256 ] 2>/dev/null && [ "${SZ%x*}" = "${SZ#*x}" ]; then ok "icon: $ICON ($SZ)"
           else warn "icon $ICON is $SZ — Flathub needs a square PNG of at least 256×256, or an SVG"; ICON=""; fi ;;
    *) ok "icon: $ICON" ;;
  esac
else
  warn "no $APP_ID.svg or .png icon in $TAG"
fi

# --- what's missing is written into your app — you release it, then re-run
if [ -z "$META" ] || [ -z "$DESKTOP" ] || [ -z "$ICON" ]; then
  MDIR="flatpak"; [ "$PROOT" != . ] && MDIR="$PROOT/flatpak"
  say "Flathub needs these in your app's repository. The wizard can write the"
  say "missing ones into $MDIR/ — you check them, commit, and release a new version."
  [ "$ASSUME_YES" = 1 ] && die "the metadata needs you — run once without --yes"
  go "Create them in $MDIR/?" || die "add the metainfo, desktop file and icon to your app, release, then re-run"
  mkdir -p "$REPO/$MDIR"
  NAME_GUESS="$(at "$TAG_REF" "$(pp linux/runner/my_application.cc)" | sed -nE 's/.*(gtk_header_bar_set_title|gtk_window_set_title)\([^,]+,[[:space:]]*"([^"]+)".*/\2/p' | sed -n 1p)"
  [ -n "$NAME_GUESS" ] || NAME_GUESS="$(printf '%s' "$PNAME" | sed -E 's/[-_]/ /g; s/(^| )([a-z])/\1\u\2/g')"
  [ -n "$(cfg_get display-name)" ] && NAME_GUESS="$(cfg_get display-name)"
  ask DNAME "The app's name, as people see it" "$NAME_GUESS"
  [ "$SAVE" = 1 ] && cfg_set display-name "$DNAME"
  if [ -z "$DESKTOP" ]; then
    CATS="AudioVideo Audio Video Development Education Game Graphics Network Office Science Settings System Utility"
    CAT="$(cfg_get categories)"; CAT="${CAT%%;*}"
    while :; do
      ask CAT "Main menu category ($CATS)" "${CAT:-Utility}"
      case " $CATS " in *" $CAT "*) break ;; esac
      warn "one of: $CATS"
    done
    [ "$SAVE" = 1 ] && cfg_set categories "$CAT;"
    {
      printf '[Desktop Entry]\nType=Application\nName=%s\nComment=%s\n' "$DNAME" "$DESC"
      printf 'Exec=%s\nIcon=%s\nTerminal=false\nCategories=%s;\n' "$MAIN_GUESS" "$APP_ID" "$CAT"
    } > "$REPO/$MDIR/$APP_ID.desktop"
    DESKTOP="$MDIR/$APP_ID.desktop"; ok "wrote $DESKTOP"
  fi
  if [ -z "$ICON" ]; then
    CAND=""
    for f in $(grep -iE '\.(svg|png)$' "$WORK/tree.txt" | grep -iE 'icon|logo|launcher|ic_launcher' || true); do
      case "$f" in
        *.svg) CAND="$f"; break ;;
        *.png) at "$TAG_REF" "$f" > "$WORK/cand.png"; SZ="$(png_size "$WORK/cand.png")"
               [ "${SZ%x*}" -ge 256 ] 2>/dev/null && [ "${SZ%x*}" = "${SZ#*x}" ] && { CAND="$f"; break; } ;;
      esac
    done
    if [ -n "$CAND" ]; then
      at "$TAG_REF" "$CAND" > "$REPO/$MDIR/$APP_ID.${CAND##*.}"
      ICON="$MDIR/$APP_ID.${CAND##*.}"; ok "icon: copied $CAND to $ICON"
    else
      handoff_add "Add an icon: a square PNG of at least 256×256 (or an SVG) at $MDIR/$APP_ID.png"
      warn "no icon of 256×256 or more (or SVG) found — add one at $MDIR/$APP_ID.png"
    fi
  fi
  if [ -z "$META" ]; then
    # the store page text is yours: the README's first paragraph as a start
    README_P="$(for f in README.md README; do at "$TAG_REF" "$f"; done 2>/dev/null | awk '/^#|^\[!|^!\[|^<|^$/ { if (p) exit; next } { p = p (p ? " " : "") $0 } END { print p }' | cut -c1-400)"
    note "a few sentences for the Flathub page, in your own words (Flathub reviews its wording)"
    ask ABOUT "What the app does" "$README_P"
    # screenshots: required. Images in the repo at this tag, or links you give.
    SHOTS="$(grep -iE '(^|/)(screenshots?|screens|images/screenshots?|docs/images?)/[^/]+\.(png|jpe?g|webp)$' "$WORK/tree.txt" | head -5 || true)"
    URLS=""
    for s in $SHOTS; do u="$(raw_url "$s")"; [ -n "$u" ] && URLS="$URLS $u"; done
    if [ -n "$URLS" ]; then ok "screenshots: $(printf '%s' "$SHOTS" | tr '\n' ' ')"
    else
      note "Flathub needs at least one screenshot: a direct image link (from a tag or commit, not a branch)"
      while :; do
        ask_opt U "Screenshot URL (blank when done)" ""
        [ -n "$U" ] || break
        URLS="$URLS $U"
      done
      [ -n "$URLS" ] || { handoff_add "Add screenshots to $MDIR/$APP_ID.metainfo.xml (<screenshots>) — Flathub requires one"; warn "no screenshot — the linter will insist on one"; }
    fi
    confirm "Does the app have chat with strangers, in-app purchases, ads, location sharing or mature content?" n && {
      handoff_add "Fill in the age rating: answer https://hughsie.github.io/oars/ and paste the result into <content_rating> in $MDIR/$APP_ID.metainfo.xml"
      OARS_NOTE=1; }
    DEV_ID="$(printf '%s' "$APP_ID" | cut -d. -f1-"$(( $(printf '%s' "$APP_ID" | tr -cd . | wc -c) ))")"
    TYPE=desktop-application
    {
      printf '<?xml version="1.0" encoding="UTF-8"?>\n<!-- Copyright %s %s -->\n' "$(date +%Y)" "$(xml_esc "$MAINT_NAME")"
      printf '<component type="%s">\n  <id>%s</id>\n\n' "$TYPE" "$APP_ID"
      printf '  <name>%s</name>\n  <summary>%s</summary>\n\n' "$(xml_esc "$DNAME")" "$(xml_esc "$DESC")"
      printf '  <metadata_license>CC0-1.0</metadata_license>\n  <project_license>%s</project_license>\n\n' "$SPDX"
      printf '  <developer id="%s">\n    <name>%s</name>\n  </developer>\n\n' "$DEV_ID" "$(xml_esc "$MAINT_NAME")"
      printf '  <description>\n    <p>%s</p>\n  </description>\n\n' "$(xml_esc "$ABOUT")"
      printf '  <launchable type="desktop-id">%s.desktop</launchable>\n\n' "$APP_ID"
      printf '  <url type="homepage">%s</url>\n' "$(xml_esc "$HOMEPAGE")"
      [ "$FORGE" = github ] || [ "$FORGE" = gitlab ] || [ "$FORGE" = codeberg ] && printf '  <url type="bugtracker">%s/issues</url>\n' "$WEB"
      printf '  <url type="vcs-browser">%s</url>\n\n' "$WEB"
      if [ -n "$URLS" ]; then
        printf '  <screenshots>\n'
        d=' type="default"'
        for u in $URLS; do printf '    <screenshot%s>\n      <image>%s</image>\n    </screenshot>\n' "$d" "$(xml_esc "$u")"; d=""; done
        printf '  </screenshots>\n\n'
      fi
      [ "${OARS_NOTE:-0}" = 1 ] && printf '  <!-- replace with the answers from https://hughsie.github.io/oars/ -->\n'
      printf '  <content_rating type="oars-1.1" />\n\n'
      printf '  <releases>\n'
      git -C "$REPO" for-each-ref --sort=-creatordate --format='%(refname:short) %(creatordate:short)' refs/tags \
        | grep -E '^v?[0-9]' | head -10 | while read -r t d; do printf '    <release version="%s" date="%s" />\n' "${t#v}" "$d"; done
      printf '  </releases>\n</component>\n'
    } > "$REPO/$MDIR/$APP_ID.metainfo.xml"
    META="$MDIR/$APP_ID.metainfo.xml"; ok "wrote $META"
  fi
  # check them now, before they go into a release
  if run_logged "$WORK/meta-lint.log" "validating the metainfo with Flathub's linter" fb flatpak-builder-lint appstream "$REPO/$META"; then
    ok "metainfo passes Flathub's linter"
  else
    warn "Flathub's linter has remarks about $META:"; grep -vE '^\s*$' "$WORK/meta-lint.log" | head -12 | sed 's/^/       /'
    handoff_add "Fix what Flathub's linter says about $META (docs: https://docs.flathub.org/docs/for-app-authors/metainfo-guidelines)"
  fi
  if fb desktop-file-validate "$REPO/$DESKTOP" > "$WORK/desktop.log" 2>&1; then ok "desktop file is valid"
  else warn "desktop-file-validate: $(head -3 "$WORK/desktop.log" | tr '\n' ' ')"; fi
  handoff_add "Read the files in $MDIR/ — they describe your app on Flathub; correct anything that's off"
  handoff_add "Commit them, and add a <release version=… date=…> line to the metainfo for the version you're about to release"
  handoff_add "Release that version (a new tag), then run store-submit.sh flathub again — it picks up from here"
  handoff_show "Flathub needs these in a release of your app first"
  save_answers
  exit 0
fi

# the metainfo must list this release (Flathub shows it as "what's new")
at "$TAG_REF" "$META" | grep -qE "<release[^>]+version=\"${VERSION//./\\.}\"" \
  || { warn "$META has no <release version=\"$VERSION\"> entry"; handoff_add "Next time, add <release version=\"…\" date=\"…\"> to $META before tagging the release"; }

# ============================================================== 4. manifest
step "4/6  Manifest"
WD="$CACHE/flathub/$APP_ID"
REV="$(git -C "$REPO" rev-list -n1 "$TAG_REF")"
GITURL="$WEB.git"; [ "$FORGE" = git ] && GITURL="$(printf '%s' "$ORIGIN" | sed -E 's#^[^@/]+@([^:]+):#https://\1/#')"
case "$TAG" in "v$VERSION") TAGPAT='^v([\d.]+)$' ;; *) TAGPAT='^([\d.]+)$' ;; esac
NET="$(cfg_get flathub-network)"; NET="${NET:-no}"
ok "network access: $NET"

# install lines for the metadata, relative to where the module builds
rel() { python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"; }
BUILDDIR="."; [ "$KIND" = flutter ] && BUILDDIR="$PROOT"
ICONDEST="share/icons/hicolor/scalable/apps/$APP_ID.svg"
case "$ICON" in *.png) at "$TAG_REF" "$ICON" > "$WORK/icon.png"; SZ="$(png_size "$WORK/icon.png")"; ICONDEST="share/icons/hicolor/$SZ/apps/$APP_ID.png" ;; esac
INSTALLS="install -Dm644 $(rel "$META" "$BUILDDIR") \${FLATPAK_DEST}/share/metainfo/$APP_ID.metainfo.xml
install -Dm644 $(rel "$DESKTOP" "$BUILDDIR") \${FLATPAK_DEST}/share/applications/$APP_ID.desktop
install -Dm644 $(rel "$ICON" "$BUILDDIR") \${FLATPAK_DEST}/$ICONDEST"
case "$META$DESKTOP" in *.in*) INSTALLS="" ; note "your build installs the metadata itself (.in templates)" ;; esac

GENERATED_BY=""
if [ "$MODE" = update ]; then
  # --------------------------------------------------------------- update
  rm -rf "$WD"; mkdir -p "$(dirname "$WD")"
  run_logged "$WORK/clone.log" "cloning flathub/$APP_ID" git clone -q --depth 1 "https://github.com/flathub/$APP_ID.git" "$WD" \
    || die "couldn't clone https://github.com/flathub/$APP_ID"
  # point the app's source at the new tag (git: tag + commit; archive: url + sha256)
  for mf in "$WD/flatpak-flutter.yml" "$WD/$APP_ID.yml" "$WD/$APP_ID.yaml" "$WD/$APP_ID.json"; do
    [ -f "$mf" ] || continue
    ARCHIVE_URL=""; ARCHIVE_SHA=""
    if [ "$FORGE" = github ]; then
      ARCHIVE_URL="https://github.com/$SLUG/archive/refs/tags/$TAG.tar.gz"
      if grep -q "archive" "$mf" && curl -sfL --max-time 60 -o "$WORK/src.tar.gz" "$ARCHIVE_URL"; then ARCHIVE_SHA="$(sha256sum "$WORK/src.tar.gz" | cut -d' ' -f1)"; fi
    fi
    fh_py - "$mf" "$SLUG" "$TAG" "$REV" "$ARCHIVE_URL" "$ARCHIVE_SHA" <<'PY' || die "couldn't update the source in $(basename "$mf")"
import json, re, sys, yaml
path, slug, tag, rev, aurl, asha = sys.argv[1:7]
is_json = path.endswith(".json")
text = open(path).read()
head = "" if is_json else "".join(l for l in text.splitlines(True) if l.startswith("#") and not text.startswith("---"))
m = json.loads(text) if is_json else yaml.safe_load(text)
hit = 0
def walk(mods):
    global hit
    for mod in mods or []:
        if not isinstance(mod, dict):
            continue
        for s in mod.get("sources", []) or []:
            if not isinstance(s, dict) or slug.lower() not in str(s.get("url", "")).lower():
                continue
            if s.get("type") == "git":
                s["tag"] = tag; s["commit"] = rev; hit += 1
            elif s.get("type") == "archive" and aurl and asha:
                s["url"] = aurl; s["sha256"] = asha; hit += 1
        walk(mod.get("modules"))
walk(m.get("modules"))
if not hit:
    sys.exit("no source pointing at " + slug)
class D(yaml.SafeDumper):
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)
with open(path, "w") as f:
    if is_json:
        json.dump(m, f, indent=4); f.write("\n")
    else:
        f.write(head); yaml.dump(m, f, Dumper=D, sort_keys=False, indent=2, allow_unicode=True, width=4096)
PY
    ok "$(basename "$mf"): source → $TAG ($(printf '%s' "$REV" | cut -c1-12))"
  done
  MANIFEST=""
  for f in "$APP_ID.yml" "$APP_ID.yaml" "$APP_ID.json"; do [ -f "$WD/$f" ] && { MANIFEST="$f"; break; }; done
  [ -n "$MANIFEST" ] || die "flathub/$APP_ID has no $APP_ID.yml/.json manifest"
  if [ -f "$WD/flatpak-flutter.yml" ]; then GENERATED_BY=flatpak-flutter; fi
  if [ -f "$WD/cargo-sources.json" ] && [ "$KIND" = rust ]; then GENERATED_BY=cargo; fi
else
  # ---------------------------------------------------------- new: whose manifest?
  rm -rf "$WD"; mkdir -p "$WD"
  OWN="$(grep -E "(^|/)($IDRE\\.(ya?ml|json)|flatpak-flutter\\.ya?ml)$" "$WORK/tree.txt" | head -1 || true)"
  if [ -n "$OWN" ]; then
    # yours, from the app repo — with the local files it refers to
    ODIR="$(dirname "$OWN")"
    at "$TAG_REF" "$OWN" > "$WD/$(basename "$OWN")"
    fh_py - "$WD/$(basename "$OWN")" <<'PY' > "$WORK/own-refs"
import json, sys, yaml
p = sys.argv[1]
m = json.load(open(p)) if p.endswith(".json") else yaml.safe_load(open(p))
out = set()
def walk(mods):
    for mod in mods or []:
        if isinstance(mod, str):
            out.add(mod); continue
        for s in mod.get("sources", []) or []:
            if isinstance(s, str):
                out.add(s)
            elif isinstance(s, dict):
                for k in ("path", "paths"):
                    v = s.get(k)
                    for x in (v if isinstance(v, list) else [v] if v else []):
                        out.add(x)
        walk(mod.get("modules"))
walk(m.get("modules"))
print("\n".join(sorted(out)))
PY
    while read -r r; do
      [ -n "$r" ] || continue
      src="$ODIR/$r"; [ "$ODIR" = . ] && src="$r"
      if grep -qxF "$src" "$WORK/tree.txt"; then mkdir -p "$WD/$(dirname "$r")"; at "$TAG_REF" "$src" > "$WD/$r"
      elif grep -q "^$src/" "$WORK/tree.txt"; then
        grep "^$src/" "$WORK/tree.txt" | while read -r f; do mkdir -p "$WD/$(dirname "${f#"$ODIR"/}")"; at "$TAG_REF" "$f" > "$WD/${f#"$ODIR"/}"; done
      fi
    done < "$WORK/own-refs"
    ok "your manifest: $OWN"
    case "$OWN" in *flatpak-flutter.y*ml) GENERATED_BY=flatpak-flutter ;; *) MANIFEST="$(basename "$OWN")" ;; esac
  else
    # ------------------------------------------- made with the community tools
    RUNTIME=org.freedesktop.Platform; SDK=org.freedesktop.Sdk; GUI=1
    case "$KIND" in
      flutter) ;;
      rust) if at "$TAG_REF" Cargo.lock | grep -qE '^name = "(gtk4|libadwaita|gtk)"'; then RUNTIME=org.gnome.Platform; SDK=org.gnome.Sdk
            elif ! at "$TAG_REF" Cargo.lock | grep -qE '^name = "(iced|egui|eframe|slint|winit|tauri|relm4|fltk|druid|dioxus)"'; then GUI=0; fi ;;
      meson) if { for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done; } | grep -qE "dependency\\([[:space:]]*'(gtk4|libadwaita-1|gtk\\+-3\\.0)'"; then
               RUNTIME=org.gnome.Platform; SDK=org.gnome.Sdk; fi ;;
      cmake) if at "$TAG_REF" CMakeLists.txt | grep -qE 'find_package\([[:space:]]*Qt6'; then RUNTIME=org.kde.Platform; SDK=org.kde.Sdk
             elif at "$TAG_REF" CMakeLists.txt | grep -qiE 'gtk'; then RUNTIME=org.gnome.Platform; SDK=org.gnome.Sdk; fi ;;
      *) die "the wizard makes Flathub manifests for Flutter, Rust, Meson and CMake apps — for a $KIND app, add your own $APP_ID.yml to the repo (see https://docs.flathub.org/docs/for-app-authors/requirements) and re-run: it then checks, builds and lints yours" ;;
    esac
    [ "$GUI" = 1 ] || die "this looks like a command-line app — Flathub is mostly for graphical apps; the AUR and nixpkgs fit it better"
    RTV="$(fh_latest "$RUNTIME")"
    [ -n "$RTV" ] || die "couldn't ask Flathub for the latest $RUNTIME (is the network up?)"
    ok "runtime: $RUNTIME $RTV (the latest, as Flathub requires)"
    MODULE="${APP_ID##*.}"
    FINISH='["--share=ipc", "--socket=fallback-x11", "--socket=wayland", "--device=dri"'
    [ "$NET" = yes ] && FINISH="$FINISH, \"--share=network\""
    FINISH="$FINISH]"
    if [ "$KIND" = flutter ]; then
      # flatpak-flutter's own template, pinned to this release
      FF="$CACHE/flatpak-flutter-$FF_VERSION"
      if [ ! -f "$FF/flatpak-flutter.py" ]; then
        run_logged "$WORK/ff.log" "downloading flatpak-flutter $FF_VERSION" \
          curl -fL --retry 3 -o "$WORK/ff.tar.gz" "https://github.com/TheAppgineer/flatpak-flutter/archive/refs/tags/$FF_VERSION.tar.gz" \
          || die "couldn't download flatpak-flutter"
        mkdir -p "$FF" && tar xzf "$WORK/ff.tar.gz" -C "$FF" --strip-components=1
      fi
      FV="$( { at "$TAG_REF" "$(pp .fvmrc)" | sed -nE 's/.*"flutter"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'
               at "$TAG_REF" "$(pp .fvm/fvm_config.json)" | sed -nE 's/.*"flutterSdkVersion"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'; } 2>/dev/null | sed -n 1p)"
      fh_py - "$FF/flatpak-flutter.py" "$WD/flatpak-flutter.yml" "$WEB" "$APP_ID" "$MAIN_GUESS" "$RTV" "$GITURL" "$TAG" "$REV" "$TAGPAT" \
            "${FV:-}" "$PROOT" "$INSTALLS" "$FINISH" <<'PY' || die "couldn't make the flatpak-flutter manifest"
import importlib.util, json, sys, yaml
ff, out, web, app_id, cmd, rtv, giturl, tag, rev, tagpat, fv, proot, installs, finish = sys.argv[1:15]
spec = importlib.util.spec_from_file_location("ff", ff); mod = importlib.util.module_from_spec(spec)
sys.argv = [ff]; spec.loader.exec_module(mod)
m = mod._generate_template_for_url(web, app_id, cmd)
m["runtime-version"] = rtv
m["finish-args"] = json.loads(finish)
app = m["modules"][0]
if proot != ".":
    app["subdir"] = proot
app["build-commands"] += [l for l in installs.splitlines() if l.strip()]
for s in app["sources"]:
    if "flutter/flutter" in s["url"]:
        if fv: s["tag"] = fv
    else:
        s.update({"url": giturl, "tag": tag, "commit": rev, "x-checker-data": {"type": "git", "tag-pattern": tagpat}})
MOD_ORDER = ["name", "buildsystem", "build-options", "make-args", "make-install-args", "rm-configure", "no-autogen",
             "no-parallel-make", "subdir", "builddir", "run-tests", "license-files", "only-arches", "skip-arches",
             "config-opts", "build-commands", "post-install", "cleanup", "sources", "modules"]
def ordered(mod):
    if not isinstance(mod, dict):
        return mod
    out = {k: mod[k] for k in MOD_ORDER if k in mod}
    out.update({k: v for k, v in mod.items() if k not in out})
    if "modules" in out:
        out["modules"] = [ordered(x) for x in out["modules"]]
    return out
m["modules"] = [ordered(x) for x in m["modules"]]
class D(yaml.SafeDumper):
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)
with open(out, "w") as f:
    yaml.dump(m, f, Dumper=D, sort_keys=False, indent=2, width=4096)
PY
      ok "flatpak-flutter.yml from flatpak-flutter's template (Flutter ${FV:-its default})"
      GENERATED_BY=flatpak-flutter
    else
      # Rust, Meson, CMake: the recipes from Flathub's docs and the cargo generator's README
      EXT=""; BUILD_JSON=""
      case "$KIND" in
        rust)
          EXT='["org.freedesktop.Sdk.Extension.rust-stable"]'
          BUILD_JSON="$(python3 -c 'import json,sys; m,b,i=sys.argv[1:4]; print(json.dumps({"name": m, "buildsystem": "simple",
  "build-options": {"append-path": "/usr/lib/sdk/rust-stable/bin", "env": {"CARGO_HOME": "/run/build/%s/cargo" % m, "CARGO_NET_OFFLINE": "true"}},
  "build-commands": ["cargo --offline fetch --manifest-path Cargo.toml --verbose", "cargo build --offline --release --all-features",
                     "install -Dm0755 target/release/%s ${FLATPAK_DEST}/bin/%s" % (b, b)] + [l for l in i.splitlines() if l.strip()]}))' "$MODULE" "$MAIN_GUESS" "$INSTALLS")" ;;
        meson)
          BUILD_JSON="$(python3 -c 'import json,sys; m,i=sys.argv[1:3]; d={"name": m, "buildsystem": "meson"}
if i.strip(): d["post-install"]=[l for l in i.splitlines() if l.strip()]
print(json.dumps(d))' "$MODULE" "$INSTALLS")" ;;
        cmake)
          BUILD_JSON="$(python3 -c 'import json,sys; m,i=sys.argv[1:3]; d={"name": m, "buildsystem": "cmake-ninja", "builddir": True, "config-opts": ["-DCMAKE_BUILD_TYPE=Release"]}
if i.strip(): d["post-install"]=[l for l in i.splitlines() if l.strip()]
print(json.dumps(d))' "$MODULE" "$INSTALLS")" ;;
      esac
      fh_py - "$WD/$APP_ID.yml" "$APP_ID" "$RUNTIME" "$RTV" "$SDK" "${EXT:-[]}" "$MAIN_GUESS" "$FINISH" "$BUILD_JSON" \
            "$GITURL" "$TAG" "$REV" "$TAGPAT" "$KIND" <<'PY' || die "couldn't write the manifest"
import json, sys, yaml
out, app_id, rt, rtv, sdk, ext, cmd, finish, build, giturl, tag, rev, tagpat, kind = sys.argv[1:15]
m = {"id": app_id, "runtime": rt, "runtime-version": rtv, "sdk": sdk}
if json.loads(ext): m["sdk-extensions"] = json.loads(ext)
m["command"] = cmd
m["finish-args"] = json.loads(finish)
mod = json.loads(build)
mod["sources"] = [{"type": "git", "url": giturl, "tag": tag, "commit": rev,
                   "x-checker-data": {"type": "git", "tag-pattern": tagpat}}]
if kind == "rust":
    mod["sources"].append("cargo-sources.json")
MOD_ORDER = ["name", "buildsystem", "build-options", "make-args", "make-install-args", "rm-configure", "no-autogen",
             "no-parallel-make", "subdir", "builddir", "run-tests", "license-files", "only-arches", "skip-arches",
             "config-opts", "build-commands", "post-install", "cleanup", "sources", "modules"]
def ordered(mod):
    if not isinstance(mod, dict):
        return mod
    out = {k: mod[k] for k in MOD_ORDER if k in mod}
    out.update({k: v for k, v in mod.items() if k not in out})
    if "modules" in out:
        out["modules"] = [ordered(x) for x in out["modules"]]
    return out
m["modules"] = [ordered(mod)]
class D(yaml.SafeDumper):
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)
with open(out, "w") as f:
    yaml.dump(m, f, Dumper=D, sort_keys=False, indent=2, width=4096)
PY
      MANIFEST="$APP_ID.yml"
      ok "wrote $MANIFEST ($KIND, following Flathub's documented recipe)"
      [ "$KIND" = rust ] && GENERATED_BY=cargo
    fi
  fi
fi

# --- the offline dependency sources, from the community tools Flathub points to
case "$GENERATED_BY" in
  flatpak-flutter)
    FF="$CACHE/flatpak-flutter-$FF_VERSION"
    if [ ! -f "$FF/flatpak-flutter.py" ]; then
      curl -fsL --retry 3 -o "$WORK/ff.tar.gz" "https://github.com/TheAppgineer/flatpak-flutter/archive/refs/tags/$FF_VERSION.tar.gz" \
        && mkdir -p "$FF" && tar xzf "$WORK/ff.tar.gz" -C "$FF" --strip-components=1 || die "couldn't download flatpak-flutter"
    fi
    in_wd() { ( cd "$WD" && "$@" ); }
    run_logged "$WORK/ff-run.log" "flatpak-flutter: pinning every Dart package and the Flutter SDK (a while)" \
      in_wd fh_py "$FF/flatpak-flutter.py" flatpak-flutter.yml \
      || { tail -n 12 "$WORK/ff-run.log" | sed 's/^/     /'; KEEP_WORK=1; die "flatpak-flutter failed — log: $WORK/ff-run.log"; }
    MANIFEST=""
    for f in "$APP_ID.yml" "$APP_ID.yaml" "$APP_ID.json"; do [ -f "$WD/$f" ] && { MANIFEST="$f"; break; }; done
    [ -n "$MANIFEST" ] || die "flatpak-flutter didn't write $APP_ID.yml"
    rm -rf "$WD/.flatpak-builder"
    ok "flatpak-flutter wrote $MANIFEST and generated/ (the offline sources)" ;;
  cargo)
    GEN="$CACHE/flatpak-builder-tools-${FBT_COMMIT:0:12}/flatpak-cargo-generator.py"
    if [ ! -f "$GEN" ]; then
      mkdir -p "$(dirname "$GEN")"
      curl -fsL --retry 3 -o "$GEN" "https://raw.githubusercontent.com/flatpak/flatpak-builder-tools/$FBT_COMMIT/cargo/flatpak-cargo-generator.py" \
        || die "couldn't download flatpak-cargo-generator"
    fi
    at "$TAG_REF" Cargo.lock > "$WORK/Cargo.lock"
    run_logged "$WORK/cargo-gen.log" "flatpak-cargo-generator: listing every crate as a source" \
      fh_py "$GEN" "$WORK/Cargo.lock" -o "$WD/cargo-sources.json" \
      || { tail -n 8 "$WORK/cargo-gen.log" | sed 's/^/     /'; die "flatpak-cargo-generator failed"; }
    ok "cargo-sources.json ($(grep -c '"type"' "$WD/cargo-sources.json") sources)" ;;
esac

# ============================================================ 5. build + lint
step "5/6  Build and lint"
in_wd() { ( cd "$WD" && "$@" ); }
while :; do
  if run_logged "$WORK/build.log" "building like Flathub does (offline, in the sandbox — a first build takes a while)" \
       in_wd fb flathub-build --install "$MANIFEST"; then
    ok "built and installed $APP_ID for your user"
    break
  fi
  bad "the build failed:"
  grep -vE '^\s*$' "$WORK/build.log" | tail -n 15 | cut -c1-200 | sed 's/^/     /'
  grep -qE "Could not resolve|Failed to download|network" "$WORK/build.log" \
    && note "a download failed — Flathub builds have no network; every dependency must be a source in the manifest"
  [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "the build failed (log: $WORK/build.log)"; }
  say "e) edit $MANIFEST (in ${EDITOR:-vi}), then build again     l) read the whole log"
  say "r) build again as it is     q) quit"
  ask CHOICE "Choice" "e"
  case "$CHOICE" in
    e|E) "${EDITOR:-vi}" "$WD/$MANIFEST" ;;
    l|L) "${PAGER:-less}" "$WORK/build.log" || cat "$WORK/build.log" ;;
    q|Q) note "the manifest is in $WD"; exit 1 ;;
  esac
done

# Flathub's linter, on the manifest and on the build — the same checks as CI
LINT_OK=1
for what in "manifest $MANIFEST" "repo repo"; do
  # shellcheck disable=SC2086
  in_wd fb flatpak-builder-lint $what > "$WORK/lint.json" 2>"$WORK/lint.err" || true
  python3 - "$WORK/lint.json" "${what%% *}" > "$WORK/lint.txt" <<'PY' || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for kind in ("errors", "warnings"):
    for e in d.get(kind, []) or []:
        print("%s %s https://docs.flathub.org/docs/for-app-authors/linter#%s" % (kind[:-1], e, e))
for m in d.get("message", []) if isinstance(d.get("message"), list) else []:
    print("info", m, "")
PY
  if grep -q '^error ' "$WORK/lint.txt"; then
    LINT_OK=0; bad "Flathub's linter (${what%% *}) found errors:"
    grep '^error ' "$WORK/lint.txt" | while read -r _ id url; do printf '       %s\n         %s%s%s\n' "$id" "$DIM" "$url" "$R"; done
  else
    ok "Flathub's linter (${what%% *}): no errors"
  fi
  grep '^warning ' "$WORK/lint.txt" | while read -r _ id url; do warn "linter warning: $id — $url"; done
done
if [ "$LINT_OK" = 0 ]; then
  note "an error that's intended can get an exception from Flathub: https://docs.flathub.org/docs/for-app-authors/linter#exceptions"
  [ "$ASSUME_YES" = 1 ] || confirm "Carry on anyway? (the reviewers will see the same errors)" n || { note "the manifest is in $WD"; exit 1; }
  handoff_add "Fix the linter errors above, or ask for an exception in the pull request"
fi

# try it out
TESTED=0
if [ "$ASSUME_YES" = 0 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  if confirm "Start $APP_ID now to check it works? (close it to carry on)" y; then
    flatpak run --user "$APP_ID" >"$WORK/run.log" 2>&1 || true
    confirm "Did it work?" y && TESTED=1
    [ "$TESTED" = 1 ] || { tail -n 15 "$WORK/run.log" | sed 's/^/     /'; handoff_add "Fix what went wrong when running it (output above), then run the wizard again"; }
  fi
fi

# ============================================================== 6. hand-off
step "6/6  Hand-off"
PR_FILES="$(cd "$WD" && find . -path ./.flatpak-builder -prune -o -path ./builddir -prune -o -path ./repo -prune -o -path ./.git -prune \
  -o -type f ! -name '*.flatpak' -print | sed 's#^\./##' | sort)"
say "Files for the pull request:"
printf '%s\n' "$PR_FILES" | sed 's/^/     /'
save_answers
if [ "$DRYRUN" = 1 ]; then
  warn "dry run — your fork isn't touched; the files are in $WD"
  exit 0
fi
have gh || die "gh (GitHub CLI) is needed to put the branch in your fork"
gh auth status --hostname github.com >/dev/null 2>&1 || {
  [ "$ASSUME_YES" = 1 ] && die "run 'gh auth login' first"
  confirm "gh isn't logged in to GitHub — log in now?" y && gh auth login --hostname github.com || true
  gh auth status --hostname github.com >/dev/null 2>&1 || die "not logged in to GitHub"; }
GH_USER="$(gh api user --jq .login)"
if [ "$MODE" = new ]; then UPREPO="$FLATHUB_REPO"; BASE=new-pr; BRANCH="$APP_ID"; TITLE="Add $APP_ID"
else UPREPO="flathub/$APP_ID"; BASE=master; BRANCH="update-$VERSION"; TITLE="Update to $VERSION"; fi

# your fork (all branches: new submissions start from new-pr)
FORK="$(gh api "repos/$GH_USER/${UPREPO#*/}" --jq "select(.fork and .parent.full_name == \"$UPREPO\") | .name" 2>/dev/null || true)"
if [ -z "$FORK" ]; then
  go "Fork $UPREPO to your GitHub account?" || die "the branch needs a fork to live in"
  gh repo fork "$UPREPO" --clone=false >"$WORK/fork.log" 2>&1 || { cat "$WORK/fork.log"; die "couldn't fork $UPREPO"; }
  FORK="$(grep -oE "$GH_USER/[A-Za-z0-9._-]+" "$WORK/fork.log" | head -1 | cut -d/ -f2)"; FORK="${FORK:-${UPREPO#*/}}"
  for _ in $(seq 1 40); do gh api "repos/$GH_USER/$FORK" >/dev/null 2>&1 && break; sleep 3; done
fi
ok "fork: https://github.com/$GH_USER/$FORK"
PRDIR="$CACHE/flathub/pr-${UPREPO#*/}-$APP_ID"
rm -rf "$PRDIR"
run_logged "$WORK/prclone.log" "fetching $UPREPO ($BASE)" \
  git clone -q --single-branch --branch "$BASE" -o upstream "https://github.com/$UPREPO.git" "$PRDIR" \
  || die "couldn't fetch $UPREPO"
git -C "$PRDIR" checkout -q -b "$BRANCH"
( cd "$WD" && printf '%s\n' "$PR_FILES" | while read -r f; do mkdir -p "$PRDIR/$(dirname "$f")"; cp "$f" "$PRDIR/$f"; done )
git -C "$PRDIR" add -A
git -C "$PRDIR" -c user.name="$MAINT_NAME" -c user.email="${MAINT_EMAIL:-$(git -C "$REPO" config user.email)}" commit -q -m "$TITLE"
push_fork() {
  git -C "$PRDIR" -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    push -f "https://github.com/$GH_USER/$FORK.git" "$BRANCH:$BRANCH"
}
go "Push the branch $BRANCH to $GH_USER/$FORK?" || { note "the files are in $PRDIR"; exit 0; }
run_logged "$WORK/push.log" "pushing $BRANCH to your fork" push_fork || {
  tail -n 4 "$WORK/push.log" | sed 's/^/     /'
  grep -qiE "authentication|403|permission" "$WORK/push.log" && note "gh's login may have expired: gh auth status"
  die "the push failed — the files are in $PRDIR"; }
[ "$(git -C "$PRDIR" ls-remote "https://github.com/$GH_USER/$FORK.git" "refs/heads/$BRANCH" | cut -f1)" = "$(git -C "$PRDIR" rev-parse HEAD)" ] \
  || die "your fork's $BRANCH doesn't match what was pushed"
ok "pushed: https://github.com/$GH_USER/$FORK/tree/$BRANCH"

# already an update PR from Flathub's bot for this version?
if [ "$MODE" = update ]; then
  BOTPR="$(gh pr list -R "$UPREPO" --state open --json number,title,url --jq ".[] | select(.title | contains(\"$VERSION\")) | .url" 2>/dev/null | head -1 || true)"
  [ -n "$BOTPR" ] && { warn "there's already an open pull request for $VERSION: $BOTPR"; handoff_add "Check $BOTPR first — Flathub's update bot may have made one already; then you don't need a new one"; }
fi

ENC="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$TITLE")"
PR_LINK="https://github.com/$UPREPO/compare/$BASE...$GH_USER:$FORK:$BRANCH?expand=1&title=$ENC"
handoff_add "Open the pull request — the link below fills in the branch and the title ($TITLE)"
if [ "$MODE" = new ]; then
  handoff_add "In the pull request, fill in Flathub's checklist yourself"
  handoff_add "Flathub's AI policy: say in the pull request whether AI-generated material is in your app or its packaging. This manifest was made by $( [ "$GENERATED_BY" = flatpak-flutter ] && echo "flatpak-flutter" || echo "store-submit.sh") (store-submit.sh was written with AI help) — state it as it is; reviewers decide (https://docs.flathub.org/docs/for-app-authors/requirements#generative-ai-policy)"
  handoff_add "Answer the reviewers yourself; when they're done, comment \"bot, build\" for a test build"
  handoff_add "Turn on two-factor authentication on GitHub: after the merge you get an invite to flathub/$APP_ID — accept it within a week"
  case "$APP_ID" in io.github.*|io.gitlab.*) handoff_add "Once it's live: flathub.org → Developer Portal → your app → Verification (log in with ${HOST%%.*})" ;; esac
else
  handoff_add "Install the test build from the bot's comment on the pull request, try it, then merge it"
fi
handoff_show "Your turn — Flathub wants a person to open this pull request" "$PR_LINK"
}

# ##########################################################################
#   store-submit.sh <store> [options] — that store's wizard, directly
# ##########################################################################
case "${1-}" in
  fdroid|play|linux|nix|aur|flathub) WIZARD="$1"; shift; "wizard_$WIZARD" "$@"; exit ;;
esac

# ##########################################################################
#   the store picker
# ##########################################################################

# ------------------------------------------------------------------ arguments
ASSUME_YES=0
DRYRUN=0
NOSAVE=0
STORE_ARG=""
DISTRO_ARG=""
REPO_ARG=""
CHECK_ONLY=0
PASS=()        # everything after `--`, handed to the store's wizard verbatim
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/store-submit"
CONF="$CONF_DIR/last.conf"
SELF="$(readlink -f "$0")"
HERE="$(dirname "$SELF")"

# id|name|wizard function (blank = not written yet)|one-line description
STORES="fdroid|F-Droid|wizard_fdroid|free and open source Android apps, built from source by F-Droid
play|Google Play|wizard_play|Android releases through the Play Developer API
linux|Linux (NixOS, Arch)|wizard_linux|Linux distributions — pick several, answer once"

usage() {
  cat <<'USAGE'
store-submit.sh — pick a store, check the app and this machine, then run that
store's wizard.

  store-submit.sh [options]             the store picker (options below)
  store-submit.sh fdroid|play|linux ... one store's wizard directly, e.g.
                                          store-submit.sh fdroid --yes
  store-submit.sh nix|aur|flathub ...   one Linux distro's wizard directly
                                        (store-submit.sh <store> --help)

  -h, --help          show this text
  -s, --store LIST    store(s) to publish to, skipping the question:
                      fdroid, play, linux — comma-separated, or "all"
                      (nix or aur here means linux with that distro)
  -d, --distros LIST  for linux: the distros, skipping the question (nix, aur)
      --repo PATH     the app's checkout (default: the git repo you run it in)
  -c, --check         only run the checks; don't start any wizard
  -y, --yes           passed to the wizard(s); needs --store
  -n, --dry-run       passed to the wizard(s)
      --no-save       passed to the wizard(s); this script won't remember
                      the chosen store either
      --list          list the stores and exit
      --forget        forget the remembered store and exit
  -- ARGS...          everything after -- goes to the wizard as is (only
                      when publishing to a single store), e.g.
                        store-submit.sh -s play -- --track beta --rollout 0.2
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -s|--store)   STORE_ARG="${2-}"; shift ;;
    -d|--distros) DISTRO_ARG="${2-}"; shift ;;
    --repo)       REPO_ARG="${2-}"; shift ;;
    -c|--check)   CHECK_ONLY=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    -n|--dry-run) DRYRUN=1 ;;
    --no-save)    NOSAVE=1 ;;
    --list)       printf '%s\n' "$STORES" | while IFS='|' read -r id name script desc; do
                    printf '  %-7s %-28s %s\n' "$id" "$name" "$desc"; done; exit 0 ;;
    --forget)     rm -f "$CONF"; printf 'forgot %s\n' "$CONF"; exit 0 ;;
    --)           shift; PASS=("$@"); break ;;
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
bad()   { printf '   %s✗ %s%s\n' "$RED" "$*" "$R"; }
die()   { printf '\n%sERROR: %s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

readline() {  # readline VAR — refuses to spin on a closed stdin
  IFS= read -r "$1" && return 0
  printf '\n' >&2
  die "end of input — this script needs an interactive terminal (or use --store with --yes)"
}

confirm() {  # confirm "question" [default y|n]
  local q="$1" def="${2:-n}" a=""
  if [ "$ASSUME_YES" = 1 ]; then [ "$def" = y ]; return; fi
  local hint="[y/N]"; [ "$def" = y ] && hint="[Y/n]"
  printf '   %s%s%s %s ' "$B" "$q" "$R" "$hint" >&2
  readline a
  [ -z "$a" ] && a="$def"
  case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac
}

store_field() {  # store_field <id> <1=id 2=name 3=wizard 4=description>
  printf '%s\n' "$STORES" | awk -F'|' -v id="$1" -v f="$2" '$1 == id { print $f }'
}
store_ids() { printf '%s\n' "$STORES" | cut -d'|' -f1; }

# ------------------------------------------------------- remembered answers
SAVED_STORES=""
if [ -f "$CONF" ]; then
  SAVED_STORES="$(sed -n 's/^SAVED_STORES=//p' "$CONF" | tr -cd 'a-z, ')"
fi
save_answers() {
  [ "$NOSAVE" = 0 ] || return 0
  mkdir -p "$CONF_DIR"
  printf '# written by store-submit.sh — safe to delete (or run --forget)\nSAVED_STORES=%s\n' \
    "$(IFS=,; printf '%s' "${CHOSEN[*]}")" > "$CONF"
}

# ============================================================== 1. which store
cat <<BANNER

  ${B}Store submission${R}

  Three steps:
    1. store       — where the app is going
    2. checks      — what that store needs from the app, and from this machine
    3. wizard      — the store's own submission wizard takes over

BANNER

# parse_stores "fdroid,play" | "1 2" | "all" — fills CHOSEN, false on nonsense
CHOSEN=()
parse_stores() {
  local tok id n i
  CHOSEN=()
  for tok in $(printf '%s' "$1" | tr ',' ' '); do
    tok="$(printf '%s' "$tok" | tr 'A-Z' 'a-z')"
    if [ "$tok" = all ]; then
      CHOSEN=(); for id in $(store_ids); do CHOSEN+=("$id"); done; return 0
    fi
    id=""
    # a Linux distro's id stands for "linux, with that distro"
    if [ -n "$(distro_field "$tok" 3)" ]; then
      id=linux; DISTRO_ARG="$DISTRO_ARG${DISTRO_ARG:+,}$tok"
    fi
    case "$tok" in
      *[!0-9]*) [ -n "$(store_field "$tok" 1)" ] && id="$tok" ;;
      *)        n=0; for i in $(store_ids); do n=$((n+1)); [ "$n" = "$tok" ] && id="$i"; done ;;
    esac
    [ -n "$id" ] || { warn "no such store: $tok"; return 1; }
    case " ${CHOSEN[*]-} " in *" $id "*) ;; *) CHOSEN+=("$id") ;; esac
  done
  [ "${#CHOSEN[@]}" -gt 0 ]
}

step "1/3  Where is the app going?"
if [ -n "$STORE_ARG" ]; then
  parse_stores "$STORE_ARG" || die "--store takes: $(store_ids | tr '\n' ' ')or all"
else
  [ "$ASSUME_YES" = 1 ] && die "--yes needs --store: there is no one to ask"
  n=0
  while IFS='|' read -r id name script desc; do
    n=$((n+1))
    printf '   %s%d)%s %-28s %s%s%s\n' "$B" "$n" "$R" "$name" "$DIM" "$desc" "$R"
  done <<EOF
$STORES
EOF
  note "one or more, e.g. \"1\" or \"1 2\" or \"fdroid,play\" or \"all\""
  while :; do
    if [ -n "$SAVED_STORES" ]; then printf '   %sPublish to%s [%s]: ' "$B" "$R" "$SAVED_STORES" >&2
    else printf '   %sPublish to%s: ' "$B" "$R" >&2; fi
    readline IN
    [ -z "$IN" ] && IN="$SAVED_STORES"
    [ -n "$IN" ] || { warn "pick at least one"; continue; }
    parse_stores "$IN" && break
  done
fi
for id in "${CHOSEN[@]}"; do ok "$(store_field "$id" 2)"; done

# --- Linux: which distributions (one set of answers serves all of them)
LINUX_DISTROS=""
case " ${CHOSEN[*]} " in
  *" linux "*)
    PRE_REPO="${REPO_ARG:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    PRESET="$(sed -nE 's/^[[:space:]]*distros[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$PRE_REPO/.store-submit.conf" 2>/dev/null | tail -1)"
    if [ -n "$DISTRO_ARG" ]; then
      for d in $(printf '%s' "$DISTRO_ARG" | tr ',' ' '); do
        [ -n "$(distro_field "$d" 3)" ] || die "no Linux distro '$d' with a wizard (one of: $(printf '%s\n' "$DISTROS" | awk -F'|' '$3 != "" { printf "%s ", $1 }'))"
        case " $LINUX_DISTROS " in *" $d "*) ;; *) LINUX_DISTROS="$LINUX_DISTROS${LINUX_DISTROS:+ }$d" ;; esac
      done
    elif [ "$ASSUME_YES" = 1 ]; then
      [ -n "$PRESET" ] || die "--yes with linux needs --distros (or a .store-submit.conf that names them)"
      LINUX_DISTROS="$PRESET"
    else
      say "Linux: which distributions? One set of answers is used for all of them."
      multi_select LINUX_DISTROS "$(distro_items)" "$PRESET"
    fi
    for d in $LINUX_DISTROS; do ok "  $(distro_field "$d" 2)"; done ;;
esac
if [ "${#PASS[@]}" -gt 0 ] && [ "${#CHOSEN[@]}" -gt 1 ]; then
  die "arguments after -- belong to one wizard; pick a single store to use them"
fi

# ======================================================= 2a. the app itself
step "2/3  Checks"
printf '\n   %sThe app%s\n' "$B" "$R"

# The app repo: --repo, else the git repo you run this from (unless that's
# this script's own), else the current directory.
SELF_REPO="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
HERE_REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ "$HERE_REPO" = "$SELF_REPO" ] && HERE_REPO=""
REPO="${REPO_ARG:-${HERE_REPO:-$PWD}}"
REPO="${REPO/#\~/$HOME}"
[ -d "$REPO" ] || die "no such directory: $REPO"
REPO="$(cd "$REPO" && pwd)"
if [ -z "$REPO_ARG" ] && [ -z "$HERE_REPO" ] && [ "$ASSUME_YES" = 0 ]; then
  warn "not inside an app's git checkout — using $REPO"
  printf '   %sPath to the app%s [%s]: ' "$B" "$R" "$REPO" >&2
  readline IN
  if [ -n "$IN" ]; then
    IN="${IN/#\~/$HOME}"; [ -d "$IN" ] || die "no such directory: $IN"
    REPO="$(cd "$IN" && pwd)"
  fi
fi
ok "checkout: $REPO"

IS_GIT=0
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 && IS_GIT=1
ORIGIN=""; DIRTY=0; LAST_TAG=""
if [ "$IS_GIT" = 1 ]; then
  ORIGIN="$(git -C "$REPO" config --get remote.origin.url 2>/dev/null || true)"
  [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null | head -1)" ] && DIRTY=1
  LAST_TAG="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null || true)"
fi

# --- what kind of project is it? (Flutter/Android detection as in the wizards)
FLUTTER_DIR=""
for p in "$REPO/pubspec.yaml" "$REPO"/*/pubspec.yaml "$REPO"/*/*/pubspec.yaml; do
  [ -f "$p" ] || continue
  d="$(dirname "$p")"
  grep -qE '^[[:space:]]+sdk:[[:space:]]*flutter' "$p" || continue
  [ -f "$d/android/app/build.gradle.kts" ] || [ -f "$d/android/app/build.gradle" ] || continue
  FLUTTER_DIR="${d#"$REPO"}"; FLUTTER_DIR="${FLUTTER_DIR#/}"; FLUTTER_DIR="${FLUTTER_DIR:-.}"
  break
done
# Any Flutter project, Android target or not (nixpkgs builds the Linux one).
FLUTTER_ANY=""
for p in "$REPO/pubspec.yaml" "$REPO"/*/pubspec.yaml "$REPO"/*/*/pubspec.yaml; do
  [ -f "$p" ] && grep -qE '^[[:space:]]+sdk:[[:space:]]*flutter' "$p" || continue
  FLUTTER_ANY="$(dirname "$p")"; FLUTTER_ANY="${FLUTTER_ANY#"$REPO"}"; FLUTTER_ANY="${FLUTTER_ANY#/}"; FLUTTER_ANY="${FLUTTER_ANY:-.}"
  break
done
FLUTTER_ANDROID=""
[ -n "$FLUTTER_DIR" ] && { FLUTTER_ANDROID="$FLUTTER_DIR/android/app"; FLUTTER_ANDROID="${FLUTTER_ANDROID#./}"; }

SUBDIR=""; GRADLE_FILE=""
for cand in "$FLUTTER_ANDROID" app mobile android .; do
  [ -n "$cand" ] || continue
  for gf in build.gradle.kts build.gradle; do
    if [ -f "$REPO/$cand/$gf" ] && grep -qE 'applicationId|namespace' "$REPO/$cand/$gf" 2>/dev/null; then
      SUBDIR="$cand"; GRADLE_FILE="$REPO/$cand/$gf"; break 2
    fi
  done
done

gval() {
  [ -n "$GRADLE_FILE" ] || return 0
  sed -e 's,//.*,,' "$GRADLE_FILE" \
    | grep -Eo "(^|[^A-Za-z_.])$1[[:space:]]*(=[[:space:]]*)?[\"']?[A-Za-z0-9_.-]+" \
    | sed -E "s/.*$1[[:space:]]*(=[[:space:]]*)?[\"']?//" \
    | grep -v '^flutter\.' \
    | sed -n 1p || true
}

KINDS=()
APPID=""; VNAME=""; VCODE=""
if [ -n "$GRADLE_FILE" ]; then
  if [ -n "$FLUTTER_DIR" ]; then KINDS+=("Flutter (Android)"); else KINDS+=("Android (Gradle)"); fi
  APPID="$(gval applicationId)"; [ -n "$APPID" ] || APPID="$(gval namespace)"
  VNAME="$(gval versionName)"; VCODE="$(gval versionCode)"
  if [ -n "$FLUTTER_DIR" ] && [ -z "$VNAME$VCODE" ]; then
    PV="$(sed -nE "s/^version:[[:space:]]*[\"']?([^\"'[:space:]]+).*/\\1/p" \
          "$REPO/$FLUTTER_DIR/pubspec.yaml" | sed -n 1p)"
    VNAME="${PV%%+*}"
    case "$PV" in *+*) VCODE="${PV#*+}" ;; esac
  fi
fi
# Anything a Linux distribution would build from source.
[ -f "$REPO/Cargo.toml" ]        && KINDS+=("Rust (Cargo)")
[ -f "$REPO/go.mod" ]            && KINDS+=("Go")
[ -f "$REPO/package.json" ]      && KINDS+=("Node.js")
{ [ -f "$REPO/pyproject.toml" ] || [ -f "$REPO/setup.py" ]; } && KINDS+=("Python")
[ -f "$REPO/meson.build" ]       && KINDS+=("Meson")
[ -f "$REPO/CMakeLists.txt" ]    && KINDS+=("CMake")
[ -f "$REPO/Makefile" ]          && KINDS+=("Make")
[ -f "$REPO/flake.nix" ]         && KINDS+=("Nix flake")
[ -f "$REPO/PKGBUILD" ]          && KINDS+=("PKGBUILD")

if [ "${#KINDS[@]}" -gt 0 ]; then ok "project: $(IFS=,; printf '%s' "${KINDS[*]}" | sed 's/,/, /g')"
else warn "could not tell what kind of project this is"; fi
[ -n "$APPID" ] && ok "application ID: $APPID"
[ -n "$VNAME$VCODE" ] && ok "version: ${VNAME:-?} (versionCode ${VCODE:-?})"

LICENSE_FILE=""
for f in LICENSE LICENSE.md LICENSE.txt COPYING COPYING.md LICENCE; do
  [ -f "$REPO/$f" ] && { LICENSE_FILE="$f"; break; }
done
if [ "$IS_GIT" = 1 ]; then
  ok "git checkout${LAST_TAG:+, latest tag $LAST_TAG}"
  if [ -n "$ORIGIN" ]; then ok "origin: $ORIGIN"
  else warn "no 'origin' remote — stores that build from source need it public somewhere"; fi
  [ "$DIRTY" = 1 ] && warn "uncommitted changes — a release only covers what is committed"
else
  warn "not a git checkout"
fi
if [ -n "$LICENSE_FILE" ]; then ok "license file: $LICENSE_FILE"
else warn "no LICENSE file"; fi

FASTLANE=""
for f in "$REPO/fastlane/metadata/android" ${FLUTTER_DIR:+"$REPO/$FLUTTER_DIR/fastlane/metadata/android"}; do
  [ -d "$f" ] && { FASTLANE="$f"; break; }
done

has_kind() { case " ${KINDS[*]-} " in *"$1"*) return 0 ;; esac; return 1; }
is_android() { [ -n "$GRADLE_FILE" ]; }

# --- per-store needs. Each needs_<id> reports with need_ok/need_warn/need_fail;
# a need_fail stops the run before the wizard starts.
BLOCKERS=0
need_ok()   { ok "$*"; }
need_warn() { warn "$*"; }
need_fail() { bad "$*"; BLOCKERS=$((BLOCKERS+1)); }

common_git() {  # what every store that builds from source wants (shown above)
  [ "$IS_GIT" = 1 ] || need_fail "not a git checkout — this store builds from a tagged commit"
}

needs_fdroid() {
  common_git
  if is_android; then need_ok "Gradle module: $SUBDIR"
  else need_fail "no Android app here (no build.gradle with an applicationId)"; return 0; fi
  [ -n "$APPID" ] || need_fail "no applicationId in ${GRADLE_FILE#"$REPO"/}"
  [ -n "$VCODE" ] || need_warn "no versionCode found — the wizard will ask"
  [ -n "$LICENSE_FILE" ] || note "  F-Droid only takes free software; the license must be clear"
  if [ -n "$VNAME" ] && [ "$IS_GIT" = 1 ]; then
    if git -C "$REPO" rev-parse -q --verify "refs/tags/v$VNAME" >/dev/null 2>&1; then
      need_ok "release tag v$VNAME"
    else
      note "no tag v$VNAME yet — the wizard creates and pushes it"
    fi
  fi
  if [ -n "$FASTLANE" ]; then need_ok "fastlane metadata: ${FASTLANE#"$REPO"/}"
  else need_warn "no fastlane metadata — the listing would have no description (the wizard can create it)"; fi
  local hits
  hits="$(grep -rlE 'com\.google\.(firebase|android\.gms)|play-services|crashlytics|firebase_|google_mobile_ads|in_app_purchase' \
          --include='*.gradle' --include='*.gradle.kts' --include='pubspec.yaml' --include='*.toml' \
          "$REPO" 2>/dev/null | grep -v '/build/' | head -3 || true)"
  if [ -n "$hits" ]; then
    need_warn "proprietary dependencies in: $(printf '%s' "$hits" | sed "s#$REPO/##" | tr '\n' ' ')"
    note "  F-Droid won't build them in; the wizard's pitfall check goes into detail"
  fi
}

PLAY_KEY=""
needs_play() {
  if is_android; then need_ok "Gradle module: $SUBDIR"
  else need_fail "no Android app here (no build.gradle with an applicationId)"; return 0; fi
  [ -n "$APPID" ] && note "the app must already exist in Play Console as $APPID"
  local art="" pat fl=""
  [ -n "$FLUTTER_DIR" ] && fl="$REPO/$FLUTTER_DIR/build/app/outputs"
  for pat in "$REPO/$SUBDIR/build/outputs/bundle/release"/*.aab \
             "$REPO/$SUBDIR/build/outputs/apk/release"/*.apk \
             ${fl:+"$fl/bundle/release"/*.aab} ${fl:+"$fl/flutter-apk/app-release.apk"}; do
    [ -f "$pat" ] || continue
    if [ -z "$art" ] || [ "$pat" -nt "$art" ]; then art="$pat"; fi
  done
  if [ -n "$art" ]; then
    need_ok "release build: ${art#"$REPO"/}"
    [ -n "$GRADLE_FILE" ] && [ "$GRADLE_FILE" -nt "$art" ] && \
      need_warn "it is older than ${GRADLE_FILE#"$REPO"/} — rebuild if the version changed"
    if have unzip; then
      if unzip -l "$art" 2>/dev/null | grep -qE 'META-INF/.*\.(RSA|DSA|EC|SF)$'; then need_ok "it is signed"
      else need_warn "no signature block in it — Play only takes builds signed with your upload key"; fi
    fi
  else
    if [ -n "$FLUTTER_DIR" ]; then need_warn "no release build yet — run: flutter build appbundle"
    else need_warn "no release build yet — run: ./gradlew :${SUBDIR}:bundleRelease"; fi
  fi
  # the service account key: $PLAY_SERVICE_ACCOUNT_JSON, the one the Play wizard
  # remembered, or its default location
  local conf="${XDG_CONFIG_HOME:-$HOME/.config}/play-submit" k
  for k in "${PLAY_SERVICE_ACCOUNT_JSON:-}" \
           "$(sed -n "s/^SAVED_KEYFILE=//p" "$conf/last.conf" 2>/dev/null | tr -d "'\"")" \
           "$conf/service-account.json"; do
    [ -n "$k" ] && [ -f "$k" ] && { PLAY_KEY="$k"; break; }
  done
  if [ -n "$PLAY_KEY" ]; then need_ok "service account key: $PLAY_KEY"
  else need_warn "no service account key found — the wizard will ask for one and explain how to get it"; fi
  if [ -n "$FASTLANE" ] && [ -n "$VCODE" ]; then
    if ls "$FASTLANE"/*/changelogs/"$VCODE".txt >/dev/null 2>&1; then need_ok "release notes: changelogs/$VCODE.txt"
    else note "no changelogs/$VCODE.txt — the wizard will ask for release notes"; fi
  fi
}

linux_needs() {  # what every Linux distro needs from the app
  common_git
  [ -n "$ORIGIN" ] || need_fail "no 'origin' remote — Linux distributions build from a public repository"
  # distros package Linux software: a Flutter app goes in as its Linux
  # desktop build; a plain Android app can't go in at all.
  if [ -n "$FLUTTER_ANY" ]; then
    local where="in ${FLUTTER_ANY}/"; [ "$FLUTTER_ANY" = . ] && where="in the project root"
    if [ -f "$REPO/$FLUTTER_ANY/linux/CMakeLists.txt" ]; then need_ok "Flutter Linux desktop target (what the distros build)"
    else need_fail "no Linux desktop target — run 'flutter create --platforms=linux .' $where and commit it"; fi
    [ -f "$REPO/$FLUTTER_ANY/pubspec.lock" ] && need_ok "pubspec.lock" || need_fail "no pubspec.lock — the builds pin the Dart packages from it"
  elif is_android; then
    need_fail "this is an Android app — Linux distributions package software for Linux"
  fi
  [ -n "$LAST_TAG" ] || note "no tags yet — the wizard creates and pushes v<version>"
  [ -n "$LICENSE_FILE" ] || need_warn "no LICENSE — distros treat software without one as unfree"
  has_kind "Rust"    && { [ -f "$REPO/Cargo.lock" ] && need_ok "Cargo.lock" || need_fail "no Cargo.lock — the builds need it committed"; }
  has_kind "Go"      && { [ -f "$REPO/go.sum" ] && need_ok "go.sum" || note "no go.sum — fine if it has no dependencies"; }
  has_kind "Node.js" && { [ -f "$REPO/package-lock.json" ] && need_ok "package-lock.json" \
                          || need_fail "no package-lock.json — the wizards package npm projects from it"; }
  has_kind "Python"  && { [ -f "$REPO/pyproject.toml" ] && need_ok "pyproject.toml" \
                          || need_fail "no pyproject.toml — the Python builds need it"; }
  if [ -f "$REPO/.store-submit.conf" ]; then need_ok ".store-submit.conf: the answers from last time"
  else note "no .store-submit.conf yet — the questions about the app are asked once, then kept there"; fi
  return 0
}
needs_nix() { note "nothing beyond the above — the wizard handles the rest"; }
needs_linux() {
  linux_needs
  local d
  for d in $LINUX_DISTROS; do
    printf '   %sfor %s:%s\n' "$DIM" "$(distro_field "$d" 2)" "$R"
    "needs_$d"
  done
}

needs_flathub() {
  # the metadata Flathub wants in the app itself (the wizard can write it)
  local id m
  id="$(sed -nE 's/^[[:space:]]*flathub-id[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$REPO/.store-submit.conf" 2>/dev/null | tail -1)"
  [ -n "$id" ] && need_ok "Flathub app ID: $id" || note "the Flathub app ID is worked out and asked once (it's permanent there)"
  m="$(git -C "$REPO" ls-files 2>/dev/null | grep -E '\.(metainfo|appdata)\.xml(\.in)?$' | head -1 || true)"
  [ -n "$m" ] && need_ok "metainfo: $m" || note "no metainfo file yet — the wizard writes one for you to check and release"
  note "you open the pull request yourself (Flathub's policy); the wizard ends with the link"
  return 0
}
needs_aur() {
  # the AUR's first rule: nothing Arch already ships in its official repos
  local name
  name="$(sed -nE 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$REPO/.store-submit.conf" 2>/dev/null | tail -1)"
  name="${name:-$(basename "$REPO" | tr 'A-Z' 'a-z')}"
  if curl -sf --max-time 15 "https://archlinux.org/packages/search/json/?name=$name" | grep -q '"pkgname"'; then
    need_fail "Arch already ships '$name' in its official repos — the AUR doesn't take duplicates (pick another name)"
  else
    need_ok "'$name' isn't in Arch's official repos"
  fi
  return 0
}

for id in "${CHOSEN[@]}"; do
  printf '\n   %sWhat %s needs%s\n' "$B" "$(store_field "$id" 2)" "$R"
  "needs_$id"
done

# ================================================== 2b. this machine
printf '\n   %sThis machine%s\n' "$B" "$R"
OS_NAME="$(uname -s)"; ARCH="$(uname -m)"; DISTRO=""; DISTRO_ID=""; DISTRO_LIKE=""
if [ -r /etc/os-release ]; then
  DISTRO="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${NAME:-}}")"
  DISTRO_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
  DISTRO_LIKE="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
fi
[ "$OS_NAME" = Darwin ] && DISTRO="macOS $(sw_vers -productVersion 2>/dev/null || true)"
ok "system: ${DISTRO:-$OS_NAME} ($ARCH)"

# the package manager install hints are written for
PM=""
case " $DISTRO_ID $DISTRO_LIKE " in
  *" nixos "*)                         PM=nixos ;;
  *" arch "*)                          PM=pacman ;;
  *" debian "*|*" ubuntu "*)           PM=apt ;;
  *" fedora "*|*" rhel "*|*" centos "*) PM=dnf ;;
  *" opensuse"*|*" suse "*)            PM=zypper ;;
esac
if [ -z "$PM" ]; then
  for c in pacman apt dnf zypper brew nix; do have "$c" && { PM="$c"; break; }; done
fi
[ -n "$PM" ] && ok "package manager: $PM" || warn "no known package manager — install hints will be generic"

# install_hint <tool> — how to get it with this machine's package manager
install_hint() {
  local t="$1" pkg=""
  case "$PM:$t" in
    nix*:fdroid|brew:fdroid|apt:fdroid) pkg=fdroidserver ;;
    pacman:fdroid)   printf 'fdroidserver is in the AUR (or pipx install fdroidserver)'; return ;;
    *:fdroid)        printf 'pipx install fdroidserver, or a checkout: git clone https://gitlab.com/fdroid/fdroidserver.git ~/Opt/fdroidserver'; return ;;
    nix*:keytool)    pkg=jdk17 ;;
    apt:keytool)     pkg=openjdk-17-jdk-headless ;;
    pacman:keytool)  pkg=jdk17-openjdk ;;
    dnf:keytool|zypper:keytool) pkg=java-17-openjdk-devel ;;
    brew:keytool)    pkg=openjdk@17 ;;
    nix*:apksigner|apt:apksigner) pkg=apksigner ;;
    *:apksigner)     printf "Android SDK build-tools (sdkmanager 'build-tools;35.0.0')"; return ;;
    pacman:python3|brew:python3) pkg=python ;;
    nix*:nixpkgs-review|nix*:gh) pkg="$t" ;;
    *:nix|*:nix-build|*:nix-prefetch-url) printf 'Nix: https://nixos.org/download'; return ;;
    nix*:nix-locate) pkg=nix-index ;;
    *:nix-locate)    printf 'nix profile install nixpkgs#nix-index, then run nix-index once'; return ;;
    *:nixpkgs-review) printf 'nix profile install nixpkgs#nixpkgs-review'; return ;;
    pacman:makepkg)  pkg=base-devel ;;
    *:makepkg|*:namcap) printf 'Arch Linux only (makepkg/namcap come with pacman, base-devel, namcap)'; return ;;
    *:ssh)           case "$PM" in pacman|brew|nix*) pkg=openssh ;; *) pkg=openssh-client ;; esac ;;
    *)               pkg="$t" ;;
  esac
  case "$PM" in
    nixos)  printf 'add pkgs.%s to your configuration (or: nix profile install nixpkgs#%s)' "$pkg" "$pkg" ;;
    nix)    printf 'nix profile install nixpkgs#%s' "$pkg" ;;
    apt)    printf 'sudo apt install %s' "$pkg" ;;
    pacman) printf 'sudo pacman -S %s' "$pkg" ;;
    dnf)    printf 'sudo dnf install %s' "$pkg" ;;
    zypper) printf 'sudo zypper install %s' "$pkg" ;;
    brew)   printf 'brew install %s' "$pkg" ;;
    *)      printf 'install %s' "$pkg" ;;
  esac
}

# The F-Droid wizard also runs fdroidserver from a source checkout; look there too.
fdroid_available() {
  have fdroid && return 0
  local d
  for d in "${FDROIDSERVER:-}" "$HOME/Opt/fdroidserver" "$HOME/opt/fdroidserver" "$HOME/fdroidserver" \
           "$HOME/src/fdroidserver" "$HOME/Projects/fdroidserver" \
           "$(sed -n 's/^SAVED_FDROIDSERVER=//p' "${XDG_CONFIG_HOME:-$HOME/.config}/fdroid-submit/last.conf" 2>/dev/null | tr -d "'\"")"; do
    [ -n "$d" ] && [ -f "$d/fdroid" ] && { FDROID_AT="$d"; return 0; }
  done
  return 1
}

# Each tools_<id> lists what the store's wizard runs: `need` stops the run when
# missing, `want` only warns. A tool shared by several stores is checked once.
MISSING=0
SEEN=" "
tool_line() {  # tool_line <need|want> <tool> "what for"
  local kind="$1" t="$2" why="$3" found=1 where=""
  # checked already — unless it was missing but optional then, and is required now
  case "$SEEN" in *" $t:need "*|*" $t:$kind "*|*" $t:found "*) return 0 ;; esac
  case "$t" in
    fdroid) FDROID_AT=""; fdroid_available || found=0
            where="${FDROID_AT:-$(command -v fdroid 2>/dev/null || true)}" ;;
    *)      have "$t" || found=0; where="$(command -v "$t" 2>/dev/null || true)" ;;
  esac
  if [ "$found" = 1 ]; then SEEN="$SEEN$t:found "; else SEEN="$SEEN$t:$kind "; fi
  if [ "$found" = 1 ]; then
    ok "$t ${DIM}($where)${R}${GRN}"
  elif [ "$kind" = need ]; then
    bad "$t — needed for $why"; note "  $(install_hint "$t")"; MISSING=$((MISSING+1))
  else
    warn "$t — optional, for $why"; note "  $(install_hint "$t")"
  fi
}
need() { tool_line need "$@"; }
want() { tool_line want "$@"; }

fdroid_saved() {  # fdroid_saved <NAME> — a value the F-Droid wizard remembered
  sed -n "s/^SAVED_$1=//p" "${XDG_CONFIG_HOME:-$HOME/.config}/fdroid-submit/last.conf" 2>/dev/null \
    | tr -d "'\"" | sed -n 1p
}

tools_fdroid() {
  need git     "cloning fdroiddata and pushing the branch"
  # fdroiddata is cloned from upstream over HTTPS as a blob-less partial clone
  # (--filter=blob:none), which older gits can't do.
  if have git; then
    local gv; gv="$(git --version | sed -nE 's/^git version ([0-9]+)\.([0-9]+).*/\1 \2/p')"
    set -- $gv
    if [ -n "$gv" ] && { [ "$1" -lt 2 ] || { [ "$1" = 2 ] && [ "$2" -lt 22 ]; }; }; then
      bad "git $1.$2 — the fdroiddata clone (--filter=blob:none) needs git 2.22 or newer"
      note "  $(install_hint git)"; MISSING=$((MISSING+1))
    fi
  fi
  want curl    "checking and creating the fdroiddata fork"
  want fdroid  "validating the metadata (readmeta / lint) before the merge request"
  want glab    "forking fdroiddata and opening the merge request for you"
  if glab auth status --hostname gitlab.com >/dev/null 2>&1; then ok "glab is logged in to gitlab.com"
  elif [ -n "${GITLAB_TOKEN:-}" ]; then ok "\$GITLAB_TOKEN is set"
  else note "  not logged in to GitLab — run 'glab auth login' (or set \$GITLAB_TOKEN), or open the MR by hand"; fi

  # The clone needs no login; only the push to your fork does — over SSH for
  # a git@gitlab.com: fork URL (the usual one).
  local data fork
  data="$(fdroid_saved FDROIDDATA)"; data="${data:-$HOME/fdroiddata}"
  fork="$(fdroid_saved FORKURL)"
  if [ -d "$data/.git" ]; then ok "fdroiddata clone: $data (reused)"
  else note "  no fdroiddata clone yet — the wizard asks where to clone it (default $data)"; fi
  [ -n "${FDROIDDATA_UPSTREAM:-}" ] && warn "\$FDROIDDATA_UPSTREAM is set: upstream is $FDROIDDATA_UPSTREAM, not fdroid's repo"
  case "${fork:-git@}" in
    git@*|ssh://*)
      want ssh "pushing the branch to your fdroiddata fork"
      note "  the push uses your SSH key on GitLab — check with: ssh -T git@gitlab.com" ;;
  esac
  [ -n "$fork" ] && ok "fork: $fork"

  # The commit in fdroiddata is signed off with your git identity (the app
  # repo's, when the fresh clone has none).
  if [ -n "$(git -C "$REPO" config user.email 2>/dev/null || true)" ]; then
    ok "git identity: $(git -C "$REPO" config user.name 2>/dev/null || true) <$(git -C "$REPO" config user.email)>"
  else
    warn "no git user.email — the fdroiddata commit falls back to the AuthorEmail you enter, or nobody@example.com"
    note "  git config --global user.name 'Your Name'; git config --global user.email you@example.com"
  fi
  want keytool   "reading your signing key (reproducible-build mode)"
  want apksigner "reading an APK's signing certificate (reproducible-build mode)"
  [ -n "$FLUTTER_DIR" ] && want flutter "finding the Flutter version when the repo has no .fvmrc"
  return 0
}
tools_play() {
  need curl    "talking to the Play Developer API"
  need openssl "signing the service account's login token"
  need python3 "reading and writing the API's JSON"
  want unzip   "checking the build is signed before uploading"
}
tools_nix() {
  need nix-build "building the package (Nix)"
  need git       "the nixpkgs checkout and your branch"
  need gh        "your nixpkgs fork and the pull request"
  if gh auth status --hostname github.com >/dev/null 2>&1; then ok "gh is logged in to GitHub"
  else note "  not logged in to GitHub — the wizard offers 'gh auth login'"; fi
  want nix-locate "finding which package provides a missing library (nix-index)"
  note "  nix-update, nixpkgs-review, jq and yq are fetched from nixpkgs when needed"
  local np; np="$(sed -n 's/^SAVED_NIXPKGS=//p' "${XDG_CONFIG_HOME:-$HOME/.config}/nixpkgs-submit/last.conf" 2>/dev/null | tr -d "'\"")"
  np="${np:-$HOME/nixpkgs}"
  if [ -f "$np/.version" ]; then ok "nixpkgs checkout: $np (reused)"
  else note "  no nixpkgs checkout yet — the wizard asks where to put one (default $np; ~200 MB)"; fi
}
tools_aur() {
  need git       "the AUR repository"
  need ssh       "the AUR only takes pushes over SSH"
  need curl      "the source tarball and the AUR's package information"
  need sha256sum "the source checksum"
  local r="" key
  for key in podman docker; do have "$key" && "$key" info >/dev/null 2>&1 && { r="$key"; break; }; done
  if [ -n "$r" ]; then ok "$r — a clean test build in an Arch container, with namcap"
  elif have makepkg; then ok "makepkg — test builds on this Arch system"
  else warn "podman — optional, for a clean test build in an Arch container before publishing"; note "  $(install_hint podman)"; fi
  key="$(sed -n "s/^SAVED_AUR_KEY=//p" "${XDG_CONFIG_HOME:-$HOME/.config}/aur-submit/last.conf" 2>/dev/null | tr -d "'\"")"
  [ -n "$key" ] || { [ -f "$HOME/.ssh/aur" ] && key="$HOME/.ssh/aur"; }
  if ssh ${key:+-i "$key" -o IdentitiesOnly=yes} -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
       aur@aur.archlinux.org list-repos >/dev/null 2>&1; then
    ok "the AUR accepts your SSH key${key:+ ($key)}"
  else
    note "  the AUR doesn't know an SSH key of yours yet — the wizard walks you through it"
  fi
}
tools_flathub() {
  need flatpak "Flathub's builder and linter run as a Flatpak (NixOS: services.flatpak.enable = true)"
  need python3 "Flathub's generators (flatpak-flutter, cargo)"
  need gh      "your fork of the Flathub repository"
  if have flatpak && flatpak info org.flatpak.Builder >/dev/null 2>&1; then ok "org.flatpak.Builder (Flathub's builder and linter)"
  else note "  org.flatpak.Builder isn't installed — the wizard installs it (for your user)"; fi
}
tools_linux() {
  local d
  for d in $LINUX_DISTROS; do "tools_$d"; done
}

check_tools() {
  MISSING=0; SEEN=" "
  for id in "${CHOSEN[@]}"; do "tools_$id"; done
}
check_tools

# ================================================== verdict
echo
if [ "$BLOCKERS" -gt 0 ]; then
  die "$BLOCKERS problem(s) with the app above (✗) — fix those first"
fi
while [ "$MISSING" -gt 0 ]; do
  warn "$MISSING required tool(s) missing (✗) — install them, then check again"
  [ "$ASSUME_YES" = 1 ] || [ "$CHECK_ONLY" = 1 ] && die "missing tools"
  confirm "Check again?" y || exit 1
  echo; check_tools; echo
done
ok "ready"

if [ "$CHECK_ONLY" = 1 ]; then
  note "--check: not starting any wizard"
  exit 0
fi
save_answers

# ================================================== 3. hand over to the wizards
step "3/3  Wizard"
FWD=()
[ "$ASSUME_YES" = 1 ] && FWD+=(--yes)
[ "$DRYRUN" = 1 ]     && FWD+=(--dry-run)
[ "$NOSAVE" = 1 ]     && FWD+=(--no-save)

TODO=()
for id in "${CHOSEN[@]}"; do
  name="$(store_field "$id" 2)"
  if [ -z "$(store_field "$id" 3)" ]; then
    warn "$name: no wizard yet — the checks above are what it will need"
    continue
  fi
  TODO+=("$id")
done
[ "${#TODO[@]}" -gt 0 ] || exit 0

n=0
for id in "${TODO[@]}"; do
  n=$((n+1))
  name="$(store_field "$id" 2)"
  ARGS=("${FWD[@]+"${FWD[@]}"}")
  # the F-Droid and nixpkgs wizards take the checkout as --repo; the Play one
  # asks, offering the directory it runs in.
  case "$id" in fdroid) ARGS+=(--repo "$REPO") ;; esac
  [ "$id" = linux ] && ARGS+=(--repo "$REPO" --distros "$(printf '%s' "$LINUX_DISTROS" | tr ' ' ',')")
  ARGS+=("${PASS[@]+"${PASS[@]}"}")
  printf '\n%s━━ %s (%d/%d): store-submit.sh %s %s%s\n' "$B$CYN" "$name" "$n" "${#TODO[@]}" "$id" "${ARGS[*]-}" "$R"
  # its own process: the wizard's traps, exits and variables stay its own
  if ( cd "$REPO" && bash "$SELF" "$id" "${ARGS[@]+"${ARGS[@]}"}" ); then
    ok "$name: done"
  else
    rc=$?
    [ "$n" -lt "${#TODO[@]}" ] && warn "stopping here — the remaining store(s) were not started"
    die "$name: its wizard exited with status $rc"
  fi
done
