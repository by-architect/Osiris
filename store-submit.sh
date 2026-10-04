#!/usr/bin/env bash
#
# store-submit.sh — asks where the app is going, checks what that store needs
# from the app and what this machine has, then runs the store's own script:
#
#   fdroid-submit.sh   F-Droid
#   linux-submit.sh    Linux: NixOS (nixpkgs), Arch (AUR), Flathub, the Snap
#                      Store and Ubuntu (Launchpad PPA)
#
# Both live next to this file and work on their own; this one only checks
# first and hands over. `store-submit.sh fdroid|linux|nix|… [options]` still
# works and just runs that script.
#
# Adding a store: its own script, one line in STORES, and a needs_<id> and a
# tools_<id> function.

set -eu

SELF="$(readlink -f "$0")"
HERE="$(dirname "$SELF")"

# ##########################################################################
#   store-submit.sh <store> [options] — straight to that store's script
# ##########################################################################
case "${1-}" in
  fdroid) shift; exec bash "$HERE/fdroid-submit.sh" "$@" ;;
  linux)  shift; exec bash "$HERE/linux-submit.sh" "$@" ;;
  nix|aur|flathub|snap|ppa) exec bash "$HERE/linux-submit.sh" "$@" ;;
esac

# the Linux distro list (DISTROS, distro_field) and its checkbox picker
# (multi_select); sourced, linux-submit.sh only defines things
. "$HERE/linux-submit.sh"

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
# id|name|script next to this one (blank = not written yet)|one-line description
STORES="fdroid|F-Droid|fdroid-submit.sh|free and open source Android apps, built from source by F-Droid
linux|Linux (NixOS, Arch)|linux-submit.sh|Linux distributions — pick several, answer once"

usage() {
  cat <<'USAGE'
store-submit.sh — pick a store, check the app and this machine, then run that
store's wizard.

  store-submit.sh [options]             the store picker (options below)
  fdroid-submit.sh [options]            F-Droid's wizard directly
  linux-submit.sh [options]             the Linux distros, from one set of answers
  linux-submit.sh nix|aur|flathub|snap|ppa   one Linux distro's wizard directly
                                        (each takes --help)

  -h, --help          show this text
  -s, --store LIST    store(s) to publish to, skipping the question:
                      fdroid, linux — comma-separated, or "all"
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
                        store-submit.sh -s fdroid -- --build
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

# parse_stores "fdroid,linux" | "1 2" | "all" — fills CHOSEN, false on nonsense
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
  note "one or more, e.g. \"1\" or \"1 2\" or \"fdroid,linux\" or \"all\""
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
needs_snap() {
  local n
  n="$(sed -nE 's/^[[:space:]]*snap-name[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$REPO/.store-submit.conf" 2>/dev/null | tail -1)"
  [ -n "$n" ] && need_ok "snap name: $n" || note "the snap name is asked once (it's unique store-wide and permanent)"
  git -C "$REPO" ls-files 2>/dev/null | grep -qE '(^|/)(snap/)?\.?snapcraft\.yaml$' && need_ok "your snapcraft.yaml is used" \
    || note "no snapcraft.yaml — the wizard writes one for your build system"
  return 0
}
needs_ppa() {
  # Launchpad builds offline, from Ubuntu's own packages
  if [ -n "$FLUTTER_ANY" ]; then
    need_fail "a Flutter app can't be built in a PPA (no internet on Launchpad, no Flutter SDK in Ubuntu) — Ubuntu users get it from the Snap Store or Flathub"
  elif has_kind "Node.js"; then
    need_fail "an npm app can't be built in a PPA (no internet on Launchpad for npm) — the Snap Store and Flathub can take it"
  else
    note "Rust and Go dependencies are vendored into the source; other libraries come from Ubuntu"
  fi
  local u; u="$(sed -nE 's/^[[:space:]]*launchpad-user[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$REPO/.store-submit.conf" 2>/dev/null | tail -1)"
  [ -n "$u" ] && need_ok "Launchpad: ~$u" || note "your Launchpad username is asked once"
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
  need python3 "reading and writing metadata/<appid>.yml, line by line"
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
tools_snap() {
  local r="" k
  for k in podman docker; do have "$k" && "$k" info >/dev/null 2>&1 && { r="$k"; break; }; done
  if [ -n "$r" ]; then ok "$r — snapcraft runs in Canonical's container, nothing to install"
  else bad "podman or docker — needed to run snapcraft (NixOS: virtualisation.podman.enable = true;)"; note "  $(install_hint podman)"; MISSING=$((MISSING + 1)); fi
  [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/snap-submit/credentials" ] && ok "Snap Store login saved" \
    || note "  no Snap Store login yet — the wizard has snapcraft ask for it once"
}
tools_ppa() {
  local r="" k
  for k in podman docker; do have "$k" && "$k" info >/dev/null 2>&1 && { r="$k"; break; }; done
  if [ -n "$r" ]; then ok "$r — Ubuntu containers make the packages and test-build them offline"
  else bad "podman or docker — needed for the Ubuntu containers (NixOS: virtualisation.podman.enable = true;)"; note "  $(install_hint podman)"; MISSING=$((MISSING + 1)); fi
  if have gpg; then ok "gpg ($(command -v gpg)) — signs the uploads"
  else note "  gpg isn't installed — the wizard uses GnuPG from nixpkgs (or: $(install_hint gnupg))"; fi
  need curl "Launchpad's API and the upload"
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
  # the F-Droid and Linux wizards take the checkout as --repo
  case "$id" in fdroid) ARGS+=(--repo "$REPO") ;; esac
  [ "$id" = linux ] && ARGS+=(--repo "$REPO" --distros "$(printf '%s' "$LINUX_DISTROS" | tr ' ' ',')")
  ARGS+=("${PASS[@]+"${PASS[@]}"}")
  script="$(store_field "$id" 3)"
  printf '\n%s━━ %s (%d/%d): %s %s%s\n' "$B$CYN" "$name" "$n" "${#TODO[@]}" "$script" "${ARGS[*]-}" "$R"
  # its own process: the wizard's traps, exits and variables stay its own
  if ( cd "$REPO" && bash "$HERE/$script" "${ARGS[@]+"${ARGS[@]}"}" ); then
    ok "$name: done"
  else
    rc=$?
    [ "$n" -lt "${#TODO[@]}" ] && warn "stopping here — the remaining store(s) were not started"
    die "$name: its wizard exited with status $rc"
  fi
done
