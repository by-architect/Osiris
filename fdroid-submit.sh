#!/usr/bin/env bash
#
# fdroid-submit.sh — interactive wizard for submitting an Android app to F-Droid.
#
# Walks through the process described in:
#   https://f-droid.org/docs/Submitting_to_F-Droid_Quick_Start_Guide/
#   https://f-droid.org/docs/Build_Metadata_Reference/
#
# It detects what it can from your app repo, asks for the rest, writes (or, for
# an app already in F-Droid, extends) metadata/<applicationId>.yml in your
# fdroiddata fork, validates it with the fdroid CLI, and pushes a branch ready
# for a merge request.
#
# Nothing is pushed without asking first.

set -eu
# NOTE: deliberately no `set -o pipefail` — `cmd | head` would SIGPIPE and abort.

# ------------------------------------------------------------------ arguments
DRYRUN=0
SAVE=1
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fdroid-submit"
CONF="$CONF_DIR/last.conf"

usage() {
  cat <<'USAGE'
fdroid-submit.sh — interactive wizard for getting an Android app into F-Droid.

  -h, --help      show this text
  -n, --dry-run   do everything except the final `git push`
      --no-save   do not remember the answers for next time
      --forget    delete the remembered answers and exit

Detects what it can from your app's git checkout, asks for the rest, writes
metadata/<applicationId>.yml into your fdroiddata fork, validates it and
pushes a branch ready for a merge request. Nothing is pushed without asking.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -n|--dry-run) DRYRUN=1 ;;
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
  printf '   %s%s%s%s: ' "$B" "$__q" "$R" "${__def:+ [$__def]}" >&2
  readline __in
  [ -z "$__in" ] && __in="$__def"
  printf -v "$__var" '%s' "$__in"
}

confirm() {  # confirm "question" [default y|n]
  local q="$1" def="${2:-n}" a=""
  local hint="[y/N]"; [ "$def" = y ] && hint="[Y/n]"
  printf '   %s%s%s %s ' "$B" "$q" "$R" "$hint" >&2
  readline a
  [ -z "$a" ] && a="$def"
  case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac
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
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi

save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  {
    printf '# written by fdroid-submit.sh — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n'        "$REPO"
    printf 'SAVED_SUBDIR=%q\n'      "$SUBDIR"
    printf 'SAVED_LICENSE=%q\n'     "${LICENSE:-}"
    printf 'SAVED_CATSEL=%q\n'      "${CATSEL:-}"
    printf 'SAVED_AUTHORNAME=%q\n'  "${AUTHORNAME:-}"
    printf 'SAVED_AUTHOREMAIL=%q\n' "${AUTHOREMAIL:-}"
    printf 'SAVED_AUTHORSITE=%q\n'  "${AUTHORSITE:-}"
    printf 'SAVED_WEBSITE=%q\n'     "${WEBSITE:-}"
    printf 'SAVED_GLUSER=%q\n'      "${GLUSER:-}"
    printf 'SAVED_FORKURL=%q\n'     "${FORKURL:-}"
    printf 'SAVED_FDROIDDATA=%q\n'  "${FDROIDDATA:-}"
    printf 'SAVED_JDK=%q\n'         "${JDK:-}"
  } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  chmod 600 "$CONF" 2>/dev/null || true
}

# ------------------------------------------------------------------- fdroid CLI
RUNNER=""
detect_runner() {
  if have fdroid; then
    RUNNER=local; ok "using fdroid from PATH ($(command -v fdroid))"
  elif have nix-shell; then
    RUNNER=nix;   ok "using nix-shell -p fdroidserver"
    note "first invocation downloads fdroidserver; later ones are cached"
  elif have podman; then
    RUNNER=podman; ok "using the fdroidserver container image (podman)"
  elif have docker; then
    RUNNER=docker; ok "using the fdroidserver container image (docker)"
  else
    RUNNER=none
    warn "no fdroid, nix-shell, podman or docker found — validation will be skipped"
    note "install one of: nix-shell -p fdroidserver | apt install fdroidserver | docker"
  fi
}

FDROID_IMAGE="registry.gitlab.com/fdroid/fdroidserver:latest"

frun() {  # frun <fdroid args...>   — run inside $FDROIDDATA
  case "$RUNNER" in
    local)  ( cd "$FDROIDDATA" && fdroid "$@" ) ;;
    # %q-quote so arguments containing spaces survive the --run string
    nix)    ( cd "$FDROIDDATA" && nix-shell -p fdroidserver --run "$(printf '%q ' fdroid "$@")" ) ;;
    # --user keeps rewritemeta from leaving root-owned files in your clone
    podman|docker)
            "$RUNNER" run --rm --user "$(id -u):$(id -g)" \
              -v "$FDROIDDATA:/repo" -w /repo "$FDROID_IMAGE" fdroid "$@" ;;
    none)   warn "skipped: fdroid $*"; return 0 ;;
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
    5. push               — branch pushed, merge request link printed

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: everything except the final push"

IS_UPDATE=0
if confirm "Is this app already published on F-Droid (i.e. a version bump)?" n; then
  IS_UPDATE=1
else
  step "Before anything else: the RFP issue"
  say "F-Droid wants a Request For Packaging issue opened first, so a maintainer"
  say "knows the app is coming."
  note "https://gitlab.com/fdroid/rfp/-/issues/new"
  if ! confirm "Have you opened an RFP issue?" n; then
    say "Open one first, then re-run this script. It only takes a minute."
    exit 0
  fi
fi

detect_runner

# ============================================================== 1. the app repo
step "1/5  Your app repository"

ask REPO "Path to the app's git checkout" "${SAVED_REPO:-$PWD}"
REPO="${REPO/#\~/$HOME}"
[ -d "$REPO/.git" ] || die "$REPO is not a git checkout"
REPO="$(cd "$REPO" && pwd)"
ok "repo: $REPO"

# --- subdir (the gradle module that produces the APK)
SUBDIR_GUESS=""
for cand in "${SAVED_SUBDIR:-}" app mobile android .; do
  [ -n "$cand" ] || continue
  for gf in build.gradle.kts build.gradle; do
    if [ -f "$REPO/$cand/$gf" ] && grep -qE 'applicationId|namespace' "$REPO/$cand/$gf" 2>/dev/null; then
      SUBDIR_GUESS="$cand"; break 2
    fi
  done
done
ask SUBDIR "Gradle module subdirectory (the one with applicationId)" "${SUBDIR_GUESS:-app}"
SUBDIR="${SUBDIR#./}"; SUBDIR="${SUBDIR%/}"

GRADLE_FILE=""
for gf in build.gradle.kts build.gradle; do
  [ -f "$REPO/$SUBDIR/$gf" ] && GRADLE_FILE="$REPO/$SUBDIR/$gf" && break
done
[ -n "$GRADLE_FILE" ] || die "no build.gradle(.kts) found in $REPO/$SUBDIR"
ok "gradle file: ${GRADLE_FILE#"$REPO"/}"

# --- detect identity and version
# Handles both Kotlin DSL (`applicationId = "x"`) and Groovy (`applicationId "x"`),
# ignores // comments, and takes the first hit.
gval() {
  sed -e 's,//.*,,' "$GRADLE_FILE" \
    | grep -Eo "(^|[^A-Za-z_.])$1[[:space:]]*(=[[:space:]]*)?[\"']?[A-Za-z0-9_.-]+" \
    | sed -E "s/.*$1[[:space:]]*(=[[:space:]]*)?[\"']?//" \
    | sed -n 1p
}
APPID_GUESS="$(gval applicationId)"
[ -n "$APPID_GUESS" ] || APPID_GUESS="$(gval namespace)"
VNAME_GUESS="$(gval versionName)"
VCODE_GUESS="$(gval versionCode)"

while :; do
  ask APPID "Application ID" "$APPID_GUESS"
  printf '%s' "$APPID" | grep -qE '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$' && break
  warn "'$APPID' is not a valid application ID (e.g. com.example.app)"
  APPID_GUESS=""
done
ask VNAME "versionName of the release to publish" "$VNAME_GUESS"
while :; do
  ask VCODE "versionCode of that release" "$VCODE_GUESS"
  case "$VCODE" in ''|*[!0-9]*) warn "versionCode must be a plain integer"; VCODE_GUESS="" ;; *) break ;; esac
done

# --- tag
TAG_GUESS="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null || echo "v$VNAME")"
ask TAG "Git tag holding that release" "$TAG_GUESS"

ORIGIN="$(git -C "$REPO" remote get-url origin 2>/dev/null || echo "")"
if git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  ok "tag $TAG -> $(git -C "$REPO" rev-list -n1 "$TAG" | cut -c1-12)"
else
  warn "tag '$TAG' does not exist locally"
fi
# F-Droid builds from the *published* tag, so the remote is what matters.
if [ -n "$ORIGIN" ]; then
  if git -C "$REPO" ls-remote --tags --exit-code "$ORIGIN" "refs/tags/$TAG" >/dev/null 2>&1; then
    ok "tag $TAG is pushed to origin"
  else
    warn "tag '$TAG' is NOT on the remote — F-Droid will not find it"
    note "git push origin $TAG"
    confirm "Continue anyway?" n || exit 1
  fi
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

# Store listing: F-Droid reads it from the app repo, not from the .yml.
FASTLANE="$REPO/fastlane/metadata/android/en-US"
if [ -d "$FASTLANE" ] || [ -d "$REPO/metadata/en-US" ] || [ -d "$REPO/$SUBDIR/src/main/play" ]; then
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
say "Fork https://gitlab.com/fdroid/fdroiddata on GitLab if you have not already."
ask GLUSER "Your GitLab username" "${SAVED_GLUSER:-}"
ask FORKURL "Fork clone URL" "${SAVED_FORKURL:-git@gitlab.com:$GLUSER/fdroiddata.git}"
ask FDROIDDATA "Where to keep the clone" "${SAVED_FDROIDDATA:-$HOME/fdroiddata}"
FDROIDDATA="${FDROIDDATA/#\~/$HOME}"

if [ -d "$FDROIDDATA/.git" ]; then
  ok "reusing $FDROIDDATA"
else
  say "cloning (this is a large repo, give it a minute)…"
  git clone "$FORKURL" "$FDROIDDATA"
fi

git -C "$FDROIDDATA" remote get-url upstream >/dev/null 2>&1 || \
  git -C "$FDROIDDATA" remote add upstream https://gitlab.com/fdroid/fdroiddata.git
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
  if [ "$IS_UPDATE" = 0 ]; then
    warn "$APPID is already in fdroiddata — switching to update mode"
    IS_UPDATE=1
  else
    ok "found existing metadata/$APPID.yml"
  fi
elif [ "$IS_UPDATE" = 1 ]; then
  warn "no metadata/$APPID.yml upstream — treating this as a new app after all"
  IS_UPDATE=0
fi

# A half-finished earlier run leaves changes behind that would block the checkout.
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
note "F-Droid builds in a clean container; extra setup goes in 'sudo:' lines."
JDK_DEF="${SAVED_JDK:-17}"
ask_opt JDK "JDK to install in the build container (blank = use the image default)" "$JDK_DEF"
case "$JDK" in ''|*[!0-9]*) JDK="" ;; esac

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
ask_opt GRADLEFLAVOUR "Gradle flavour (blank = 'yes', the default variant)" ""

BUILD_BLOCK="$WORK/build.yml"
{
  printf "  - versionName: '%s'\n" "$VNAME"
  printf '    versionCode: %s\n' "$VCODE"
  printf '    commit: %s\n' "$TAG"
  [ "$SUBDIR" != "." ] && printf '    subdir: %s\n' "$SUBDIR"
  if [ -n "$JDK" ]; then
    printf '    sudo:\n'
    printf '      - apt-get update\n'
    printf '      - apt-get install -y openjdk-%s-jdk-headless\n' "$JDK"
    printf '      - update-java-alternatives -a\n'
  fi
  printf '    gradle:\n'
  printf "      - '%s'\n" "${GRADLEFLAVOUR:-yes}"
} > "$BUILD_BLOCK"

YML="$WORK/$APPID.yml"

if [ "$IS_UPDATE" = 1 ]; then
  # ---------- update: keep the upstream file, add one build, bump CurrentVersion
  git -C "$FDROIDDATA" show "$EXISTING" > "$YML"
  if grep -qE "^[[:space:]]+versionCode: $VCODE\$" "$YML"; then
    die "versionCode $VCODE is already in metadata/$APPID.yml — nothing to do"
  fi
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
    sed -E "s|^CurrentVersion:.*|CurrentVersion: '$VNAME'|; s|^CurrentVersionCode:.*|CurrentVersionCode: $VCODE|" \
      "$YML" > "$YML.new" && mv "$YML.new" "$YML"
  else
    printf "\nCurrentVersion: '%s'\nCurrentVersionCode: %s\n" "$VNAME" "$VCODE" >> "$YML"
  fi
  ok "added versionCode $VCODE to the existing metadata"
else
  # ---------- new app: ask for everything the entry needs
  # --- license
  LIC_GUESS="${SAVED_LICENSE:-}"
  if [ -z "$LIC_GUESS" ]; then
    for f in LICENSE LICENSE.md LICENSE.txt LICENCE LICENCE.md COPYING COPYING.md; do
      [ -f "$REPO/$f" ] || continue
      if   grep -qi "GNU AFFERO GENERAL PUBLIC LICENSE" "$REPO/$f"; then LIC_GUESS="AGPL-3.0-only"
      elif grep -qi "GNU LESSER GENERAL PUBLIC LICENSE" "$REPO/$f"; then LIC_GUESS="LGPL-3.0-only"
      elif grep -qi "GNU GENERAL PUBLIC LICENSE" "$REPO/$f"; then
        if grep -q "Version 3" "$REPO/$f"; then LIC_GUESS="GPL-3.0-only"; else LIC_GUESS="GPL-2.0-only"; fi
      elif grep -qi "Apache License" "$REPO/$f";        then LIC_GUESS="Apache-2.0"
      elif grep -qi "MIT License" "$REPO/$f";           then LIC_GUESS="MIT"
      elif grep -qi "Mozilla Public License" "$REPO/$f"; then LIC_GUESS="MPL-2.0"
      elif grep -qi "Redistribution and use in source" "$REPO/$f"; then LIC_GUESS="BSD-3-Clause"
      elif grep -qi "This is free and unencumbered" "$REPO/$f"; then LIC_GUESS="Unlicense"
      fi
      [ -n "$LIC_GUESS" ] && { ok "license looks like $LIC_GUESS (from $f)"; break; }
    done
  fi
  note "SPDX identifier, e.g. GPL-3.0-only, GPL-3.0-or-later, Apache-2.0, MIT, AGPL-3.0-only"
  ask LICENSE "License" "$LIC_GUESS"

  # --- categories
  CATS_ALL="Connectivity Development Games Graphics Internet Money Multimedia Navigation Phone&SMS Reading Science&Education Security Sports&Health System Theming Time Writing"
  say "Categories (pick one or more by number, space separated):"
  i=1; for c in $CATS_ALL; do printf '     %2d) %s\n' "$i" "${c//&/ & }"; i=$((i+1)); done
  CATS_MAX=$((i-1))
  while :; do
    ask CATSEL "Numbers" "${SAVED_CATSEL:-1}"
    CATEGORIES=""; BADSEL=""
    for n in $CATSEL; do
      case "$n" in ''|*[!0-9]*) BADSEL="$n"; break ;; esac
      [ "$n" -ge 1 ] && [ "$n" -le "$CATS_MAX" ] || { BADSEL="$n"; break; }
      c="$(echo "$CATS_ALL" | awk -v k="$n" '{print $k}')"
      CATEGORIES="$CATEGORIES${CATEGORIES:+|}${c//&/ & }"
    done
    [ -z "$BADSEL" ] && [ -n "$CATEGORIES" ] && break
    warn "'${BADSEL:-}' is not one of 1-$CATS_MAX"
  done
  ok "categories: ${CATEGORIES//|/, }"

  # --- urls
  ask SOURCE  "SourceCode URL"   "$WEB_GUESS"
  ask REPOURL "Repo URL (must end in .git)" "${WEB_GUESS:+$WEB_GUESS.git}"
  case "$REPOURL" in *.git) ;; *) warn "Repo usually ends in .git — fdroid lint will say so" ;; esac
  ask_opt ISSUES    "IssueTracker URL"  "${WEB_GUESS:+$WEB_GUESS/issues}"
  ask_opt CHANGELOG "Changelog URL"     "${WEB_GUESS:+$WEB_GUESS/releases}"
  ask_opt WEBSITE   "WebSite URL (blank if none)" "${SAVED_WEBSITE:-}"

  # --- author
  ask_opt AUTHORNAME  "AuthorName"    "${SAVED_AUTHORNAME:-$(git -C "$REPO" config user.name 2>/dev/null || echo "")}"
  ask_opt AUTHOREMAIL "AuthorEmail"   "${SAVED_AUTHOREMAIL:-$(git -C "$REPO" config user.email 2>/dev/null || echo "")}"
  ask_opt AUTHORSITE  "AuthorWebSite" "${SAVED_AUTHORSITE:-}"

  # --- flags
  REQROOT=false
  confirm "Does the app require root?" n && REQROOT=true

  # --- anti-features
  AF_ALL="Ads Tracking NonFreeNet NonFreeAdd NonFreeDep NonFreeAssets UpstreamNonFree NoSourceSince KnownVuln"
  ANTIFEATURES=""
  if confirm "Declare any anti-features (ads, tracking, non-free deps…)?" n; then
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
  step "Publishing mode"
  say "  1) ${B}F-Droid builds and signs${R}  — F-Droid compiles from source and signs with"
  say "     its own key. Simplest. Users get F-Droid's signature, so an app already"
  say "     installed from your GitHub APK cannot update to it."
  say "  2) ${B}Reproducible build${R}         — F-Droid rebuilds from source, checks the result"
  say "     matches your signed APK, and ships YOUR APK. Keeps your signature."
  say "     Needs Binaries: and AllowedAPKSigningKeys."
  ask MODE "Which?" "1"

  BINARIES=""; SIGNKEY=""
  if [ "$MODE" = "2" ]; then
    note "use %v where the version goes, e.g. .../releases/download/v%v/App-%v.apk"
    ask BINARIES "Binaries URL pattern" "${WEB_GUESS:+$WEB_GUESS/releases/download/v%v/$(basename "$REPO")-%v.apk}"
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
    printf "CurrentVersion: '%s'\n" "$VNAME"
    printf 'CurrentVersionCode: %s\n' "$VCODE"
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
  warn "no fdroid CLI available — skipping readmeta/rewritemeta/lint"
  warn "the maintainers' CI will run these anyway, so expect to fix what it reports"
else
  say "fdroid readmeta";             frun readmeta              || warn "readmeta reported problems"
  say "fdroid rewritemeta $APPID";   frun rewritemeta "$APPID"  || warn "rewritemeta reported problems"
  say "fdroid lint $APPID";          frun lint "$APPID"         || warn "lint reported problems"
  if [ "$YMLSUM" != "$(cksum < "$FDROIDDATA/metadata/$APPID.yml")" ]; then
    note "rewritemeta reformatted the file — that is normal"
  fi
  echo
  say "A full build takes a long time and needs the Android SDK, but it is the"
  say "single best predictor of whether your MR will be accepted."
  if confirm "Run 'fdroid build -v -l $APPID' now?" n; then
    frun build -v -l "$APPID" || warn "build failed — fix this before opening the MR"
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

if [ "$IS_UPDATE" = 1 ]; then
  MSG="Update $APPID to $VNAME ($VCODE)"
else
  MSG="New App: $APPID"
fi
ask COMMITMSG "Commit message" "$MSG"

if [ "$DRYRUN" = 1 ]; then
  warn "dry run — not committing or pushing"
  note "$FDROIDDATA (branch $BRANCH)"
elif confirm "Commit and push to $FORKURL ($BRANCH)?" n; then
  git -C "$FDROIDDATA" commit -q -m "$COMMITMSG"
  git -C "$FDROIDDATA" push -u origin "$BRANCH"
  ok "pushed"
  cat <<DONE

   ${B}Open the merge request:${R}
   https://gitlab.com/$GLUSER/fdroiddata/-/merge_requests/new?merge_request%5Bsource_branch%5D=$BRANCH&merge_request%5Btarget_branch%5D=$UPBRANCH

   Target it at fdroid/fdroiddata, branch $UPBRANCH.
   Expect roughly 24-48 hours from merge until the app appears in the repo.

DONE
else
  say "Nothing pushed. The branch and file are ready at:"
  note "$FDROIDDATA (branch $BRANCH)"
fi
