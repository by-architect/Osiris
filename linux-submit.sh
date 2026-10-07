#!/usr/bin/env bash
#
# linux-submit.sh — publish an app to Linux, from one set of answers: NixOS
# (nixpkgs), Arch (AUR), Debian, Ubuntu (Launchpad PPA), Fedora (COPR and its
# own repositories), openSUSE (OBS), Alpine (aports), Gentoo (GURU), Flathub,
# the Snap Store and Homebrew.
#
#   linux-submit.sh [options]          pick the distros, answer once, then each
#                                      distro's wizard runs
#   linux-submit.sh <distro> [options] one distro's wizard, where <distro> is
#                                      nix, aur, debian, ppa, copr, fedora,
#                                      obs, alpine, guru, flathub, snap, brew
#   (each takes --help)
#
# Layout: the shared helpers, then each wizard as one function (wizard_<id>),
# then the few lines at the bottom that pick one. A distro's wizard always
# runs in a process of its own (wizard_linux starts `linux-submit.sh <id>`),
# so its variables, traps and exits stay its own. Their bodies are
# deliberately not indented: their here-documents must start at column 0.
#
# Sourced, it only defines things and runs nothing.
#
# Adding a distro: one line in DISTROS, a wizard_<id> function, its id in the
# `case` at the bottom, and — for questions a several-distro run should ask
# up front — a <id>_questions function that wizard_linux calls.

set -eu

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
# passed up to `linux-submit.sh` for its summary.
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
    printf '# linux-submit.sh — what the Linux packages say about this app.\n'
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
#   nixpkgs wizard — linux-submit.sh nix [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_nix() {
#
# linux-submit.sh nix — get an app into nixpkgs (the package set Nix and NixOS
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
linux-submit.sh nix — get an app into nixpkgs, or update it there.

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
    printf '# written by linux-submit.sh nix — safe to delete (or run --forget)\n'
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
      printf 'Updated with `nix-update`, run by [linux-submit.sh](%s); built and checked locally.\n' "$TOOL_URL"
    else
      printf 'Automation disclosure: `package.nix` was generated by [linux-submit.sh](%s), a deterministic script (no AI involved when it runs) that detects the project, fills in hashes by building, and formats with treefmt.' "$TOOL_URL"
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
debian|Debian (official archive)|wizard_debian|up to a sponsor's upload; Ubuntu takes it later
ppa|Ubuntu (Launchpad PPA)|wizard_ppa|apt for Ubuntu, Mint, Pop!_OS…; Launchpad builds it
copr|Fedora (COPR)|wizard_copr|your own repository built by Fedora; dnf copr enable
fedora|Fedora (official)|wizard_fedora|prepared up to the package review; people review it
obs|openSUSE (OBS)|wizard_obs|your home project on build.opensuse.org; zypper
alpine|Alpine Linux (aports)|wizard_alpine|an APKBUILD in aports' testing, through a merge request
guru|Gentoo (GURU)|wizard_guru|an ebuild in GURU, Gentoo's user repository
flathub|Flathub (every distro)|wizard_flathub|prepared up to the pull request; you open it
snap|Snap Store (every distro)|wizard_snap|built and uploaded; the store reviews it
brew|Homebrew (macOS and Linux)|wizard_brew|a formula in homebrew/core, or your own tap"

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
#   Linux wizard — linux-submit.sh [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_linux() {
#
# linux-submit.sh — publish one app to several Linux distributions:
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
linux-submit.sh — publish an app to several Linux distributions at once.

  -h, --help           show this text
  -d, --distros LIST   distros to publish to, skipping the question:
                       nix, aur, debian, ppa, copr, fedora, obs,
                       alpine, guru, flathub, snap, brew — comma-separated, or "all"
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
case " $CHOSEN " in *" debian "*) debian_questions ;; esac
case " $CHOSEN " in *" ppa "*) ppa_questions ;; esac
case " $CHOSEN " in *" copr "*) copr_questions ;; esac
case " $CHOSEN " in *" fedora "*) fedora_questions ;; esac
case " $CHOSEN " in *" obs "*) obs_questions ;; esac
case " $CHOSEN " in *" alpine "*) alpine_questions ;; esac
case " $CHOSEN " in *" guru "*) guru_questions ;; esac
case " $CHOSEN " in *" flathub "*) flathub_questions ;; esac
case " $CHOSEN " in *" snap "*) snap_questions ;; esac
case " $CHOSEN " in *" brew "*) brew_questions ;; esac
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
  printf '\n%s━━ %s (%d/%d): linux-submit.sh %s %s%s\n' "$B$CYN" "$name" "$n" "$TOTAL" "$d" "${FWD[*]}" "$R"
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
  else bad "$(distro_field "$d" 2) — stopped (exit $rc); run it again with: linux-submit.sh $d"; FAILED=1; fi
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
#   AUR wizard — linux-submit.sh aur [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_aur() {
#
# linux-submit.sh aur — publish an app to the AUR (Arch User Repository), or
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
linux-submit.sh aur — publish an app to the AUR, or update it there.

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
    printf '# written by linux-submit.sh aur — safe to delete (or run --forget)\n'
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
say "  • Next release: run linux-submit.sh aur (or linux-submit.sh) again; it bumps pkgver."
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

# --- network access (a Flatpak permission), shared with the Snap Store
ask_network
}

# ##########################################################################
#   Flathub wizard — linux-submit.sh flathub [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_flathub() {
#
# linux-submit.sh flathub — prepare an app for Flathub (or a new version of
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
linux-submit.sh flathub — prepare an app for Flathub, or an update of it.
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
  { printf '# written by linux-submit.sh flathub — safe to delete (or run --forget)\n'
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
      warn "one of: $CATS"; CAT=""
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
    AB_DEF="$(cfg_get about)"; [ -n "$AB_DEF" ] || AB_DEF="$README_P"
    ask ABOUT "What the app does" "$AB_DEF"
    [ "$SAVE" = 1 ] && cfg_set about "$ABOUT"
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
  handoff_add "Release that version (a new tag), then run linux-submit.sh flathub again — it picks up from here"
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
NET="$(cfg_get network)"; NET="${NET:-no}"
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
  handoff_add "Flathub's AI policy: say in the pull request whether AI-generated material is in your app or its packaging. This manifest was made by $( [ "$GENERATED_BY" = flatpak-flutter ] && echo "flatpak-flutter" || echo "linux-submit.sh") (linux-submit.sh was written with AI help) — state it as it is; reviewers decide (https://docs.flathub.org/docs/for-app-authors/requirements#generative-ai-policy)"
  handoff_add "Answer the reviewers yourself; when they're done, comment \"bot, build\" for a test build"
  handoff_add "Turn on two-factor authentication on GitHub: after the merge you get an invite to flathub/$APP_ID — accept it within a week"
  case "$APP_ID" in io.github.*|io.gitlab.*) handoff_add "Once it's live: flathub.org → Developer Portal → your app → Verification (log in with ${HOST%%.*})" ;; esac
else
  handoff_add "Install the test build from the bot's comment on the pull request, try it, then merge it"
fi
handoff_show "Your turn — Flathub wants a person to open this pull request" "$PR_LINK"
}

# ##########################################################################
#   Snap Store's questions — the snap name, and network access. Part of
#   "Your app" whenever the Snap Store is among the distros.
# ##########################################################################
snap_name_problems() {  # snap_name_problems <name> — one line per rule it breaks
  local n="$1"
  [ "${#n}" -le 40 ] || echo "it is longer than 40 characters"
  printf '%s' "$n" | grep -qE '^[a-z0-9-]+$' || echo "only lowercase letters, digits and - are allowed"
  printf '%s' "$n" | grep -qE '[a-z]' || echo "it needs at least one letter"
  case "$n" in -*|*-) echo "it must not start or end with -" ;; esac
  case "$n" in *--*) echo "it must not have two - in a row" ;; esac
}
snap_questions() {
  local guess first=1
  guess="$(cfg_get snap-name)"
  [ -n "$guess" ] || guess="$(printf '%s' "$PNAME" | tr 'A-Z_' 'a-z-' | tr -cd 'a-z0-9-' | sed -E 's/-+/-/g; s/^-//; s/-$//' | cut -c1-40)"
  while :; do
    if [ "$first" = 1 ] && [ -n "$(cfg_get snap-name)" ] && [ "$ASK_ALL" = 0 ]; then
      SNAP_NAME="$guess"; ok "snap name: $SNAP_NAME"
    else
      [ "$first" = 1 ] && note "the snap name is unique across the whole Snap Store and can't change after registering"
      ask SNAP_NAME "Snap name" "$guess"
    fi
    first=0
    PROBS="$(snap_name_problems "$SNAP_NAME")"
    [ -z "$PROBS" ] && break
    printf '%s\n' "$PROBS" | while read -r l; do warn "snap name: $l"; done
    [ "$ASSUME_YES" = 1 ] && die "fix the snap name and re-run"
    guess="$SNAP_NAME"
  done
  [ "${SAVE:-1}" = 1 ] && cfg_set snap-name "$SNAP_NAME"
  ask_network
}
# ask_network — does the app use the internet? (a permission on Flathub and
# the Snap Store). Guessed from its dependencies; asked once, kept in the config.
ask_network() {
  NET="$(cfg_get network)"
  [ -n "$NET" ] && { ok "network access: $NET"; return 0; }
  NET=no
  { at "$TAG_REF" "$(pp pubspec.yaml)"; at "$TAG_REF" Cargo.lock; at "$TAG_REF" package.json; at "$TAG_REF" go.mod; at "$TAG_REF" pyproject.toml; } 2>/dev/null \
    | grep -qiE '(^|[^a-z])(http|dio|web_socket|supabase|firebase|reqwest|hyper|ureq|axios|grpc|requests|httpx|net/http)([^a-z]|$)' && NET=yes
  if [ "$ASSUME_YES" = 0 ]; then confirm "Does $PNAME use the internet?" "$( [ "$NET" = yes ] && echo y || echo n)" && NET=yes || NET=no; fi
  [ "${SAVE:-1}" = 1 ] && cfg_set network "$NET"
  ok "network access: $NET"
}

# ##########################################################################
#   Snap Store wizard — linux-submit.sh snap [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_snap() {
#
# linux-submit.sh snap — publish an app to the Snap Store, or a new version.
#
# Follows Snapcraft's documentation:
#   https://ubuntu.com/docs/snapcraft/stable/how-to/publishing/
#
# Snapcraft runs in Canonical's own container image (ghcr.io/canonical/
# snapcraft), so it works on any distro with podman or docker — nothing to
# install. It writes snapcraft.yaml (or uses yours), builds the snap, logs you
# in once (in snapcraft's own prompt), registers the name, and uploads. Every
# new snap and revision is reviewed by the store before it's public.

set -eu

DRYRUN=0
SAVE=1
ASSUME_YES=0
ASK_ALL=0
REPO_ARG=""
CHANNEL_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/snap-submit"
CONF="$CONF_DIR/last.conf"
CREDS_FILE="$CONF_DIR/credentials"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/store-submit"
SNAPIMG="${SNAPCRAFT_IMAGE:-ghcr.io/canonical/snapcraft:8_core24}"
SNAP_WEB="https://snapcraft.io"

usage() {
  cat <<'USAGE'
linux-submit.sh snap — publish an app to the Snap Store, or update it there.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --config FILE   the shared answers (default: .store-submit.conf in the repo)
      --channel NAME  stable, candidate, beta or edge (default: remembered, else stable)
  -n, --dry-run       build the snap; don't register or upload anything
      --no-save       do not remember the answers for next time
      --forget        delete the remembered answers and the saved login, and exit
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
    --channel)    CHANNEL_ARG="${2-}"; shift ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF" "$CREDS_FILE"; printf 'forgot %s and the saved login\n' "$CONF"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WIZ_NAME=snap-submit
linux_common

SAVED_REPO=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  { printf '# written by linux-submit.sh snap — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n' "${REPO:-${SAVED_REPO:-}}"; } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}

# ------------------------------------------------------------------ helpers
RUNTIME=""
for r in podman docker; do
  have "$r" && "$r" info >/dev/null 2>&1 && { RUNTIME="$r"; break; }
done
# sc <project dir> <snapcraft args...> — snapcraft in Canonical's container.
# The login travels as an environment variable, never on the command line.
sc() {
  local wd="$1"; shift
  ( [ -f "$CREDS_FILE" ] && SNAPCRAFT_STORE_CREDENTIALS="$(cat "$CREDS_FILE")" && export SNAPCRAFT_STORE_CREDENTIALS
    "$RUNTIME" run --rm -v "$wd:/project" -e SNAPCRAFT_STORE_CREDENTIALS "$SNAPIMG" "$@" )
}
# docker runs the container as root: hand the files back to you afterwards
fix_owner() {
  [ "$RUNTIME" = docker ] || return 0
  "$RUNTIME" run --rm -v "$1:/project" --entrypoint chown "$SNAPIMG" -R "$(id -u):$(id -g)" /project >/dev/null 2>&1 || true
}

# =============================================================== 0. orientation
cat <<BANNER

  ${B}Snap Store wizard${R}

  Six stages:
    1. your app       — shared with the other distros, plus the snap name
    2. tools + login  — snapcraft in Canonical's container; your store login
    3. snapcraft.yaml — yours, or written for your build system
    4. build          — the snap, built by snapcraft (it lints as it goes)
    5. register       — the name reserved in the Snap Store (first time)
    6. upload         — to your channel; the store reviews it before it's public

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: the snap is built; nothing is registered or uploaded"
for t in git curl python3; do have "$t" || die "$t is missing — install it and re-run"; done
[ -n "$RUNTIME" ] || die "snapcraft runs in a container here: install podman or docker (NixOS: virtualisation.podman.enable = true;)"

# ============================================================== 1. the app
linux_app "1/6  Your app"
snap_questions

# ======================================================== 2. tools + login
step "2/6  Snapcraft and your store login"
if ! "$RUNTIME" image inspect "$SNAPIMG" >/dev/null 2>&1; then
  run_logged "$WORK/pull.log" "fetching snapcraft ($SNAPIMG, first time only)" "$RUNTIME" pull "$SNAPIMG" \
    || { tail -n 4 "$WORK/pull.log" | sed 's/^/     /'; die "couldn't fetch $SNAPIMG"; }
fi
ok "snapcraft: $SNAPIMG (via $RUNTIME)"

whoami_ok() { sc "$WORK" whoami > "$WORK/whoami.log" 2>&1 && grep -q '^username:' "$WORK/whoami.log"; }
if [ "$DRYRUN" = 1 ] && [ ! -f "$CREDS_FILE" ]; then
  note "dry run: not logging in"
else
  while ! { [ -f "$CREDS_FILE" ] && whoami_ok; }; do
    [ -f "$CREDS_FILE" ] && { warn "the saved Snap Store login doesn't work any more (expired?)"; rm -f "$CREDS_FILE"; }
    say "The Snap Store needs your developer login, once. Snapcraft asks for it itself:"
    note "email, password and 2FA code of your Ubuntu One account (none yet? $SNAP_WEB/account)"
    [ "$ASSUME_YES" = 1 ] && die "log in once without --yes"
    mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
    TTY=(); [ -t 0 ] && TTY=(-it)
    "$RUNTIME" run --rm "${TTY[@]+"${TTY[@]}"}" -v "$CONF_DIR:/creds" "$SNAPIMG" export-login /creds/credentials \
      || warn "snapcraft couldn't log you in"
    fix_owner "$CONF_DIR"
    [ -f "$CREDS_FILE" ] && chmod 600 "$CREDS_FILE"
    [ -f "$CREDS_FILE" ] || { confirm "Try again?" y || die "the Snap Store needs your login to publish"; }
  done
  [ -f "$CREDS_FILE" ] && ok "logged in as $(sed -n 's/^username: *//p' "$WORK/whoami.log") (saved in $CREDS_FILE, readable only by you)"
fi

# ======================================================== 3. snapcraft.yaml
step "3/6  snapcraft.yaml"
WD="$CACHE/snap/$SNAP_NAME"
rm -rf "$WD"; mkdir -p "$WD"
OWN="$(grep -E '(^|/)(snap/snapcraft\.yaml|snapcraft\.yaml|\.snapcraft\.yaml)$' "$WORK/tree.txt" | head -1 || true)"
if [ -n "$OWN" ]; then
  # yours: build it from the tagged source
  git -C "$REPO" archive "$TAG_REF" | tar x -C "$WD"
  YAML="$WD/$OWN"
  YV="$(sed -nE "s/^version:[[:space:]]*[\"']?([^\"'[:space:]]+).*/\\1/p" "$YAML" | head -1)"
  YN="$(sed -nE "s/^name:[[:space:]]*[\"']?([^\"'[:space:]]+).*/\\1/p" "$YAML" | head -1)"
  ok "your $OWN (from $TAG)"
  [ -n "$YV" ] && [ "$YV" != "$VERSION" ] && warn "it says version $YV, the release is $VERSION"
  [ -n "$YN" ] && [ "$YN" != "$SNAP_NAME" ] && { warn "it names the snap '$YN'"; SNAP_NAME="$YN"; }
else
  GUI=0; EXT=""; BUILD_PKGS=""; STAGE_PKGS=""
  case "$KIND" in
    flutter) GUI=1 ;;
    rust)  at "$TAG_REF" Cargo.lock | grep -qE '^name = "(gtk4|libadwaita|gtk|iced|egui|eframe|slint|winit|tauri|relm4)"' && GUI=1
           at "$TAG_REF" Cargo.lock | grep -q '^name = "openssl-sys"' && { BUILD_PKGS="libssl-dev pkg-config"; STAGE_PKGS="libssl3t64"; } ;;
    meson|cmake) { for f in $(grep -E '(^|/)(meson\.build|CMakeLists\.txt)$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done; } \
                   | grep -qiE "gtk|libadwaita|Qt6|Qt5" && GUI=1 ;;
  esac
  [ "$GUI" = 1 ] && EXT="gnome"
  ABOUT="$(cfg_get about)"
  if [ -z "$ABOUT" ]; then
    README_P="$(for f in README.md README; do at "$TAG_REF" "$f"; done 2>/dev/null | awk '/^#|^\[!|^!\[|^<|^$/ { if (p) exit; next } { p = p (p ? " " : "") $0 } END { print p }' | cut -c1-400)"
    note "a few sentences for the store page, in your own words"
    ask ABOUT "What the app does" "${README_P:-$DESC}"
    [ "$SAVE" = 1 ] && cfg_set about "$ABOUT"
  fi
  SUMMARY="$DESC"
  if [ "${#SUMMARY}" -gt 78 ]; then
    warn "the Snap Store's summary is at most 78 characters (yours is ${#SUMMARY})"
    while [ "${#SUMMARY}" -gt 78 ]; do ask SUMMARY "A shorter summary" "$(printf '%s' "$DESC" | cut -c1-78)"; done
  fi
  TITLE="$(cfg_get display-name)"; [ -n "$TITLE" ] || TITLE="$(printf '%s' "$PNAME" | sed -E 's/[-_]/ /g; s/(^| )([a-z])/\1\u\2/g')"
  # the icon: the one Flathub uses, or the app's own
  ICON="$(grep -E "(^|/)$(cfg_get flathub-id | sed 's/[.]/\\./g')\\.(svg|png)$" "$WORK/tree.txt" 2>/dev/null | head -1 || true)"
  [ -n "$ICON" ] || ICON="$(grep -iE '\.(png|svg)$' "$WORK/tree.txt" | grep -iE 'icon|logo|launcher' | head -1 || true)"
  GITURL_SNAP="$WEB.git"
  [ "$FORGE" = git ] && GITURL_SNAP="$(printf '%s' "$ORIGIN" | sed -E 's#^[^@/]+@([^:]+):#https://\1/#')"
  mkdir -p "$WD/snap/gui"
  [ -n "$ICON" ] && at "$TAG_REF" "$ICON" > "$WD/snap/gui/$SNAP_NAME.${ICON##*.}"
  python3 - "$WD/snap/snapcraft.yaml" "$SNAP_NAME" "$TITLE" "$VERSION" "$SUMMARY" "$ABOUT" "$SPDX" "$HOMEPAGE" "$WEB" \
          "$KIND" "$GITURL_SNAP" "$TAG" "$PROOT" "$MAIN_GUESS" "$EXT" "$NET" "$BUILD_PKGS" "$STAGE_PKGS" "${ICON:+snap/gui/$SNAP_NAME.${ICON##*.}}" <<'PY' \
    || die "couldn't write snapcraft.yaml"
import json, sys
(out, name, title, version, summary, about, spdx, homepage, web, kind, giturl, tag, proot, cmd,
 ext, net, build_pkgs, stage_pkgs, icon) = sys.argv[1:20]
q = lambda s: json.dumps(s, ensure_ascii=False)          # a YAML-safe string
part = {"source": giturl, "source-tag": tag}
if proot != ".":
    part["source-subdir"] = proot
command = "bin/" + cmd
if kind == "flutter":
    part.update({"plugin": "flutter", "flutter-target": "lib/main.dart"}); command = cmd
elif kind == "rust":
    part["plugin"] = "rust"
elif kind == "go":
    part.update({"plugin": "go", "build-snaps": ["go/latest/stable"]})
elif kind == "python":
    part["plugin"] = "python"
elif kind == "node":
    part.update({"plugin": "npm", "npm-include-node": True, "npm-node-version": "22.12.0"})
elif kind == "meson":
    part.update({"plugin": "meson", "meson-parameters": ["--prefix=/usr", "--buildtype=release"]}); command = "usr/bin/" + cmd
elif kind == "cmake":
    part.update({"plugin": "cmake", "cmake-parameters": ["-DCMAKE_INSTALL_PREFIX=/usr", "-DCMAKE_BUILD_TYPE=Release"]}); command = "usr/bin/" + cmd
elif kind == "make":
    part.update({"plugin": "make", "make-parameters": ["PREFIX=/usr"]}); command = "usr/bin/" + cmd
if build_pkgs: part["build-packages"] = build_pkgs.split()
if stage_pkgs: part["stage-packages"] = stage_pkgs.split()
app = {"command": command}
if ext: app["extensions"] = [ext]
plugs = (["network"] if net == "yes" else []) + ([] if ext else ["home"])
if plugs: app["plugs"] = plugs
L = []
L.append("name: " + name)
L.append("title: " + q(title))
L.append("version: " + q(version))
L.append("summary: " + q(summary))
L.append("description: |")
L += ["  " + l for l in (about or summary).splitlines()]
L.append("license: " + spdx)
L.append("website: " + homepage)
L.append("source-code: " + web)
if "github.com" in web or "gitlab.com" in web or "codeberg.org" in web:
    L.append("issues: " + web + "/issues")
if icon: L.append("icon: " + icon)
L += ["", "base: core24", "grade: stable", "confinement: strict", "", "apps:", "  %s:" % name]
L.append("    command: " + app["command"])
if "extensions" in app: L.append("    extensions: [%s]" % ", ".join(app["extensions"]))
if "plugs" in app: L.append("    plugs: [%s]" % ", ".join(app["plugs"]))
L += ["", "parts:", "  %s:" % name]
for k, v in part.items():
    if isinstance(v, list):   L.append("    %s: [%s]" % (k, ", ".join(v)))
    elif isinstance(v, bool): L.append("    %s: %s" % (k, "true" if v else "false"))
    else:                     L.append("    %s: %s" % (k, q(v) if k in ("source-tag", "npm-node-version") else v))
open(out, "w").write("\n".join(L) + "\n")
PY
  YAML="$WD/snap/snapcraft.yaml"
  ok "wrote snapcraft.yaml ($KIND, core24${EXT:+, the $EXT extension}, strict confinement)"
fi
echo; sed 's/^/     /' "$YAML"; echo

# ================================================================= 4. build
step "4/6  Build"
while :; do
  if run_logged "$WORK/pack.log" "snapcraft pack (a first build takes a while)" sc "$WD" pack; then
    fix_owner "$WD"
    SNAPFILE="$(cd "$WD" && ls -t ./*.snap 2>/dev/null | head -1 || true)"
    [ -n "$SNAPFILE" ] && { ok "built ${SNAPFILE#./} ($(du -h "$WD/$SNAPFILE" | cut -f1))"; break; }
    bad "snapcraft finished but no .snap file appeared"
  else
    fix_owner "$WD"
    bad "the build failed:"
  fi
  grep -vE '^\s*$' "$WORK/pack.log" | tail -n 15 | cut -c1-200 | sed 's/^/     /'
  grep -qiE "Could not find a required package|Unable to locate package" "$WORK/pack.log" \
    && note "a build-packages/stage-packages name isn't an Ubuntu 24.04 package — check them at https://packages.ubuntu.com"
  [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "the build failed (log: $WORK/pack.log)"; }
  say "e) edit snapcraft.yaml (in ${EDITOR:-vi}), then build again     l) read the whole log"
  say "r) build again as it is     q) quit"
  ask CHOICE "Choice" "e"
  case "$CHOICE" in
    e|E) "${EDITOR:-vi}" "$YAML" ;;
    l|L) "${PAGER:-less}" "$WORK/pack.log" || cat "$WORK/pack.log" ;;
    q|Q) note "snapcraft.yaml is in $WD"; exit 1 ;;
  esac
done
# snapcraft lints while it packs: pass on what it said
if grep -qiE '^Lint (warnings|OK)' "$WORK/pack.log"; then
  if grep -qi '^Lint warnings' "$WORK/pack.log"; then
    warn "snapcraft's linter says:"; sed -n '/^Lint warnings/,/^[A-Z][a-z]* /p' "$WORK/pack.log" | head -12 | sed 's/^/       /'
  else ok "snapcraft's linter: no warnings"; fi
fi
note "snapd can't run on every distro — try it on Ubuntu (or any snapd system): sudo snap install --dangerous $WD/${SNAPFILE#./}"

save_answers
if [ "$DRYRUN" = 1 ]; then
  warn "dry run — built, nothing registered or uploaded; it's in $WD"
  exit 0
fi

# ============================================================== 5. register
step "5/6  The name in the Snap Store"
if sc "$WORK" names > "$WORK/names.log" 2>&1 && awk 'NR > 1 { print $1 }' "$WORK/names.log" | grep -qxF "$SNAP_NAME"; then
  ok "'$SNAP_NAME' is registered to you"
else
  go "Register the name '$SNAP_NAME' in the Snap Store? (it's yours for good)" || die "a snap needs its name registered before it can be uploaded"
  if sc "$WORK" register --yes "$SNAP_NAME" > "$WORK/register.log" 2>&1; then
    ok "registered '$SNAP_NAME'"
  else
    tail -n 4 "$WORK/register.log" | sed 's/^/     /'
    if grep -qiE "already (registered|taken)|reserved|not available" "$WORK/register.log"; then
      note "pick another name — for an unofficial snap, Snapcraft suggests <name>-<your username>"
      [ "$SAVE" = 1 ] && cfg_set snap-name ""
      die "'$SNAP_NAME' isn't available — run again to choose another name"
    fi
    die "registering the name failed"
  fi
fi

# ================================================================ 6. upload
step "6/6  Upload"
CHANNEL="${CHANNEL_ARG:-$(cfg_get snap-channel)}"
[ -n "$CHANNEL" ] || { note "stable is what people get by default; candidate, beta and edge are for testers"; ask CHANNEL "Release to channel" "stable"; }
case "$CHANNEL" in stable|candidate|beta|edge|*/*) ;; *) die "channel must be stable, candidate, beta or edge" ;; esac
[ "$SAVE" = 1 ] && cfg_set snap-channel "$CHANNEL"
go "Upload ${SNAPFILE#./} and release it to $CHANNEL?" || { note "the snap is in $WD"; exit 0; }
run_logged "$WORK/upload.log" "uploading to the Snap Store (it scans the snap as it arrives)" sc "$WD" upload --release="$CHANNEL" "/project/${SNAPFILE#./}" \
  || { tail -n 8 "$WORK/upload.log" | sed 's/^/     /'; die "the upload failed — the snap is in $WD"; }
REV="$(grep -oE 'Revision [0-9]+' "$WORK/upload.log" | head -1 | grep -oE '[0-9]+' || true)"
ok "uploaded${REV:+ as revision $REV}"
if grep -qiE "manual review|pending|held for review" "$WORK/upload.log"; then
  warn "the store holds it for review before it goes public — you'll get an email; nothing else to do"
elif grep -qiE "released" "$WORK/upload.log"; then
  ok "released to $CHANNEL"
fi
sc "$WORK" status "$SNAP_NAME" > "$WORK/status.log" 2>&1 && { sed 's/^/     /' "$WORK/status.log" | head -12; }

printf '\n   %sDone.%s %s %s → %s\n   %s/%s\n\n' "$B" "$R" "$SNAP_NAME" "$VERSION" "$CHANNEL" "$SNAP_WEB" "$SNAP_NAME"
say "  • People install it with: sudo snap install $SNAP_NAME"
say "  • New snaps and revisions are reviewed by the store first — watch your email."
say "  • Its page (description, screenshots, categories): $SNAP_WEB/$SNAP_NAME/listing"
say "  • Next release: run linux-submit.sh snap (or linux-submit.sh) again."
echo
}

# ##########################################################################
#   debian/ packaging — what the Launchpad PPA and Debian wizards share.
#   Needs linux_common and linux_app's globals ($KIND, $TAG_REF, $WORK…).
# ##########################################################################
# pc_deb <pkg-config module> — the -dev package that ships it ("" if not
# known); Debian's names, which Ubuntu shares
pc_deb() {
  case "$1" in
    gtk4) echo libgtk-4-dev ;; gtk+-3.0) echo libgtk-3-dev ;; libadwaita-1) echo libadwaita-1-dev ;;
    glib-2.0|gio-2.0|gobject-2.0|gio-unix-2.0) echo libglib2.0-dev ;; json-glib-1.0) echo libjson-glib-dev ;;
    libsoup-3.0) echo libsoup-3.0-dev ;; sqlite3) echo libsqlite3-dev ;; openssl|libssl|libcrypto) echo libssl-dev ;;
    libcurl) echo libcurl4-openssl-dev ;; zlib) echo zlib1g-dev ;; x11) echo libx11-dev ;;
    wayland-client|wayland-cursor) echo libwayland-dev ;; xkbcommon) echo libxkbcommon-dev ;; dbus-1) echo libdbus-1-dev ;;
    libpulse|libpulse-simple) echo libpulse-dev ;; alsa) echo libasound2-dev ;; libxml-2.0) echo libxml2-dev ;;
    cairo) echo libcairo2-dev ;; pango|pangocairo) echo libpango1.0-dev ;; gdk-pixbuf-2.0) echo libgdk-pixbuf-2.0-dev ;;
    fontconfig) echo libfontconfig-dev ;; freetype2) echo libfreetype-dev ;; libpng) echo libpng-dev ;;
    libsecret-1) echo libsecret-1-dev ;; libnotify) echo libnotify-dev ;; gstreamer-1.0) echo libgstreamer1.0-dev ;;
    libsystemd) echo libsystemd-dev ;; libudev) echo libudev-dev ;; epoxy) echo libepoxy-dev ;; libarchive) echo libarchive-dev ;;
    libzstd) echo libzstd-dev ;; liblzma) echo liblzma-dev ;; sdl2) echo libsdl2-dev ;; vulkan) echo libvulkan-dev ;;
    *) echo "" ;;
  esac
}

# deb_recipe <ppa|debian> — how $KIND builds with debhelper: sets BDEPS
# (Build-Depends), ARCH, XDEPS (more Depends), RULES_DH (dh's line in
# debian/rules) and RULES_EXTRA (the rest of it). A PPA builds Rust and Go
# with their dependencies vendored into the source. Debian takes every one
# from its own packages (dh-cargo, dh-golang; the Debian wizard works out
# $RUST_BDEPS, $GO_BDEPS and $PY_BDEPS first) and builds with debhelper 14,
# which Ubuntu's LTS releases don't have yet.
deb_recipe() {
  local flavour="$1" where=Ubuntu pc d b
  BDEPS="debhelper-compat (= 13)"; ARCH=any; XDEPS=""; RULES_EXTRA=""; RULES_DH=""
  if [ "$flavour" = debian ]; then
    where=Debian
    # compat 14 asks single-binary packages to say so (debhelper-compat-upgrade-checklist(7))
    BDEPS="debhelper-compat (= 14), dh-sequence-single-binary"
  fi
  case "$KIND" in
    meson|cmake)
      if [ "$KIND" = meson ]; then BDEPS="$BDEPS, meson, ninja-build, pkgconf"
        PCS="$(for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done | grep -oE "dependency\([[:space:]]*'[^']+'" | sed -E "s/.*'([^']+)'/\\1/" | sort -u)"
      else BDEPS="$BDEPS, cmake"
        PCS="$(at "$TAG_REF" CMakeLists.txt | tr '\n' ' ' | grep -oE 'pkg_check_modules\([^)]*\)' | sed -E 's/^pkg_check_modules\(//; s/\)$//' \
               | awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^(REQUIRED|QUIET|IMPORTED_TARGET|GLOBAL)$/) { m = $i; sub(/[<>=].*/, "", m); if (m != "") print m } }' | sort -u)"
        [ -n "$PCS" ] && BDEPS="$BDEPS, pkgconf"
        # Debian builds with its own optimisation flags (dh passes CMAKE_BUILD_TYPE=None)
        if [ "$flavour" = ppa ]; then
          RULES_EXTRA='
override_dh_auto_configure:
	dh_auto_configure -- -DCMAKE_BUILD_TYPE=Release'
        fi
      fi
      for pc in $PCS; do
        case "$pc" in threads|m|dl|rt|dependency) continue ;; esac
        d="$(pc_deb "$pc")"
        if [ -n "$d" ]; then BDEPS="$BDEPS, $d"; else warn "no $where package known for '$pc' — the test build will tell if it's needed"; fi
      done
      case " $PCS " in *gtk4*|*libadwaita*) BDEPS="$BDEPS, desktop-file-utils, appstream, libglib2.0-bin" ;; esac ;;
    make)
      RULES_EXTRA='
override_dh_auto_install:
	dh_auto_install -- PREFIX=/usr' ;;
    python)
      ARCH=all; BDEPS="$BDEPS, dh-sequence-python3, pybuild-plugin-pyproject, python3-all"
      if [ "$flavour" = debian ]; then
        # the build backend, and what the tests import — under Debian's names
        [ -n "${PY_BDEPS:-}" ] && BDEPS="$BDEPS, $PY_BDEPS"
      else
        at "$TAG_REF" pyproject.toml > "$WORK/pyproject.toml"
        for b in $(python3 -c 'import re,sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); [print(re.match(r"[A-Za-z0-9._-]+", r).group(0).lower().replace("_","-")) for r in d.get("build-system",{}).get("requires",[])]' "$WORK/pyproject.toml" 2>/dev/null); do
          BDEPS="$BDEPS, python3-$b"
        done
        RULES_EXTRA="export PYBUILD_NAME=$PNAME"
      fi
      XDEPS=', ${python3:Depends}'
      RULES_DH='dh $@ --buildsystem=pybuild' ;;
    rust)
      if [ "$flavour" = debian ]; then
        # dh-cargo builds against Debian's own crates (librust-*-dev), offline
        BDEPS="$BDEPS, dh-sequence-cargo, ${RUST_BDEPS:-cargo:native, rustc:native, libstd-rust-dev}"
        RULES_DH='dh $@ --buildsystem cargo'
      else
        BDEPS="$BDEPS, cargo, rustc"
        at "$TAG_REF" Cargo.lock | grep -q '^name = "openssl-sys"' && BDEPS="$BDEPS, libssl-dev, pkgconf"
        RULES_EXTRA="export CARGO_HOME = \$(CURDIR)/debian/cargo-home

override_dh_auto_build:
	cargo build --release --offline --frozen

override_dh_auto_test:
ifeq (,\$(filter nocheck,\$(DEB_BUILD_OPTIONS)))
	cargo test --release --offline --frozen
endif

override_dh_auto_install:
	find target/release -maxdepth 1 -type f -executable -exec install -Dm755 -t debian/$PNAME/usr/bin {} +

override_dh_auto_clean:
	rm -rf target debian/cargo-home"
      fi ;;
    go)
      if [ "$flavour" = debian ]; then
        # dh-golang builds against Debian's own Go packages (golang-*-dev), offline
        BDEPS="$BDEPS, dh-sequence-golang, golang-any${GO_BDEPS:+, $GO_BDEPS}"
        RULES_DH='dh $@ --builddirectory=_build'
        RULES_EXTRA='
override_dh_auto_install:
	dh_auto_install -- --no-source'
      else
        BDEPS="$BDEPS, golang-go"
        GOTARGET=.; grep -qE '^cmd/[^/]+/main\.go$' "$WORK/tree.txt" && GOTARGET='./cmd/...'
        RULES_EXTRA="export GOCACHE = \$(CURDIR)/debian/gocache
export GOFLAGS = -mod=vendor -trimpath -buildvcs=false
export GOTOOLCHAIN = local

override_dh_auto_build:
	mkdir -p build && go build -o build/ $GOTARGET

override_dh_auto_test:

override_dh_auto_install:
	install -Dm755 -t debian/$PNAME/usr/bin build/*

override_dh_auto_clean:
	rm -rf build debian/gocache"
      fi ;;
    *) if [ "$flavour" = ppa ]; then die "the PPA wizard packages Meson, CMake, Make, Python, Rust and Go apps"
       else die "the Debian wizard packages Meson, CMake, Make, Python, Rust and Go apps"; fi ;;
  esac
  return 0
}

# deb_control <dir> <name> <section> <Standards-Version> <synopsis> <long
# description> [<more source fields>] [<more binary fields>] — <dir>/debian/control
# for one binary package, from deb_recipe's answers
deb_control() {
  local dir="$1" name="$2" section="$3" std="$4" synopsis="$5" about="$6" sfields="${7-}" bfields="${8-}"
  # Debian's rules for the synopsis match nixpkgs': one short line, no article, no period
  {
    printf 'Source: %s\nSection: %s\nPriority: optional\n' "$name" "$section"
    printf 'Maintainer: %s <%s>\n' "$MAINT_NAME" "${MAINT_EMAIL:-$(git -C "$REPO" config user.email)}"
    printf 'Build-Depends: %s\nStandards-Version: %s\n' "$BDEPS" "$std"
    printf 'Homepage: %s\n' "$HOMEPAGE"
    [ -n "$sfields" ] && printf '%s\n' "$sfields"
    printf 'Rules-Requires-Root: no\n\n'
    printf 'Package: %s\nArchitecture: %s\n' "$name" "$ARCH"
    printf 'Depends: ${shlibs:Depends}, ${misc:Depends}%s\n' "$XDEPS"
    [ -n "$bfields" ] && printf '%s\n' "$bfields"
    printf 'Description: %s\n' "$synopsis"
    printf '%s\n' "$about" | fold -s -w 78 | sed -e 's/[[:space:]]*$//' -e 's/^$/./' -e 's/^/ /'
  } > "$dir/debian/control"
}

# deb_rules <dir> — <dir>/debian/rules, from deb_recipe's answers
deb_rules() {
  {
    printf '#!/usr/bin/make -f\n\n'
    printf '%%:\n\t%s\n' "${RULES_DH:-dh \$@}"
    [ -n "$RULES_EXTRA" ] && printf '%s\n' "$RULES_EXTRA"
  } > "$1/debian/rules"
  chmod 755 "$1/debian/rules"
}

# ##########################################################################
#   Launchpad PPA — questions shared with a Linux run, and helpers
# ##########################################################################
LP_API="${LP_API_ROOT:-https://api.launchpad.net/devel}"
LP_WEB="https://launchpad.net"
lp_get() { curl -sf --max-time 25 "$LP_API/$1"; }   # lp_get <path> — anonymous API read
# lp_versions — the versions of $PNAME published in the PPA, one per line
lp_versions() {
  lp_get "~$LP_USER/+archive/ubuntu/$PPA_NAME?ws.op=getPublishedSources&source_name=$PNAME&exact_match=true" 2>/dev/null \
    | python3 -c 'import json,sys; [print(e["source_package_version"]) for e in json.load(sys.stdin).get("entries", [])]' 2>/dev/null || true
}

# ppa_questions — the Launchpad account, the PPA and the Ubuntu releases
ppa_questions() {
  local first=1 guess
  case "$KIND" in
    flutter) die "Launchpad builds without internet, and Ubuntu has no Flutter SDK — a Flutter app can't be built in a PPA. Ubuntu users get it from the Snap Store (Ubuntu's App Center) or Flathub" ;;
    node)    die "Launchpad builds without internet, so npm can't fetch packages there — this wizard can't package an npm app for a PPA; the Snap Store and Flathub can" ;;
  esac
  guess="$(cfg_get launchpad-user)"
  while :; do
    if [ "$first" = 1 ] && [ -n "$guess" ] && [ "$ASK_ALL" = 0 ]; then LP_USER="$guess"
    else
      [ "$first" = 1 ] && note "your Launchpad username — the part after ~ in https://launchpad.net/~you (no account yet? $LP_WEB/+login)"
      ask LP_USER "Launchpad username" "$guess"
    fi
    first=0
    LP_USER="${LP_USER#\~}"
    lp_get "~$LP_USER" > "$WORK/lp-user.json" 2>/dev/null && break
    warn "there's no Launchpad account '$LP_USER' ($LP_WEB/~$LP_USER)"
    [ "$ASSUME_YES" = 1 ] && die "check the Launchpad username in the config"
    guess=""
  done
  ok "Launchpad: $LP_WEB/~$LP_USER"
  [ "${SAVE:-1}" = 1 ] && cfg_set launchpad-user "$LP_USER"

  PPA_NAME="$(cfg_get ppa-name)"
  if [ -z "$PPA_NAME" ] || [ "$ASK_ALL" = 1 ]; then
    note "the PPA people add: ppa:$LP_USER/<name> — one per app is usual"
    while :; do
      ask PPA_NAME "PPA name" "${PPA_NAME:-$(printf '%s' "$PNAME" | tr 'A-Z_' 'a-z-')}"
      printf '%s' "$PPA_NAME" | grep -qE '^[a-z0-9][a-z0-9+.-]*$' && break
      warn "lowercase letters, digits, and + . - only"
    done
    [ "${SAVE:-1}" = 1 ] && cfg_set ppa-name "$PPA_NAME"
  fi
  ok "PPA: ppa:$LP_USER/$PPA_NAME"

  # the Ubuntu releases to build for: the supported ones, read from Launchpad
  lp_get "ubuntu/series" > "$WORK/series.json" || die "couldn't ask Launchpad for Ubuntu's releases"
  python3 - "$WORK/series.json" > "$WORK/series.txt" <<'PY'
import json, sys
for e in json.load(open(sys.argv[1]))["entries"]:
    if e.get("active") and e["status"] in ("Supported", "Current Stable Release"):
        print("%s|%s|%s" % (e["name"], e["version"], e["status"]))
PY
  [ -s "$WORK/series.txt" ] || die "Launchpad lists no supported Ubuntu releases right now"
  PPA_SERIES="$(cfg_get ppa-series)"
  # drop releases that aren't supported any more
  local keep="" s
  for s in $PPA_SERIES; do grep -q "^$s|" "$WORK/series.txt" && keep="$keep${keep:+ }$s"; done
  if [ -z "$keep" ] || [ "$ASK_ALL" = 1 ]; then
    local items="" pre=""
    while IFS='|' read -r n v st; do
      items="$items$n|Ubuntu $v ($n)|1|$st"$'\n'
      case "$v" in *.04) [ $(( ${v%%.*} % 2 )) = 0 ] && pre="$pre $n" ;; esac   # LTS releases preselected
    done < "$WORK/series.txt"
    if [ "$ASSUME_YES" = 1 ]; then keep="$(printf '%s' "$pre" | xargs)"
    else say "Which Ubuntu releases? (Linux Mint, Pop!_OS, Zorin… follow the matching LTS)"; multi_select keep "$items" "$pre"; fi
  fi
  PPA_SERIES="$keep"
  [ "${SAVE:-1}" = 1 ] && cfg_set ppa-series "$PPA_SERIES"
  ok "Ubuntu releases: $PPA_SERIES"
}

# ##########################################################################
#   Launchpad PPA wizard — linux-submit.sh ppa [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_ppa() {
#
# linux-submit.sh ppa — publish an app to Ubuntu (and Mint, Pop!_OS, Zorin…)
# through a Launchpad PPA, or a new version of it.
#
# Follows Launchpad's documentation:
#   https://ubuntu.com/docs/launchpad/user/how-to/packaging/ppa-package-upload/
#   https://ubuntu.com/docs/launchpad/user/reference/packaging/ppas/building-a-source-package/
#
# Writes the debian/ packaging (or uses yours), makes a source package per
# Ubuntu release, test-builds it offline in an Ubuntu container like
# Launchpad's builders (with lintian), signs it with your GPG key and uploads
# it. Launchpad then builds and publishes it.

set -eu

DRYRUN=0
SAVE=1
ASSUME_YES=0
ASK_ALL=0
NO_TEST=0
REPO_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ppa-submit"
CONF="$CONF_DIR/last.conf"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/store-submit"
LP_FTP="${LP_FTP_ROOT:-ftp://ppa.launchpad.net}"

usage() {
  cat <<'USAGE'
linux-submit.sh ppa — publish an app to Ubuntu through a Launchpad PPA.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --config FILE   the shared answers (default: .store-submit.conf in the repo)
      --no-test       skip the offline test build in Ubuntu containers
  -n, --dry-run       make and test the packages; don't sign or upload
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
    --no-test)    NO_TEST=1 ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF"; printf 'forgot %s\n' "$CONF"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WIZ_NAME=ppa-submit
linux_common

SAVED_REPO=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  { printf '# written by linux-submit.sh ppa — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n' "${REPO:-${SAVED_REPO:-}}"; } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}

RUNTIME=""
for r in podman docker; do have "$r" && "$r" info >/dev/null 2>&1 && { RUNTIME="$r"; break; }; done
# gpg: yours, or GnuPG from nixpkgs when it isn't installed
gpgx() { tool gnupg gpg "$@"; }
TTYARGS=(); [ -t 0 ] && TTYARGS=(--pinentry-mode loopback)

# =============================================================== 0. orientation
cat <<BANNER

  ${B}Launchpad PPA wizard${R}  (Ubuntu, Linux Mint, Pop!_OS, Zorin, elementary…)

  Five stages:
    1. your app       — shared with the other distros, plus Launchpad and releases
    2. signing        — your GPG key, known to Launchpad; your PPA
    3. debian/        — the packaging, written for your build system (or yours)
    4. build + check  — source packages, then an offline test build like
                        Launchpad's, in Ubuntu containers, with lintian
    5. upload         — signed, sent to your PPA; Launchpad builds and publishes

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: packages are made and tested; nothing is signed or uploaded"
for t in git curl python3; do have "$t" || die "$t is missing — install it and re-run"; done
[ -n "$RUNTIME" ] || die "the packages are made in Ubuntu containers: install podman or docker (NixOS: virtualisation.podman.enable = true;)"

# ============================================================== 1. the app
linux_app "1/5  Your app"
ppa_questions

# ================================================================ 2. signing
step "2/5  Signing and your PPA"
# Launchpad only takes uploads signed with a key registered to your account.
LP_FPRS="$(lp_get "~$LP_USER/gpg_keys" | python3 -c 'import json,sys; [print(e["fingerprint"]) for e in json.load(sys.stdin)["entries"]]' 2>/dev/null || true)"
local_fprs() { gpgx --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }'; }
KEY="$(cfg_get gpg-key)"
pick_key() {  # KEY = the first local key Launchpad knows ("" if none)
  KEY=""
  for f in $(local_fprs); do printf '%s\n' "$LP_FPRS" | grep -qx "$f" && { KEY="$f"; break; }; done
  return 0
}
[ -n "$KEY" ] && printf '%s\n' "$LP_FPRS" | grep -qx "$KEY" && local_fprs | grep -qx "$KEY" || pick_key
while [ -z "$KEY" ]; do
  [ "$DRYRUN" = 1 ] && { note "dry run: no signing key needed yet"; break; }
  warn "none of your GPG keys is registered on Launchpad yet"
  [ "$ASSUME_YES" = 1 ] && die "set up your signing key once without --yes"
  CAND="$(gpgx --list-secret-keys --with-colons 2>/dev/null | awk -F: -v e="${MAINT_EMAIL:-@}" '$1 == "fpr" { f = $10 } $1 == "uid" && index($10, e) { print f; exit }')"
  [ -n "$CAND" ] || CAND="$(local_fprs | head -1)"
  if [ -z "$CAND" ]; then
    say "You have no GPG key. The wizard can make one for $MAINT_NAME <${MAINT_EMAIL:-?}>."
    [ -n "${MAINT_EMAIL:-}" ] || die "a signing key needs an email — set maintainer-email in the config (it must be an address of your Launchpad account)"
    confirm "Create it now? (gpg asks for a passphrase)" y || die "Launchpad needs a signed upload"
    gpgx "${TTYARGS[@]+"${TTYARGS[@]}"}" --quick-generate-key "$MAINT_NAME <$MAINT_EMAIL>" ed25519 sign 3y || die "gpg couldn't create the key"
    CAND="$(local_fprs | tail -1)"
  fi
  ok "key: $CAND"
  if confirm "Publish it to keyserver.ubuntu.com, where Launchpad looks it up?" y; then
    gpgx --keyserver hkps://keyserver.ubuntu.com --send-keys "$CAND" >/dev/null 2>&1 && ok "sent to keyserver.ubuntu.com" || warn "couldn't send it — Launchpad also accepts it pasted on the page below"
  fi
  say "Register it on Launchpad (once):"
  note "1. open $LP_WEB/~$LP_USER/+editpgpkeys and import the fingerprint $CAND"
  note "2. Launchpad emails you an encrypted message — decrypt it (your mail app, or: gpg -d)"
  note "3. open the link inside it. The key's email must be a confirmed address of your account"
  confirm "Done? Check again" y || die "Launchpad needs your key registered to accept uploads"
  LP_FPRS="$(lp_get "~$LP_USER/gpg_keys" | python3 -c 'import json,sys; [print(e["fingerprint"]) for e in json.load(sys.stdin)["entries"]]' 2>/dev/null || true)"
  pick_key
done
if [ -n "$KEY" ]; then
  ok "signing key $KEY is registered on Launchpad"
  [ "$SAVE" = 1 ] && cfg_set gpg-key "$KEY"
  KEYMAIL="$(gpgx --list-keys --with-colons "$KEY" 2>/dev/null | awk -F: '$1 == "uid" { print $10 }' | grep -oE '<[^>]+>' | tr -d '<>' | head -1)"
  [ -n "${MAINT_EMAIL:-}" ] && [ -n "$KEYMAIL" ] && [ "$KEYMAIL" != "$MAINT_EMAIL" ] && \
    warn "the key is for $KEYMAIL, the packages say $MAINT_EMAIL — Launchpad matches them to your account, both should be yours"
fi
# the PPA itself: made once on the web (its terms are yours to accept)
while ! lp_get "~$LP_USER/+archive/ubuntu/$PPA_NAME" >/dev/null 2>&1; do
  [ "$DRYRUN" = 1 ] && { note "dry run: the PPA ppa:$LP_USER/$PPA_NAME doesn't exist yet"; break; }
  warn "the PPA ppa:$LP_USER/$PPA_NAME doesn't exist yet"
  note "create it at $LP_WEB/~$LP_USER/+activate-ppa — URL name: $PPA_NAME; accept the PPA terms of use"
  [ "$ASSUME_YES" = 1 ] && die "create the PPA once, then re-run"
  confirm "Done? Check again" y || die "uploads need the PPA"
done
lp_get "~$LP_USER/+archive/ubuntu/$PPA_NAME" >/dev/null 2>&1 && ok "PPA: $LP_WEB/~$LP_USER/+archive/ubuntu/$PPA_NAME"

# ================================================================ 3. debian/
step "3/5  debian/ packaging"
WD="$CACHE/ppa/$PNAME"
rm -rf "$WD"; mkdir -p "$WD/out"
SRC="$WD/$PNAME-$VERSION"
mkdir -p "$SRC"
git -C "$REPO" archive "$TAG_REF" | tar x -C "$SRC"
if [ -d "$SRC/debian" ]; then
  ok "your debian/ (from $TAG)"
  OWN_DEBIAN=1
else
  OWN_DEBIAN=0
  deb_recipe ppa
  mkdir -p "$SRC/debian/source"
  echo "3.0 (quilt)" > "$SRC/debian/source/format"
  ABOUT="$(cfg_get about)"; [ -n "$ABOUT" ] || ABOUT="$DESC."
  deb_control "$SRC" "$PNAME" misc 4.7.0 "$DESC" "$ABOUT" "Vcs-Browser: $WEB"
  deb_rules "$SRC"
  {
    printf 'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n'
    printf 'Upstream-Name: %s\nSource: %s\n\n' "$PNAME" "$WEB"
    printf 'Files: *\nCopyright: %s %s\nLicense: %s\n' "$(date +%Y)" "$MAINT_NAME" "$SPDX"
    printf ' The full license text is in the LICENSE file of the source.\n'
  } > "$SRC/debian/copyright"
  ok "wrote debian/ (control, rules, copyright, source/format) for $KIND"
fi
echo; sed 's/^/     /' "$SRC/debian/control"; echo

# versions: <upstream>-1ppa<n>~ubuntu<release>.1, one per Ubuntu release — n
# goes up when this upstream version is in the PPA already
PPA_N=1
PUB="$(lp_versions)"
while printf '%s\n' "$PUB" | grep -q "^$VERSION-1ppa$PPA_N~"; do PPA_N=$((PPA_N + 1)); done
[ "$PPA_N" -gt 1 ] && note "$VERSION is in the PPA already: this is ppa$PPA_N"
series_version() { grep "^$1|" "$WORK/series.txt" | cut -d'|' -f2; }

# ========================================================= 4. build + check
step "4/5  Build and check"
IMG_TOOLS="ubuntu:$(series_version "$(printf '%s' "$PPA_SERIES" | awk '{ print $NF }')")"
# one container: vendor the Rust/Go dependencies (Launchpad builds offline),
# the orig tarball, and a source package per Ubuntu release
CHLOG=""
for s in $PPA_SERIES; do
  v="$VERSION-1ppa$PPA_N~ubuntu$(series_version "$s").1"
  CHLOG="$CHLOG$s $v"$'\n'
done
DATE="$(date -R)"
MAINT="$MAINT_NAME <${MAINT_EMAIL:-$(git -C "$REPO" config user.email)}>"
src_packages() {
  "$RUNTIME" run --rm -v "$WD:/work" -e PNAME="$PNAME" -e VERSION="$VERSION" -e KIND="$KIND" -e OWN="$OWN_DEBIAN" \
    -e CHLOG="$CHLOG" -e DATE="$DATE" -e MAINT="$MAINT" -e OWNER="$(id -u):$(id -g)" "$IMG_TOOLS" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    extra=""; [ "$KIND" = rust ] && extra="cargo"; [ "$KIND" = go ] && extra="golang-go"
    apt-get install -y -qq --no-install-recommends dpkg-dev devscripts debhelper fakeroot xz-utils ca-certificates git $extra >/dev/null
    cd /work/$PNAME-$VERSION
    if [ "$KIND" = rust ] && [ ! -d vendor ]; then
      echo "==> cargo vendor"; mkdir -p .cargo; cargo vendor --locked vendor > .cargo/config.toml
    fi
    if [ "$KIND" = go ] && [ ! -d vendor ]; then echo "==> go mod vendor"; GOTOOLCHAIN=local go mod vendor || GOTOOLCHAIN=auto go mod vendor; fi
    cd /work
    tar --exclude="$PNAME-$VERSION/debian" -cJf "${PNAME}_${VERSION}.orig.tar.xz" "$PNAME-$VERSION"
    first=1
    printf "%s" "$CHLOG" | while read -r series version; do
      [ -n "$series" ] || continue
      note="  * Release $VERSION."
      printf "%s (%s) %s; urgency=medium\n\n%s\n\n -- %s  %s\n\n" "$PNAME" "$version" "$series" "$note" "$MAINT" "$DATE" > "$PNAME-$VERSION/debian/changelog"
      opt=-sd; [ "$first" = 1 ] && opt=-sa
      echo "==> source package $version ($series)"
      (cd "$PNAME-$VERSION" && dpkg-buildpackage -S $opt -us -uc -d) || { echo "STORE-SUBMIT: source package failed for $series"; exit 3; }
      first=0
    done
    mv /work/*.dsc /work/*.debian.tar.* /work/*_source.changes /work/*.orig.tar.xz /work/out/ 2>/dev/null || true
    rm -f /work/*_source.buildinfo
    chown -R "$OWNER" /work
    echo "STORE-SUBMIT: OK"'
}
run_logged "$WORK/src.log" "source packages for: $PPA_SERIES${KIND:+ (vendoring $KIND dependencies)}" src_packages \
  && grep -q "STORE-SUBMIT: OK" "$WORK/src.log" \
  || { grep -vE '^\s*$' "$WORK/src.log" | tail -n 15 | sed 's/^/     /'; KEEP_WORK=1; die "couldn't make the source packages (log: $WORK/src.log)"; }
ls "$WD/out"/*.dsc >/dev/null 2>&1 || die "no .dsc came out — log: $WORK/src.log"
ok "source packages: $(cd "$WD/out" && ls ./*.dsc | sed 's#^\./##' | tr '\n' ' ')"

# the offline test build, per Ubuntu release: build dependencies installed
# with the network on, then the network cut, then the build — like Launchpad
test_build() {  # test_build <series>
  local s="$1" v img
  v="$(printf '%s' "$CHLOG" | awk -v s="$s" '$1 == s { print $2 }')"
  img="ubuntu:$(series_version "$s")"
  "$RUNTIME" run --rm --cap-add NET_ADMIN -v "$WD/out:/src:ro" -e DSC="${PNAME}_${v#*:}.dsc" -e PNAME="$PNAME" "$img" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends dpkg-dev devscripts equivs lintian iproute2 fakeroot >/dev/null
    mkdir /b && cd /b && dpkg-source -x "/src/$DSC" pkg >/dev/null
    cd pkg && mk-build-deps -ir -t "apt-get -y -qq --no-install-recommends" debian/control >/dev/null 2>&1 \
      || { echo "STORE-SUBMIT: build dependencies not installable"; apt-get build-dep -s . 2>&1 | tail -5; exit 4; }
    for i in $(ls /sys/class/net | grep -v "^lo$"); do ip link set "$i" down; done
    echo "==> building offline"
    dpkg-buildpackage -b -us -uc || { echo "STORE-SUBMIT: build failed"; exit 5; }
    echo "==> lintian"
    lintian --no-tag-display-limit ../*.deb 2>&1 | sed "s/^/LINTIAN: /" || true
    ls ../*.deb | sed "s/^/DEB: /"
    echo "STORE-SUBMIT: OK"'
}
TESTED=""
if [ "$NO_TEST" = 1 ]; then
  warn "--no-test: not test-built"
else
  for s in $PPA_SERIES; do
    while :; do
      if run_logged "$WORK/test-$s.log" "offline test build for Ubuntu $(series_version "$s") ($s)" test_build "$s" \
         && grep -q "STORE-SUBMIT: OK" "$WORK/test-$s.log"; then
        ok "builds offline on Ubuntu $(series_version "$s"): $(grep '^DEB: ' "$WORK/test-$s.log" | sed 's#^DEB: \.\./##' | tr '\n' ' ')"
        if grep -q '^LINTIAN: [EW]:' "$WORK/test-$s.log"; then
          warn "lintian (Debian's package checker) says:"
          grep '^LINTIAN: [EW]:' "$WORK/test-$s.log" | sed 's/^LINTIAN: /       /' | head -10
        else ok "lintian: no errors or warnings"; fi
        TESTED="$TESTED $s"; break
      fi
      L="$WORK/test-$s.log"
      if grep -q "build dependencies not installable" "$L"; then
        bad "a build dependency isn't available on Ubuntu $(series_version "$s"):"; grep -E "Unable to locate|has no installation candidate|but it is not" "$L" | head -3 | sed 's/^/       /'
      elif grep -qiE "requires rustc|rustc [0-9.]+ is not supported|package .* cannot be built because it requires rustc" "$L"; then
        bad "the code needs a newer Rust than Ubuntu $(series_version "$s") has"
        note "use Ubuntu's versioned toolchain: Build-Depends cargo-1.XX, rustc-1.XX, and PATH=/usr/lib/rust-1.XX/bin in debian/rules — or leave $s out"
      elif grep -qiE "go.mod requires go >=|requires go[0-9.]+ or later" "$L"; then
        bad "the code needs a newer Go than Ubuntu $(series_version "$s") has"
        note "use golang-1.XX-go and PATH=/usr/lib/go-1.XX/bin in debian/rules — or leave $s out"
      elif grep -qiE "Could not resolve|Temporary failure in name resolution|failed to download" "$L"; then
        bad "the build tried to download something — Launchpad builds have no network; it must be vendored or packaged"
      else
        bad "the test build failed on Ubuntu $(series_version "$s"):"
      fi
      grep -vE '^\s*$' "$L" | grep -v '^LINTIAN' | tail -n 12 | cut -c1-200 | sed 's/^/     /'
      [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "the test build failed (log: $L)"; }
      say "l) read the whole log     r) build again     s) skip $s     q) quit"
      ask CHOICE "Choice" "l"
      case "$CHOICE" in
        l|L) "${PAGER:-less}" "$L" || cat "$L" ;;
        s|S) warn "not test-built for $s"; break ;;
        q|Q) note "the packaging is in $WD"; exit 1 ;;
      esac
    done
  done
fi

save_answers
if [ "$DRYRUN" = 1 ]; then
  warn "dry run — made and tested; nothing signed or uploaded. It's all in $WD"
  exit 0
fi

# ================================================================ 5. upload
step "5/5  Sign and upload"
# sign like debsign: clearsign the .dsc, put its new checksums in the
# .changes, clearsign the .changes
sign_changes() {  # sign_changes <file_source.changes>
  local ch="$1" dsc
  dsc="$(dirname "$ch")/$(awk '/^Files:/ { f = 1; next } f && /\.dsc$/ { print $NF; exit }' "$ch")"
  gpgx "${TTYARGS[@]+"${TTYARGS[@]}"}" --batch --yes --local-user "$KEY" --clearsign -o "$dsc.asc" "$dsc" && mv "$dsc.asc" "$dsc"
  python3 - "$ch" "$dsc" <<'PY'
import hashlib, os, sys
ch, dsc = sys.argv[1], sys.argv[2]
data = open(dsc, "rb").read(); name = os.path.basename(dsc); size = str(len(data))
sums = {"Checksums-Sha1:": hashlib.sha1(data).hexdigest(), "Checksums-Sha256:": hashlib.sha256(data).hexdigest(), "Files:": hashlib.md5(data).hexdigest()}
out, sec = [], None
for line in open(ch).read().splitlines():
    if line and not line.startswith(" "):
        sec = line.split()[0] if line.split() else None
    elif sec in sums and line.split()[-1] == name:
        f = line.split()
        f[0], f[1] = sums[sec], size
        line = " " + " ".join(f)
    out.append(line)
open(ch, "w").write("\n".join(out) + "\n")
PY
  gpgx "${TTYARGS[@]+"${TTYARGS[@]}"}" --batch --yes --local-user "$KEY" --clearsign -o "$ch.asc" "$ch" && mv "$ch.asc" "$ch"
}
note "gpg may ask for your key's passphrase"
for ch in "$WD/out"/*_source.changes; do
  sign_changes "$ch" || die "signing $(basename "$ch") failed"
  gpgx --verify "$ch" >/dev/null 2>&1 || die "the signature on $(basename "$ch") doesn't verify"
done
ok "signed with $KEY"

go "Upload to ppa:$LP_USER/$PPA_NAME for $PPA_SERIES?" || { note "signed packages are in $WD/out"; exit 0; }
DEST="$LP_FTP/~$LP_USER/ubuntu/$PPA_NAME/"
# in build order: the first release's upload carries the orig tarball (-sa),
# the others refer to it (-sd) — so it has to arrive first
UPLOADS="$(printf '%s' "$CHLOG" | while read -r s v; do [ -n "$v" ] && printf '%s\n' "$WD/out/${PNAME}_${v}_source.changes"; done)"
for ch in $UPLOADS; do
  FILES="$(awk '/^Files:/ { f = 1; next } /^[^ ]/ { f = 0 } f && NF { print $NF }' "$ch")"
  for f in $FILES "$(basename "$ch")"; do
    run_logged "$WORK/ftp.log" "uploading $f" curl -sS --retry 3 -T "$WD/out/$f" "$DEST" \
      || { tail -n 3 "$WORK/ftp.log" | sed 's/^/     /'; die "uploading $f failed"; }
  done
  ok "uploaded $(basename "$ch")"
done

# Launchpad answers by email, and on the PPA page within a few minutes
say "Launchpad checks the upload (it emails you if it's rejected)…"
for _ in $(seq 1 24); do
  PUB="$(lp_versions)"
  SEEN=0
  while read -r s v; do [ -n "$s" ] && printf '%s\n' "$PUB" | grep -qxF "$v" && SEEN=$((SEEN + 1)); done <<EOF
$CHLOG
EOF
  [ "$SEEN" -ge "$(printf '%s' "$CHLOG" | grep -c .)" ] && break
  sleep 5
done
if [ "$SEEN" -ge "$(printf '%s' "$CHLOG" | grep -c .)" ]; then ok "accepted: Launchpad is building it now"
else warn "not listed yet — if the email says rejected, the usual causes: the key isn't registered, or the changelog email isn't one of your Launchpad addresses"; fi

printf '\n   %sDone.%s %s %s → ppa:%s/%s\n   %s/~%s/+archive/ubuntu/%s/+packages\n\n' "$B" "$R" "$PNAME" "$VERSION" "$LP_USER" "$PPA_NAME" "$LP_WEB" "$LP_USER" "$PPA_NAME"
say "  • People install it with:"
say "      sudo add-apt-repository ppa:$LP_USER/$PPA_NAME && sudo apt install $PNAME"
say "  • Launchpad builds it for each release (usually minutes); build failures are emailed."
say "  • Next release: run linux-submit.sh ppa (or linux-submit.sh) again."
echo
}

# ##########################################################################
#   Debian's questions — the package name, its section and description.
#   Part of "Your app" whenever Debian is among the distros, so a Linux run
#   asks them up front; what Debian can't take is refused right here.
#   Needs linux_common and linux_app's globals.
# ##########################################################################
# deb_name_problems <name> — one line per rule of Debian's it breaks (Policy 5.6.1)
deb_name_problems() {
  local n="$1"
  [ "${#n}" -ge 2 ] || echo "it needs at least 2 characters"
  printf '%s' "$n" | grep -qE '^[a-z0-9][a-z0-9+.-]*$' \
    || echo "only lowercase letters, digits, + - and . — starting with a letter or digit"
  return 0
}

debian_questions() {
  local first=1 guess secs readme probs
  # Debian builds every package from source, offline, from Debian's own packages
  case "$KIND" in
    flutter) die "Debian builds every package from source, offline and from its own packages — and has no Flutter SDK, so a Flutter app can't go into Debian. Debian users get it from Flathub (sudo apt install flatpak) or the Snap Store (sudo apt install snapd)" ;;
    node)    die "Debian builds offline, and every npm package an app uses must be in Debian first (a bundled node_modules isn't allowed) — this wizard can't take an npm app into Debian. Debian users get it from Flathub or the Snap Store, which both work on Debian" ;;
  esac
  [ -n "${MAINT_EMAIL:-}" ] || die "Debian needs your email: it's the package's Maintainer address, where its bug reports go — set maintainer-email in ${LINUX_CONF##*/}"
  case "$SPDX" in
    '') die "no license found — Debian only takes software under a free license: add a LICENSE file and release again" ;;
    CC-*-NC*|CC-*-ND*|SSPL-*|BUSL-*|Elastic-*|*Commons-Clause*)
      die "$SPDX isn't free by Debian's rules (https://www.debian.org/social_contract#guidelines) — Debian's archive can't take it" ;;
    LicenseRef-*|NOASSERTION|other)
      warn "Debian's FTP masters decide whether $SPDX is free by their rules — a well-known license makes that quick" ;;
  esac

  # --- the package name: Debian's rules are a little stricter (no _)
  guess="$(cfg_get debian-name)"
  [ -n "$guess" ] || guess="$(printf '%s' "$PNAME" | tr '_' '-')"
  while :; do
    if [ "$first" = 1 ] && [ -z "$(deb_name_problems "$guess")" ] && [ "$ASK_ALL" = 0 ]; then DEB_NAME="$guess"
    else ask DEB_NAME "Debian package name" "$guess"; fi
    first=0
    probs="$(deb_name_problems "$DEB_NAME")"
    [ -z "$probs" ] && break
    printf '%s\n' "$probs" | while read -r l; do warn "Debian package name: $l"; done
    [ "$ASSUME_YES" = 1 ] && die "fix debian-name in the config and re-run"
    guess="$DEB_NAME"
  done
  ok "Debian package name: $DEB_NAME"
  [ "${SAVE:-1}" = 1 ] && cfg_set debian-name "$DEB_NAME"

  # --- the archive section it's listed under
  secs="utils admin devel editors games graphics mail math net science sound text video web x11 gnome kde misc"
  DEB_SECTION="$(cfg_get debian-section)"
  case " $secs " in *" $DEB_SECTION "*) ;; *) DEB_SECTION="" ;; esac
  if [ -z "$DEB_SECTION" ] || [ "$ASK_ALL" = 1 ]; then
    note "the section of Debian's archive it's listed in — utils suits most tools"
    while :; do
      ask DEB_SECTION "Debian section ($secs)" "${DEB_SECTION:-utils}"
      case " $secs " in *" $DEB_SECTION "*) break ;; esac
      warn "one of: $secs"; DEB_SECTION=""
    done
    [ "${SAVE:-1}" = 1 ] && cfg_set debian-section "$DEB_SECTION"
  fi
  ok "Debian section: $DEB_SECTION"

  # --- the one-line description: 80 characters at most (lintian: synopsis-too-long)
  DEB_SYNOPSIS="$(cfg_get debian-synopsis)"; [ -n "$DEB_SYNOPSIS" ] || DEB_SYNOPSIS="$DESC"
  while [ "${#DEB_SYNOPSIS}" -gt 80 ]; do
    warn "Debian's one-line description has 80 characters at most (yours has ${#DEB_SYNOPSIS})"
    [ "$ASSUME_YES" = 1 ] && die "set a shorter debian-synopsis in the config"
    ask DEB_SYNOPSIS "A shorter one" "$(printf '%s' "$DEB_SYNOPSIS" | cut -c1-80)"
    [ "${SAVE:-1}" = 1 ] && cfg_set debian-synopsis "$DEB_SYNOPSIS"
  done

  # --- the long description: your own words (shared with Flathub and the Snap Store)
  ABOUT="$(cfg_get about)"
  if [ -z "$ABOUT" ] || [ "$ASK_ALL" = 1 ]; then
    readme="$(for f in README.md README; do at "$TAG_REF" "$f"; done 2>/dev/null | awk '/^#|^\[!|^!\[|^<|^$/ { if (p) exit; next } { p = p (p ? " " : "") $0 } END { print p }' | cut -c1-400)"
    note "a few sentences on what it does, in your own words — the package's long description, and the ITP's"
    ask ABOUT "What the app does" "${ABOUT:-$readme}"
    [ "${SAVE:-1}" = 1 ] && cfg_set about "$ABOUT"
  fi
  [ "$ABOUT" = "$DESC" ] && warn "the long description only repeats the short one — reviewers ask for more (the about line in the config)"
  ok "description: $DEB_SYNOPSIS"
  return 0
}

# ##########################################################################
#   Debian wizard — linux-submit.sh debian [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_debian() {
#
# linux-submit.sh debian — get an app into Debian itself, or ship a new
# version of one that's there. Ubuntu takes its packages from Debian, and
# Linux Mint, Pop!_OS, elementary… take Ubuntu's: they get it with their
# next releases.
#
# Follows Debian's own documentation:
#   https://mentors.debian.net/intro-maintainers/
#   https://mentors.debian.net/sponsors/rfs-howto/
#   https://www.debian.org/devel/wnpp/
#   https://www.debian.org/doc/manuals/developers-reference/pkgs.en.html#new-package
#   https://www.debian.org/doc/debian-policy/
#   https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
#   https://manpages.debian.org/unstable/devscripts/debian-watch.5.en.html
#   https://wiki.debian.org/Teams/RustPackaging/Policy
#   https://go-team.pages.debian.net/packaging.html
#
# Only a Debian developer can upload a new package (your sponsor), and the
# FTP masters review each new one before it's in. So the wizard does it all
# up to the sponsor: it checks nobody packages the app already, writes
# Debian-grade packaging (kept for your next releases, and for the changes
# reviewers ask for), builds it cleanly and offline in a Debian unstable
# container as an ordinary user, like Debian's build daemons, runs lintian
# (pedantic), files the ITP, signs and uploads to mentors.debian.net, and
# asks for a sponsor (the RFS).
#
# Debian builds everything from source, offline, with only what Debian has:
# bundled dependencies aren't allowed. So Flutter and npm apps can't go in
# (it says so up front), and Rust, Go and Python apps only when the
# libraries they use are packaged in Debian already (it checks).
#
# Mail in your name (the ITP and the RFS go to Debian's public lists) is
# sent only when you say so and this machine can send mail (msmtp or
# sendmail); otherwise, and always with --yes, it's written out for you.

set -eu

DRYRUN=0
SAVE=1
ASSUME_YES=0
ASK_ALL=0
NO_TEST=0
FRESH=0
REPO_ARG=""
ITP_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/debian-submit"
CONF="$CONF_DIR/last.conf"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/store-submit"
# your packaging, kept between runs: reviewers ask for changes, and each next
# release builds on it
KEEP_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/store-submit/debian"
DEB_IMAGE="${DEBIAN_IMAGE:-docker.io/library/debian:unstable}"
DEB_MIRROR="https://deb.debian.org/debian"
MADISON="https://api.ftp-master.debian.org/madison"
GO_PATHS="https://api.ftp-master.debian.org/binary/by_metadata/Go-Import-Path"
NEW_QUEUE="https://ftp-master.debian.org/new.822"
WNPP_LIST="https://qa.debian.org/data/bts/wnpp_rm"   # what devscripts' wnpp-check reads
PYDIST="https://salsa.debian.org/python-team/tools/dh-python/-/raw/master/pydist/cpython3_fallback"
MENTORS="https://mentors.debian.net"
BTS="https://bugs.debian.org"
STD_FALLBACK=4.7.4   # Debian Policy's version, when the archive can't be asked

usage() {
  cat <<'USAGE'
linux-submit.sh debian — get an app into Debian, or a new version of it.
Debian needs a sponsor (a Debian developer) to upload it: the wizard does
everything up to that and ends with your to-do list.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask; it never sends
                      mail in your name, and stops before a new package's
                      upload for you to read it first
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --config FILE   the shared answers (default: .store-submit.conf in the repo)
      --itp NUMBER    the ITP bug you filed already (default: found, or filed)
      --fresh         write the debian/ packaging anew (yours is kept otherwise)
      --no-test       skip the offline test build and lintian
  -n, --dry-run       package, build and check; send, sign and upload nothing
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
    --itp)        ITP_ARG="${2-}"; ITP_ARG="${ITP_ARG#\#}"; shift ;;
    --fresh)      FRESH=1 ;;
    --no-test)    NO_TEST=1 ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF"; printf 'forgot %s\n' "$CONF"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
case "$ITP_ARG" in *[!0-9]*) printf 'not a bug number: %s\n' "$ITP_ARG" >&2; exit 2 ;; esac

WIZ_NAME=debian-submit
linux_common

SAVED_REPO=""; SAVED_MENTORS_KEY=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  {
    printf '# written by linux-submit.sh debian — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n'        "${REPO:-${SAVED_REPO:-}}"
    printf 'SAVED_MENTORS_KEY=%q\n' "${MENTORS_KEY:-${SAVED_MENTORS_KEY:-}}"
  } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  chmod 600 "$CONF" 2>/dev/null || true
}

# ------------------------------------------------------------------ helpers
RUNTIME=""
for r in podman docker; do have "$r" && "$r" info >/dev/null 2>&1 && { RUNTIME="$r"; break; }; done
# docker's containers run as root: what they write is handed back to you
HOST_IDS=""; [ "$RUNTIME" = docker ] && HOST_IDS="$(id -u):$(id -g)"
# gpg: yours, or GnuPG from nixpkgs when it isn't installed
gpgx() { tool gnupg gpg "$@"; }
TTYARGS=(); [ -t 0 ] && { TTYARGS=(--pinentry-mode loopback); GPG_TTY="$(tty)"; export GPG_TTY; }

# this machine's mail setup, if it has one: msmtp (configured), or a sendmail
MAILER=()
if have msmtp && { [ -f "$HOME/.msmtprc" ] || [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/msmtp/config" ]; }; then
  MAILER=(msmtp -t)
else
  for m in sendmail /usr/sbin/sendmail /usr/lib/sendmail /run/wrappers/bin/sendmail; do
    if have "$m"; then MAILER=("$m" -t -oi); break; fi
  done
fi

# madison <name…> — what Debian's archive has under those names (source or
# binary, every suite), as JSON
madison() { curl -sf --max-time 60 "$MADISON?package=$(printf '%s' "$*" | tr ' ' '+')&f=json"; }
# unstable_version <package> — its version in unstable ("" if none)
unstable_version() {
  madison "$1" 2>/dev/null | python3 -c 'import json,sys
for e in json.load(sys.stdin):
    for p, s in (e or {}).items():
        for v in s.get("unstable", {}):
            print(v); sys.exit()' 2>/dev/null || true
}
# pool_dir <source> — its directory in Debian's (and mentors') pool
pool_dir() {
  case "$1" in lib?*) printf '%s/%s' "$(printf '%s' "$1" | cut -c1-4)" "$1" ;; *) printf '%s/%s' "$(printf '%s' "$1" | cut -c1)" "$1" ;; esac
}
# deb822_field <file> <field> — a field of a Debian control file (signed or
# not), its continuation lines one per line
deb822_field() {
  python3 - "$1" "$2" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
text = re.sub(r"(?s)^-----BEGIN PGP SIGNED MESSAGE-----.*?\n\n", "", text)
text = text.split("\n-----BEGIN PGP SIGNATURE-----")[0]
out, on = [], False
for line in text.split("\n"):
    if re.match(r"\S", line):
        on = line.split(":", 1)[0].lower() == sys.argv[2].lower()
        if on:
            out.append(line.split(":", 1)[1].strip())
    elif on and line.strip():
        out.append(line.strip())
print("\n".join(l for l in out if l))
PY
}
# vcmp <a> <b> — -1, 0 or 1: two upstream versions compared as dpkg does
vcmp() {
  python3 - "$1" "$2" <<'PY'
import sys
def order(c):
    return -1 if c == "~" else (ord(c) if c.isalpha() else ord(c) + 256)
def cmp(a, b):
    while a or b:
        while (a and not a[0].isdigit()) or (b and not b[0].isdigit()):
            x = order(a[0]) if a and not a[0].isdigit() else 0
            y = order(b[0]) if b and not b[0].isdigit() else 0
            if x != y:
                return (x > y) - (x < y)
            a = a[1:] if a and not a[0].isdigit() else a
            b = b[1:] if b and not b[0].isdigit() else b
        da = len(a) - len(a.lstrip("0123456789")); db = len(b) - len(b.lstrip("0123456789"))
        x, y = int(a[:da] or 0), int(b[:db] or 0)
        if x != y:
            return (x > y) - (x < y)
        a, b = a[da:], b[db:]
    return 0
print(cmp(sys.argv[1], sys.argv[2]))
PY
}
# upstream_of <Debian version> — without the epoch and the Debian revision
upstream_of() { local v="${1#*:}"; case "$v" in *-*) v="${v%-*}" ;; esac; printf '%s' "$v"; }

# bts bugs <key> <value> [<key> <value>…] | bts status <number…> — Debian's
# bug tracker (its SOAP interface), one bug per line:
#   number|subject|done (empty while open)|tags|owner|submitter
bts() {
  python3 - "$BTS/cgi-bin/soap.cgi" "$@" <<'PY' 2>/dev/null || true
import sys, urllib.request, xml.etree.ElementTree as ET
from xml.sax.saxutils import escape
url, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
def call(method, inner):
    body = ('<?xml version="1.0" encoding="UTF-8"?><soap:Envelope'
            ' xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"'
            ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
            ' xmlns:xsd="http://www.w3.org/2001/XMLSchema"'
            ' xmlns:soapenc="http://schemas.xmlsoap.org/soap/encoding/">'
            '<soap:Body><%s xmlns="Debbugs/SOAP">%s</%s></soap:Body></soap:Envelope>') % (method, inner, method)
    req = urllib.request.Request(url, body.encode(), {"Content-Type": "text/xml; charset=utf-8",
                                                      "SOAPAction": '"Debbugs/SOAP#%s"' % method})
    return ET.fromstring(urllib.request.urlopen(req, timeout=60).read())
local = lambda e: e.tag.rsplit("}", 1)[-1]
if cmd == "bugs":
    inner = "".join('<a%d xsi:type="xsd:string">%s</a%d>' % (i, escape(a), i) for i, a in enumerate(args))
    nums = [e.text for e in call("get_bugs", inner).iter() if local(e) == "item" and (e.text or "").isdigit()]
else:
    nums = [a for a in args if a.isdigit()]
if not nums:
    sys.exit(0)
items = "".join('<item xsi:type="xsd:int">%s</item>' % n for n in nums)
root = call("get_status", '<bugs soapenc:arrayType="xsd:int[%d]" xsi:type="soapenc:Array">%s</bugs>' % (len(nums), items))
for item in root.iter():
    kids = {local(c): c for c in item}
    if local(item) != "item" or "key" not in kids or "value" not in kids:
        continue
    f = {local(c): (c.text or "").replace("|", "/").replace("\n", " ") for c in kids["value"]}
    print("|".join([kids["key"].text or "", f.get("subject", ""), f.get("done", ""), f.get("tags", ""),
                    f.get("owner", ""), f.get("originator", "")]))
PY
}
# my_bug <wnpp|sponsorship-requests> <subject start> — your open bug whose
# subject starts so (looked up live: you as submitter or owner)
my_bug() {
  { bts bugs package "$1" submitter "$MAINT_EMAIL"; bts bugs package "$1" owner "$MAINT_EMAIL"; } \
    | awk -F'|' -v s="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" 'index(tolower($2), s) == 1 && $3 == "" { print $1 "|" $2 "|" $4; exit }'
}

# mail_write <file> <to> <subject> <body file> [<header: value>…] — a plain-text mail from you
mail_write() {
  python3 - "$@" "$MAINT_NAME" "$MAINT_EMAIL" <<'PY'
import sys
from email.message import EmailMessage
from email.policy import default
from email.utils import formataddr
out, to, subject, body = sys.argv[1:5]
extra, (name, addr) = sys.argv[5:-2], sys.argv[-2:]
m = EmailMessage(policy=default.clone(max_line_length=998))
m["From"] = formataddr((name, addr)); m["To"] = to; m["Subject"] = subject
for h in extra:
    k, v = h.split(":", 1); m[k.strip()] = v.strip()
m.set_content(open(body, encoding="utf-8").read(), charset="utf-8", cte="8bit")
open(out, "wb").write(bytes(m))
PY
}
# mail_send <file> — through this machine's mail setup; false if it has none, or it fails
mail_send() { [ "${#MAILER[@]}" -gt 0 ] && "${MAILER[@]}" < "$1" > "$WORK/mail.log" 2>&1; }
# can_mail — whether the wizard may send mail in your name now
can_mail() { [ "$DRYRUN" = 0 ] && [ "$ASSUME_YES" = 0 ] && [ "${#MAILER[@]}" -gt 0 ]; }

# =============================================================== 0. orientation
cat <<BANNER

  ${B}Debian wizard${R}  (and with it, later: Ubuntu, Linux Mint, Pop!_OS…)

  Seven stages:
    1. your app         — shared with the other distros, plus Debian's questions
    2. Debian already?  — the archive, the NEW queue, WNPP, mentors — and whether
                          Debian has every library the app builds with
    3. debian/          — Debian-grade packaging, kept for your next releases
    4. build + check    — built offline in Debian unstable as an ordinary user,
                          like Debian's build daemons; lintian, pedantic
    5. ITP              — the "intent to package" bug that debian-devel sees
    6. upload           — signed with your GPG key, sent to mentors.debian.net
    7. sponsor          — the RFS; ${B}a Debian developer${R} reviews it and uploads it

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: packaged, built and checked; nothing is sent, signed or uploaded"
[ "$ASSUME_YES" = 1 ] && note "--yes: using everything detected; mail in your name is written out, not sent"
for t in git curl python3 tar; do have "$t" || die "$t is missing — install it and re-run"; done
[ -n "$RUNTIME" ] || die "Debian packages are built and checked in a Debian container: install podman or docker (NixOS: virtualisation.podman.enable = true;)"

# ============================================================== 1. the app
linux_app "1/7  Your app"
debian_questions
# Debian's upstream version: pre-releases sort before the release with ~
DEB_UVER="$(printf '%s' "$VERSION" | sed -E 's/([0-9])[-_.]?((alpha|beta|rc|pre|dev)[0-9.]*)$/\1~\2/')"
case "$DEB_UVER" in *[!A-Za-z0-9.+~-]*) die "version $VERSION has characters a Debian version can't have" ;; esac
[ "$DEB_UVER" != "$VERSION" ] && note "Debian sorts pre-releases with ~ — its version is $DEB_UVER"
MAIN_PROG="$(cfg_get main-program)"; MAIN_PROG="${MAIN_PROG:-$MAIN_GUESS}"

# ===================================================== 2. Debian already?
step "2/7  In Debian already?"
MODE=new; ARCHIVE_VER=""; EPOCH=""; RFP=""; RFS_BUG=""; RFS_SUBJECT=""; RFS_TAGS=""
ITP="${ITP_ARG:-$(cfg_get debian-itp)}"
# archive_lookup — what the archive has under $DEB_NAME, as lines of
# name|suite|version|source|component|src-or-bin
archive_lookup() {
  madison "$DEB_NAME" > "$WORK/archive.json" || die "couldn't ask Debian's archive ($MADISON) — check your connection"
  python3 - "$WORK/archive.json" > "$WORK/archive.txt" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for entry in data if isinstance(data, list) else [data]:
    for pkg, suites in (entry or {}).items():
        for suite, vers in suites.items():
            for ver, d in vers.items():
                kind = "src" if "source" in d.get("architectures", []) else "bin"
                print("|".join([pkg, suite, ver, d.get("source", pkg), d.get("component", "main"), kind]))
PY
}
# --- the name: free in Debian, or the app's own package
while :; do
  archive_lookup || die "Debian's archive gave an answer the wizard can't read"
  OTHER_SRC="$(awk -F'|' -v n="$DEB_NAME" '$1 == n && $4 != n { print $4; exit }' "$WORK/archive.txt")"
  [ -z "$OTHER_SRC" ] && break
  warn "Debian has a package called $DEB_NAME already, built from $OTHER_SRC: https://tracker.debian.org/pkg/$OTHER_SRC"
  note "if that's your app, it's in Debian already; if not, yours needs another name"
  [ "$ASSUME_YES" = 1 ] && die "choose another name (debian-name in the config)"
  while :; do
    ask DEB_NAME "Another Debian package name" "$DEB_NAME-$(printf '%s' "$OWNER" | tr 'A-Z_' 'a-z-' | tr -cd 'a-z0-9-')"
    [ -z "$(deb_name_problems "$DEB_NAME")" ] && break
    deb_name_problems "$DEB_NAME" | while read -r l; do warn "$l"; done
  done
  [ "$SAVE" = 1 ] && cfg_set debian-name "$DEB_NAME"
done

if awk -F'|' -v n="$DEB_NAME" '$4 == n { f = 1 } END { exit !f }' "$WORK/archive.txt"; then
  # --- in Debian: a new version, if you maintain it
  read -r ARCHIVE_VER COMP <<EOF
$(awk -F'|' -v n="$DEB_NAME" '$1 == n && $6 == "src" { print ($2 == "unstable" ? 0 : 1), $3, $5 }' "$WORK/archive.txt" | sort -n | head -1 | cut -d' ' -f2-)
EOF
  [ -n "$ARCHIVE_VER" ] || die "Debian lists binaries of $DEB_NAME but no source package — see https://tracker.debian.org/pkg/$DEB_NAME"
  DSC_URL="$DEB_MIRROR/pool/${COMP:-main}/$(pool_dir "$DEB_NAME")/${DEB_NAME}_${ARCHIVE_VER#*:}.dsc"
  curl -sf --max-time 60 -o "$WORK/archive.dsc" "$DSC_URL" || die "couldn't fetch $DSC_URL"
  MAINTS="$(deb822_field "$WORK/archive.dsc" Maintainer; deb822_field "$WORK/archive.dsc" Uploaders)"
  if ! printf '%s' "$MAINTS" | grep -qiF "$MAINT_EMAIL"; then
    say "Debian has $DEB_NAME $ARCHIVE_VER, maintained by: $(printf '%s' "$MAINTS" | head -1)"
    note "its maintainers upload new versions: tell them about yours (reportbug $DEB_NAME, \"new upstream version\"), or offer help"
    note "https://tracker.debian.org/pkg/$DEB_NAME"
    die "$DEB_NAME is in Debian, maintained by someone else"
  fi
  MODE=update
  case "$ARCHIVE_VER" in *:*) EPOCH="${ARCHIVE_VER%%:*}:" ;; esac
  ok "$DEB_NAME is in Debian at $ARCHIVE_VER, and you maintain it — this is a new version"
  case "$(vcmp "$(upstream_of "$ARCHIVE_VER")" "$DEB_UVER")" in
    0) die "Debian has $DEB_NAME $(upstream_of "$ARCHIVE_VER") already — nothing to do (a packaging fix: edit it, add a changelog entry with dch -i, upload as usual)" ;;
    1) die "Debian has a newer $DEB_NAME ($ARCHIVE_VER) than $DEB_UVER" ;;
  esac
else
  ok "$DEB_NAME isn't in Debian's archive"
  # --- the NEW queue: uploaded, waiting for the FTP masters
  if curl -sf --max-time 60 -o "$WORK/new.822" "$NEW_QUEUE"; then
    NEWQ="$(python3 - "$WORK/new.822" "$DEB_NAME" <<'PY'
import sys
name = sys.argv[2]
for para in open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n\n"):
    f = dict(l.split(": ", 1) for l in para.split("\n") if ": " in l and not l.startswith(" "))
    if f.get("Source") == name or name in [b.strip() for b in f.get("Binary", "").split(",")]:
        print("|".join([f.get("Source", ""), f.get("Version", ""), f.get("Age", ""), f.get("Changed-By", "") + " " + f.get("Maintainer", "")]))
        break
PY
)"
    if [ -n "$NEWQ" ]; then
      IFS='|' read -r NQ_SRC NQ_VER NQ_AGE NQ_BY <<EOF
$NEWQ
EOF
      if printf '%s' "$NQ_BY" | grep -qiF "$MAINT_EMAIL"; then
        ok "your $NQ_SRC $NQ_VER is in Debian's NEW queue ($NQ_AGE) — the FTP masters review it there"
        handoff_add "Wait for the FTP masters' verdict on $NQ_SRC $NQ_VER (it's emailed to you); nothing else to do until then"
        handoff_show "Debian's FTP masters have your package" "https://ftp-master.debian.org/new.html"
        exit 0
      fi
      die "$NQ_SRC $NQ_VER is waiting in Debian's NEW queue ($NQ_AGE), from ${NQ_BY%% <*} — someone packages this name already"
    fi
    ok "nothing called $DEB_NAME waits in the NEW queue"
  else
    warn "couldn't read Debian's NEW queue ($NEW_QUEUE)"
  fi

  # --- WNPP: someone packaging it already (ITP), or asking for it (RFP)
  WN=""
  if curl -sf --max-time 60 -o "$WORK/wnpp" "$WNPP_LIST"; then
    WN="$(awk -F': ' -v n="$DEB_NAME" '$1 == n { print $2 }' "$WORK/wnpp")"
  else
    warn "couldn't read Debian's WNPP list ($WNPP_LIST)"
  fi
  while read -r wtype wbug; do
    [ -n "$wbug" ] || continue
    IFS='|' read -r _ wsubj _ _ wowner wsub <<EOF
$(bts status "$wbug")
EOF
    mine=0; printf '%s %s' "${wowner:-}" "${wsub:-}" | grep -qiF "$MAINT_EMAIL" && mine=1
    case "$wtype" in
      ITP) if [ "$mine" = 1 ]; then ITP="$wbug"
           elif [ -z "${wsubj:-}" ]; then
             die "WNPP has an ITP for $DEB_NAME (#$wbug), and the bug tracker can't be asked whose it is right now — try again later ($BTS/$wbug)"
           else
             say "WNPP #$wbug: ${wsubj:-ITP for $DEB_NAME} — ${wowner:-$wsub}"
             note "$BTS/$wbug — write to $wbug@bugs.debian.org to work together, or to take it over if it's stalled"
             die "someone intends to package $DEB_NAME already (ITP #$wbug)"
           fi ;;
      RFP) RFP="$wbug"; ok "it was asked for in Debian (RFP #$wbug) — that bug becomes your ITP" ;;
      RFS) if [ "$mine" = 1 ]; then RFS_BUG="$wbug"
           else warn "there's a request for a sponsor for a $DEB_NAME by someone else: $BTS/$wbug"; fi ;;
      *)   note "WNPP has a $wtype bug for this name: $BTS/$wbug" ;;
    esac
  done <<EOF
$WN
EOF
  # your own ITP, asked live (the list above is refreshed a few times a day)
  if [ -z "$ITP" ]; then
    MINE="$(my_bug wnpp "ITP: $DEB_NAME ")"
    [ -n "$MINE" ] && ITP="${MINE%%|*}"
  fi
  if [ -n "$ITP" ]; then
    IFS='|' read -r _ isubj idone _ iowner isub <<EOF
$(bts status "$ITP")
EOF
    ISUBJ="$(printf '%s' "${isubj:-}" | tr 'A-Z' 'a-z')"; LNAME="$(printf '%s' "$DEB_NAME" | tr 'A-Z' 'a-z')"
    if [ -z "$ISUBJ" ]; then warn "couldn't ask the bug tracker about #$ITP — using it as your ITP"
    else
      case "$ISUBJ" in
        "itp: $LNAME "*) ;;
        "rfp: $LNAME "*) warn "#$ITP is still titled RFP — the bug tracker may not have retitled it yet" ;;
        *) die "#$ITP isn't an ITP for $DEB_NAME (it's \"$isubj\") — check --itp, or debian-itp in the config" ;;
      esac
      [ -n "${idone:-}" ] && die "ITP #$ITP is closed — file a new one: drop debian-itp from the config and re-run"
      printf '%s %s' "${iowner:-}" "${isub:-}" | grep -qiF "$MAINT_EMAIL" || warn "ITP #$ITP is owned by ${iowner:-$isub}, not by $MAINT_EMAIL"
      ok "your ITP: #$ITP — $BTS/$ITP"
    fi
  elif [ -z "$RFP" ]; then
    ok "nobody has announced packaging $DEB_NAME (WNPP)"
  fi
fi

# --- a request for a sponsor of yours that's still open
MINE="$(my_bug sponsorship-requests "RFS: $DEB_NAME/")"
if [ -n "$MINE" ]; then
  IFS='|' read -r RFS_BUG RFS_SUBJECT RFS_TAGS <<EOF
$MINE
EOF
  ok "your request for a sponsor is open: #$RFS_BUG${RFS_TAGS:+ (tags: $RFS_TAGS)}"
fi

# --- mentors.debian.net: a version uploaded there before
MENTORS_HAS="$(curl -sf --max-time 60 "$MENTORS/api/packages/?name=$DEB_NAME" | python3 -c 'import json,sys
for p in json.load(sys.stdin):
    print(",".join(p.get("uploaders", [])) + "|" + " ".join(p.get("versions", {}).values()))' 2>/dev/null || true)"
if [ -n "$MENTORS_HAS" ]; then
  if printf '%s' "${MENTORS_HAS%%|*}" | grep -qiF "$MAINT_EMAIL"; then
    ok "your upload on mentors.debian.net: $DEB_NAME ${MENTORS_HAS#*|}"
  else
    warn "mentors.debian.net has a $DEB_NAME ${MENTORS_HAS#*|} from ${MENTORS_HAS%%|*}: $MENTORS/package/$DEB_NAME/"
    [ "$ASSUME_YES" = 1 ] && die "someone else has a $DEB_NAME on mentors.debian.net — is that you, with another address?"
    confirm "Carry on anyway? (is that you, with another address?)" n || exit 1
  fi
fi

# --- what the app builds with: Debian has to have every library itself
DEPS_BLOCK=0; TOOLCHAIN_OLD=0; RUST_BDEPS=""; GO_BDEPS=""; PY_BDEPS=""; GO_MODULE=""; CRATE=""
: > "$WORK/deps.txt"
case "$KIND" in
  rust)
    at "$TAG_REF" Cargo.lock > "$WORK/Cargo.lock"; at "$TAG_REF" Cargo.toml > "$WORK/Cargo.toml"
    CRATE="$(toml_get package name < "$WORK/Cargo.toml")"
    deps_rust() {
      python3 - "$WORK/Cargo.lock" "$WORK/Cargo.toml" "$MADISON" "$WORK/deps.txt" <<'PY'
import json, re, sys, tomllib, urllib.request
from collections import deque
lockf, tomlf, madison, out = sys.argv[1:5]
lock = tomllib.load(open(lockf, "rb")); top = tomllib.load(open(tomlf, "rb"))
pk = lock.get("package", [])
# crates for other systems: Debian's crate packages leave them out
OTHER = re.compile(r"^(windows|winapi|winreg|wasm-bindgen|js-sys|web-sys|wasi|wasip[0-9]|wasite|objc|objc2|block2|core-foundation"
                   r"|core-graphics|cocoa|security-framework|system-configuration|android|ndk|jni|redox|libredox|redox_syscall"
                   r"|hermit-abi|fuchsia|schannel|mach|mach2|io-kit|dispatch|dispatch2)([-_].*)?$")
def key(v):  # the part of a version Debian's package names carry: 1, 0.4, 0.0.3
    p = (re.split(r"[+-]", v)[0].split(".") + ["0", "0"])[:3]
    return p[0] if p[0] != "0" else ("0." + p[1] if p[1] != "0" else "0.0." + p[2])
def upstream(v):
    v = v.split(":", 1)[-1]
    return re.split(r"[+~]", v.rsplit("-", 1)[0] if "-" in v else v)[0]
deb = lambda n: n.replace("_", "-").lower()
real = lambda n, v: v.get("package", n) if isinstance(v, dict) else n
byname = {}
for p in pk:
    byname.setdefault(p["name"], []).append(p)
def resolve(spec):
    f = spec.split(); c = byname.get(f[0], [])
    if len(f) > 1:
        c = [p for p in c if p["version"] == f[1]] or c
    return c[0] if c else None
# the app's own dev-dependencies and other systems' dependencies aren't built
normal = {real(n, v) for t in ("dependencies", "build-dependencies") for n, v in top.get(t, {}).items()}
skip = {real(n, v) for n, v in top.get("dev-dependencies", {}).items()} - normal
for cond, t in top.get("target", {}).items():
    if re.search(r'windows|macos|ios|android|wasm|target_os\s*=\s*"(?!linux)', cond):
        skip |= {real(n, v) for n, v in t.get("dependencies", {}).items()}
need, seen, todo = {}, set(), deque()
for r in [p for p in pk if "source" not in p]:
    todo.extend(d for d in r.get("dependencies", []) if d.split()[0] not in skip)
while todo:
    p = resolve(todo.popleft())
    if not p or (p["name"], p["version"]) in seen:
        continue
    seen.add((p["name"], p["version"]))
    if OTHER.match(p["name"]):
        continue
    if "source" in p:
        need[(p["name"], p["version"])] = p
    todo.extend(p.get("dependencies", []))
names = sorted({x for (n, v), p in need.items() if not p["source"].startswith("git+")
                for x in ("rust-" + deb(n), "rust-%s-%s" % (deb(n), key(v)))})
found = {}
for i in range(0, len(names), 60):
    print("asking the archive about crates %d-%d of %d" % (i + 1, min(i + 60, len(names)), len(names)), flush=True)
    url = "%s?package=%s&s=unstable&f=json" % (madison, "+".join(names[i:i + 60]))
    data = json.load(urllib.request.urlopen(url, timeout=120))
    for entry in data if isinstance(data, list) else [data]:
        for pkg, suites in (entry or {}).items():
            for vers in suites.values():
                found.setdefault(pkg, set()).update(vers)
with open(out, "w") as o:
    for (n, v), p in sorted(need.items()):
        if p["source"].startswith("git+"):
            o.write("git|%s|%s|%s\n" % (n, v, p["source"].split("#")[0])); continue
        have = sorted(found.get("rust-" + deb(n), set()) | found.get("rust-%s-%s" % (deb(n), key(v)), set()))
        good = [h for h in have if key(upstream(h)) == key(v)]
        if good:
            o.write("ok|%s|%s|%s\n" % (n, v, good[0]))
        elif have:
            o.write("version|%s|%s|%s\n" % (n, v, " ".join(have)))
        else:
            o.write("missing|%s|%s|\n" % (n, v))
PY
    }
    run_logged "$WORK/deps.log" "checking the crates it builds with against Debian's" deps_rust \
      || { tail -n 3 "$WORK/deps.log" | sed 's/^/     /'; warn "couldn't check the crates against Debian's archive"; }
    RV="$(toml_get package rust-version < "$WORK/Cargo.toml")"
    [ -n "$RV" ] || RV="$(toml_get workspace.package rust-version < "$WORK/Cargo.toml")"
    DR="$(upstream_of "$(unstable_version rustc)")"
    if [ -n "$RV" ] && [ -n "$DR" ] && [ "$(vcmp "$RV" "$DR")" = 1 ]; then
      warn "the app asks for Rust $RV; Debian unstable has $DR — Debian builds with its own"; TOOLCHAIN_OLD=1
    fi ;;
  go)
    at "$TAG_REF" go.mod > "$WORK/go.mod"
    GO_MODULE="$(sed -nE 's/^module[[:space:]]+([^[:space:]]+).*/\1/p' "$WORK/go.mod" | head -1)"
    deps_go() {
      python3 - "$WORK/go.mod" "$GO_PATHS" "$WORK/deps.txt" <<'PY'
import json, sys, urllib.request
gomod, url, out = sys.argv[1:4]
reqs, block = [], False
for line in open(gomod, encoding="utf-8"):
    s, ind = line.split("//")[0].strip(), "// indirect" in line
    if s.startswith("require ("):
        block = True; continue
    if block and s == ")":
        block = False; continue
    if s.startswith("require "):
        s = s[len("require "):]
    elif not block:
        continue
    f = s.split()
    if len(f) >= 2:
        reqs.append((f[0], f[1], ind))
print("asking the archive which Go libraries it has", flush=True)
dev = {}
for e in json.load(urllib.request.urlopen(url, timeout=180)):
    if e.get("binary", "").endswith("-dev"):
        for p in e.get("metadata_value", "").split(","):
            dev.setdefault(p.strip(), e["binary"])
with open(out, "w") as o:
    for path, ver, ind in reqs:
        if path in dev:
            o.write("ok|%s|%s|%s\n" % (path, ver, dev[path]))
        else:
            o.write("%s|%s|%s|\n" % ("indirect" if ind else "missing", path, ver))
PY
    }
    run_logged "$WORK/deps.log" "checking the Go modules it builds with against Debian's" deps_go \
      || { tail -n 3 "$WORK/deps.log" | sed 's/^/     /'; warn "couldn't check the Go modules against Debian's archive"; }
    GO_BDEPS="$(awk -F'|' '$1 == "ok" { print $4 }' "$WORK/deps.txt" | sort -u | paste -sd, - | sed 's/,/, /g')"
    GV="$(sed -nE 's/^go[[:space:]]+([0-9][0-9.]*).*/\1/p' "$WORK/go.mod" | head -1)"
    DG="$(upstream_of "$(unstable_version golang-go)")"; DG="${DG%%~*}"
    if [ -n "$GV" ] && [ -n "$DG" ] && [ "$(vcmp "$GV" "$DG")" = 1 ]; then
      warn "go.mod asks for Go $GV; Debian unstable has $DG — Debian builds with its own"; TOOLCHAIN_OLD=1
    fi ;;
  python)
    at "$TAG_REF" pyproject.toml > "$WORK/pyproject.toml"
    deps_python() {
      python3 - "$WORK/pyproject.toml" "$PYDIST" "$WORK/deps.txt" <<'PY'
import re, sys, tomllib, urllib.request
pp, url, out = sys.argv[1:4]
d = tomllib.load(open(pp, "rb"))
norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()
print("asking dh-python which Python packages Debian has", flush=True)
fb = {}
for line in urllib.request.urlopen(url, timeout=120).read().decode().splitlines():
    f = line.split()
    if len(f) >= 2:
        fb[norm(f[0])] = f[1]
def name(req):
    m = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", req)
    return m.group(1) if m else ""
def elsewhere(req):  # only for other systems, old Pythons or extras
    m = req.split(";", 1)[1] if ";" in req else ""
    return bool(re.search(r"extra\s*==|sys_platform\s*==\s*.(win32|darwin|cygwin)|platform_system\s*==\s*.(Windows|Darwin)"
                          r"|python_version\s*<\s*.3\.([0-9]|1[01])\b", m))
deps = list(d.get("project", {}).get("dependencies", []))
deps += [k for k in d.get("tool", {}).get("poetry", {}).get("dependencies", {}) if k.lower() != "python"]
with open(out, "w") as o:
    for kind, reqs in (("build", d.get("build-system", {}).get("requires", [])), ("dep", deps)):
        for r in reqs:
            n = name(r)
            if n and not elsewhere(r):
                o.write("%s|%s|%s|%s\n" % ("ok" if norm(n) in fb else "missing", n, kind, fb.get(norm(n), "")))
PY
    }
    if run_logged "$WORK/deps.log" "checking its Python dependencies against Debian's" deps_python; then
      PY_BDEPS="$( { awk -F'|' '$1 == "ok" && $3 == "build" { print $4 }' "$WORK/deps.txt"
                     awk -F'|' '$1 == "ok" && $3 == "dep" { print $4 " <!nocheck>" }' "$WORK/deps.txt"; } | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g')"
      # a build backend Debian doesn't know by name: its python3- package, if it has one
      for b in $(awk -F'|' '$1 == "missing" && $3 == "build" { print tolower($2) }' "$WORK/deps.txt" | tr '_.' '--'); do
        PY_BDEPS="${PY_BDEPS:+$PY_BDEPS, }python3-$b"
      done
    else
      tail -n 3 "$WORK/deps.log" | sed 's/^/     /'; warn "couldn't check the Python dependencies against Debian's"
    fi ;;
esac
if [ -s "$WORK/deps.txt" ]; then
  NOK="$(grep -c '^ok|' "$WORK/deps.txt" || true)"; NALL="$(grep -c . "$WORK/deps.txt" || true)"
  ok "$NOK of the $NALL libraries it builds with are packaged in Debian"
  if grep -qE '^(missing|git)\|' "$WORK/deps.txt"; then
    DEPS_BLOCK=1
    bad "not in Debian:"
    awk -F'|' '$1 == "missing" { print "       " $2 ($3 == "dep" ? "" : $3 == "build" ? " (to build it)" : " " $3) }
               $1 == "git" { print "       " $2 " (from git: " $4 ")" }' "$WORK/deps.txt" | head -25
    [ "$(grep -cE '^(missing|git)\|' "$WORK/deps.txt")" -gt 25 ] && note "… and more: $WORK/deps.txt"
  fi
  if grep -q '^version|' "$WORK/deps.txt"; then
    warn "in Debian, but not at the version the app asks for (Debian's maintainers often patch that in):"
    awk -F'|' '$1 == "version" { print "       " $2 " " $3 " — Debian: " $4 }' "$WORK/deps.txt" | head -15
  fi
  grep -q '^indirect|' "$WORK/deps.txt" && note "not in Debian, maybe not needed (indirect): $(awk -F'|' '$1 == "indirect" { printf "%s ", $2 }' "$WORK/deps.txt" | cut -c1-300)"
fi
if [ "$DEPS_BLOCK" = 1 ]; then
  say "Debian builds an app only from libraries Debian packages itself (bundling them isn't allowed),"
  say "so these would have to go into Debian first, each as a package of its own:"
  case "$KIND" in
    rust)   note "Rust crates go in through the Debian Rust team (debcargo-conf): https://wiki.debian.org/Teams/RustPackaging" ;;
    go)     note "Go libraries go in one by one (dh-make-golang, an ITP each): https://go-team.pages.debian.net/packaging.html" ;;
    python) note "Python libraries go in as python3-… packages, usually through the Debian Python team: https://wiki.debian.org/Teams/PythonTeam" ;;
  esac
fi
[ "$TOOLCHAIN_OLD" = 1 ] && { say "Debian builds with the compiler it ships: the app has to build with that one."; DEPS_BLOCK=1; }
if [ "$DEPS_BLOCK" = 1 ]; then
  note "until then, Debian users can get it from Flathub or the Snap Store (both work on Debian)"
  [ "$ASSUME_YES" = 1 ] && die "Debian lacks what the app builds with (above)"
  confirm "Carry on anyway? (the test build shows what's really missing)" n \
    || die "Debian lacks what the app builds with (above)"
fi

# ================================================================ 3. debian/
step "3/7  debian/ packaging"
KEEP="$KEEP_ROOT/$DEB_NAME"
WD="$CACHE/debian/$DEB_NAME"
DEB_VER="$EPOCH$DEB_UVER-1"
FVER="${DEB_VER#*:}"   # file names have no epoch
rm -rf "$WD"; mkdir -p "$WD/out" "$WD/result" "$KEEP"
SRCDIR="$WD/$DEB_NAME-$DEB_UVER"

# --- the upstream tarball, as uscan fetches it with debian/watch
case "$FORGE" in
  github) ORIG_URL="https://api.github.com/repos/$SLUG/tarball/refs/tags/$TAG" ;;
  gitlab) ORIG_URL="https://gitlab.com/api/v4/projects/$(printf '%s' "$SLUG" | sed 's#/#%2F#g')/repository/archive.tar.gz?sha=$TAG" ;;
  *)      ORIG_URL="" ;;   # uscan's git mode: git archive of the tag, xz-compressed
esac
if [ -n "$ORIG_URL" ] && [ "${DRY_NO_TAG:-0}" != 1 ]; then
  ORIG="$WD/${DEB_NAME}_${DEB_UVER}.orig.tar.gz"
  run_logged "$WORK/orig.log" "downloading the release tarball ($TAG)" curl -fL --retry 3 -o "$ORIG" "$ORIG_URL" \
    || { tail -n 3 "$WORK/orig.log" | sed 's/^/     /'; die "couldn't download $ORIG_URL — is tag $TAG pushed?"; }
else
  ORIG="$WD/${DEB_NAME}_${DEB_UVER}.orig.tar.xz"
  [ "${DRY_NO_TAG:-0}" = 1 ] && warn "dry run, and the tag isn't online: the upstream tarball is made from HEAD"
  git -C "$REPO" archive --format=tar --prefix="$DEB_NAME-$DEB_UVER/" "$TAG_REF" | tool xz xz -6 > "$ORIG" \
    && [ -s "$ORIG" ] || die "couldn't make the upstream tarball"
fi
mkdir -p "$SRCDIR"
case "$ORIG" in
  *.xz) tool xz xz -dc "$ORIG" | tar x -C "$SRCDIR" --strip-components=1 ;;
  *)    tar xzf "$ORIG" -C "$SRCDIR" --strip-components=1 ;;
esac || die "couldn't unpack $(basename "$ORIG")"
ok "upstream tarball: $(basename "$ORIG") ($(du -h "$ORIG" | cut -f1))"

# seed_from_archive — debian/ as it is in Debian now (its debian.tar from the archive)
seed_from_archive() {
  local sum tarball url
  read -r sum tarball <<EOF
$(deb822_field "$WORK/archive.dsc" Checksums-Sha256 | awk 'NF == 3 && $3 ~ /\.debian\.tar\./ { print $1, $3; exit }')
EOF
  [ -n "${tarball:-}" ] || die "Debian's $DEB_NAME $ARCHIVE_VER has no debian.tar (a native package?) — update it by hand"
  url="${DSC_URL%/*}/$tarball"
  curl -sf --max-time 120 -o "$WORK/$tarball" "$url" || die "couldn't download $url"
  [ "$(sha256sum "$WORK/$tarball" | cut -d' ' -f1)" = "$sum" ] || die "$tarball doesn't match its checksum in Debian's .dsc"
  tar xf "$WORK/$tarball" -C "$KEEP" debian || die "couldn't unpack $tarball"
}

# deb_wrap <control> — one relation per line, sorted, as wrap-and-sort -ast writes them
deb_wrap() {
  python3 - "$1" <<'PY'
import re, sys
p = sys.argv[1]
out, arch = [], ""
for line in open(p, encoding="utf-8").read().split("\n"):
    if line.startswith("Architecture:"):
        arch = line.split(":", 1)[1].strip()
    m = re.match(r"^(Build-Depends|Depends|Built-Using|Static-Built-Using): (.*)$", line)
    if not m:
        out.append(line); continue
    items = [i.strip() for i in m.group(2).split(",") if i.strip()]
    if m.group(1) == "Depends" and arch == "all":
        items = [i for i in items if i != "${shlibs:Depends}"]
    out.append(m.group(1) + ":")
    out += [" %s," % i for i in sorted(set(items), key=str.lower)]
open(p, "w", encoding="utf-8").write("\n".join(out))
PY
}

# deb_copyright <file> — debian/copyright in Debian's machine-readable format
# (DEP-5): the holders from the source's notices, the licenses Debian ships
# in /usr/share/common-licenses by reference, every other one in full from
# the source's own license file
deb_copyright() {
  mkdir -p "$WORK/lic"
  grep -iE '^(LICEN[CS]E|COPYING)[^/]*$|^LICEN[CS]ES/[^/]+$' "$WORK/tree.txt" | while read -r f; do
    at "$TAG_REF" "$f" > "$WORK/lic/$(printf '%s' "$f" | tr '/' '_')"
  done
  # the notices in the app's own files (bundled third-party code is left to licensecheck, later)
  git -C "$REPO" grep --full-name -I -i -E 'copyright[[:space:]]*(\(c\)|©)?[[:space:]]*[0-9]{4}' "$TAG_REF" -- . 2>/dev/null \
    | awk -v rev="$TAG_REF" '{ s = substr($0, length(rev) + 2); p = index(s, ":")
        if (substr(s, 1, p - 1) !~ /(^|\/)(debian|vendor|third_party|thirdparty|external|node_modules)\//) print substr(s, p + 1) }' \
    | head -n 300 > "$WORK/copyright-lines" || true
  python3 - "$1" "$SPDX" "$(cfg_get display-name || true)" "$REPONAME" "$MAINT_NAME <$MAINT_EMAIL>" "$WEB" \
    "$(date +%Y)" "$WORK/copyright-lines" "$WORK/lic" \
    "$(git -C "$REPO" log --reverse --format=%ad --date=format:%Y "$TAG_REF" | head -1)" \
    "$(git -C "$REPO" log -1 --format=%ad --date=format:%Y "$TAG_REF")" "$MAINT_NAME" <<'PY'
import os, re, sys, datetime
out, spdx, display, repo, contact, source, year, linesf, licdir, y0, y1, maint = sys.argv[1:13]
DEP5 = {"GPL-2.0-only": "GPL-2", "GPL-2.0": "GPL-2", "GPL-2.0-or-later": "GPL-2+", "GPL-2.0+": "GPL-2+",
        "GPL-3.0-only": "GPL-3", "GPL-3.0": "GPL-3", "GPL-3.0-or-later": "GPL-3+", "GPL-3.0+": "GPL-3+",
        "LGPL-2.1-only": "LGPL-2.1", "LGPL-2.1": "LGPL-2.1", "LGPL-2.1-or-later": "LGPL-2.1+", "LGPL-2.1+": "LGPL-2.1+",
        "LGPL-3.0-only": "LGPL-3", "LGPL-3.0": "LGPL-3", "LGPL-3.0-or-later": "LGPL-3+", "LGPL-3.0+": "LGPL-3+",
        "AGPL-3.0-only": "AGPL-3", "AGPL-3.0": "AGPL-3", "AGPL-3.0-or-later": "AGPL-3+",
        "MIT": "Expat", "BSD-2-Clause": "BSD-2-clause", "BSD-3-Clause": "BSD-3-clause"}
parts = re.split(r"\s+(AND|OR|and|or)\s+", spdx.replace("(", " ").replace(")", " ").strip())
ids = [DEP5.get(p, p) for p in parts[0::2]]
expr = ids[0] + "".join(" %s %s" % (op.lower(), i) for op, i in zip(parts[1::2], ids[1:]))
def gnu(fam, ver, later):
    lib = fam == "LGPL"
    full = "GNU Lesser General Public License" if lib else "GNU General Public License"
    what = "This library" if lib else "This program"
    if later:
        t = ["%s is free software: you can redistribute it and/or modify" % what,
             "it under the terms of the %s as published by" % full,
             "the Free Software Foundation, either version %s of the License, or" % ver,
             "(at your option) any later version."]
    else:
        t = ["%s is free software: you can redistribute it and/or modify" % what,
             "it under the terms of the %s version %s" % (full, ver),
             "as published by the Free Software Foundation."]
    return t + ["", "%s is distributed in the hope that it will be useful," % what,
                "but WITHOUT ANY WARRANTY; without even the implied warranty of",
                "MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the",
                "%s for more details." % full, "",
                "You should have received a copy of the %s" % full,
                "along with this %s.  If not, see <https://www.gnu.org/licenses/>." % ("library" if lib else "program"), "",
                "On Debian systems, the complete text of the %s" % full,
                'version %s can be found in "/usr/share/common-licenses/%s-%s".' % (ver, fam, ver)]
COMMON = {
    "Apache-2.0": ['Licensed under the Apache License, Version 2.0 (the "License");',
                   "you may not use this file except in compliance with the License.",
                   "You may obtain a copy of the License at", "", "https://www.apache.org/licenses/LICENSE-2.0", "",
                   "Unless required by applicable law or agreed to in writing, software",
                   'distributed under the License is distributed on an "AS IS" BASIS,',
                   "WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.",
                   "See the License for the specific language governing permissions and",
                   "limitations under the License.", "",
                   "On Debian systems, the complete text of the Apache License, Version 2.0",
                   'can be found in "/usr/share/common-licenses/Apache-2.0".'],
    "MPL-2.0": ["This Source Code Form is subject to the terms of the Mozilla Public",
                "License, v. 2.0. If a copy of the MPL was not distributed with this",
                "file, You can obtain one at https://mozilla.org/MPL/2.0/.", "",
                "On Debian systems, the complete text of the Mozilla Public License,",
                'version 2.0, can be found in "/usr/share/common-licenses/MPL-2.0".'],
    "CC0-1.0": ["To the extent possible under law, the author(s) have dedicated all",
                "copyright and related and neighboring rights to this software to the",
                "public domain worldwide. This software is distributed without any warranty.", "",
                "On Debian systems, the complete text of the CC0 1.0 Universal license",
                'can be found in "/usr/share/common-licenses/CC0-1.0".'],
}
# the others are quoted in full from the source: found by their wording
SIGS = {"Expat": ["Permission is hereby granted, free of charge"],
        "BSD-2-clause": ["Redistribution and use in source and binary forms"],
        "BSD-3-clause": ["Redistribution and use in source and binary forms", "Neither the name"],
        "ISC": ["Permission to use, copy, modify, and/or distribute this software"],
        "0BSD": ["Permission to use, copy, modify, and/or distribute this software"],
        "Zlib": ["This software is provided 'as-is'"],
        "Unlicense": ["This is free and unencumbered software"],
        "BSL-1.0": ["Boost Software License"],
        "AGPL-3": ["GNU AFFERO GENERAL PUBLIC LICENSE"], "AGPL-3+": ["GNU AFFERO GENERAL PUBLIC LICENSE"]}
files = {f: open(os.path.join(licdir, f), encoding="utf-8", errors="replace").read() for f in sorted(os.listdir(licdir))} if os.path.isdir(licdir) else {}
def full_text(lid, spdx_id):
    for f, t in files.items():   # REUSE: LICENSES/<SPDX id>.txt
        if f in ("LICENSES_%s.txt" % spdx_id, "LICENCES_%s.txt" % spdx_id):
            return t
    cands = [f for f, t in files.items() if all(s.lower() in t.lower() for s in SIGS.get(lid, ["\0"]))]
    if lid == "BSD-2-clause":
        cands = [f for f in cands if "neither the name" not in files[f].lower()]
    if not cands and len(files) == 1:
        cands = list(files)
    if not cands:
        return None
    hint = {"Expat": "mit"}.get(lid, lid.split("-")[0]).lower()   # LICENSE-MIT, LICENSE-BSD…
    t = files[sorted(cands, key=lambda f: (hint not in f.lower(), len(f)))[0]]
    if lid.startswith("AGPL"):
        return t
    lines = t.replace("\r", "").split("\n")
    drop = re.compile(r"^\s*($|#|(the\s+)?\S+(\s\S+){0,3}\s+licen[cs]e(\s*\(\S+\))?\s*$|copyright\b|\(c\)|©|all rights reserved)", re.I)
    while lines and drop.match(lines[0]):
        lines.pop(0)
    return "\n".join(lines)
def para(text_lines):
    return "\n".join(" " + l.rstrip().expandtabs() if l.strip() else " ." for l in text_lines)
missing, paras = [], []
for lid, sid in zip(ids, parts[0::2]):
    m = re.match(r"^(L?GPL)-([\d.]+)(\+?)$", lid)
    if m:
        body = gnu(m.group(1), m.group(2), bool(m.group(3)))
    elif lid in COMMON:
        body = COMMON[lid]
    else:
        t = full_text(lid, sid)
        if t is None:
            missing.append(lid); paras.append("License: %s" % lid); continue
        body = t.strip("\n").split("\n")
    paras.append("License: %s\n%s" % (lid, para(body)))
# the holders: from the copyright notices in the source
pat = re.compile(r"copyright\s*(?:\(c\)|©)?\s*((?:\d{4})(?:\s*(?:-|–|,|to)\s*(?:\d{4}|present))*)\s*,?\s*(?:by\s+)?(.*)", re.I)
holders = {}
for line in open(linesf, encoding="utf-8", errors="replace"):
    m = pat.search(line)
    if not m:
        continue
    who = re.sub(r"(?i)\s*all rights reserved\.?", "", m.group(2))
    who = re.sub(r"[\s*/#;\"'`>-]+$", "", re.sub(r"\s+", " ", who)).strip(" .,;:")
    if not who or re.search(r"(?i)free software foundation|apache software foundation", who):   # the license texts' own
        continue
    years = set()
    for a, b in re.findall(r"(\d{4})(?:\s*(?:-|–|to)\s*(\d{4}|present))?", m.group(1)):
        b = datetime.date.today().year if b == "present" else int(b or a)
        years.update(range(int(a), b + 1))
    holders.setdefault(who.lower(), [who, set()])[1].update(years)
def span(ys):
    ys, out = sorted(ys), []
    for y in ys:
        if out and y == out[-1][1] + 1:
            out[-1][1] = y
        else:
            out.append([y, y])
    return ", ".join(str(a) if a == b else "%d-%d" % (a, b) for a, b in out)
lines = ["%s %s" % (span(ys), who) for who, ys in holders.values()]
if not lines:
    lines = ["%s %s" % (y0 if y0 == y1 else "%s-%s" % (y0, y1), maint)]
    print("NOHOLDERS", file=sys.stderr)
txt = ["Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/",
       "Upstream-Name: %s" % (display or repo), "Upstream-Contact: %s" % contact, "Source: %s" % source, "",
       "Files: *", "Copyright: " + "\n           ".join(lines), "License: %s" % expr, "",
       "Files: debian/*", "Copyright: %s %s" % (year, contact), "License: %s" % expr, ""]
open(out, "w", encoding="utf-8").write("\n".join(txt) + "\n" + "\n\n".join(paras) + "\n")
for lid in missing:
    print("NOTEXT %s" % lid, file=sys.stderr)
PY
}

# deb_changelog — debian/changelog's top entry is $DEB_VER: a new package
# has one entry ("Initial release", closing the ITP), a new version gets one
# on top. Prints what it did: same, closes, new or added.
deb_changelog() {
  python3 - "$KEEP/debian/changelog" "$DEB_NAME" "$DEB_VER" "$MODE" "${ITP:-}" "$MAINT_NAME <$MAINT_EMAIL>" "$(LC_ALL=C date -R)" <<'PY'
import os, re, sys
path, name, ver, mode, itp, maint, date = sys.argv[1:8]
old = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
m = re.match(r"(\S+) \(([^)]+)\) ([^;]+);", old)
closes = " (Closes: #%s)" % itp if itp else ""
entry = lambda body: "%s (%s) unstable; urgency=medium\n\n%s\n\n -- %s  %s\n" % (name, ver, body, maint, date)
if m and m.group(2) == ver:
    top, sep, rest = old.partition("\n -- ")
    if mode == "new" and itp and "#" + itp not in top:
        if re.search(r"Initial release\.?", top):
            top = re.sub(r"(Initial release\.?)", lambda x: x.group(1) + closes, top, count=1)
        else:
            top = top.rstrip("\n") + "\n  * Initial release.%s\n" % closes
        open(path, "w", encoding="utf-8").write(top + sep + rest)
        print("closes")
    else:
        print("same")
elif mode == "new":
    open(path, "w", encoding="utf-8").write(entry("  * Initial release.%s" % closes))
    print("new")
else:
    open(path, "w", encoding="utf-8").write(entry("  * New upstream release.") + "\n" + old)
    print("added")
PY
}

# rust_deps — the librust-*-dev build dependencies for the app's Cargo.toml,
# worked out by Debian's own tool (debcargo), in a Debian container
rust_deps() {
  "$RUNTIME" run --rm -v "$SRCDIR:/src:ro" "$DEB_IMAGE" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends debcargo >/dev/null
    cp -r /src /tmp/src && cd /tmp/src
    echo "==> debcargo deb-dependencies Cargo.toml"
    debcargo deb-dependencies Cargo.toml'
}

# --- your packaging: kept in $KEEP/debian between runs
if [ "$FRESH" = 1 ] && [ -d "$KEEP/debian" ]; then
  mv "$KEEP/debian" "$KEEP/debian.before-$(date +%Y%m%d-%H%M%S)"
  note "--fresh: your previous debian/ is kept beside it, as $(ls -d "$KEEP"/debian.before-* | tail -1 | sed 's#.*/##')"
fi
if [ "$MODE" = update ] && [ -d "$KEEP/debian" ] && ! grep -qF "($ARCHIVE_VER)" "$KEEP/debian/changelog" 2>/dev/null; then
  mv "$KEEP/debian" "$KEEP/debian.before-$(date +%Y%m%d-%H%M%S)"
  warn "your kept debian/ doesn't include $ARCHIVE_VER, the version in Debian — starting from Debian's (yours is kept beside it)"
fi
if [ -d "$KEEP/debian" ]; then
  ok "your packaging from last time: $KEEP/debian (your edits are kept)"
elif [ "$MODE" = update ]; then
  seed_from_archive
  ok "Debian's packaging of $ARCHIVE_VER"
elif in_tree debian/control && in_tree debian/rules; then
  git -C "$REPO" archive "$TAG_REF" debian | tar x -C "$KEEP"
  ok "your debian/ (from $TAG)"
else
  mkdir -p "$KEEP/debian/source" "$KEEP/debian/upstream"
  echo "3.0 (quilt)" > "$KEEP/debian/source/format"
  if [ "$KIND" = rust ]; then
    if run_logged "$WORK/debcargo.log" "working out the librust-*-dev build dependencies (debcargo, in Debian unstable)" rust_deps; then
      RUST_BDEPS="$(grep -E 'rustc:native|librust-' "$WORK/debcargo.log" | tail -1)"
    fi
    if [ -n "$RUST_BDEPS" ]; then ok "build dependencies from debcargo: $(printf '%s' "$RUST_BDEPS" | tr ',' '\n' | grep -c librust || true) crate packages"
    else warn "debcargo couldn't work them out ($(tail -n 1 "$WORK/debcargo.log")) — add the librust-*-dev packages to Build-Depends yourself"; fi
  fi
  deb_recipe debian
  STD="$(upstream_of "$(unstable_version debian-policy)" | cut -d. -f1-3)"; STD="${STD:-$STD_FALLBACK}"
  SFIELDS=""; BFIELDS=""
  case "$KIND" in
    rust) [ -n "$CRATE" ] && [ "$CRATE" != "$DEB_NAME" ] && SFIELDS="X-Cargo-Crate: $CRATE"
          BFIELDS='Built-Using: ${cargo:Built-Using}
Static-Built-Using: ${cargo:Static-Built-Using}' ;;
    go)   SFIELDS="XS-Go-Import-Path: $GO_MODULE"
          BFIELDS='Static-Built-Using: ${misc:Static-Built-Using}' ;;
  esac
  deb_control "$KEEP" "$DEB_NAME" "$DEB_SECTION" "$STD" "$DEB_SYNOPSIS" "$ABOUT" "$SFIELDS" "$BFIELDS"
  deb_wrap "$KEEP/debian/control"
  deb_rules "$KEEP"
  deb_copyright "$KEEP/debian/copyright" 2> "$WORK/copyright.log" || die "couldn't write debian/copyright"
  # what uscan watches for new releases (watch file format 5, its templates)
  case "$FORGE" in
    github) printf 'Version: 5\nTemplate: GitHub\nOwner: %s\nProject: %s\n' "$OWNER" "$REPONAME" ;;
    gitlab) printf 'Version: 5\nTemplate: GitLab\nDist: %s\n' "$WEB" ;;
    *)      printf 'Version: 5\nSource: %s\nMatching-Pattern: refs/tags/@ANY_VERSION@\nMode: git\nPgp-Mode: none\n' \
              "$(printf '%s' "$ORIGIN" | sed -E 's#^[^@/]+@([^:]+):#https://\1/#')" ;;
  esac > "$KEEP/debian/watch"
  # where upstream lives (DEP-12)
  {
    printf -- '---\n'
    case "$FORGE" in
      github|codeberg) printf 'Bug-Database: %s/issues\nBug-Submit: %s/issues/new\n' "$WEB" "$WEB" ;;
      gitlab)          printf 'Bug-Database: %s/-/issues\nBug-Submit: %s/-/issues/new\n' "$WEB" "$WEB" ;;
    esac
    if [ "$FORGE" = git ]; then printf 'Repository: %s\n' "$(printf '%s' "$ORIGIN" | sed -E 's#^[^@/]+@([^:]+):#https://\1/#')"
    else printf 'Repository: %s.git\nRepository-Browse: %s\n' "$WEB" "$WEB"; fi
  } > "$KEEP/debian/upstream/metadata"
  # dh-cargo wants one, even for an app that isn't on crates.io
  [ "$KIND" = rust ] && printf '{"package":"Could not get crate checksum","files":{}}\n' > "$KEEP/debian/cargo-checksum.json"
  ok "wrote debian/: control, rules, copyright, watch, upstream/metadata, source/format ($KIND)"
  if grep -q NOHOLDERS "$WORK/copyright.log"; then
    warn "no copyright notice in the source — debian/copyright names you, from the git history's years; check it"
  fi
  for l in $(sed -n 's/^NOTEXT //p' "$WORK/copyright.log"); do
    warn "no $l license text found in the source — paste it into its License: paragraph in debian/copyright"
    handoff_add "debian/copyright: paste the full $l license text into its License: paragraph ($KEEP/debian/copyright)"
  done
  # every Build-Depends must exist in unstable (the librust-*/dh-sequence-* names are virtual)
  BD="$(deb822_field "$KEEP/debian/control" Build-Depends | tr ',|' '\n\n' | sed -E 's/[[:space:]]*[(<\[].*//; s/:.*//; s/^[[:space:]]+//' \
        | grep -vE '^(librust-|dh-sequence-|debhelper-compat$|$)' | sort -u | tr '\n' ' ')"
  if [ -n "$BD" ]; then
    # shellcheck disable=SC2086
    if NOBD="$(madison $BD | python3 -c 'import json,sys
have = {p for e in json.load(sys.stdin) for p, s in (e or {}).items() if "unstable" in s}
print(" ".join(sorted(set(sys.argv[1:]) - have)))' $BD 2>/dev/null)"; then
      for p in $NOBD; do warn "Build-Depends: $p isn't in Debian unstable — the test build will say"; done
    else
      warn "couldn't check the Build-Depends against Debian's archive"
    fi
  fi
fi
SRCNAME="$(deb822_field "$KEEP/debian/control" Source | head -1)"
[ "$SRCNAME" = "$DEB_NAME" ] || die "$KEEP/debian/control names the source package \"$SRCNAME\", not $DEB_NAME — set debian-name = $SRCNAME in the config, or change debian/control"
case "$(cat "$KEEP/debian/source/format" 2>/dev/null)" in
  "3.0 (quilt)") ;;
  *) warn "debian/source/format isn't 3.0 (quilt) — Debian's form with an upstream tarball; setting it"
     mkdir -p "$KEEP/debian/source"; echo "3.0 (quilt)" > "$KEEP/debian/source/format" ;;
esac
VCS="$(cfg_get debian-vcs)"
if [ -n "$VCS" ] && ! grep -q '^Vcs-Git:' "$KEEP/debian/control"; then
  sed -i "/^Homepage:/a Vcs-Browser: ${VCS%.git}\nVcs-Git: ${VCS%.git}.git" "$KEEP/debian/control"
  ok "Vcs-Browser/Vcs-Git: ${VCS%.git} (debian-vcs in the config)"
fi

# --- debian/changelog: its top entry is this version
case "$(deb_changelog)" in
  new)   ok "debian/changelog: $DEB_NAME ($DEB_VER) — Initial release${ITP:+, closes ITP #$ITP}" ;;
  added) ok "debian/changelog: $DEB_VER — New upstream release" ;;
  *)     ok "debian/changelog: $DEB_VER is the top entry already" ;;
esac
TOPDIST="$(sed -nE '1s/^[^ ]+ \([^)]+\) ([^;]+);.*/\1/p' "$KEEP/debian/changelog")"
case "$TOPDIST" in unstable|experimental) ;; *) warn "debian/changelog's top entry is for $TOPDIST — Debian's uploads go to unstable" ;; esac
echo; sed 's/^/     /' "$KEEP/debian/control"; echo
note "the packaging lives in $KEEP/debian — edit it there; each run builds from it"

# ====================================================== 4. build + check
step "4/7  Build and check"
# make_source — the source package (.dsc, .debian.tar.xz, _source.changes)
# from the upstream tarball and $KEEP/debian, in a Debian container
make_source() {
  rm -rf "$SRCDIR/debian" "$WD/out"; mkdir -p "$WD/out"
  cp -a "$KEEP/debian" "$SRCDIR/debian"
  "$RUNTIME" run --rm -v "$WD:/work" -e DIR="${SRCDIR##*/}" -e HOST_IDS="$HOST_IDS" "$DEB_IMAGE" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends dpkg-dev fakeroot xz-utils >/dev/null
    cd "/work/$DIR"
    echo "==> dpkg-buildpackage -S"
    dpkg-buildpackage -S -sa -d -nc -us -uc || { echo "STORE-SUBMIT: the source package failed"; exit 3; }
    cd /work
    for f in ./*.dsc ./*.debian.tar.* ./*_source.changes ./*_source.buildinfo; do [ -e "$f" ] && mv "$f" out/; done
    cp ./*.orig.tar.* out/
    [ -z "$HOST_IDS" ] || chown -R "$HOST_IDS" /work
    echo "STORE-SUBMIT: OK"'
}
# test_build — like Debian's build daemons (sbuild): a clean Debian unstable,
# only the build dependencies, the network cut, an ordinary user whose HOME
# doesn't exist; then lintian, licensecheck, the package installed and run,
# and manual pages written with help2man for programs that have none
test_build() {
  "$RUNTIME" run --rm --cap-add NET_ADMIN -v "$WD/out:/src:ro" -v "$WD/result:/result" \
    -e DSC="${DEB_NAME}_${FVER}.dsc" -e NAME="$DEB_NAME" -e MAIN="$MAIN_PROG" -e VERSION="$VERSION" \
    -e SYNOPSIS="$DEB_SYNOPSIS" -e HOST_IDS="$HOST_IDS" "$DEB_IMAGE" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    rm -f /etc/apt/apt.conf.d/docker-clean
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends build-essential dpkg-dev fakeroot iproute2 >/dev/null
    # the checkers are fetched now and installed after the build, so they cannot hide a missing build dependency
    apt-get install -y -qq --no-install-recommends --download-only lintian licensecheck help2man >/dev/null
    useradd -m builder
    install -d -o builder /build
    cp /src/*.orig.tar.* /build/ && chown builder /build/*.orig.tar.*
    runuser -u builder -- dpkg-source -x "/src/$DSC" /build/pkg >/dev/null
    apt-get build-dep -y -qq --no-install-recommends /build/pkg > /tmp/deps.log 2>&1 \
      || { echo "STORE-SUBMIT: build dependencies not installable"; tail -n 25 /tmp/deps.log; exit 4; }
    for i in /sys/class/net/*; do [ "${i##*/}" = lo ] || ip link set "${i##*/}" down; done
    echo "==> building offline, as an ordinary user"
    cd /build/pkg
    runuser -u builder -- env HOME=/sbuild-nonexistent LC_ALL=C.UTF-8 DEB_BUILD_OPTIONS="parallel=$(nproc)" \
      dpkg-buildpackage -us -uc -sa || { echo "STORE-SUBMIT: build failed"; exit 5; }
    ls /build/*.deb | sed "s#^/build/#DEB: #"
    apt-get install -y -qq --no-install-recommends --no-download lintian licensecheck help2man >/dev/null
    echo "==> lintian"
    runuser -u builder -- env HOME=/home/builder lintian --pedantic --info --display-info --display-experimental \
      --no-tag-display-limit /build/*.changes > /result/lintian.txt 2>&1 || true
    grep -E "^[EWIPX]: " /result/lintian.txt | sed "s/^/LINTIAN: /" || true
    echo "==> licensecheck"
    licensecheck -r -m --shortname-scheme=debian,spdx -l 0 -c ".*" -i "(^|/)(debian|\.git)/" /build/pkg 2>/dev/null \
      | sed "s#^/build/pkg/#LICENSE: #" || true
    echo "==> installing it"
    if apt-get install -y -qq --no-install-recommends --no-download /build/"$NAME"_*.deb >/dev/null 2>&1; then
      for b in $(dpkg -L "$NAME" | grep -E "^/usr/s?bin/[^/]+$"); do
        n="${b##*/}"
        echo "BIN: $b"
        if ! dpkg -L "$NAME" | grep -qE "/usr/share/man/man[18]/$n\.[18](\.gz)?$"; then
          echo "NOMAN: $n"
          if timeout 30 help2man -N --name="$SYNOPSIS" --version-string="$VERSION" "$b" > "/result/$n.1" 2>/dev/null && [ -s "/result/$n.1" ]; then
            echo "MANPAGE: $n"
          else rm -f "/result/$n.1"; fi
        fi
      done
      if [ -n "$MAIN" ] && command -v "$MAIN" >/dev/null; then
        if out="$(timeout 10 "$MAIN" --version 2>&1)"; then printf "%s\n" "$out" | head -n 2 | sed "s/^/VERSION: /"
        else echo "STORE-SUBMIT: $MAIN --version failed"; fi
      fi
    else
      echo "STORE-SUBMIT: not installable offline (it needs packages the build did not)"
    fi
    cp /build/*.changes /build/*.deb /build/*.buildinfo /result/ 2>/dev/null || true
    [ -z "$HOST_IDS" ] || chown -R "$HOST_IDS" /result
    echo "STORE-SUBMIT: OK"'
}
# lintian_tags <letter> — that kind of lintian's tags from the test build
lintian_tags() { grep "^LINTIAN: $1: " "$WORK/test.log" | grep -v "initial-upload-closes-no-bugs" || true; }

TESTED=0; MAN_ADDED=0
while :; do
  run_logged "$WORK/src.log" "the source package ($DEB_NAME $DEB_VER)" make_source && grep -q "STORE-SUBMIT: OK" "$WORK/src.log" \
    || { grep -vE '^\s*$' "$WORK/src.log" | tail -n 15 | sed 's/^/     /'; KEEP_WORK=1; die "couldn't make the source package (log: $WORK/src.log)"; }
  [ -f "$WD/out/${DEB_NAME}_${FVER}.dsc" ] || die "no ${DEB_NAME}_${FVER}.dsc came out — log: $WORK/src.log"
  ok "source package: ${DEB_NAME}_${FVER}.dsc"
  [ "$NO_TEST" = 1 ] && { warn "--no-test: not test-built, and lintian didn't run"; break; }
  if run_logged "$WORK/test.log" "building it offline in Debian unstable, then lintian (a first run takes a while)" test_build \
     && grep -q "STORE-SUBMIT: OK" "$WORK/test.log"; then
    ok "builds offline in Debian unstable: $(sed -n 's/^DEB: //p' "$WORK/test.log" | tr '\n' ' ')"
    grep '^VERSION: ' "$WORK/test.log" | head -1 | sed 's/^VERSION: /   ✓ --version → /'
    grep -q "STORE-SUBMIT: .* --version failed" "$WORK/test.log" && note "$MAIN_PROG --version didn't answer in the container (fine for a graphical app)"
    grep -q "STORE-SUBMIT: not installable offline" "$WORK/test.log" && note "it wasn't tried out: installing it needs packages the build didn't"
    cp "$WD/result/lintian.txt" "$KEEP/lintian.txt" 2>/dev/null || true
    LE="$(lintian_tags E | grep -c . || true)"; LW="$(lintian_tags W | grep -c . || true)"
    LI="$(lintian_tags I | grep -c . || true)"; LP="$(lintian_tags P | grep -c . || true)"; LX="$(lintian_tags X | grep -c . || true)"
    if [ "$LE" -gt 0 ]; then bad "lintian (Debian's package checker): $LE error(s)"; lintian_tags E | sed 's/^LINTIAN: /       /' | head -15; fi
    if [ "$LW" -gt 0 ]; then warn "lintian: $LW warning(s)"; lintian_tags W | sed 's/^LINTIAN: /       /' | head -15; fi
    [ "$LE" = 0 ] && [ "$LW" = 0 ] && ok "lintian: no errors or warnings"
    [ $((LI + LP + LX)) -gt 0 ] && note "lintian also has $LI info, $LP pedantic and $LX experimental remark(s) — all explained in $KEEP/lintian.txt"
    [ "$MODE" = new ] && [ -z "$ITP" ] && grep -q "initial-upload-closes-no-bugs" "$WORK/test.log" \
      && note "(lintian's initial-upload-closes-no-bugs goes once the changelog closes the ITP — stage 5)"
    # files under other licenses than the app's: debian/copyright must list them
    MAINLIC="$(awk '/^Files: \*$/ { f = 1 } f && /^License:/ { sub(/^License: */, ""); print; exit }' "$KEEP/debian/copyright" 2>/dev/null)"
    OTHERLIC="$(sed -n 's/^LICENSE: //p' "$WORK/test.log" | awk -F'\t' -v m=" $MAINLIC " '$2 != "" && $2 !~ /UNKNOWN|GENERATED/ && index(m, " " $2 " ") == 0 { print "       " $1 " — " $2 }')"
    if [ -n "$OTHERLIC" ]; then
      warn "licensecheck finds files under other licenses than $MAINLIC:"
      printf '%s\n' "$OTHERLIC" | head -12
      [ "${LIC_NOTED:-0}" = 1 ] || handoff_add "debian/copyright: give the files licensecheck found under other licenses their own Files: paragraphs (the FTP masters check this closely)"
      LIC_NOTED=1
    fi
    # programs without a manual page: help2man wrote one from --help
    NOMAN="$(sed -n 's/^NOMAN: //p' "$WORK/test.log" | tr '\n' ' ')"; MANS="$(sed -n 's/^MANPAGE: //p' "$WORK/test.log")"
    if [ -n "$NOMAN" ]; then
      warn "no manual page for: $NOMAN— Debian wants one for every program (lintian: no-manual-page)"
      if [ -n "$MANS" ] && [ "$MAN_ADDED" = 0 ] \
         && { [ "$ASSUME_YES" = 1 ] || confirm "Add the ones help2man made from --help (debian/<program>.1), and build again?" y; }; then
        for m in $MANS; do cp "$WD/result/$m.1" "$KEEP/debian/$m.1"; printf 'debian/%s.1\n' "$m" >> "$KEEP/debian/$DEB_NAME.manpages"; done
        sort -u -o "$KEEP/debian/$DEB_NAME.manpages" "$KEEP/debian/$DEB_NAME.manpages"
        MAN_ADDED=1; ok "added $(printf '%s\n' "$MANS" | grep -c .) manual page(s) — they're from --help: read them, improve them"
        continue
      fi
    fi
    if [ "$LE" -gt 0 ]; then
      [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "lintian found errors — fix them (or override a false alarm in debian/source/lintian-overrides), then re-run"; }
      say "Sponsors don't upload a package that lintian finds errors in."
      say "e) edit debian/control and debian/rules (in ${EDITOR:-vi}), then build again     l) read lintian's report"
      say "r) build again as it is     c) carry on anyway     q) quit"
      while :; do
        ask CHOICE "Choice" "e"
        case "$CHOICE" in l|L) "${PAGER:-less}" "$KEEP/lintian.txt" || cat "$KEEP/lintian.txt" ;; *) break ;; esac
      done
      case "$CHOICE" in
        e|E) "${EDITOR:-vi}" "$KEEP/debian/control" "$KEEP/debian/rules"; continue ;;
        r|R) continue ;;
        q|Q) note "the packaging is in $KEEP/debian"; exit 1 ;;
      esac
    fi
    TESTED=1
    break
  fi
  L="$WORK/test.log"
  if grep -q "build dependencies not installable" "$L"; then
    bad "a build dependency can't be installed in Debian unstable:"
    grep -E "Unable to locate|has no installation candidate|but it is not|unmet dependencies|Depends:" "$L" | head -5 | sed 's/^/       /'
  elif grep -qiE "no matching package named|failed to select a version for|failed to load source for dependency" "$L"; then
    bad "a crate isn't in Debian at the version Cargo.toml asks for (Debian's crates: /usr/share/cargo/registry)"
  elif grep -qiE "cannot find package|no required module provides package|is not in (GOROOT|std)" "$L"; then
    bad "a Go library isn't in Debian under that import path"
  elif grep -qiE "ModuleNotFoundError|No module named" "$L"; then
    bad "a Python module is missing while building — its python3-… package belongs in Build-Depends"
  elif grep -qiE "Could not resolve|Temporary failure in name resolution|failed to download|Network is unreachable" "$L"; then
    bad "the build tried to download something — Debian builds have no network; it must come from Debian's packages"
  elif grep -qiE "sbuild-nonexistent" "$L"; then
    bad "the build writes to HOME — Debian's build daemons have none (export HOME in debian/rules, or fix the build)"
  else
    bad "the test build failed:"
  fi
  grep -vE '^\s*$' "$L" | grep -v '^LINTIAN' | tail -n 12 | cut -c1-200 | sed 's/^/     /'
  [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "the test build failed (log: $L)"; }
  say "e) edit debian/control and debian/rules (in ${EDITOR:-vi}), then build again     l) read the whole log"
  say "r) build again as it is     s) skip the test build     q) quit"
  ask CHOICE "Choice" "e"
  case "$CHOICE" in
    e|E) "${EDITOR:-vi}" "$KEEP/debian/control" "$KEEP/debian/rules" ;;
    l|L) "${PAGER:-less}" "$L" || cat "$L" ;;
    s|S) warn "not test-built"; break ;;
    q|Q) note "the packaging is in $KEEP/debian"; exit 1 ;;
  esac
done
MAINLIC="$(awk '/^Files: \*$/ { f = 1 } f && /^License:/ { sub(/^License: */, ""); print; exit }' "$KEEP/debian/copyright" 2>/dev/null)"

# ================================================================== 5. ITP
step "5/7  ITP — telling Debian you're packaging it"
REBUILD=0
if [ "$MODE" = update ]; then
  ok "in Debian already — no ITP needed"
elif [ -n "$ITP" ]; then
  ok "ITP: #$ITP — $BTS/$ITP"
else
  case "$KIND" in
    rust) LANG_NAME=Rust ;; go) LANG_NAME=Go ;; python) LANG_NAME=Python ;;
    *) LANG_NAME="$(awk -F. 'NF > 1 { e = tolower($NF) } e == "c" || e == "h" { c++ } e ~ /^(cc|cpp|cxx|hpp|hh)$/ { x++ } e == "vala" { v++ }
                    END { if (x > c && x >= v) print "C++"; else if (v > c) print "Vala"; else print "C" }' "$WORK/tree.txt")" ;;
  esac
  if [ -n "$RFP" ]; then
    # someone asked for it: their RFP becomes your ITP (retitled, you as its owner)
    printf 'retitle %s ITP: %s -- %s\nowner %s !\nthanks\n' "$RFP" "$DEB_NAME" "$DEB_SYNOPSIS" "$RFP" > "$WORK/itp-body"
    mail_write "$KEEP/itp.eml" control@bugs.debian.org "ITP: $DEB_NAME -- $DEB_SYNOPSIS (RFP #$RFP)" "$WORK/itp-body"
    ITP_TO="control@bugs.debian.org"; ITP_WHAT="the mail that turns RFP #$RFP into your ITP"
  else
    DEB_WHY="$(cfg_get debian-why)"
    if [ -z "$DEB_WHY" ] && [ "$ASSUME_YES" = 0 ]; then
      note "the ITP is read on debian-devel: why is the app useful in Debian, and how does it compare to similar packages?"
      ask_opt DEB_WHY "A few words for that (Enter to leave it out)" ""
      [ "$SAVE" = 1 ] && cfg_set debian-why "$DEB_WHY"
    fi
    # the ITP as reportbug writes it (Developer's Reference 5.1)
    {
      printf 'Package: wnpp\nSeverity: wishlist\nOwner: %s <%s>\n' "$MAINT_NAME" "$MAINT_EMAIL"
      printf 'X-Debbugs-Cc: debian-devel@lists.debian.org, %s\n\n' "$MAINT_EMAIL"
      printf '* Package name    : %s\n  Version         : %s\n' "$DEB_NAME" "$DEB_UVER"
      printf '  Upstream Contact: %s <%s>\n* URL             : %s\n' "$MAINT_NAME" "$MAINT_EMAIL" "$HOMEPAGE"
      printf '* License         : %s\n  Programming Lang: %s\n' "${MAINLIC:-$SPDX}" "$LANG_NAME"
      printf '  Description     : %s\n\n' "$DEB_SYNOPSIS"
      printf '%s\n' "$ABOUT" | fold -s -w 72 | sed 's/[[:space:]]*$//'
      [ -n "${DEB_WHY:-}" ] && printf '\n%s\n' "$DEB_WHY" | fold -s -w 72 | sed 's/[[:space:]]*$//'
      printf '\nI will maintain the package, and I am looking for a sponsor; it will\nbe at %s/package/%s/\n' "$MENTORS" "$DEB_NAME"
    } > "$WORK/itp-body"
    mail_write "$KEEP/itp.eml" submit@bugs.debian.org "ITP: $DEB_NAME -- $DEB_SYNOPSIS" "$WORK/itp-body"
    ITP_TO="submit@bugs.debian.org, a copy to debian-devel"; ITP_WHAT="the ITP"
  fi
  say "Debian wants a package announced before it's uploaded — $ITP_WHAT:"
  echo; sed 's/^/     /' "$KEEP/itp.eml"; echo
  SENT=0
  if can_mail; then
    confirm "Edit it first (in ${EDITOR:-vi})?" n && "${EDITOR:-vi}" "$KEEP/itp.eml"
    if go "Send it to $ITP_TO, from $MAINT_EMAIL (with ${MAILER[0]##*/})?"; then
      if mail_send "$KEEP/itp.eml"; then SENT=1; ok "sent"
      else warn "sending failed: $(tail -n 2 "$WORK/mail.log" | tr '\n' ' ')"; fi
    fi
  elif [ "$DRYRUN" = 1 ]; then warn "dry run — not sent; it's in $KEEP/itp.eml"
  elif [ "$ASSUME_YES" = 1 ]; then note "--yes: mail in your name isn't sent for you"
  else note "this machine has no mail setup the wizard can use (msmtp or sendmail)"; fi
  if [ "$SENT" = 1 ] && [ -n "$RFP" ]; then
    ITP="$RFP"
  elif [ "$SENT" = 1 ]; then
    say "The bug tracker gives it a number within minutes (and mails it to you)…"
    for _ in $(seq 1 30); do
      MINE="$(my_bug wnpp "ITP: $DEB_NAME ")"
      [ -n "$MINE" ] && { ITP="${MINE%%|*}"; break; }
      sleep 10
    done
    if [ -n "$ITP" ]; then ok "ITP: #$ITP — $BTS/$ITP"
    else
      ask_opt ITP "Its number, from the bug tracker's reply (Enter to stop here for now)" ""
      ITP="${ITP#\#}"; case "$ITP" in *[!0-9]*) warn "not a bug number: $ITP"; ITP="" ;; esac
    fi
  fi
  if [ -z "$ITP" ] && [ "$DRYRUN" = 0 ]; then
    if [ "$SENT" = 0 ]; then
      handoff_add "Send $ITP_WHAT: a plain-text mail from $MAINT_EMAIL; To, Subject and text are in $KEEP/itp.eml (open it with any mail program)"
    fi
    handoff_add "The bug tracker replies with the bug number within minutes — then run linux-submit.sh debian again: it finds your ITP and carries on to the upload"
    save_answers
    handoff_show "Your turn — Debian wants the ITP before the upload" "$BTS/cgi-bin/pkgreport.cgi?package=wnpp;submitter=$MAINT_EMAIL"
    exit 0
  fi
fi
if [ "$MODE" = new ] && [ -n "$ITP" ]; then
  [ "$SAVE" = 1 ] && cfg_set debian-itp "$ITP"
  [ "$(deb_changelog)" = closes ] && { REBUILD=1; ok "debian/changelog closes ITP #$ITP"; }
fi

save_answers
if [ "$DRYRUN" = 1 ]; then
  warn "dry run — packaged, built and checked; nothing sent, signed or uploaded"
  note "packaging: $KEEP/debian · source package: $WD/out$( [ -f "$KEEP/itp.eml" ] && [ -z "$ITP" ] && printf ' · ITP: %s' "$KEEP/itp.eml")"
  exit 0
fi

# ================================================================ 6. upload
step "6/7  Sign and upload to mentors.debian.net"
# a new package is yours to answer for in Debian: read it before it goes out
if [ "$MODE" = new ]; then
  say "The packaging, in $KEEP/debian:"
  (cd "$KEEP/debian" && find . -type f | sed 's#^\./#     #' | sort)
  if [ "$ASSUME_YES" = 1 ]; then
    handoff_add "Read the packaging in $KEEP/debian — you answer for it in Debian — then run linux-submit.sh debian once without --yes: it signs and uploads it"
    handoff_show "Your turn — a new Debian package needs you to read it first" "$MENTORS/intro-maintainers/"
    exit 0
  fi
  confirm "Have you read it — control, rules, copyright, changelog — and do you stand behind it?" n \
    || { note "edit it in $KEEP/debian, then re-run"; exit 1; }
fi
if [ "$REBUILD" = 1 ]; then
  run_logged "$WORK/src.log" "the source package again (the changelog changed)" make_source && grep -q "STORE-SUBMIT: OK" "$WORK/src.log" \
    || { grep -vE '^\s*$' "$WORK/src.log" | tail -n 15 | sed 's/^/     /'; KEEP_WORK=1; die "couldn't make the source package (log: $WORK/src.log)"; }
fi
CHANGES="${DEB_NAME}_${FVER}_source.changes"
[ -f "$WD/out/$CHANGES" ] || die "no $CHANGES — log: $WORK/src.log"

# --- your GPG key: mentors.debian.net takes uploads signed with the one in your account
sign_keys() { gpgx --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1 == "sec" { want = 1; usable = ($2 !~ /[erd]/ && $12 ~ /S/) } $1 == "fpr" && want { if (usable) print $10; want = 0 }'; }
sign_keys > "$WORK/keys" || true
KEY="$(cfg_get gpg-key)"
if [ -z "$KEY" ] || ! grep -qx "$KEY" "$WORK/keys"; then
  KEY=""
  while read -r f; do
    [ -n "$f" ] || continue
    gpgx --list-keys --with-colons "$f" 2>/dev/null | awk -F: '$1 == "uid" { print tolower($10) }' \
      | grep -qF "<$(printf '%s' "$MAINT_EMAIL" | tr 'A-Z' 'a-z')>" && { KEY="$f"; break; }
  done < "$WORK/keys"
  [ -n "$KEY" ] || KEY="$(head -1 "$WORK/keys")"
fi
if [ -z "$KEY" ]; then
  say "You have no GPG key to sign with. The wizard can make one for $MAINT_NAME <$MAINT_EMAIL>."
  [ "$ASSUME_YES" = 1 ] && die "create your signing key once without --yes"
  confirm "Create it now? (gpg asks for a passphrase)" y || die "mentors.debian.net only takes signed uploads"
  gpgx "${TTYARGS[@]+"${TTYARGS[@]}"}" --quick-generate-key "$MAINT_NAME <$MAINT_EMAIL>" ed25519 sign 3y || die "gpg couldn't create the key"
  KEY="$(sign_keys | tail -1)"
  [ -n "$KEY" ] || die "gpg made no usable key"
fi
ok "signing key: $KEY"
[ "$SAVE" = 1 ] && cfg_set gpg-key "$KEY"
MENTORS_KEY=""
if [ "${SAVED_MENTORS_KEY:-}" = "$KEY" ]; then
  MENTORS_KEY="$KEY"; ok "it's the key in your mentors.debian.net account"
elif [ "$ASSUME_YES" = 0 ] && confirm "Is it the GPG key in your mentors.debian.net account?" n; then
  MENTORS_KEY="$KEY"
else
  mkdir -p "$CONF_DIR"; gpgx --armor --export "$KEY" > "$CONF_DIR/mentors-key.asc"
  say "mentors.debian.net needs an account, with this key in it (once):"
  note "1. sign up at $MENTORS/accounts/register/ (as a Maintainer), with $MAINT_EMAIL — its mails go there"
  note "2. log in, open $MENTORS/accounts/profile/ and paste $CONF_DIR/mentors-key.asc (your public key) under GPG key"
  if [ "$ASSUME_YES" = 1 ]; then
    handoff_add "Make a mentors.debian.net account and add your GPG key to it (the steps above), then run linux-submit.sh debian again"
    save_answers; handoff_show "Your turn — mentors.debian.net needs your account and key" "$MENTORS/accounts/register/"; exit 0
  fi
  confirm "Done?" y || die "mentors.debian.net needs your account and key to take the upload"
  MENTORS_KEY="$KEY"
fi
save_answers

# --- sign it like debsign: the .dsc, then the .buildinfo (which lists the
# .dsc), then the .changes, each with the new checksums of what it lists
clearsign() { gpgx "${TTYARGS[@]+"${TTYARGS[@]}"}" --yes --local-user "$KEY" --clearsign -o "$1.asc" "$1" && mv "$1.asc" "$1"; }
deb_resum() {  # deb_resum <file> <listed file…> — their new sizes and checksums in <file>
  python3 - "$@" <<'PY'
import hashlib, os, sys
target, files = sys.argv[1], sys.argv[2:]
info = {}
for f in files:
    data = open(f, "rb").read()
    info[os.path.basename(f)] = (str(len(data)), {"md5": hashlib.md5(data).hexdigest(), "sha1": hashlib.sha1(data).hexdigest(),
                                                  "sha256": hashlib.sha256(data).hexdigest()})
algo = {"Files:": "md5", "Checksums-Md5:": "md5", "Checksums-Sha1:": "sha1", "Checksums-Sha256:": "sha256"}
out, sec = [], None
for line in open(target, encoding="utf-8").read().split("\n"):
    if line and not line.startswith(" "):
        sec = algo.get(line.split()[0])
    elif sec and line.split() and line.split()[-1] in info:
        f = line.split(); size, sums = info[f[-1]]
        f[0], f[1] = sums[sec], size
        line = " " + " ".join(f)
    out.append(line)
open(target, "w", encoding="utf-8").write("\n".join(out))
PY
}
deb_sign() {  # deb_sign <_source.changes>
  local ch="$1" dir dsc bi
  dir="$(dirname "$ch")"
  dsc="$(awk '/^Files:/ { f = 1; next } /^[^ ]/ { f = 0 } f && /\.dsc$/ { print $NF; exit }' "$ch")"
  bi="$(awk '/^Files:/ { f = 1; next } /^[^ ]/ { f = 0 } f && /\.buildinfo$/ { print $NF; exit }' "$ch")"
  [ -n "$dsc" ] && clearsign "$dir/$dsc" || return 1
  if [ -n "$bi" ]; then deb_resum "$dir/$bi" "$dir/$dsc" && clearsign "$dir/$bi" || return 1; fi
  deb_resum "$ch" "$dir/$dsc" ${bi:+"$dir/$bi"} && clearsign "$ch"
}
note "gpg may ask for your key's passphrase"
deb_sign "$WD/out/$CHANGES" || die "signing $CHANGES failed"
gpgx --verify "$WD/out/$CHANGES" >/dev/null 2>&1 || die "the signature on $CHANGES doesn't verify"
ok "signed with $KEY"

# --- the upload, with dput (Debian's own, in a container), as mentors.debian.net documents it
dput_upload() {
  "$RUNTIME" run --rm -v "$WD/out:/up" -e CHANGES="$CHANGES" -e HOST_IDS="$HOST_IDS" "$DEB_IMAGE" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends dput gnupg ca-certificates >/dev/null
    gpg --batch --quiet --import /up/signing-key.asc 2>/dev/null || true
    printf "[mentors]\nfqdn = mentors.debian.net\nincoming = /upload\nmethod = https\nallow_unsigned_uploads = 0\nprogress_indicator = 0\nallowed_distributions = .*\n" > ~/.dput.cf
    echo "==> dput mentors $CHANGES"
    dput mentors "/up/$CHANGES" || { echo "STORE-SUBMIT: dput failed"; exit 6; }
    [ -z "$HOST_IDS" ] || chown -R "$HOST_IDS" /up
    echo "STORE-SUBMIT: OK"'
}
[ -n "${MENTORS_HAS:-}" ] && note "mentors.debian.net has ${MENTORS_HAS#*|} from you — this upload takes its place"
go "Upload $DEB_NAME $DEB_VER to mentors.debian.net?" || { note "the signed files are in $WD/out"; exit 0; }
gpgx --armor --export "$KEY" > "$WD/out/signing-key.asc"
run_logged "$WORK/dput.log" "uploading to mentors.debian.net (dput)" dput_upload && grep -q "STORE-SUBMIT: OK" "$WORK/dput.log" \
  || { grep -vE '^\s*$' "$WORK/dput.log" | tail -n 8 | sed 's/^/     /'; KEEP_WORK=1; die "the upload failed — the signed files are in $WD/out"; }
rm -f "$WD/out/signing-key.asc"
ok "uploaded"
say "mentors.debian.net checks the upload (and mails you either way)…"
SEEN=""
for _ in $(seq 1 24); do
  SEEN="$(curl -sf --max-time 30 "$MENTORS/api/packages/?name=$DEB_NAME" | python3 -c 'import json,sys
for p in json.load(sys.stdin):
    for v in p.get("versions", {}).values(): print(v)
    print("needs_sponsor=%s" % p.get("needs_sponsor"))' 2>/dev/null || true)"
  printf '%s\n' "$SEEN" | grep -qxF -e "$DEB_VER" -e "$FVER" && break
  sleep 5
done
if printf '%s\n' "$SEEN" | grep -qxF -e "$DEB_VER" -e "$FVER"; then ok "on mentors.debian.net: $MENTORS/package/$DEB_NAME/"
else warn "mentors.debian.net doesn't list it yet — if its mail says rejected, the usual cause: the key isn't the one in your account"; fi

# ================================================================ 7. sponsor
step "7/7  A sponsor"
DGET="$MENTORS/debian/pool/main/$(pool_dir "$DEB_NAME")/${DEB_NAME}_${FVER}.dsc"
awk '/^Changes:/ { f = 1; next } f && /^[^ ]/ { exit } f { l[++n] = $0 }
     END { while (n > 0 && l[n] ~ /^ \.?$/) n--; for (i = 1; i <= n; i++) print l[i] }' "$WD/out/$CHANGES" > "$WORK/changes"
if [ -n "$RFS_BUG" ]; then
  # your request is open: the reviewers get a follow-up, not a new request
  RFS_FILE="$KEEP/rfs-followup.eml"; RFS_TO="$RFS_BUG@bugs.debian.org"; RFS_WHAT="a follow-up on your request #$RFS_BUG"
  WHAT=""
  [ "$ASSUME_YES" = 0 ] && ask_opt WHAT "What changed since your last upload? (for the reviewers; Enter to leave out)" ""
  {
    case " $RFS_TAGS " in *" moreinfo "*) printf 'Control: tags -1 - moreinfo\n\n' ;; esac
    printf 'Hi,\n\nI have uploaded %s %s to mentors.debian.net:\n\n  %s/package/%s/\n\n' "$DEB_NAME" "$DEB_VER" "$MENTORS" "$DEB_NAME"
    printf "Alternatively, download it with 'dget':\n\n  dget -x %s\n\n" "$DGET"
    [ -n "$WHAT" ] && printf '%s\n\n' "$WHAT" | fold -s -w 72 | sed 's/[[:space:]]*$//'
    printf 'Changes since the last upload:\n\n'; cat "$WORK/changes"
    printf '\nRegards,\n-- \n  %s\n' "$MAINT_NAME"
  } > "$WORK/rfs-body"
  mail_write "$RFS_FILE" "$RFS_TO" "Re: $RFS_SUBJECT" "$WORK/rfs-body"
else
  # the request mentors.debian.net's how-to gives (rfs-howto)
  RFS_FILE="$KEEP/rfs.eml"; RFS_TO="submit@bugs.debian.org"; RFS_WHAT="your request for a sponsor (RFS)"
  SEV=wishlist; TAGS=" [ITP]"; [ "$MODE" = update ] && { SEV=normal; TAGS=""; }
  {
    printf 'Package: sponsorship-requests\nSeverity: %s\n\nDear mentors,\n\n' "$SEV"
    printf 'I am looking for a sponsor for my package "%s":\n\n' "$DEB_NAME"
    printf ' * Package name     : %s\n   Version          : %s\n' "$DEB_NAME" "$DEB_VER"
    printf '   Upstream contact : %s <%s>\n * URL              : %s\n' "$MAINT_NAME" "$MAINT_EMAIL" "$HOMEPAGE"
    printf ' * License          : %s\n * Vcs              : %s\n' "${MAINLIC:-$SPDX}" "${VCS:-none yet}"
    printf '   Section          : %s\n\n' "$DEB_SECTION"
    printf 'The source builds the following binary packages:\n\n  %s - %s\n\n' "$DEB_NAME" "$DEB_SYNOPSIS"
    printf 'To access further information about this package, please visit the following URL:\n\n  %s/package/%s/\n\n' "$MENTORS" "$DEB_NAME"
    printf "Alternatively, you can download the package with 'dget' using this command:\n\n  dget -x %s\n\n" "$DGET"
    printf 'Changes since the last upload:\n\n'; cat "$WORK/changes"
    printf '\nRegards,\n-- \n  %s\n' "$MAINT_NAME"
  } > "$WORK/rfs-body"
  mail_write "$RFS_FILE" "$RFS_TO" "RFS: $DEB_NAME/$DEB_VER$TAGS -- $DEB_SYNOPSIS" "$WORK/rfs-body"
fi
say "$RFS_WHAT:"
echo; sed 's/^/     /' "$RFS_FILE"; echo
SENT=0
if can_mail; then
  confirm "Edit it first (in ${EDITOR:-vi})?" n && "${EDITOR:-vi}" "$RFS_FILE"
  if go "Send it to $RFS_TO, from $MAINT_EMAIL (with ${MAILER[0]##*/})?"; then
    if mail_send "$RFS_FILE"; then SENT=1; ok "sent — the bug tracker copies it to debian-mentors"
    else warn "sending failed: $(tail -n 2 "$WORK/mail.log" | tr '\n' ' ')"; fi
  fi
elif [ "$ASSUME_YES" = 1 ]; then note "--yes: mail in your name isn't sent for you"
else note "this machine has no mail setup the wizard can use (msmtp or sendmail)"; fi

[ "$SENT" = 1 ] || handoff_add "Send $RFS_WHAT: a plain-text mail from $MAINT_EMAIL; To, Subject and text are in $RFS_FILE"
printf '%s\n' "$SEEN" | grep -qx "needs_sponsor=False" \
  && handoff_add "On $MENTORS/package/$DEB_NAME/ (logged in), switch on \"Needs a sponsor\" — it puts the package on mentors' front page"
handoff_add "Follow the RFS bug (or the debian-mentors list) and answer the reviewers there; for changes, edit $KEEP/debian and run linux-submit.sh debian again — it uploads again and writes the follow-up"
if [ "$MODE" = new ]; then
  handoff_add "Once a sponsor uploads it, it waits in the NEW queue for the FTP masters' review (often weeks; they read debian/copyright closely): https://ftp-master.debian.org/new.html"
  handoff_add "Then it's in Debian unstable, reaches testing days later, and Ubuntu takes it at its next import — Mint, Pop!_OS and the rest follow Ubuntu"
else
  handoff_add "Tell your previous sponsor about it too — they may upload it right away"
fi
[ "$TESTED" = 1 ] || handoff_add "It wasn't test-built here: build it once with podman or docker before a sponsor does (run without --no-test)"
handoff_show "Your turn — Debian needs a sponsor to upload $DEB_NAME $DEB_VER" "$MENTORS/package/$DEB_NAME/"
}

# ##########################################################################
#   RPM — shared by the Fedora COPR, Fedora and openSUSE (OBS) wizards: the
#   .spec writer, vendoring, the offline test build in a Fedora or openSUSE
#   container, and the COPR helpers both Fedora wizards use. Needs
#   linux_common and linux_app's globals.
# ##########################################################################
RPM_FEDORA_IMG="${RPM_FEDORA_IMAGE:-registry.fedoraproject.org/fedora}"   # + :<release>
RPM_SUSE_IMG="${RPM_SUSE_IMAGE:-registry.opensuse.org/opensuse/tumbleweed:latest}"
COPR_URL="${COPR_URL:-https://copr.fedorainfracloud.org}"
COPR_DL="${COPR_DL:-https://download.copr.fedorainfracloud.org/results}"
COPR_CONF_FILE="${COPR_CONFIG:-$HOME/.config/copr}"   # copr-cli's own login

# rpm_kind_ok — refuse early what can't become an RPM: the build servers of
# Fedora, COPR and OBS have no internet, so everything must be in the sources
rpm_kind_ok() {
  case "$KIND" in
    flutter) die "Fedora and openSUSE have no Flutter SDK and their build servers are offline — a Flutter app can't be built as an RPM. Their users get it from Flathub (both ship Flatpak) or the Snap Store" ;;
  esac
  if [ "$KIND" = python ] && at "$TAG_REF" pyproject.toml | grep -qiE 'maturin|setuptools[-_]rust'; then
    die "this Python package compiles Rust code (maturin) — its crates would have to be vendored as well, which this wizard doesn't do. Fedora and openSUSE users can install it with pipx, or get it from Flathub"
  fi
  return 0
}

# rpm_tools — the helpers the container runs: %files from what the build
# installed (files.py), the placeholders filled in (finalize.py), and the
# build itself (build.sh) and the install check (try.sh)
rpm_tools() {
  mkdir -p "$WORK/rpm-tools"
  cat > "$WORK/rpm-tools/files.py" <<'PY'
import os, re, sys
# files.py <list: TYPE<tab>/path> <flavor: copr|fedora|suse> <name> <kind>
# What the probe build installed -> %files lines and the bits that go with
# them, one "KEY<tab>value" per line: BIN FILES DEVEL LANG BR REQ CHECK
# INSTALL NOTE PYMOD PYLIC.
lst, flavor, name, kind = sys.argv[1:5]
suse = flavor == "suse"
entries = []
for line in open(lst):
    t, _, p = line.rstrip("\n").partition("\t")
    if p:
        entries.append((t, p))

# directories other packages own: what is under them is listed file by file
SHARED = set("""/ /etc /etc/xdg /etc/xdg/autostart /etc/profile.d /etc/bash_completion.d /usr /usr/bin /usr/sbin
/usr/lib /usr/lib64 /usr/libexec /usr/include /usr/share /usr/share/applications /usr/share/metainfo
/usr/share/appdata /usr/share/pixmaps /usr/share/icons /usr/share/man /usr/share/locale /usr/share/doc
/usr/share/licenses /usr/share/info /usr/share/help /usr/share/glib-2.0 /usr/share/glib-2.0/schemas
/usr/share/dbus-1 /usr/share/dbus-1/services /usr/share/dbus-1/system-services /usr/share/dbus-1/system.d
/usr/share/mime /usr/share/mime/packages /usr/share/bash-completion /usr/share/bash-completion/completions
/usr/share/zsh /usr/share/zsh/site-functions /usr/share/fish /usr/share/fish/vendor_completions.d
/usr/share/fish/vendor_functions.d /usr/lib/systemd /usr/lib/systemd/system /usr/lib/systemd/user
/usr/lib/udev /usr/lib/udev/rules.d /usr/lib/sysusers.d /usr/lib/tmpfiles.d /usr/lib64/pkgconfig
/usr/lib/pkgconfig /usr/share/pkgconfig /usr/share/gir-1.0 /usr/lib64/girepository-1.0 /usr/share/vala
/usr/share/vala/vapi /usr/share/polkit-1 /usr/share/polkit-1/actions /usr/share/polkit-1/rules.d
/usr/share/thumbnailers /usr/share/gnome-shell /usr/share/gnome-shell/search-providers /usr/share/sounds
/usr/share/fonts /usr/share/themes /usr/lib/node_modules /usr/share/X11 /usr/share/kio /usr/share/krunner
/usr/share/kservices5 /usr/share/kservices6 /usr/share/qlogging-categories6 /usr/lib/cmake /usr/lib64/cmake""".split())
# on openSUSE nothing else owns these: a package that installs into them owns them too
SUSE_OWN = ["/usr/share/zsh", "/usr/share/zsh/site-functions", "/usr/share/fish",
            "/usr/share/fish/vendor_completions.d", "/usr/share/fish/vendor_functions.d",
            "/usr/share/bash-completion", "/usr/share/bash-completion/completions"]

def shared(d):
    return (d in SHARED or re.match(r"^/usr/share/(icons/hicolor|man|locale|help)(/|$)", d)
            or re.match(r"^/usr/lib(64)?/python3\.\d+(/site-packages)?$", d))

MAP = [("/usr/share/bash-completion/completions", "%{_datadir}/bash-completion/completions" if suse else "%{bash_completions_dir}"),
       ("/usr/share/zsh/site-functions", "%{_datadir}/zsh/site-functions" if suse else "%{zsh_completions_dir}"),
       ("/usr/share/fish/vendor_completions.d", "%{_datadir}/fish/vendor_completions.d" if suse else "%{fish_completions_dir}"),
       ("/usr/share/metainfo", "%{_datadir}/metainfo" if suse else "%{_metainfodir}"),
       ("/usr/lib/systemd/system", "%{_unitdir}"), ("/usr/lib/systemd/user", "%{_userunitdir}"),
       ("/usr/lib/node_modules", "%{_prefix}/lib/node_modules" if suse else "%{nodejs_sitelib}"),
       ("/usr/share/man", "%{_mandir}"), ("/usr/share/doc", "%{_docdir}"), ("/usr/share/licenses", "%{_defaultlicensedir}"),
       ("/usr/share/info", "%{_infodir}"), ("/usr/share", "%{_datadir}"), ("/usr/include", "%{_includedir}"),
       ("/usr/libexec", "%{_libexecdir}"), ("/usr/lib64", "%{_libdir}"), ("/usr/lib", "%{_prefix}/lib"),
       ("/usr/bin", "%{_bindir}"), ("/usr/sbin", "%{_sbindir}"), ("/etc", "%{_sysconfdir}"),
       ("/var/lib", "%{_sharedstatedir}"), ("/var", "%{_localstatedir}"), ("/usr", "%{_prefix}")]
def macro(p):
    for pre, m in MAP:
        if p == pre or p.startswith(pre + "/"):
            return m + p[len(pre):]
    return p

out = {k: [] for k in ("BIN", "FILES", "DEVEL", "LANG", "BR", "REQ", "CHECK", "INSTALL", "NOTE", "PYMOD", "PYLIC")}
def add(k, v):
    if v not in out[k]:
        out[k].append(v)

def top_new_dir(p):
    """the highest directory above p that no other package owns"""
    d, top = os.path.dirname(p), None
    while d and d != "/" and not shared(d):
        top, d = d, os.path.dirname(d)
    return top

SITE = re.compile(r"^/usr/lib(64)?/python3\.\d+/site-packages/([^/]+)(/.*)?$")
desktop = metainfo = icons = False
pylic = False
for t, p in sorted(entries):
    if t == "d" or re.match(r"^/usr/(lib/debug|src/debug|lib/\.build-id)(/|$)", p):
        continue
    m = SITE.match(p)
    if m:
        top = m.group(2)
        if top.endswith((".dist-info", ".egg-info")):
            if "/licenses/" in p or re.search(r"/(LICEN[CS]E|COPYING)", p):
                pylic = True
            if suse:
                add("FILES", "%%{python3_sitelib}/%s/" % re.sub(r"-[^-]+\.(dist|egg)-info$", r"-%{version}.\1-info", top))
            continue
        if top == "__pycache__":
            mod = os.path.basename(p).split(".")[0]
            if suse:
                add("FILES", "%%{python3_sitelib}/__pycache__/%s.*" % mod)
            continue
        mod = top[:-3] if top.endswith(".py") else top
        if mod.endswith(".pth") or top.endswith(".so"):
            mod = top
        add("PYMOD", mod)
        if suse:
            add("FILES", "%%{python3_sitelib}/%s%s" % (top, "/" if m.group(3) else ""))
        continue
    if kind == "go" and p.startswith("/usr/share/licenses/" + name + "/"):
        continue                                          # %{go_vendor_license_filelist}
    if re.search(r"\.(la|a)$", p) and p.startswith(("/usr/lib/", "/usr/lib64/")):
        add("INSTALL", "find %{buildroot} -name '*.la' -delete" if p.endswith(".la") else "find %{buildroot}%{_libdir} -name '*.a' -delete")
        add("NOTE", "static or libtool libraries are deleted (" + os.path.basename(p) + ") — distributions ship shared ones")
        continue
    m = re.match(r"^/usr/share/locale/[^/]+/LC_MESSAGES/(.+)\.mo$", p)
    if m:
        add("LANG", m.group(1)); continue
    m = re.match(r"^/usr/share/help/[^/]+/([^/]+)/", p)
    if m:
        add("LANG", m.group(1) + " --with-gnome"); continue
    m = re.match(r"^/usr/share/icons/hicolor/[^/]+/([^/]+)/([^/]+?)(-symbolic)?\.(png|svg|xpm)$", p)
    if m:
        icons = True
        add("FILES", "%%{_datadir}/icons/hicolor/*/%s/%s%s.*" % (m.group(1), m.group(2), m.group(3) or ""))
        continue
    m = re.match(r"^/usr/share/man/(man[^/]+)/(.+?)(\.(gz|bz2|xz|zst))?$", p)
    if m:
        add("FILES", "%%{_mandir}/%s/%s*" % (m.group(1), m.group(2))); continue
    if re.match(r"^/usr/share/applications/[^/]+\.desktop$", p):
        desktop = True
    if re.match(r"^/usr/share/(metainfo|appdata)/[^/]+\.xml$", p):
        metainfo = True
        if p.startswith("/usr/share/appdata/"):
            add("NOTE", p + " is in the old appdata/ directory — metainfo/ is where it belongs now")
    if re.match(r"^/usr/(lib|lib64)/systemd/", p):
        add("NOTE", "systemd units are installed — add the %systemd_* scriptlets (Fedora: Scriptlets guideline)")
    if p.startswith(("/usr/bin/", "/usr/sbin/")):
        add("BIN", os.path.basename(p))
    # development files go to -devel
    if (p.startswith("/usr/include/") or re.match(r"^/usr/(lib64|lib|share)/pkgconfig/[^/]+\.pc$", p)
            or re.match(r"^/usr/lib(64)?/lib[^/]+\.so$", p) or p.startswith(("/usr/share/gir-1.0/", "/usr/share/vala/vapi/"))
            or re.match(r"^/usr/lib(64)?/cmake/", p)):
        top = top_new_dir(p)
        add("DEVEL", macro(top) + "/" if top else macro(p)); continue
    m = re.match(r"^(/usr/lib(64)?/lib[^/]+\.so)\.(\d+)", p)
    if m and os.path.dirname(p) in ("/usr/lib", "/usr/lib64"):
        add("FILES", macro(m.group(1)) + "." + m.group(3) + "{,.*}"); continue
    if suse:
        for d in SUSE_OWN:
            if p.startswith(d + "/"):
                for dd in SUSE_OWN:
                    if d == dd or d.startswith(dd + "/"):
                        add("FILES", "%dir " + macro(dd))
    top = top_new_dir(p)
    if top:
        if top.startswith("/usr/lib/node_modules/@") and top.count("/") == 4:
            add("FILES", "%dir " + macro(top))
            top = "/".join(p.split("/")[:6])
        add("FILES", macro(top) + "/")
    elif p.startswith("/etc/"):
        add("FILES", "%config(noreplace) " + macro(p))
    else:
        add("FILES", macro(p))

if desktop:
    add("BR", "desktop-file-utils")
    add("CHECK", "desktop-file-validate %{buildroot}%{_datadir}/applications/*.desktop")
if metainfo:
    add("BR", "appstream-glib" if suse else "libappstream-glib")
    add("CHECK", "appstream-util validate-relax --nonet %s/*.xml" % ("%{buildroot}%{_datadir}/metainfo" if suse else "%{buildroot}%{_metainfodir}"))
if icons:
    add("BR" if suse else "REQ", "hicolor-icon-theme")
if pylic:
    add("PYLIC", "1")
# the %dir lines first, then the rest in a stable order
out["FILES"].sort(key=lambda f: (not f.startswith("%dir "), f))
for k in ("BIN", "FILES", "DEVEL", "LANG", "BR", "REQ", "CHECK", "INSTALL", "NOTE", "PYMOD", "PYLIC"):
    for v in out[k]:
        print("%s\t%s" % (k, v))
PY
  cat > "$WORK/rpm-tools/finalize.py" <<'PY'
import re, sys
# finalize.py <spec> <files.py output> <flavor> <kind> — the spec with its
# "# @…@" placeholders filled in from what the probe build installed
spec_path, files_out, flavor, kind = sys.argv[1:5]
suse = flavor == "suse"
spec = open(spec_path).read()
out = {}
for line in open(files_out):
    k, _, v = line.rstrip("\n").partition("\t")
    if v:
        out.setdefault(k, []).append(v)
get = lambda k: out.get(k, [])

# build and runtime dependencies the installed files call for
add = "".join("BuildRequires:  %s\n" % b for b in get("BR") if not re.search(r"^BuildRequires:\s+%s\s*$" % re.escape(b), spec, re.M))
add += "".join("Requires:       %s\n" % r for r in get("REQ"))
spec = spec.replace("# @BR@\n", add)

# translations: one %find_lang per domain, gathered in the first one's list
inst, doms = [], {}
for l in get("LANG"):
    d, _, flag = l.partition(" ")
    doms.setdefault(d, set())
    if flag:
        doms[d].add(flag)
lang = None
for d in sorted(doms):
    inst.append("%%find_lang %s%s" % (d, "".join(" " + f for f in sorted(doms[d]))))
    if lang is None:
        lang = d + ".lang"
    else:
        inst.append("cat %s.lang >> %s" % (d, lang))
inst += get("INSTALL")
spec = spec.replace("# @INSTALL@\n", "".join(x + "\n" for x in inst))
spec = spec.replace("# @CHECK@\n", "".join(x + "\n" for x in get("CHECK")))

# Rust: each executable installed by name (the guidelines' way for apps)
bins = get("BIN")
if kind == "rust" and bins:
    def inst_bins(m):
        d = m.group(1)
        return "".join("install -Dpm 0755 target/%s/%s -t %%{buildroot}%%{_bindir}\n" % (d, b) for b in bins)
    spec = re.sub(r"^find target/(rpm|release) -maxdepth 1 .*\n", inst_bins, spec, flags=re.M)

# Python: the modules by name (Fedora: '*' isn't allowed outside automation)
if kind == "python" and not suse and get("PYMOD"):
    flag = "-l" if get("PYLIC") else "-L"
    spec = re.sub(r"^%pyproject_save_files .*$", "%%pyproject_save_files %s %s" % (flag, " ".join(get("PYMOD"))), spec, flags=re.M)

files = get("FILES")
# the app installs its own docs: then %doc with relative paths must go
if any(f.startswith("%{_docdir}/") for f in files):
    spec = re.sub(r"^%doc .*\n", "", spec, flags=re.M)
if lang:
    spec = re.sub(r"^(%files)( .*)?$", lambda m: m.group(1) + (m.group(2) or "") + " -f " + lang, spec, count=1, flags=re.M)
spec = spec.replace("# @FILES@\n", "".join(f + "\n" for f in files))

# headers, pkg-config files and .so links: a -devel package
devel = get("DEVEL")
if devel:
    req = "%{name}%{?_isa} = %{version}-%{release}" if not suse else "%{name} = %{version}"
    sub = ("%%package devel\nSummary:        Development files for %%{name}\nRequires:       %s\n\n"
           "%%description devel\nDevelopment files for %%{name}.\n\n" % req)
    spec = spec.replace("# @SUBPKG@\n", sub)
    spec = re.sub(r"^%changelog", "%files devel\n" + "".join(d + "\n" for d in devel) + "\n%changelog", spec, count=1, flags=re.M)
else:
    spec = spec.replace("# @SUBPKG@\n", "")
spec = re.sub(r"\n{3,}", "\n\n", spec)
sys.stdout.write(spec)
for n in get("NOTE"):
    sys.stderr.write("NOTE: %s\n" % n)
PY
  cat > "$WORK/rpm-tools/build.sh" <<'SH'
#!/bin/bash
# In the container: /w holds the spec and its sources, /tools these helpers.
# Build dependencies are installed with the network on, then it's cut and the
# package is built offline, like Fedora's, COPR's and OBS's builders do.
set -e
export LANG=C.UTF-8
SPEC="/w/${SPECNAME:-$PNAME}.spec"; T=/root/rpmbuild
D=(--define "_topdir $T" --define "_sourcedir /w")
mkdir -p /w/out "$T"
# bspec — the spec rpmbuild reads: on openSUSE, %changelog comes from the
# .changes file the way OBS fills it in; the spec itself keeps it empty
BSPEC="/tmp/bspec/${SPECNAME:-$PNAME}.spec"   # named like the package: rpmlint checks the SRPM's spec name
if [ "$FLAVOR" = suse ] && [ -f "/w/$PNAME.changes" ]; then
  # like OBS: the build runs with SOURCE_DATE_EPOCH from the newest .changes entry
  SOURCE_DATE_EPOCH="$(date -u -d "$(sed -n '2s/ - .*//p' "/w/$PNAME.changes")" +%s 2>/dev/null || true)"
  [ -n "$SOURCE_DATE_EPOCH" ] && export SOURCE_DATE_EPOCH
fi
bspec() {
  mkdir -p /tmp/bspec; cp "$SPEC" "$BSPEC"
  [ "$FLAVOR" = suse ] && [ -f "/w/$PNAME.changes" ] && awk '
    /^-+$/ { getline; split($0, h, " - "); split(h[1], f, " "); printf "* %s %s %02d %s %s\n", f[1], f[2], f[3], f[6], h[2]; next }
    /^[[:space:]]*$/ { next } { print }' "/w/$PNAME.changes" >> "$BSPEC"
  return 0
}
fail() { echo "STORE-SUBMIT: $*"; [ -z "${OWNER:-}" ] || chown -R "$OWNER" /w 2>/dev/null || true; exit 3; }
missing() {  # what the package manager couldn't find, as MISSING: lines
  grep -oE "No match for argument: .*|nothing provides [^ ]+( [<>=]+ [^ ]+)?|No provider of '[^']+'|Unable to find a match: .*" "$1" \
    | sed -E "s/^No match for argument: //; s/^nothing provides //; s/^No provider of '([^']+)'/\1/; s/^Unable to find a match: //" \
    | sort -u | sed 's/^/MISSING: /' || true
}
if command -v dnf >/dev/null 2>&1; then
  PM=dnf
  dnf -y install --skip-unavailable rpm-build rpmlint python3 iproute desktop-file-utils libappstream-glib glibc-langpack-en $TOOLS > /tmp/tools.log 2>&1 \
    || { tail -5 /tmp/tools.log; fail "couldn't install rpm-build"; }
  if [ -n "${EXTRA_REPO:-}" ]; then
    printf '[store-submit-extra]\nname=%s\nbaseurl=%s\ngpgcheck=0\nskip_if_unavailable=True\n' "$EXTRA_REPO" "$EXTRA_REPO" > /etc/yum.repos.d/store-submit-extra.repo
  fi
else
  PM=zypper
  zypper -n --gpg-auto-import-keys ref > /tmp/tools.log 2>&1 || true
  for i in 1 2 3; do
    zypper -n in --no-recommends rpm-build rpmlint python3 iproute2 desktop-file-utils appstream-glib $TOOLS >> /tmp/tools.log 2>&1 && break
    [ "$i" = 3 ] && { tail -5 /tmp/tools.log; fail "couldn't install rpm-build"; }
  done
fi
if [ "${FETCH:-0}" = 1 ]; then
  # your own spec: its sources downloaded from where it says
  if [ "$PM" = dnf ]; then dnf -y -q install rpmdevtools > /dev/null 2>&1 || true; else zypper -n -q in rpmdevtools > /dev/null 2>&1 || true; fi
  spectool -g -C /w "$SPEC" > /w/out/fetch.log 2>&1 || { tail -5 /w/out/fetch.log; fail "couldn't download the spec's sources (spectool -g)"; }
fi
if [ "${MODE:-build}" = srpm ]; then
  # no test build: the %files list is the wizard's guess
  if grep -q '^# @FILES@' "$SPEC"; then
    python3 /tools/finalize.py "$SPEC" /w/out/files.guess "$FLAVOR" "$KIND" > /w/out/final.spec 2> /w/out/notes.txt || fail "couldn't finish the spec"
    cp /w/out/final.spec "$SPEC"
  fi
  rm -f /w/out/*.rpm
  bspec; rpmbuild -bs --nodeps "${D[@]}" "$BSPEC" > /w/out/srpm.log 2>&1 || { tail -8 /w/out/srpm.log; fail "the SRPM couldn't be made"; }
  cp $T/SRPMS/*.src.rpm /w/out/
  [ -z "${OWNER:-}" ] || chown -R "$OWNER" /w
  echo "STORE-SUBMIT: OK"; exit 0
fi
echo "==> source package"
bspec; rpmbuild -bs --nodeps "${D[@]}" "$BSPEC" > /w/out/srpm.log 2>&1 || { tail -8 /w/out/srpm.log; fail "the SRPM couldn't be made"; }
echo "==> build dependencies"
# with their documentation, like the build servers: the images leave docs out
# (tsflags=nodocs, excludedocs), and some builds read them (include_str!)
if [ "$PM" = dnf ]; then
  dnf -y --setopt=tsflags= builddep $T/SRPMS/*.src.rpm > /tmp/bd.log 2>&1 || { missing /tmp/bd.log; tail -5 /tmp/bd.log; fail "build dependencies not installable"; }
  # %generate_buildrequires: rpmbuild names them (exit 11), dnf installs them
  rc=0
  for _ in 1 2 3 4 5 6 7 8; do
    rc=0; bspec; rpmbuild -br "${D[@]}" "$BSPEC" > /tmp/br.log 2>&1 || rc=$?
    [ "$rc" = 11 ] || break
    dnf -y --setopt=tsflags= builddep $T/SRPMS/*.buildreqs.nosrc.rpm > /tmp/bd.log 2>&1 || { missing /tmp/bd.log; tail -5 /tmp/bd.log; fail "build dependencies not installable"; }
    rm -f $T/SRPMS/*.buildreqs.nosrc.rpm
  done
  [ "$rc" = 0 ] || { tail -15 /tmp/br.log; fail "the build dependencies couldn't be worked out (rpmbuild -br)"; }
else
  for c in /etc/zypp/zypp.conf /usr/etc/zypp/zypp.conf; do
    [ -f "$c" ] && grep -qE '^[[:space:]]*rpm\.install\.excludedocs[[:space:]]*=[[:space:]]*yes' "$c" || continue
    sed -E 's/^[[:space:]]*rpm\.install\.excludedocs[[:space:]]*=.*/rpm.install.excludedocs = no/' "$c" > /tmp/zypp.conf
    mkdir -p /etc/zypp && cp /tmp/zypp.conf /etc/zypp/zypp.conf; break
  done
  mapfile -t BRS < <(rpmspec -q --buildrequires "${D[@]}" "$SPEC" 2>/dev/null | sed 's/ //g')
  for i in 1 2 3; do
    [ "${#BRS[@]}" -gt 0 ] || break
    zypper -n in --no-recommends "${BRS[@]}" > /tmp/bd.log 2>&1 && break
    grep -q "No provider of" /tmp/bd.log && i=3   # a missing package won't appear by retrying
    [ "$i" = 3 ] && { missing /tmp/bd.log; tail -5 /tmp/bd.log; fail "build dependencies not installable"; }
  done
fi
# like the build servers: no network from here on
for n in $(ls /sys/class/net 2>/dev/null); do
  [ "$n" = lo ] || ip link set "$n" down || fail "couldn't take the network down for the offline build"
done
echo "==> building offline"
if grep -q '^# @FILES@' "$SPEC"; then
  # what %install installs decides the %files list (a copy without %doc and
  # %license, which rpm would copy into the buildroot too), then the rest is done
  rm -rf /tmp/br
  bspec; sed -e '/^%doc /d' -e '/^%license /d' "$BSPEC" > /tmp/probe.spec
  rpmbuild -bi --nocheck "${D[@]}" --define "_unpackaged_files_terminate_build 0" --buildroot /tmp/br /tmp/probe.spec > /w/out/probe.log 2>&1 || { cp /w/out/probe.log /w/out/build.log; fail "the build failed"; }
  (cd /tmp/br && find . -mindepth 1 \( -type d -printf 'd\t/%P\n' \) -o \( ! -type d -printf 'f\t/%P\n' \)) > /w/out/files.txt
  python3 /tools/files.py /w/out/files.txt "$FLAVOR" "$PNAME" "$KIND" > /w/out/files.out || fail "couldn't read what the build installed"
  python3 /tools/finalize.py "$SPEC" /w/out/files.out "$FLAVOR" "$KIND" > /w/out/final.spec 2> /w/out/notes.txt || fail "couldn't finish the spec"
  cp /w/out/final.spec "$SPEC"
  # packages from a short-circuited build can't be installed: a full build,
  # the way the build servers do it
  echo "==> building again with the final spec"
fi
bspec; rpmbuild -bb "${D[@]}" "$BSPEC" > /w/out/build.log 2>&1 || fail "the build failed"
rm -f $T/SRPMS/*.rpm /w/out/*.rpm
bspec; rpmbuild -bs --nodeps "${D[@]}" "$BSPEC" >> /w/out/srpm.log 2>&1 || fail "the SRPM couldn't be made"
cp $T/SRPMS/*.src.rpm /w/out/
find $T/RPMS -name '*.rpm' -exec cp {} /w/out/ \;
echo "==> rpmlint"
LINT=$(ls /w/out/*.rpm); [ "$FLAVOR" = suse ] && LINT=$(ls /w/out/*.rpm | grep -vE -- '-debug(info|source)-')
rpmlint "$SPEC" $LINT 2>&1 | sed 's/^/RPMLINT: /' || true
[ -z "${OWNER:-}" ] || chown -R "$OWNER" /w
echo "STORE-SUBMIT: OK"
SH
  cat > "$WORK/rpm-tools/try.sh" <<'SH'
#!/bin/bash
# In the container, network on: install the built packages the way users
# will (dependencies from the distro), then run the program.
set -e
cd /w/out
PKGS=$(ls ./*.rpm | grep -vE '\.src\.rpm$|-debug(info|source)-')
if command -v dnf >/dev/null 2>&1; then
  dnf -y install ${EXTRA_REPO:+--repofrompath=extra,$EXTRA_REPO --setopt=extra.gpgcheck=0} $PKGS > /tmp/i.log 2>&1 \
    || { grep -E "nothing provides|No match|conflicts with" /tmp/i.log | sed 's/^/MISSING: /'; tail -5 /tmp/i.log; echo "STORE-SUBMIT: not installable"; exit 4; }
else
  zypper -n --gpg-auto-import-keys ref > /dev/null 2>&1 || true
  zypper -n in --no-recommends --allow-unsigned-rpm $PKGS > /tmp/i.log 2>&1 \
    || { grep -E "nothing provides|No provider|conflicts with" /tmp/i.log | sed 's/^/MISSING: /'; tail -5 /tmp/i.log; echo "STORE-SUBMIT: not installable"; exit 4; }
fi
rpm -ql $(rpm -qp --qf '%{name}\n' $PKGS) 2>/dev/null | grep -E '^/usr/s?bin/.' | sed 's/^/BIN: /' || true
if [ -n "${MAIN:-}" ] && command -v "$MAIN" >/dev/null 2>&1; then
  echo "==> $MAIN --version"
  timeout 10 "$MAIN" --version < /dev/null 2>&1 | head -3 | sed 's/^/VERSION: /' || echo "STORE-SUBMIT: $MAIN --version failed"
fi
echo "STORE-SUBMIT: OK"
SH
}

# rpm_owner — who files written in a container should belong to: with docker
# (root) that's you; rootless podman's root already is you, so nothing
rpm_owner() { [ "$RUNTIME" = docker ] && printf '%s:%s' "$(id -u)" "$(id -g)"; return 0; }

# rpm_about — the %description: yours from the config, else the README's
# first paragraph of prose (no HTML, badges, images or headings; markdown
# taken out), else the one-line description
rpm_about() {
  local a; a="$(cfg_get about)"
  [ -n "$a" ] || a="$(for f in README.md README README.rst; do at "$TAG_REF" "$(pp "$f")" && break; done 2>/dev/null | python3 -c '
import re, sys, unicodedata
lines = [l.strip() for l in sys.stdin.read().splitlines()][:80]
para, fence, prev = [], False, ""
for i, l in enumerate(lines):
    if l.startswith(("```", "~~~")):
        fence = not fence
    nxt = lines[i + 1] if i + 1 < len(lines) else ""
    prose = (not fence and bool(l) and re.match(r"^([A-Za-z0-9\"(`]|\*\*?\w)", l) and not re.search(r"<[A-Za-z/!][^>]*>", l)
             and not re.match(r"^[=~^-]{3,}$", nxt) and not re.match(r"^\S+$", l))
    if prose and (para or not prev):
        para.append(l)
    elif para:
        j = " ".join(para)
        # a description: six words or more, not an instruction leading into code
        if len(j.split()) >= 6 and not j.endswith(":") and not re.match(r"(?i)(to )?(install|run|download|build|usage|see|clone)\b", j):
            break
        para = []
    prev = l
else:
    j = " ".join(para)
    if len(j.split()) < 6 or j.endswith(":"):
        para = []
t = " ".join(para)
t = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", t)
t = re.sub(r"(\*\*|\*|`)([^*`]+)\1", r"\2", t)
t = "".join(c for c in t if unicodedata.category(c) not in ("So", "Cn", "Co") and not 0xFE00 <= ord(c) <= 0xFE0F and c != "\u200d")
t = re.sub(r"\s+([.,;:!?])", r"\1", " ".join(t.split()))
print(t[:700], end="")' 2>/dev/null || true)"
  [ -n "$a" ] || a="$(clean_desc "$(printf '%s' "${FORGE_DESC:-}" | python3 -c 'import sys, unicodedata; print(" ".join("".join(c for c in sys.stdin.read() if unicodedata.category(c) not in ("So", "Cn", "Co") and not 0xFE00 <= ord(c) <= 0xFE0F and c != "\u200d").split()), end="")' 2>/dev/null)")"
  [ -n "$a" ] && a="${a%.}."
  [ -n "$a" ] && [ "$a" != . ] || a="$DESC."
  printf '%s' "$a"
}
rpm_wrap() { printf '%s\n' "$1" | fold -s -w 79 | sed 's/[[:space:]]*$//'; }   # %description lines ≤ 79

# rpm_source — the release tarball: its URL for the spec ($SRC0, in terms of
# %{version}), the file in $RPM_WD ($SRC_FILE), the directory it unpacks to
# ($SRC_TOP). Downloaded from the forge, so it's the one reviewers compare.
rpm_source() {
  local tagx real top want
  case "$TAG" in
    "v$VERSION") tagx='v%{version}' ;;
    "$VERSION")  tagx='%{version}' ;;
    *)           tagx="$TAG" ;;
  esac
  [ "$RPM_VERSION" != "$VERSION" ] && tagx="$TAG"   # %{version} isn't the real version then
  SRC_FILE="$PNAME-$VERSION.tar.gz"; real=""
  case "$FORGE" in
    github)   SRC0="https://github.com/$SLUG/archive/$tagx/%{name}-%{version}.tar.gz"
              real="https://github.com/$SLUG/archive/$TAG/$SRC_FILE"; want="$REPONAME-${TAG#v}" ;;
    gitlab)   SRC0="https://gitlab.com/$SLUG/-/archive/$tagx/$REPONAME-$tagx.tar.gz#/%{name}-%{version}.tar.gz"
              real="https://gitlab.com/$SLUG/-/archive/$TAG/$REPONAME-$TAG.tar.gz"; want="$REPONAME-$TAG" ;;
    codeberg) SRC0="https://codeberg.org/$SLUG/archive/$tagx.tar.gz#/%{name}-%{version}.tar.gz"
              real="https://codeberg.org/$SLUG/archive/$TAG.tar.gz"; want="$REPONAME" ;;
    *)        SRC0="%{name}-%{version}.tar.gz"; want="$PNAME-$VERSION" ;;
  esac
  rm -f "$RPM_WD/$SRC_FILE"
  if [ -n "$real" ] && [ "${DRY_NO_TAG:-0}" != 1 ]; then
    run_logged "$WORK/download.log" "downloading $real" curl -fL --retry 3 -o "$RPM_WD/$SRC_FILE" "$real" \
      || { tail -n 3 "$WORK/download.log" | sed 's/^/     /'; die "couldn't download $real — is tag $TAG pushed?"; }
  else
    # no forge tarball (a dry run before the tag is pushed, or a plain git
    # host): made from the tag with git, laid out like the forge's
    [ -z "$real" ] && warn "no release tarball URL is known for ${HOST:-this git host} — the source is made with git archive (Fedora wants a URL in Source0)"
    git -C "$REPO" archive --format=tar.gz --prefix="$want/" "$TAG_REF" > "$RPM_WD/$SRC_FILE" || die "git archive failed"
  fi
  top="$(tar tzf "$RPM_WD/$SRC_FILE" 2>/dev/null | head -1 | cut -d/ -f1)"
  [ -n "$top" ] || die "$SRC_FILE is empty or not a tarball"
  SRC_TOP="$top"
  [ "$RPM_VERSION" = "$VERSION" ] && SRC_TOP="$(printf '%s' "$top" | sed "s/$(printf '%s' "$VERSION" | sed 's/[.]/\\./g')/%{version}/")"
  [ "$RPM_VERSION" != "$VERSION" ] && SRC0="$(printf '%s' "$SRC0" | sed "s/%{version}/$VERSION/g")"
  SRC_SHA="$(sha256sum "$RPM_WD/$SRC_FILE" | cut -d' ' -f1)"
  ok "source: ${real:-git archive of $TAG} → $top/ (sha256 ${SRC_SHA:0:16}…)"
}

# rpm_pcs — the pkg-config modules a Meson or CMake project asks for
rpm_pcs() {
  case "$KIND" in
    meson) for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done \
             | grep -oE "dependency\([[:space:]]*'[^']+'" | sed -E "s/.*'([^']+)'/\\1/" ;;
    cmake) for f in $(grep -E '(^|/)CMakeLists\.txt$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done | tr '\n' ' ' \
             | grep -oE 'pkg_check_modules\([^)]*\)' | sed -E 's/^pkg_check_modules\(//; s/\)$//' \
             | awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^(REQUIRED|QUIET|IMPORTED_TARGET|GLOBAL)$/) { m = $i; sub(/[<>=].*/, "", m); if (m != "") print m } }' ;;
  esac | grep -vxE 'threads|m|dl|rt|dependency|' | sort -u
}
# rpm_sys_br <crate> — the system library a Rust -sys crate links (pkg-config
# names, the same on Fedora and openSUSE)
rpm_sys_br() {
  case "$1" in
    openssl-sys) echo 'pkgconfig(openssl)' ;; alsa-sys) echo 'pkgconfig(alsa)' ;; libdbus-sys) echo 'pkgconfig(dbus-1)' ;;
    libudev-sys) echo 'pkgconfig(libudev)' ;; gtk4-sys) echo 'pkgconfig(gtk4)' ;; gtk-sys) echo 'pkgconfig(gtk+-3.0)' ;;
    libadwaita-sys) echo 'pkgconfig(libadwaita-1)' ;; webkit2gtk-sys) echo 'pkgconfig(webkit2gtk-4.1)' ;;
    javascriptcore-rs-sys) echo 'pkgconfig(javascriptcoregtk-4.1)' ;; soup3-sys) echo 'pkgconfig(libsoup-3.0)' ;;
    glib-sys) echo 'pkgconfig(glib-2.0)' ;; gio-sys) echo 'pkgconfig(gio-2.0)' ;; gobject-sys) echo 'pkgconfig(gobject-2.0)' ;;
    cairo-sys-rs) echo 'pkgconfig(cairo)' ;; pango-sys) echo 'pkgconfig(pango)' ;; gdk-pixbuf-sys) echo 'pkgconfig(gdk-pixbuf-2.0)' ;;
    graphene-sys) echo 'pkgconfig(graphene-gobject-1.0)' ;; gdk4-sys|gsk4-sys) echo 'pkgconfig(gtk4)' ;;
    libz-sys) echo 'pkgconfig(zlib)' ;; libssh2-sys) echo 'pkgconfig(libssh2)' ;; curl-sys) echo 'pkgconfig(libcurl)' ;;
    freetype-sys) echo 'pkgconfig(freetype2)' ;; servo-fontconfig-sys|yeslogic-fontconfig-sys) echo 'pkgconfig(fontconfig)' ;;
    expat-sys) echo 'pkgconfig(expat)' ;; wayland-sys) echo 'pkgconfig(wayland-client)' ;; libpulse-sys) echo 'pkgconfig(libpulse)' ;;
    pcre2-sys) echo 'pkgconfig(libpcre2-8)' ;; libsodium-sys) echo 'pkgconfig(libsodium)' ;; xkbcommon-sys) echo 'pkgconfig(xkbcommon)' ;;
    x11-sys|x11) echo 'pkgconfig(x11)' ;; libgit2-sys) echo 'pkgconfig(libgit2)' ;; sqlite3-sys|libsqlite3-sys) echo 'pkgconfig(sqlite3)' ;;
    libseccomp-sys) echo 'pkgconfig(libseccomp)' ;; hidapi) echo 'pkgconfig(hidapi-hidraw)' ;; libusb1-sys) echo 'pkgconfig(libusb-1.0)' ;;
    bindgen) echo 'clang-devel' ;;
  esac
}

# rpm_py_meta — what pyproject.toml says, as "key value" lines (backend,
# build, dep, script, name, scm), names normalised as python3dist() has them
rpm_py_meta() {
  at "$TAG_REF" pyproject.toml > "$WORK/pyproject.toml"
  python3 - "$WORK/pyproject.toml" <<'PY'
import re, sys
try:
    import tomllib
except ImportError:
    sys.exit("python 3.11 or newer is needed to read pyproject.toml")
d = tomllib.load(open(sys.argv[1], "rb"))
norm = lambda s: re.sub(r"[-_.]+", "-", s).lower()
def req(r):
    m = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(\[[^]]*\])?\s*(\(?\s*>=\s*([0-9][^,;)\s]*))?", r)
    return (norm(m.group(1)), m.group(4) or "") if m else (None, "")
bs = d.get("build-system", {})
print("backend", bs.get("build-backend", ""))
for r in bs.get("requires", []):
    n, v = req(r)
    if n: print("build", n, v)
p = d.get("project", {})
print("name", norm(p.get("name", "")))
for r in p.get("dependencies", []):
    # markers: extras, and other platforms' dependencies, aren't needed on Linux
    if ";" in r and re.search(r"extra\s*==|win32|darwin|cygwin|['\"](Windows|Darwin)['\"]|os_name\s*==\s*['\"]nt", r.split(";", 1)[1]):
        continue
    n, v = req(r)
    if n: print("dep", n, v)
for s in list(p.get("scripts", {})) + list(p.get("gui-scripts", {})):
    print("script", s)
if any(re.match(r"(setuptools[-_]scm|hatch[-_]vcs|pdm[-_]backend|versioningit|poetry-dynamic-versioning)", r) for r in bs.get("requires", [])):
    print("scm 1")
PY
}

# rpm_node_meta — package.json and package-lock.json, as "key value" lines:
# name, bin <name> <path>, build, main, lic (bundled modules' licenses),
# native (modules with install scripts), platform (OS/CPU-specific ones)
rpm_node_meta() {
  at "$TAG_REF" package.json > "$WORK/package.json"
  at "$TAG_REF" package-lock.json > "$WORK/package-lock.json"
  python3 - "$WORK/package.json" "$WORK/package-lock.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
lock = json.load(open(sys.argv[2]))
print("name", p.get("name", ""))
b = p.get("bin")
if isinstance(b, str):
    print("bin", p.get("name", "").split("/")[-1], b)
elif isinstance(b, dict):
    for k, v in b.items():
        print("bin", k, v)
if (p.get("scripts") or {}).get("build"):
    print("build 1")
if p.get("main") or p.get("exports"):
    print("main 1")
for path, e in (lock.get("packages") or {}).items():
    if not path or e.get("dev") or e.get("link"):
        continue
    name = path.split("node_modules/")[-1]
    lic = e.get("license") or "UNKNOWN"
    print("lic", name, e.get("version", ""), lic if isinstance(lic, str) else (lic.get("type") or "UNKNOWN"))
    if e.get("hasInstallScript"):
        print("native", name)
    if e.get("os") or e.get("cpu"):
        print("platform", name)
PY
}

# rpm_spdx_and <expr…> — one SPDX expression from several, as Fedora wants
# it: every license once, joined with AND, compound ones in parentheses.
# "/" means OR (old Cargo style); "A OR B" and "B OR A" count as one.
rpm_spdx_and() {
  python3 - "$@" <<'PY'
import re, sys
terms = []
for e in sys.argv[1:]:
    e = re.sub(r"\s*\(\*\)\s*$", "", re.sub(r"\s*/\s*", " OR ", e.strip()))
    if not e or e == "UNKNOWN":
        continue
    if "(" not in e and " AND " not in e:
        e = " OR ".join(sorted(set(e.split(" OR "))))
    if e not in terms:
        terms.append(e)
print(" AND ".join("(%s)" % t if len(terms) > 1 and re.search(r" (OR|AND) ", t) and not re.match(r"^\(.*\)$", t) else t for t in terms))
PY
}

# rpm_vendor <flavor> — the dependencies Rust, Go and npm would download,
# packed as sources (the builders are offline), in a container with the
# network on. Fedora's layout for copr/fedora, openSUSE's (OBS services') for suse.
rpm_vendor() {
  local fl="$1" img tools
  case "$KIND" in rust|go|node) ;; *) return 0 ;; esac
  img="$RPM_FEDORA_IMG:latest"; [ "$fl" = suse ] && img="$RPM_SUSE_IMG"
  case "$KIND:$fl" in
    rust:suse) tools="cargo zstd tar" ;;           rust:*) tools="cargo xz zstd tar" ;;
    go:suse)   tools="go zstd tar" ;;              go:*)   tools="golang go-vendor-tools python3-specfile askalono-cli tar bzip2" ;;
    node:suse) tools="nodejs-default npm-default tar gzip" ;; node:*) tools="nodejs npm tar gzip" ;;
  esac
  mkdir -p "$RPM_WD/out"
  RV_IMG="$img"; RV_TOOLS="$tools"; RV_FL="$fl"
  run_logged "$WORK/vendor.log" "vendoring the $KIND dependencies (in $img, with the network on)" rpm_vendor_run || true
  grep -q "STORE-SUBMIT: OK" "$WORK/vendor.log" \
    || { grep -vE '^\s*$' "$WORK/vendor.log" | tail -n 12 | sed 's/^/     /'; KEEP_WORK=1; die "vendoring the $KIND dependencies failed (log: $WORK/vendor.log)"; }
  case "$KIND" in
    rust) ok "crates vendored: $(tar tf "$RPM_WD/$( [ "$fl" = suse ] && echo vendor.tar.zst || echo "$PNAME-$VERSION-vendor.tar.xz")" 2>/dev/null | grep -cE '^vendor/[^/]+/$' || echo '?') crates" ;;
    go)   ok "Go modules vendored" ;;
    node) ok "npm modules bundled (node_modules from package-lock.json)" ;;
  esac
}
rpm_vendor_run() {
  "$RUNTIME" run --rm -v "$RPM_WD:/w:Z" -e PNAME="$PNAME" -e VERSION="$VERSION" -e KIND="$KIND" -e FLAVOR="$RV_FL" \
    -e SRC_FILE="$SRC_FILE" -e TOOLS="$RV_TOOLS" -e NODE_BUILD="${NODE_BUILD:-0}" -e OWNER="$(rpm_owner)" "$RV_IMG" bash -c '
    set -e
    export LANG=C.UTF-8 HOME=/tmp/home; mkdir -p "$HOME"
    fail() { echo "STORE-SUBMIT: $*"; [ -z "${OWNER:-}" ] || chown -R "$OWNER" /w 2>/dev/null || true; exit 3; }
    if command -v dnf >/dev/null 2>&1; then dnf -y -q install $TOOLS > /tmp/t.log 2>&1 || { tail -5 /tmp/t.log; fail "could not install $TOOLS"; }
    else for i in 1 2 3; do zypper -n -q in --no-recommends $TOOLS > /tmp/t.log 2>&1 && break; [ "$i" = 3 ] && { tail -5 /tmp/t.log; fail "could not install $TOOLS"; }; done; fi
    mkdir -p /v/src && tar xf "/w/$SRC_FILE" -C /v/src --strip-components=1 || fail "could not unpack $SRC_FILE"
    cd /v/src
    case "$KIND" in
      rust)
        echo "==> cargo vendor"
        cargo vendor --locked --versioned-dirs vendor > /v/config.toml || fail "cargo vendor failed"
        mkdir -p .cargo && cp /v/config.toml .cargo/config.toml
        # what is linked into the program, as %cargo_license_summary counts it
        cargo tree --offline --locked --workspace --edges no-build,no-dev,no-proc-macro --target all --prefix none --format "{l}" \
          2>/dev/null | sort -u > /w/out/crate-licenses.txt || true
        if [ "$FLAVOR" = suse ]; then tar --zstd -cf /w/vendor.tar.zst .cargo/config.toml Cargo.lock vendor
        else tar -cJf "/w/$PNAME-$VERSION-vendor.tar.xz" vendor; fi ;;
      go)
        if [ "$FLAVOR" = suse ]; then
          echo "==> go mod vendor"
          go mod vendor || fail "go mod vendor failed"
          tar --zstd -cf /w/vendor.tar.zst vendor
        else
          cd /w
          echo "==> go_vendor_archive"
          go_vendor_archive create --config /w/go-vendor-tools.toml --write-config "/w/$PNAME.spec" || fail "go_vendor_archive failed"
          echo "==> go_vendor_license"
          go_vendor_license --config /w/go-vendor-tools.toml --path "/w/$PNAME.spec" report --autofill auto --write-config --update-spec \
            > /w/out/go-license.log 2>&1 || echo "STORE-SUBMIT-WARN: licenses"
        fi ;;
      node)
        echo "==> npm ci (production modules)"
        npm ci --omit=dev --ignore-scripts --no-audit --no-fund || fail "npm ci failed"
        rm -f node_modules/.package-lock.json
        mv node_modules /v/node_modules_prod
        if [ "$NODE_BUILD" = 1 ]; then
          echo "==> npm ci (with the build tools)"
          npm ci --ignore-scripts --no-audit --no-fund || fail "npm ci failed"
          npm run build || fail "npm run build failed"
          rm -f node_modules/.package-lock.json
          mv node_modules /v/node_modules_dev
          tar czf "/w/$PNAME-$VERSION-nm-dev.tgz" -C /v node_modules_dev
        fi
        # the files npm would publish: what the package installs
        npm pack --dry-run --json --ignore-scripts 2>/dev/null > /w/out/npm-pack.json || fail "npm pack --dry-run failed"
        tar czf "/w/$PNAME-$VERSION-nm-prod.tgz" -C /v node_modules_prod ;;
    esac
    [ -z "${OWNER:-}" ] || chown -R "$OWNER" /w
    echo "STORE-SUBMIT: OK"'
}

# rpm_spec <flavor> — the .spec for $KIND, written to $RPM_WD/$PNAME.spec.
#   copr   Fedora's guidelines, with a plain Release and %changelog so EPEL,
#          openSUSE and Mageia chroots can build it too
#   fedora Fedora's guidelines as a package review expects them (rpmautospec)
#   suse   openSUSE's conventions (Release: 0, a .changes file, vendor.tar.zst)
# The # @…@ lines are filled in by the test build from what the build really
# installs (finalize.py); a spec without them is used as it is.
rpm_spec() {
  local fl="$1" s="$RPM_WD/$PNAME.spec" b n v l gotarget dt
  local suse=0; [ "$fl" = suse ] && suse=1
  {
  if [ "$suse" = 1 ]; then
    printf '#\n# spec file for package %s\n#\n# Copyright (c) %s %s\n#\n' "$PNAME" "$(date +%Y)" "$MAINT_NAME"
    cat <<'HDR'
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via https://bugs.opensuse.org/
#


HDR
  fi
  case "$KIND" in
    rust)   [ "$suse" = 0 ] && printf '%%bcond check 1\n\n# prevent library files from being installed\n%%global cargo_install_lib 0\n\n' ;;
    go)     [ "$suse" = 0 ] && printf '%%bcond check 1\n\n' ;;
    python) [ "$suse" = 1 ] && printf '%%define pythons python3\n' ;;
    node)   printf '%%global npm_name %s\n' "$NODE_NAME"; [ "$NODE_NATIVE" = 1 ] && [ "$suse" = 0 ] && printf '%%{?nodejs_default_filter}\n'; echo ;;
  esac
  printf 'Name:           %s\nVersion:        %s\n' "$PNAME" "$RPM_VERSION"
  case "$fl" in
    fedora) printf 'Release:        %%autorelease\n' ;;
    copr)   printf 'Release:        %s%%{?dist}\n' "$RPM_REL" ;;
    suse)   printf 'Release:        0\n' ;;
  esac
  printf 'Summary:        %s\n' "$DESC"
  [ "$suse" = 0 ] && echo
  [ -n "$LIC_NOTE" ] && printf '%s\n' "$LIC_NOTE"
  printf 'License:        %s\n' "$LIC_EXPR"
  [ "$KIND" = rust ] && [ "$suse" = 0 ] && printf '# LICENSE.dependencies contains a full license breakdown\n'
  printf 'URL:            %s\n' "$HOMEPAGE"
  printf 'Source0:        %s\n' "$SRC0"
  case "$KIND:$fl" in
    rust:suse|go:suse) printf 'Source1:        vendor.tar.zst\n' ;;
    rust:*) printf 'Source1:        %%{name}-%%{version}-vendor.tar.xz\n' ;;
    go:*)   printf '# Generated by go-vendor-tools\nSource1:        %%{name}-%%{version}-vendor.tar.bz2\n# Go Vendor Tools configuration\nSource2:        go-vendor-tools.toml\n' ;;
    node:*) printf 'Source1:        %%{name}-%%{version}-nm-prod.tgz\n'
            [ "$NODE_BUILD" = 1 ] && printf 'Source2:        %%{name}-%%{version}-nm-dev.tgz\n'
            printf 'Source3:        %%{name}-%%{version}-bundled-licenses.txt\n' ;;
  esac
  echo
  # --- architectures and build dependencies
  case "$KIND:$fl" in
    rust:suse) printf 'BuildRequires:  cargo-packaging\nBuildRequires:  zstd\n' ;;
    rust:*)    printf 'BuildRequires:  cargo-rpm-macros >= 26\n' ;;
    go:suse)   printf 'BuildRequires:  golang(API) >= %s\nBuildRequires:  zstd\n' "${GO_API:-1.21}" ;;
    go:*)      printf 'ExclusiveArch:  %%{golang_arches_future}\nBuildRequires:  go-rpm-macros\nBuildRequires:  go-vendor-tools\n' ;;
    python:suse)
      # python3-<name>: the primary Python's package (python3dist() would match every flavour)
      printf 'BuildRequires:  python-rpm-macros\n'
      printf 'BuildRequires:  python3-%s\n' pip wheel $PY_BUILD ;;
    python:*)  printf 'BuildRequires:  python3-devel\n' ;;
    node:suse) printf 'BuildRequires:  nodejs-devel-default\n'; [ "$NODE_BUILD" = 1 ] && printf 'BuildRequires:  npm-default\n'; printf 'Requires:       nodejs-default\n' ;;
    node:*)    if [ "$NODE_ARCHES" = noarch ]; then printf 'ExclusiveArch:  %%{nodejs_arches} noarch\n'; elif [ -n "$NODE_ARCHES" ]; then printf 'ExclusiveArch:  %s\n' "$NODE_ARCHES"; else printf 'ExclusiveArch:  %%{nodejs_arches}\n'; fi
               printf 'BuildRequires:  nodejs-devel\n'; [ "$NODE_BUILD" = 1 ] && printf 'BuildRequires:  npm\n'; printf 'Requires:       nodejs\n' ;;
    meson:*)   printf 'BuildRequires:  meson\n' ;;
    cmake:*)   printf 'BuildRequires:  cmake\n' ;;
    make:*)    printf 'BuildRequires:  make\n' ;;
  esac
  for b in "${RPM_BRS[@]+"${RPM_BRS[@]}"}"; do printf 'BuildRequires:  %s\n' "$b"; done
  for b in "${RPM_REQS[@]+"${RPM_REQS[@]}"}"; do printf 'Requires:       %s\n' "$b"; done
  printf '# @BR@\n'
  { [ "$KIND" = python ] && [ "$PY_ARCH" = noarch ]; } || { [ "$KIND" = node ] && [ "$NODE_ARCHES" = noarch ]; } \
    && printf 'BuildArch:      noarch\n'
  printf '\n%%description\n'; rpm_wrap "$ABOUT"
  printf '\n# @SUBPKG@\n%%prep\n'
  # --- %prep
  case "$KIND:$fl" in
    rust:suse|go:suse) printf '%%autosetup -p1 -a1 -n %s\n' "$SRC_TOP" ;;
    rust:*) printf '%%autosetup -n %s -p1 -a1\n%%cargo_prep -v vendor\n' "$SRC_TOP" ;;
    go:*)   printf '%%autosetup -n %s -p1\ntar -xf %%{S:1}\n' "$SRC_TOP" ;;
    python:suse) printf '%%autosetup -n %s -p1\n' "$SRC_TOP"
            # modules are no scripts: no shebang, no exec bit (openSUSE's rpmlint)
            printf "find . -name '*.py' -exec sed -i '1{/^#!/d}' {} +\nfind . -name '*.py' -exec chmod a-x {} +\n" ;;
    node:*) printf '%%autosetup -n %s -p1\ncp %%{SOURCE3} .\ntar xzf %%{SOURCE1}\n' "$SRC_TOP"
            [ "$NODE_BUILD" = 1 ] && printf 'tar xzf %%{SOURCE2}\n' ;;
    *)      printf '%%autosetup -n %s -p1\n' "$SRC_TOP" ;;
  esac
  # --- dynamic build dependencies (Fedora)
  if [ "$suse" = 0 ]; then
    case "$KIND" in
      go)     printf '\n%%generate_buildrequires\n%%go_vendor_license_buildrequires -c %%{S:2}\n' ;;
      python) printf '\n%%generate_buildrequires\n'; [ "$PY_SCM" = 1 ] && printf 'export SETUPTOOLS_SCM_PRETEND_VERSION=%%{version}\n'; printf '%%pyproject_buildrequires\n' ;;
    esac
  fi
  # --- %build
  printf '\n%%build\n'
  case "$KIND:$fl" in
    rust:suse) printf '%%{cargo_build}\n' ;;
    rust:*)    printf '%%cargo_build\n%%{cargo_license_summary}\n%%{cargo_license} > LICENSE.dependencies\n%%{cargo_vendor_manifest}\n' ;;
    go:*)
      [ "$suse" = 0 ] && printf '%%global gomodulesmode GO111MODULE=on\n'
      printf 'mkdir -p _build/bin\n'
      for gotarget in $GO_TARGETS; do
        n="${gotarget##*/}"; [ "$gotarget" = . ] && n="$MAIN_GUESS"
        if [ "$suse" = 1 ]; then printf 'go build -mod=vendor -buildmode=pie -trimpath -o _build/bin/%s %s\n' "$n" "$gotarget"
        else printf '%%gobuild -o _build/bin/%s %s\n' "$n" "$gotarget"; fi
      done ;;
    python:*) [ "$PY_SCM" = 1 ] && printf 'export SETUPTOOLS_SCM_PRETEND_VERSION=%%{version}\n'; printf '%%pyproject_wheel\n' ;;
    node:*)   if [ "$NODE_BUILD" = 1 ]; then printf 'ln -s node_modules_dev node_modules\nnpm run build\nrm node_modules\n'; else printf '# nothing to build\n'; fi ;;
    meson:*)  printf '%%meson\n%%meson_build\n' ;;
    cmake:*)  printf '%%cmake\n%%cmake_build\n' ;;
    make:*)   printf '%%make_build PREFIX=%%{_prefix}\n' ;;
  esac
  # --- %install
  printf '\n%%install\n'
  case "$KIND:$fl" in
    rust:suse) printf 'find target/release -maxdepth 1 -type f -executable -exec install -Dpm 0755 -t %%{buildroot}%%{_bindir} {} +\n' ;;
    rust:*)    printf 'find target/rpm -maxdepth 1 -type f -executable -exec install -Dpm 0755 -t %%{buildroot}%%{_bindir} {} +\n' ;;
    go:*)      [ "$suse" = 0 ] && printf '%%go_vendor_license_install -c %%{S:2}\n'
               printf 'install -m 0755 -vd                %%{buildroot}%%{_bindir}\ninstall -m 0755 -vp _build/bin/* %%{buildroot}%%{_bindir}/\n' ;;
    python:suse) printf '%%pyproject_install\n%%python_compileall\n' ;;
    python:*)  printf "%%pyproject_install\n%%pyproject_save_files '*' -a\n" ;;
    node:*)
      dt='%{nodejs_sitelib}'; [ "$suse" = 1 ] && dt='%{_prefix}/lib/node_modules'
      printf 'mkdir -p %%{buildroot}%s/%%{npm_name}\n' "$dt"
      printf 'cp -pr %s %%{buildroot}%s/%%{npm_name}/\n' "$NODE_FILES" "$dt"
      printf 'cp -pr node_modules_prod %%{buildroot}%s/%%{npm_name}/node_modules\n' "$dt"
      [ -n "$NODE_BINS" ] && printf 'mkdir -p %%{buildroot}%%{_bindir}\n'
      for b in $NODE_BINS; do
        n="${b%%=*}"; v="${b#*=}"; v="${v#./}"
        printf 'chmod 0755 %%{buildroot}%s/%%{npm_name}/%s\n' "$dt" "$v"
        [ "$suse" = 1 ] && printf "sed -i '1s|^#!/usr/bin/env node|#!/usr/bin/node|' %%{buildroot}%s/%%{npm_name}/%s\n" "$dt" "$v"
        printf 'ln -s ../lib/node_modules/%%{npm_name}/%s %%{buildroot}%%{_bindir}/%s\n' "$v" "$n"
      done ;;
    meson:*)  printf '%%meson_install\n' ;;
    cmake:*)  printf '%%cmake_install\n' ;;
    make:*)   printf '%%make_install PREFIX=%%{_prefix}\n' ;;
  esac
  printf '# @INSTALL@\n'
  # --- %check
  printf '\n%%check\n'
  case "$KIND:$fl" in
    go:fedora|go:copr) printf '%%go_vendor_license_check -c %%{S:2}\n' ;;
  esac
  printf '# @CHECK@\n'
  case "$KIND:$fl" in
    rust:suse) printf '%%{cargo_test}\n' ;;
    rust:*)    printf '%%if %%{with check}\n%%cargo_test\n%%endif\n' ;;
    go:suse)   printf 'go test -mod=vendor ./...\n' ;;
    go:*)      printf '%%if %%{with check}\n%%gotest ./...\n%%endif\n' ;;
    python:suse) [ -n "$PY_IMPORT" ] && printf '%%{python_expand PYTHONPATH=%%{buildroot}%%{$python_sitelib} $python -c "import %s"}\n' "$PY_IMPORT" ;;
    python:*)  printf '%%pyproject_check_import\n' ;;
    node:suse) [ "$NODE_MAIN" = 1 ] && printf "cd %%{buildroot}%%{_prefix}/lib/node_modules/%%{npm_name} && node -e 'require(\"./\")'\n" ;;
    node:*)    [ "$NODE_MAIN" = 1 ] && printf "cd %%{buildroot}%%{nodejs_sitelib}/%%{npm_name} && %%{__nodejs} -e 'require(\"./\")'\n" ;;
    meson:*)   printf '%%meson_test\n' ;;
    cmake:*)   printf '%%ctest\n' ;;
  esac
  # --- %files
  case "$KIND:$fl" in
    go:fedora|go:copr) printf '\n%%files -f %%{go_vendor_license_filelist}\n' ;;
    python:fedora|python:copr) printf '\n%%files -f %%{pyproject_files}\n' ;;
    *) printf '\n%%files\n' ;;
  esac
  for l in $RPM_LICS; do printf '%%license %s\n' "$l"; done
  case "$KIND:$fl" in
    rust:fedora|rust:copr) printf '%%license LICENSE.dependencies\n%%license cargo-vendor.txt\n' ;;
    node:*) printf '%%license %%{name}-%%{version}-bundled-licenses.txt\n' ;;
  esac
  [ -n "$RPM_DOC" ] && printf '%%doc %s\n' "$RPM_DOC"
  printf '# @FILES@\n\n%%changelog\n'
  case "$fl" in
    fedora) printf '%%autochangelog\n' ;;
    copr)   printf '* %s %s <%s> - %s-%s\n- %s\n' "$(LC_ALL=C date +'%a %b %d %Y')" "$MAINT_NAME" "$RPM_EMAIL" "$RPM_VERSION" "$RPM_REL" \
              "$( [ "$RPM_REL" = 1 ] && echo "Release $VERSION" || echo "Rebuild of $VERSION")" ;;
  esac
  } > "$s.new"
  cat -s "$s.new" > "$s" && rm -f "$s.new"
}

# rpm_prepare <flavor> — everything the spec needs: the release tarball, what
# the project declares (dependencies, programs, licenses), the vendored
# dependencies, and the spec itself. $RPM_WD must exist.
rpm_prepare() {
  local fl="$1" c l pcs pc langs p f k n v
  local -a lics=()
  RPM_BRS=(); RPM_REQS=(); LIC_NOTE=""
  RPM_VERSION="$(printf '%s' "$VERSION" | tr -- '-' '~')"   # rpm forbids "-" in Version; ~ sorts as a pre-release
  [ "$RPM_VERSION" != "$VERSION" ] && note "RPM versions can't contain '-': Version is $RPM_VERSION"
  RPM_EMAIL="${MAINT_EMAIL:-$(git -C "$REPO" config user.email 2>/dev/null || echo "$(id -un)@localhost")}"
  ABOUT="$(rpm_about)"
  RPM_LICS="$(grep -E '^(LICEN[CS]E|COPYING|UNLICENSE)([._-][A-Za-z0-9.-]+)?$' "$WORK/tree.txt" | tr '\n' ' ' || true)"
  RPM_DOC="$(grep -m1 -E '^README(\.(md|rst|txt|adoc))?$' "$WORK/tree.txt" || true)"
  [ -n "$RPM_LICS" ] || warn "no LICENSE file in $TAG — Fedora and openSUSE want the license text in the package"
  rpm_source
  LIC_EXPR="$SPDX"
  case "$KIND" in
    rust)
      for c in $(at "$TAG_REF" Cargo.lock | sed -nE 's/^name = "([a-z0-9_-]+)"$/\1/p' | sort -u); do
        p="$(rpm_sys_br "$c")"; [ -n "$p" ] && RPM_BRS+=("$p")
      done
      [ "${#RPM_BRS[@]}" -gt 0 ] && ok "system libraries for -sys crates: ${RPM_BRS[*]}" ;;
    go)
      GO_MOD="$(at "$TAG_REF" go.mod | sed -nE 's/^module[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)"
      GO_API="$(at "$TAG_REF" go.mod | sed -nE 's/^go[[:space:]]+([0-9]+\.[0-9]+).*/\1/p' | head -1)"
      GO_TARGETS="$(grep -E '^cmd/[^/]+/main\.go$' "$WORK/tree.txt" | sed -E 's#/main\.go$##; s#^#./#' | tr '\n' ' ' || true)"
      [ -n "$GO_TARGETS" ] || GO_TARGETS="."
      ok "Go module $GO_MOD (go $GO_API); programs: $GO_TARGETS"
      [ "$fl" != suse ] && printf '[licensing]\ndetector = "askalono"\n' > "$RPM_WD/go-vendor-tools.toml" ;;
    python)
      rpm_py_meta > "$WORK/py.meta" || die "couldn't read pyproject.toml"
      PY_BUILD="$(awk '$1 == "build" { print $2 }' "$WORK/py.meta" | tr '\n' ' ')"
      PY_SCM="$(awk '$1 == "scm" { print $2 }' "$WORK/py.meta")"; PY_SCM="${PY_SCM:-0}"
      PY_ARCH=noarch
      grep -qE '\.(c|cc|cpp|pyx)$' "$WORK/tree.txt" && grep -qiE 'ext_modules|Extension\(|cython|scikit-build|meson-python|mesonpy' <(at "$TAG_REF" setup.py; at "$TAG_REF" pyproject.toml) 2>/dev/null \
        && { PY_ARCH=""; RPM_BRS+=(gcc); }
      PY_IMPORT="$(awk '$1 == "name" { gsub(/-/, "_", $2); print $2 }' "$WORK/py.meta")"
      if [ "$fl" = suse ]; then
        # openSUSE generates no Python requirements itself: they're listed,
        # and needed at build time too, for the import check in %check
        while read -r k n v; do
          [ "$k" = dep ] || continue
          RPM_REQS+=("python3-$n${v:+ >= $v}"); RPM_BRS+=("python3-$n")
        done < "$WORK/py.meta"
      fi
      ok "Python: $(awk '$1 == "backend" { print $2 }' "$WORK/py.meta")$( [ "$PY_SCM" = 1 ] && echo ', version from git tags')" ;;
    node)
      in_tree package-lock.json || die "no package-lock.json in $TAG — the bundled modules come from it"
      rpm_node_meta > "$WORK/node.meta" || die "couldn't read package.json / package-lock.json"
      NODE_NAME="$(awk '$1 == "name" { print $2 }' "$WORK/node.meta")"
      NODE_BINS="$(awk '$1 == "bin" { print $2 "=" $3 }' "$WORK/node.meta" | tr '\n' ' ')"
      NODE_BUILD="$(awk '$1 == "build" { print $2 }' "$WORK/node.meta")"; NODE_BUILD="${NODE_BUILD:-0}"
      NODE_MAIN="$(awk '$1 == "main" { print $2 }' "$WORK/node.meta")"; NODE_MAIN="${NODE_MAIN:-0}"
      NODE_NATIVE=0; NODE_ARCHES=noarch
      if grep -q '^native ' "$WORK/node.meta"; then
        NODE_NATIVE=1; NODE_ARCHES=""
        warn "modules with install scripts (native code): $(awk '$1 == "native" { printf "%s ", $2 }' "$WORK/node.meta")— the offline build doesn't run them; the test build shows whether the app still works"
      fi
      if grep -q '^platform ' "$WORK/node.meta"; then
        NODE_ARCHES="x86_64"
        warn "platform-specific modules ($(awk '$1 == "platform" { printf "%s ", $2 }' "$WORK/node.meta"| cut -c1-80)) are bundled for x86_64 only — the package is x86_64-only"
      fi
      [ -n "$NODE_BINS" ] || warn "package.json declares no \"bin\" — nothing will be in /usr/bin"
      awk '$1 == "lic" { l = $4; for (i = 5; i <= NF; i++) l = l " " $i; print $2 " " $3 ": " l }' "$WORK/node.meta" > "$RPM_WD/$PNAME-$VERSION-bundled-licenses.txt"
      mapfile -t lics < <(sed 's/^[^:]*: //' "$RPM_WD/$PNAME-$VERSION-bundled-licenses.txt" | sort -u)
      grep -q ' UNKNOWN$' "$RPM_WD/$PNAME-$VERSION-bundled-licenses.txt" \
        && warn "some bundled modules declare no license: $(grep ' UNKNOWN$' "$RPM_WD/$PNAME-$VERSION-bundled-licenses.txt" | cut -d' ' -f1 | head -5 | tr '\n' ' ')— check them by hand"
      LIC_EXPR="$(rpm_spdx_and "$SPDX" "${lics[@]+"${lics[@]}"}")"
      LIC_NOTE="# $SPDX for the app; the bundled modules' licenses are listed in the bundled-licenses file"
      ok "npm package $NODE_NAME; programs: ${NODE_BINS:-none}$( [ "$NODE_BUILD" = 1 ] && echo '; it has a build step')" ;;
    meson|cmake|make)
      pcs="$(rpm_pcs)"
      for pc in $pcs; do RPM_BRS+=("pkgconfig($pc)"); done
      [ -n "$pcs" ] && RPM_BRS+=(pkgconf)
      langs="c"
      case "$KIND" in
        meson) l="$(for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done | tr '\n' ' ' \
                    | grep -oE "(project|add_languages)\([^)]*\)" | grep -oE "'(c|cpp|vala|rust|cs|objc|fortran)'" | tr -d "'" | sort -u | tr '\n' ' ')"
               langs="$l"
               for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done | grep -q "import('i18n')\|import(\"i18n\")\|i18n.merge_file\|gettext(" && RPM_BRS+=(gettext)
               for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done | grep -qE "compile_resources|compile_schemas|glib-compile" && RPM_BRS+=('pkgconfig(glib-2.0)')
               for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done | grep -q "blueprint-compiler" && RPM_BRS+=(blueprint-compiler) ;;
        cmake) l="$(at "$TAG_REF" CMakeLists.txt | tr '\n' ' ' | grep -oiE 'project\([^)]*\)' | head -1)"
               if printf '%s' "$l" | grep -qi 'LANGUAGES'; then
                 langs="$(printf '%s' "$l" | grep -oiE '\b(C|CXX)\b' | tr 'A-Z' 'a-z' | sed 's/^cxx$/cpp/' | sort -u | tr '\n' ' ')"
               else langs="c cpp"; fi ;;
        make)  grep -qE '\.(cc|cpp|cxx)$' "$WORK/tree.txt" && langs="c cpp" ;;
      esac
      case " $langs " in *" c "*|*" vala "*) RPM_BRS+=(gcc) ;; esac
      case " $langs " in *" cpp "*) RPM_BRS+=(gcc-c++) ;; esac
      case " $langs " in *" vala "*) RPM_BRS+=(vala) ;; esac
      case " $langs " in *" rust "*) RPM_BRS+=(rust cargo) ;; esac
      ok "$KIND, languages: $(printf '%s' "${langs:-none}" | xargs); pkg-config: $(printf '%s' "${pcs:-none}" | xargs)" ;;
  esac
  # --- the vendored dependencies (copr/suse always; fedora per guidelines)
  case "$KIND" in
    rust|node) rpm_vendor "$fl" ;;
    go) [ "$fl" = suse ] && rpm_vendor "$fl" ;;
  esac
  if [ "$KIND" = node ]; then
    # what goes into the package: the top-level entries `npm pack` would publish
    NODE_FILES="$(python3 -c 'import json,re,sys; d=json.load(open(sys.argv[1])); d=d[0] if isinstance(d,list) else d; print(" ".join(sorted({f["path"].split("/")[0] for f in d.get("files",[]) if not re.match(r"(?i)(node_modules|readme|licen[cs]e|changelog|history)", f["path"])})))' "$RPM_WD/out/npm-pack.json" 2>/dev/null || true)"
    [ -n "$NODE_FILES" ] || NODE_FILES="package.json"
  fi
  if [ "$KIND" = rust ]; then
    lics=(); [ -f "$RPM_WD/out/crate-licenses.txt" ] && mapfile -t lics < <(grep -v '^[[:space:]]*$' "$RPM_WD/out/crate-licenses.txt" | sort -u)
    if [ "${#lics[@]}" -gt 0 ]; then
      LIC_EXPR="$(rpm_spdx_and "$SPDX" "${lics[@]}")"
      LIC_NOTE="# $SPDX for the app itself, the rest for the vendored crates linked into it"
    else
      warn "couldn't work out the crates' licenses — check License: against %cargo_license_summary in the build log"
    fi
  fi
  rpm_spec "$fl"
  # Go (Fedora): go-vendor-tools makes the vendor archive from the spec and
  # fills in License: — so it runs on the written spec
  if [ "$KIND" = go ] && [ "$fl" != suse ]; then
    rpm_vendor "$fl"
    if grep -q "STORE-SUBMIT-WARN: licenses" "$WORK/vendor.log"; then
      warn "go-vendor-tools couldn't tell every vendored module's license:"
      grep -iE 'error|unknown|undetected|missing' "$RPM_WD/out/go-license.log" | head -6 | sed 's/^/       /'
      note "fill them in go-vendor-tools.toml (https://fedora.gitlab.io/sigs/go/go-vendor-tools/config/), then re-run"
      handoff_add "Some Go modules' licenses weren't detected: add them to $RPM_WD/go-vendor-tools.toml, then run the wizard again"
    else
      ok "License: $(sed -n 's/^License:[[:space:]]*//p' "$RPM_WD/$PNAME.spec" | head -1) (go-vendor-tools)"
    fi
  fi
  ok "wrote $PNAME.spec ($KIND, $( case "$fl" in suse) echo "openSUSE's conventions" ;; *) echo "Fedora's guidelines" ;; esac))"
}

# rpm_build <image> <flavor> — the offline test build in a container, with
# rpmlint; a failure offers edit / log / rebuild / skip / quit. Sets TESTED=1.
# The container's spec replaces $RPM_WD/$PNAME.spec (its %files filled in).
rpm_build_tools() {  # rpm_build_tools <flavor> — the macro packages the spec needs to parse
  case "$KIND:$1" in
    rust:suse) echo cargo-packaging ;; python:suse) echo python-rpm-macros ;;
    rust:*) echo cargo-rpm-macros ;; go:suse) ;; go:*) echo go-rpm-macros go-vendor-tools ;;
    python:*) echo pyproject-rpm-macros python3-devel ;; node:suse) ;; node:*) echo nodejs-packaging ;;
  esac
}
rpm_build() {
  local img="$1" fl="$2" tools choice L f
  TESTED=0
  tools="$(rpm_build_tools "$fl")"
  rpm_tools
  while :; do
    rm -rf "$RPM_WD/out/build.log" "$RPM_WD/out/notes.txt"
    if run_logged "$WORK/test.log" "offline test build in $img (a first build takes a while)" \
         "$RUNTIME" run --rm --cap-add NET_ADMIN -v "$RPM_WD:/w:Z" -v "$WORK/rpm-tools:/tools:ro,Z" \
           -e PNAME="$PNAME" -e SPECNAME="${RPM_SPECNAME:-$PNAME}" -e KIND="$KIND" -e FLAVOR="$fl" -e TOOLS="$tools" -e EXTRA_REPO="${EXTRA_REPO:-}" -e FETCH="${RPM_FETCH:-0}" \
           -e OWNER="$(rpm_owner)" "$img" bash /tools/build.sh \
       && grep -q "STORE-SUBMIT: OK" "$WORK/test.log"; then
      ok "built offline: $(for f in "$RPM_WD"/out/*.rpm; do case "$f" in *-debuginfo-*|*-debugsource-*) ;; *) printf '%s ' "${f##*/}" ;; esac; done)"
      [ -s "$RPM_WD/out/notes.txt" ] && sed 's/^NOTE: /   ! /' "$RPM_WD/out/notes.txt"
      if grep -qE '^RPMLINT: .* (E|W): ' "$WORK/test.log"; then
        RPMLINT_E="$(grep -cE '^RPMLINT: .* E: ' "$WORK/test.log" || true)"
        warn "rpmlint says ($RPMLINT_E error(s)):"
        grep -E '^RPMLINT: .* (E|W): ' "$WORK/test.log" | sed 's/^RPMLINT: /       /' | head -12
      else
        RPMLINT_E=0; ok "rpmlint: no errors or warnings"
      fi
      TESTED=1; return 0
    fi
    L="$WORK/test.log"
    if grep -q "build dependencies not installable" "$L"; then
      bad "build dependencies the distro doesn't have:"
      grep '^MISSING: ' "$L" | sed 's/^MISSING: /       /' | head -12
    elif grep -qiE "go\.mod requires go >=|requires go[0-9.]+ or later|toolchain not available" "$L" "$RPM_WD/out/build.log" 2>/dev/null; then
      bad "the code needs a newer Go than $img has"
    elif grep -qiE "requires rustc [0-9.]+|is not supported by the following package" "$RPM_WD/out/build.log" 2>/dev/null; then
      bad "the code needs a newer Rust than $img has"
    elif grep -qiE "Installed \(but unpackaged\) file" "$RPM_WD/out/build.log" 2>/dev/null; then
      bad "the build installs files the spec doesn't list:"; grep -A8 'Installed (but unpackaged)' "$RPM_WD/out/build.log" | tail -8 | sed 's/^/       /'
    elif grep -qiE "Could not resolve host|Temporary failure in name resolution|failed to download|network is unreachable" "$RPM_WD/out/build.log" 2>/dev/null; then
      bad "the build tried to download something — the builders are offline; it has to be vendored or packaged"
    else
      bad "the test build failed"
    fi
    { [ -f "$RPM_WD/out/build.log" ] && cat "$RPM_WD/out/build.log"; cat "$L"; } | grep -vE '^\s*$|^MISSING: |^RPMLINT: ' | tail -n 14 | cut -c1-200 | sed 's/^/     /'
    [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "the test build failed (logs: $L, $RPM_WD/out/build.log)"; }
    say "e) edit the spec (in ${EDITOR:-vi}), then build again     l) read the whole log"
    say "r) build again as it is     s) skip the test build     q) quit"
    ask choice "Choice" "e"
    case "$choice" in
      e|E) "${EDITOR:-vi}" "$RPM_WD/${RPM_SPECNAME:-$PNAME}.spec" ;;
      l|L) { cat "$RPM_WD/out/build.log" "$L" 2>/dev/null; } | "${PAGER:-less}" || true ;;
      s|S) warn "not test-built"; return 0 ;;
      q|Q) note "the spec and sources are in $RPM_WD"; exit 1 ;;
    esac
  done
}

# rpm_srpm <image> <flavor> — only the source RPM (--no-test): the %files
# list is guessed from the programs the project declares
rpm_srpm() {
  local img="$1" fl="$2" b dt
  rpm_tools
  dt='%{nodejs_sitelib}'; [ "$fl" = suse ] && dt='%{_prefix}/lib/node_modules'
  { case "$KIND" in
      node) printf 'FILES\t%s/%s/\n' "$dt" "$NODE_NAME"
            for b in $NODE_BINS; do printf 'BIN\t%s\nFILES\t%%{_bindir}/%s\n' "${b%%=*}" "${b%%=*}"; done ;;
      python) printf 'PYMOD\t%s\n' "$PY_IMPORT"
              [ "$fl" = suse ] && printf 'FILES\t%%{python3_sitelib}/%s/\nFILES\t%%{python3_sitelib}/%s-%%{version}.dist-info/\n' "$PY_IMPORT" "$PY_IMPORT"
              printf 'BIN\t%s\nFILES\t%%{_bindir}/%s\n' "$MAIN_GUESS" "$MAIN_GUESS" ;;
      *) printf 'BIN\t%s\nFILES\t%%{_bindir}/%s\n' "$MAIN_GUESS" "$MAIN_GUESS" ;;
    esac; } > "$RPM_WD/out/files.guess"
  run_logged "$WORK/srpm.log" "making the source RPM in $img" \
    "$RUNTIME" run --rm -v "$RPM_WD:/w:Z" -v "$WORK/rpm-tools:/tools:ro,Z" -e PNAME="$PNAME" -e KIND="$KIND" -e FLAVOR="$fl" \
      -e TOOLS="$(rpm_build_tools "$fl")" -e MODE=srpm -e FETCH="${RPM_FETCH:-0}" -e OWNER="$(rpm_owner)" "$img" bash /tools/build.sh \
    && grep -q "STORE-SUBMIT: OK" "$WORK/srpm.log" \
    || { grep -vE '^\s*$' "$WORK/srpm.log" | tail -n 8 | sed 's/^/     /'; die "couldn't make the source RPM (log: $WORK/srpm.log)"; }
  warn "not test-built: the %files list is a guess (the programs only) — the build fails if it installs more"
}

# rpm_try <image> — install the built packages in a fresh container the way
# users will (dependencies from the distro's repositories) and run the program
rpm_try() {
  local img="$1"
  [ "$TESTED" = 1 ] || return 0
  if run_logged "$WORK/try.log" "installing the packages in a clean $img" \
       "$RUNTIME" run --rm -v "$RPM_WD:/w:Z" -v "$WORK/rpm-tools:/tools:ro,Z" -e MAIN="$MAIN_GUESS" -e EXTRA_REPO="${EXTRA_REPO:-}" \
         "$img" bash /tools/try.sh && grep -q "STORE-SUBMIT: OK" "$WORK/try.log"; then
    ok "installs with its dependencies$(grep -m1 '^VERSION: ' "$WORK/try.log" | sed 's/^VERSION: /; --version → /')"
    grep -q "STORE-SUBMIT: .* --version failed" "$WORK/try.log" && warn "$MAIN_GUESS --version didn't work in the container (fine for a GUI app)"
    grep -q '^BIN: ' "$WORK/try.log" || warn "it installs no program in /usr/bin"
  else
    bad "the packages don't install in a clean system:"
    grep '^MISSING: ' "$WORK/try.log" | sed 's/^MISSING: /       /' | head -8
    grep -vE '^\s*$|^MISSING: ' "$WORK/try.log" | tail -n 5 | sed 's/^/     /'
    [ "$ASSUME_YES" = 1 ] && die "the built packages don't install (log: $WORK/try.log)"
    confirm "Carry on anyway?" n || { note "the spec is in $RPM_WD"; exit 1; }
  fi
}

# ------------------------------------------------------------------- COPR
# copr_api <path> — an anonymous read of COPR's API v3
copr_api() { curl -sf --max-time 30 "$COPR_URL/api_3/$1"; }
# copr_conf <key> — a value from copr-cli's config (the token is never read)
copr_conf() {
  [ -f "$COPR_CONF_FILE" ] || return 0
  case "$1" in
    expiration) sed -nE 's/^#[[:space:]]*expiration date:[[:space:]]*([0-9-]+).*/\1/p' "$COPR_CONF_FILE" | tail -1 ;;
    *) sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\\1/p" "$COPR_CONF_FILE" | tail -1 ;;
  esac
}
# copr_cli <args…> — copr-cli: yours, or Fedora's own in a container (it isn't
# in nixpkgs). An argument that is a local file (the SRPM) is handed in too.
copr_cli() {
  local a args=() mnt=()
  if have copr-cli; then copr-cli --config "$COPR_CONF_FILE" "$@"; return; fi
  [ -n "$RUNTIME" ] || { printf 'copr-cli is missing, and there is no podman or docker to run it in\n' >&2; return 127; }
  for a in "$@"; do
    if [ -f "$a" ]; then mnt=(-v "$(cd "$(dirname "$a")" && pwd):/up:ro,Z"); args+=("/up/$(basename "$a")"); else args+=("$a"); fi
  done
  "$RUNTIME" run --rm -v "$COPR_CONF_FILE:/root/.config/copr:ro" "${mnt[@]+"${mnt[@]}"}" "$RPM_FEDORA_IMG:latest" \
    bash -c 'dnf -y -q install copr-cli >/dev/null 2>&1 || { echo "could not install copr-cli in the container" >&2; exit 125; }; exec copr-cli "$@"' \
    copr-cli "${args[@]}"
}
# copr_split — COPR_OWNER and COPR_NAME from COPR_PROJECT ("name", "owner/name" or "@group/name")
copr_split() {
  case "$COPR_PROJECT" in
    */*) COPR_OWNER="${COPR_PROJECT%%/*}"; COPR_NAME="${COPR_PROJECT#*/}" ;;
    *)   COPR_OWNER="${COPR_USER:-$(copr_conf username)}"; COPR_NAME="$COPR_PROJECT" ;;
  esac
  COPR_FULL="$COPR_OWNER/$COPR_NAME"
}

# copr_questions — the COPR project and the releases it builds for. Part of
# "Your app" whenever COPR is among the distros; the config keeps them.
copr_questions() {
  local guess sel items="" pre="" rel arch r keep="" c n label notes
  COPR_USER="$(copr_conf username)"
  guess="$(cfg_get copr-project)"
  if [ -n "$guess" ] && [ "$ASK_ALL" = 0 ]; then COPR_PROJECT="$guess"
  else
    note "your COPR project — people add it with: dnf copr enable ${COPR_USER:-<you>}/<project>"
    while :; do
      ask COPR_PROJECT "COPR project (a name, or @group/name)" "${guess:-$PNAME}"
      printf '%s' "$COPR_PROJECT" | grep -qE '^(@?[A-Za-z0-9_.-]+/)?[A-Za-z0-9_.+-]+$' && break
      [ "$ASSUME_YES" = 1 ] && die "'$COPR_PROJECT' isn't a valid COPR project name"
      warn "letters, digits and . _ + - only"; guess=""
    done
  fi
  [ "${SAVE:-1}" = 1 ] && cfg_set copr-project "$COPR_PROJECT"
  ok "COPR project: $COPR_PROJECT"
  # the releases and architectures COPR builds for today
  copr_api "mock-chroots/list" > "$WORK/chroots.json" || die "couldn't ask COPR which releases it builds for ($COPR_URL)"
  python3 - "$WORK/chroots.json" > "$WORK/chroots.txt" <<'PY'
import json, re, sys
for name, comment in sorted(json.load(open(sys.argv[1])).items()):
    m = re.match(r"^(fedora-(\d+|rawhide)|epel-\d+|centos-stream-\d+|opensuse-(tumbleweed|leap-[\d.]+)|mageia-(\d+|cauldron))-(x86_64|aarch64|ppc64le|s390x)$", name)
    if m and "EOL" not in (comment or ""):
        print(name)
PY
  for c in $(cfg_get copr-chroots); do grep -qxF "$c" "$WORK/chroots.txt" && keep="$keep${keep:+ }$c"; done
  if [ -z "$keep" ] || [ "$ASK_ALL" = 1 ]; then
    for rel in $(sed -E 's/-(x86_64|aarch64|ppc64le|s390x)$//' "$WORK/chroots.txt" | sort -u | sort -t- -k1,1 -k2,2Vr); do
      case "$rel" in
        fedora-rawhide) label="Fedora Rawhide"; notes="the development version — breaks now and then" ;;
        fedora-*)  label="Fedora ${rel#fedora-}"; notes=""; pre="$pre $rel" ;;
        epel-*)    n="${rel#epel-}"; label="EPEL $n"; notes="RHEL, AlmaLinux, Rocky $n$( [ "$n" -le 9 ] && echo ' — older tools, may need changes')" ;;
        centos-stream-*) label="CentOS Stream ${rel#centos-stream-}"; notes="" ;;
        opensuse-*) label="openSUSE $(printf '%s' "${rel#opensuse-}" | sed 's/tumbleweed/Tumbleweed/; s/leap-/Leap /')"; notes="the spec is Fedora-style — 'linux-submit.sh obs' suits openSUSE" ;;
        mageia-*)  label="Mageia ${rel#mageia-}"; notes="the spec is Fedora-style — may need changes" ;;
      esac
      items="$items$rel|$label|1|$notes"$'\n'
    done
    if [ "$ASSUME_YES" = 1 ]; then sel="$(printf '%s' "$pre" | xargs)"
    else say "Which releases should COPR build for? (new Fedora releases are added by themselves)"; multi_select sel "$items" "$pre"; fi
    items=""
    for arch in x86_64 aarch64 ppc64le s390x; do
      case "$arch" in x86_64) notes="PCs and most servers" ;; aarch64) notes="ARM: Raspberry Pi, ARM laptops and servers" ;; *) notes="IBM servers" ;; esac
      items="$items$arch|$arch|1|$notes"$'\n'
    done
    if [ "$ASSUME_YES" = 1 ]; then arch="x86_64 aarch64"
    else say "Which architectures?"; multi_select arch "$items" "x86_64 aarch64"; fi
    keep=""
    for r in $sel; do for c in $arch; do grep -qxF "$r-$c" "$WORK/chroots.txt" && keep="$keep${keep:+ }$r-$c"; done; done
    [ -n "$keep" ] || die "COPR builds none of those combinations"
  fi
  COPR_CHROOTS="$keep"
  [ "${SAVE:-1}" = 1 ] && cfg_set copr-chroots "$COPR_CHROOTS"
  ok "COPR builds for: $COPR_CHROOTS"
}

# copr_login — copr-cli's own login: the API token in ~/.config/copr. Sets COPR_USER.
copr_login() {
  local exp who line conf
  while :; do
    if [ -f "$COPR_CONF_FILE" ]; then
      exp="$(copr_conf expiration)"
      if [ -n "$exp" ] && [[ "$(date +%F)" > "$exp" ]]; then
        warn "your COPR API token expired on $exp"
      elif who="$(copr_cli whoami 2>"$WORK/copr.err")" && [ -n "$who" ]; then
        COPR_USER="$(printf '%s\n' "$who" | tail -1 | tr -d '[:space:]')"
        ok "logged in to COPR as $COPR_USER${exp:+ (the token is valid until $exp)}"
        return 0
      else
        tail -n 3 "$WORK/copr.err" | sed 's/^/     /'
        warn "copr-cli couldn't log in with $COPR_CONF_FILE"
      fi
    fi
    [ "$ASSUME_YES" = 1 ] && die "set up copr-cli's login once without --yes"
    say "COPR needs your API token (once; it expires after some months — then again):"
    note "1. open $COPR_URL/api/ and log in with your Fedora account (none yet? https://accounts.fedoraproject.org)"
    note "2. copy the whole [copr-cli] block the page shows"
    say "Paste it here, then press Enter on an empty line:"
    conf=""
    while :; do readline line; [ -z "$line" ] && [ -n "$conf" ] && break; [ -n "$line" ] && conf="$conf$line"$'\n'; done
    if printf '%s' "$conf" | grep -q '^\[copr-cli\]' && printf '%s' "$conf" | grep -qE '^token[[:space:]]*='; then
      mkdir -p "$(dirname "$COPR_CONF_FILE")"
      ( umask 077; printf '%s' "$conf" > "$COPR_CONF_FILE" ); chmod 600 "$COPR_CONF_FILE"
      ok "saved to $COPR_CONF_FILE (copr-cli's own config, readable only by you)"
    else
      warn "that isn't the [copr-cli] block — it starts with [copr-cli] and has login, username and token lines"
    fi
  done
}

# copr_project — the project exists and builds for $COPR_CHROOTS (asks first)
copr_project() {
  local have_c missing c args=() desc instr
  if copr_api "project?ownername=$COPR_OWNER&projectname=$COPR_NAME" > "$WORK/project.json" 2>/dev/null; then
    have_c="$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1])).get("chroot_repos", {}))))' "$WORK/project.json")"
    missing=""
    for c in $COPR_CHROOTS; do case " $have_c " in *" $c "*) ;; *) missing="$missing $c" ;; esac; done
    if [ -n "$missing" ]; then
      if go "Add$missing to $COPR_FULL?"; then
        for c in $have_c $missing; do args+=(--chroot "$c"); done
        copr_cli modify "${args[@]}" "$COPR_FULL" >"$WORK/modify.log" 2>&1 || { tail -n 4 "$WORK/modify.log" | sed 's/^/     /'; die "couldn't add the releases to $COPR_FULL"; }
        ok "added$missing"
      fi
    fi
    ok "project: $COPR_URL/coprs/$COPR_FULL/"
    return 0
  fi
  [ "${DRYRUN:-0}" = 1 ] && { note "dry run: the project $COPR_FULL doesn't exist yet"; return 0; }
  desc="$DESC. Homepage: $HOMEPAGE"
  instr="$(printf 'Install it with:\n\n```\nsudo dnf copr enable %s\nsudo dnf install %s\n```\n' "$COPR_FULL" "$PNAME")"
  go "Create the COPR project $COPR_FULL (for: $COPR_CHROOTS)?" || die "a COPR build needs a project"
  for c in $COPR_CHROOTS; do args+=(--chroot "$c"); done
  copr_cli create "${args[@]}" --description "$desc" --instructions "$instr" --enable-net off \
    --follow-fedora-branching on "$COPR_FULL" > "$WORK/create.log" 2>&1 \
    || { tail -n 4 "$WORK/create.log" | sed 's/^/     /'; die "couldn't create $COPR_FULL"; }
  ok "created $COPR_URL/coprs/$COPR_FULL/"
}

# copr_release — the Release number for this version: 1, or one more than
# what the project has built of it already
copr_release() {
  local v
  v="$(copr_api "package?ownername=$COPR_OWNER&projectname=$COPR_NAME&packagename=$PNAME&with_latest_build=True" 2>/dev/null \
       | python3 -c 'import json,sys; b=(json.load(sys.stdin).get("builds") or {}).get("latest") or {}; print((b.get("source_package") or {}).get("version") or "")' 2>/dev/null || true)"
  RPM_REL=1
  case "$v" in
    "$RPM_VERSION"-*) v="${v#"$RPM_VERSION"-}"; v="${v%%.*}"; case "$v" in *[!0-9]*|'') ;; *) RPM_REL=$((v + 1)) ;; esac ;;
  esac
  [ "$RPM_REL" -gt 1 ] && note "$COPR_FULL has $PNAME $RPM_VERSION already: this is release $RPM_REL"
  return 0
}

# copr_build <srpm> [chroot…] — upload and start the build; sets COPR_BUILD
copr_build() {
  local srpm="$1" a=(); shift
  for c in "$@"; do a+=(-r "$c"); done
  run_logged "$WORK/copr-build.log" "uploading $(basename "$srpm") to $COPR_FULL" copr_cli build --nowait "${a[@]+"${a[@]}"}" "$COPR_FULL" "$srpm" \
    || { tail -n 5 "$WORK/copr-build.log" | sed 's/^/     /'; die "COPR didn't take the build"; }
  COPR_BUILD="$(sed -nE 's/^Created builds: ([0-9]+).*/\1/p' "$WORK/copr-build.log" | head -1)"
  [ -n "$COPR_BUILD" ] || die "COPR didn't say which build it started — see $COPR_URL/coprs/$COPR_FULL/builds/"
  ok "build $COPR_BUILD started: $COPR_URL/coprs/build/$COPR_BUILD/"
}

# copr_wait — until COPR_BUILD is done (safe to interrupt: COPR carries on);
# then each release's result. Returns 1 if any failed.
copr_wait() {
  local st="" t0 el i=0 spin='|/-\' failed=0 name state url
  t0="$(date +%s)"
  while :; do
    st="$(copr_api "build/$COPR_BUILD" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null || true)"
    case "$st" in succeeded|failed|canceled|skipped) break ;; esac
    el=$(( $(date +%s) - t0 ))
    if [ -t 1 ]; then printf '\r\033[K   %s %sCOPR is building%s %s%s — %dm%02ds (Ctrl-C is safe: COPR carries on)%s' "${spin:i%4:1}" "$B" "$R" "$DIM" "${st:-waiting}" $((el / 60)) $((el % 60)) "$R"
    elif [ $((i % 10)) = 0 ]; then say "COPR: ${st:-waiting} ($((el / 60)) min)"; fi
    i=$((i + 1)); sleep 15
  done
  [ -t 1 ] && printf '\r\033[K'
  copr_api "build-chroot/list?build_id=$COPR_BUILD" > "$WORK/bc.json" 2>/dev/null || true
  while IFS='|' read -r name state url; do
    [ -n "$name" ] || continue
    if [ "$state" = succeeded ]; then ok "$name: built"
    else
      bad "$name: $state"; failed=1
      if [ -n "$url" ] && curl -sf --max-time 30 "${url}builder-live.log.gz" | gunzip 2>/dev/null | grep -vE '^\s*$' | tail -n 12 > "$WORK/fail.log" 2>/dev/null; then
        cut -c1-200 "$WORK/fail.log" | sed 's/^/       /'; note "whole log: ${url}builder-live.log.gz"
      fi
    fi
  done < <(python3 -c 'import json,sys; [print("%s|%s|%s" % (i["name"], i["state"], i.get("result_url") or "")) for i in json.load(open(sys.argv[1])).get("items", [])]' "$WORK/bc.json" 2>/dev/null)
  [ "$st" = succeeded ] && [ "$failed" = 0 ]
}

# rpm_own_spec <flavor> — the app's own .spec at the tag, if it has one: used
# as it is, with this Version (and Release); its sources are downloaded by
# spectool in the test build. Returns 1 when there's none.
rpm_own_spec() {
  local own dir f
  own="$(grep -m1 -E "(^|/)$PNAME\\.spec$" "$WORK/tree.txt" || true)"
  [ -n "$own" ] || return 1
  dir="$(dirname "$own")"
  at "$TAG_REF" "$own" > "$RPM_WD/$PNAME.spec"
  # patches and other local sources next to it
  [ "$dir" != . ] && grep -E "^$dir/[^/]+$" "$WORK/tree.txt" | while read -r f; do at "$TAG_REF" "$f" > "$RPM_WD/$(basename "$f")"; done
  RPM_VERSION="$(printf '%s' "$VERSION" | tr -- '-' '~')"
  sed -i -E "s/^(Version:[[:space:]]*).*/\\1$RPM_VERSION/" "$RPM_WD/$PNAME.spec"
  if [ "$1" = copr ] && grep -qE '^Release:[[:space:]]*[0-9]' "$RPM_WD/$PNAME.spec"; then
    sed -i -E "s/^(Release:[[:space:]]*)[0-9]+/\\1${RPM_REL:-1}/" "$RPM_WD/$PNAME.spec"
  fi
  RPM_FETCH=1
  ok "your $own (from $TAG), Version set to $RPM_VERSION"
  note "it's used as it is: its sources are downloaded by spectool, nothing is vendored"
}

# ##########################################################################
#   Fedora COPR wizard — linux-submit.sh copr [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_copr() {
#
# linux-submit.sh copr — publish an app to Fedora COPR, Fedora's community
# build service: a repository of your own, built on Fedora's servers for the
# Fedora (and EPEL, …) releases you pick. People add it with
# `dnf copr enable you/project`.
#
# Follows COPR's documentation and Fedora's packaging guidelines:
#   https://docs.pagure.org/copr.copr/user_documentation.html
#   https://docs.fedoraproject.org/en-US/packaging-guidelines/
#   …/packaging-guidelines/{Rust,Golang,Python,Node.js,Meson,CMake}/
#
# Writes the .spec for your build system (or uses yours), vendors what Rust,
# Go and npm would download (COPR builds offline by default), test-builds it
# offline in a Fedora container with rpmlint and installs it there, creates
# the COPR project if needed, uploads the source RPM with copr-cli and waits
# for COPR's builds.

set -eu

DRYRUN=0
SAVE=1
ASSUME_YES=0
ASK_ALL=0
NO_TEST=0
REPO_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/copr-submit"
CONF="$CONF_DIR/last.conf"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/store-submit"

usage() {
  cat <<'USAGE'
linux-submit.sh copr — publish an app to Fedora COPR, or a new version of it.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask (the first
                      login still needs you)
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --config FILE   the shared answers (default: .store-submit.conf in the repo)
      --no-test       skip the offline test build in a Fedora container
  -n, --dry-run       write, vendor and test-build; nothing is created or
                      uploaded on COPR
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
    --no-test)    NO_TEST=1 ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF"; printf 'forgot %s\n' "$CONF"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WIZ_NAME=copr-submit
linux_common

SAVED_REPO=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  { printf '# written by linux-submit.sh copr — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n' "${REPO:-${SAVED_REPO:-}}"; } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}

RUNTIME=""
for r in podman docker; do have "$r" && "$r" info >/dev/null 2>&1 && { RUNTIME="$r"; break; }; done

# =============================================================== 0. orientation
cat <<BANNER

  ${B}Fedora COPR wizard${R}  (dnf copr enable you/app — Fedora, EPEL…)

  Six stages:
    1. your app     — shared with the other distros, plus the COPR project
                      and the releases it builds for
    2. COPR login   — copr-cli's own API token (~/.config/copr)
    3. the spec     — written for your build system (or yours), with what
                      Rust, Go and npm would download vendored
    4. test build   — offline in a Fedora container, like COPR; rpmlint;
                      installed in a clean one and run
    5. project      — created on COPR (or given the new releases)
    6. build        — the source RPM uploaded; COPR builds it for each release

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: written, vendored and test-built; nothing is created or uploaded on COPR"
[ "$ASSUME_YES" = 1 ] && note "--yes: using everything detected; stopping only on problems"
for t in git curl python3 tar sha256sum; do have "$t" || die "$t is missing — install it and re-run"; done
[ -n "$RUNTIME" ] || die "the source RPM is made and tested in Fedora containers: install podman or docker (NixOS: virtualisation.podman.enable = true;)"

# ============================================================== 1. the app
linux_app "1/6  Your app"
rpm_kind_ok
copr_questions

# ============================================================ 2. COPR login
step "2/6  COPR login"
if [ "$DRYRUN" = 1 ] && [ ! -f "$COPR_CONF_FILE" ]; then
  note "dry run: not logging in"
else
  copr_login
fi
copr_split
[ -n "$COPR_OWNER" ] || { COPR_OWNER="<you>"; COPR_FULL="$COPR_OWNER/$COPR_NAME"; }
PROJECT_EXISTS=0
copr_api "project?ownername=$COPR_OWNER&projectname=$COPR_NAME" >/dev/null 2>&1 && PROJECT_EXISTS=1
if [ "$PROJECT_EXISTS" = 1 ]; then ok "$COPR_FULL exists: $COPR_URL/coprs/$COPR_FULL/"
else ok "$COPR_FULL is new — it's created in stage 5"; fi

# ============================================================== 3. the spec
step "3/6  The spec"
RPM_WD="$CACHE/copr/$PNAME"
rm -rf "$RPM_WD"; mkdir -p "$RPM_WD/out"
RPM_VERSION="$(printf '%s' "$VERSION" | tr -- '-' '~')"
copr_release
RPM_FETCH=0
if ! rpm_own_spec copr; then
  rpm_prepare copr
fi

# ============================================================ 4. test build
step "4/6  Test build"
# the newest Fedora release the project builds for, the way COPR builds it
REL="$(printf '%s\n' $COPR_CHROOTS | sed -nE 's/^fedora-([0-9]+)-.*/\1/p' | sort -n | tail -1)"
[ -n "$REL" ] || { printf '%s\n' $COPR_CHROOTS | grep -q '^fedora-rawhide-' && REL=rawhide; }
[ -n "$REL" ] || { REL=latest; note "no Fedora release among the chroots — testing on the latest Fedora"; }
IMG="$RPM_FEDORA_IMG:$REL"
# packages the project has built already (dependencies you added) count too
EXTRA_REPO=""
[ "$PROJECT_EXISTS" = 1 ] && [ "$REL" != latest ] && EXTRA_REPO="$COPR_DL/$COPR_FULL/fedora-$REL-$(uname -m)/"
if [ "$NO_TEST" = 1 ]; then
  warn "--no-test: not test-built"
  rpm_srpm "$IMG" copr
else
  rpm_build "$IMG" copr
  rpm_try "$IMG"
fi
SRPM="$(ls "$RPM_WD"/out/*.src.rpm 2>/dev/null | head -1 || true)"
[ -n "$SRPM" ] || die "no source RPM came out — see $WORK/test.log"
ok "source RPM: $(basename "$SRPM")"
echo; sed 's/^/     /' "$RPM_WD/$PNAME.spec"; echo
note "the spec, sources and packages are in $RPM_WD"

save_answers
if [ "$DRYRUN" = 1 ]; then
  warn "dry run — nothing created or uploaded on COPR; it's all in $RPM_WD"
  exit 0
fi

# ============================================================== 5. project
step "5/6  The COPR project"
copr_project

# ================================================================ 6. build
step "6/6  Build"
go "Upload $(basename "$SRPM") and build it for: $COPR_CHROOTS?" || { note "the source RPM is in $RPM_WD/out"; exit 0; }
# shellcheck disable=SC2086
copr_build "$SRPM" $COPR_CHROOTS
if copr_wait; then
  ok "built for every release"
else
  warn "COPR's build failed for some releases (above): fix the spec, then run the wizard again"
  note "builds: $COPR_URL/coprs/$COPR_FULL/builds/"
  exit 1
fi

printf '\n   %sDone.%s %s %s → %s\n   %s/coprs/%s/\n\n' "$B" "$R" "$PNAME" "$VERSION" "$COPR_FULL" "$COPR_URL" "$COPR_FULL"
say "  • People install it with:"
say "      sudo dnf copr enable $COPR_FULL"
say "      sudo dnf install $PNAME"
say "    (no copr command in dnf? it's in dnf5-plugins on Fedora, dnf-plugins-core on EPEL)"
say "  • Next release: run linux-submit.sh copr (or linux-submit.sh) again."
say "  • COPR isn't Fedora itself — for Fedora's own repositories: linux-submit.sh fedora"
echo
}

# ##########################################################################
#   Fedora's questions and helpers — your Fedora account, Bugzilla, and
#   whether the app is in Fedora already. Part of "Your app" whenever Fedora
#   is among the distros.
# ##########################################################################
BZ_URL="${BZ_URL:-https://bugzilla.redhat.com}"
FE_NEEDSPONSOR=177841   # the tracker bug new packagers' review requests block
FEDORA_DOCS="https://docs.fedoraproject.org/en-US/package-maintainers"

# fedora_questions — your Fedora account, its Bugzilla email, and whether
# you're a packager already (then no sponsor is needed)
fedora_questions() {
  FAS_USER="$(cfg_get fedora-account)"
  if [ -z "$FAS_USER" ] || [ "$ASK_ALL" = 1 ]; then
    note "your Fedora account name (FAS, https://accounts.fedoraproject.org) — blank if you have none yet"
    ask_opt FAS_USER "Fedora account username" "$FAS_USER"
    [ "${SAVE:-1}" = 1 ] && cfg_set fedora-account "$FAS_USER"
  fi
  if [ -n "$FAS_USER" ]; then ok "Fedora account: $FAS_USER"; else note "no Fedora account yet — it goes on your to-do list"; fi
  BZ_EMAIL="$(cfg_get fedora-bugzilla-email)"
  if [ -z "$BZ_EMAIL" ] || [ "$ASK_ALL" = 1 ]; then
    note "the review request is filed in Red Hat Bugzilla, from an account with your Fedora account's email"
    ask BZ_EMAIL "Email of your Fedora account" "${BZ_EMAIL:-${MAINT_EMAIL:-}}"
    [ "${SAVE:-1}" = 1 ] && cfg_set fedora-bugzilla-email "$BZ_EMAIL"
  fi
  ok "Bugzilla account: $BZ_EMAIL"
  FE_PACKAGER="$(cfg_get fedora-packager)"
  if [ -z "$FE_PACKAGER" ] || [ "$ASK_ALL" = 1 ]; then
    if confirm "Are you a Fedora packager already (sponsored into the packager group)?" n; then FE_PACKAGER=yes; else FE_PACKAGER=no; fi
    [ "${SAVE:-1}" = 1 ] && cfg_set fedora-packager "$FE_PACKAGER"
  fi
  if [ "$FE_PACKAGER" = yes ]; then ok "packager: yes"; else ok "packager: not yet — a sponsor reviews your first package"; fi
}

# fedora_where — is $PNAME in Fedora? Sets FED_SRC (its dist-git repository),
# FED_VER (the version in Rawhide), FED_URL (its upstream) and FED_MAINT
fedora_where() {
  local n
  FED_SRC=""; FED_VER=""; FED_URL=""; FED_MAINT=""
  curl -sf --max-time 20 "https://mdapi.fedoraproject.org/rawhide/pkg/$PNAME" > "$WORK/mdapi.json" 2>/dev/null || : > "$WORK/mdapi.json"
  if [ -s "$WORK/mdapi.json" ]; then
    FED_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$WORK/mdapi.json" 2>/dev/null || true)"
    FED_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("url",""))' "$WORK/mdapi.json" 2>/dev/null || true)"
  fi
  for n in "$PNAME" "rust-$PNAME" "python-$PNAME" "golang-$PNAME" "nodejs-$PNAME"; do
    curl -sf --max-time 20 "https://src.fedoraproject.org/api/0/rpms/$n" > "$WORK/distgit.json" 2>/dev/null || continue
    FED_SRC="$n"
    FED_MAINT="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("access_users",{}); print(" ".join(sorted(set(sum((a.get(k,[]) for k in ("owner","admin","commit","collaborator")), [])))))' "$WORK/distgit.json" 2>/dev/null || true)"
    break
  done
}

# fedora_reviews — review requests for $PNAME in Bugzilla, as
# "id|status|resolution|creator" lines (anonymous search)
fedora_reviews() {
  curl -sf --max-time 30 -G "$BZ_URL/rest/bug" --data-urlencode product=Fedora --data-urlencode "component=Package Review" \
       --data-urlencode "summary=Review Request: $PNAME" --data-urlencode "include_fields=id,summary,status,resolution,creator_detail" 2>/dev/null \
    | python3 -c '
import json, re, sys
name = sys.argv[1]
for b in json.load(sys.stdin).get("bugs", []):
    if re.match(r"^Review Request:\s*%s\s+-" % re.escape(name), b.get("summary", "")):
        c = b.get("creator_detail") or {}
        print("%s|%s|%s|%s" % (b["id"], b.get("status", ""), b.get("resolution", ""), c.get("email") or c.get("name") or ""))' "$PNAME" 2>/dev/null || true
}

# bz <METHOD> <path> [json] — Red Hat Bugzilla's REST API with your API key;
# the key goes to curl on stdin, never on the command line
bz() {
  printf 'header = "Authorization: Bearer %s"\n' "$BZ_KEY" \
    | curl -sS --max-time 60 -K - -X "$1" -H 'Content-Type: application/json' -H 'Accept: application/json' \
        ${3:+--data-binary "$3"} "$BZ_URL/rest/$2"
}
# bz_json key=value… — a JSON object from the arguments (numbers stay numbers)
bz_json() {
  python3 -c '
import json, sys
d = {}
for a in sys.argv[1:]:
    k, _, v = a.partition("=")
    d[k] = int(v) if v.isdigit() else v
print(json.dumps(d))' "$@"
}

# ##########################################################################
#   Fedora wizard — linux-submit.sh fedora [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_fedora() {
#
# linux-submit.sh fedora — get an app into Fedora's own repositories: up to
# the package review, which people do. (A package already in Fedora is
# updated by its maintainers; the wizard bumps the spec and says how.)
#
# Follows Fedora's process and guidelines:
#   https://docs.fedoraproject.org/en-US/package-maintainers/New_Package_Process_for_New_Contributors/
#   https://docs.fedoraproject.org/en-US/package-maintainers/Package_Review_Process/
#   https://docs.fedoraproject.org/en-US/packaging-guidelines/  (and its Rust, Golang,
#     Python, Node.js, Meson, CMake pages)
#   https://bugzilla.redhat.com/docs/en/html/api/core/v1/bug.html  (filing the review)
#
# Writes the spec to Fedora's guidelines (rpmautospec, vendoring where the
# language guidelines allow or require it), builds it offline in a Fedora
# Rawhide container with rpmlint, puts the spec and SRPM online with a COPR
# build (what Fedora's docs recommend), and files the Review Request in Red
# Hat Bugzilla with your API key — or prepares the exact text for you.
# Fedora's Review Service then builds it and runs fedora-review on the bug.
# The account, the sponsor, the review itself and fedpkg are yours to do:
# they end up on your to-do list.

set -eu

DRYRUN=0
SAVE=1
ASSUME_YES=0
ASK_ALL=0
NO_TEST=0
REPO_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fedora-submit"
CONF="$CONF_DIR/last.conf"
BZ_KEY_FILE="$CONF_DIR/bugzilla-api-key"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/store-submit"

usage() {
  cat <<'USAGE'
linux-submit.sh fedora — get an app into Fedora, up to the package review.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask (a new
                      package still needs you to read the spec)
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --config FILE   the shared answers (default: .store-submit.conf in the repo)
      --no-test       skip the offline test build (not recommended: the
                      %files list is then a guess)
  -n, --dry-run       write and test-build; nothing goes to COPR or Bugzilla
      --no-save       do not remember the answers for next time
      --forget        delete the remembered answers and the saved
                      Bugzilla API key, and exit
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
    --no-test)    NO_TEST=1 ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF" "$BZ_KEY_FILE"; printf 'forgot %s and the saved Bugzilla API key\n' "$CONF"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WIZ_NAME=fedora-submit
linux_common

SAVED_REPO=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  { printf '# written by linux-submit.sh fedora — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n' "${REPO:-${SAVED_REPO:-}}"; } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}

RUNTIME=""
for r in podman docker; do have "$r" && "$r" info >/dev/null 2>&1 && { RUNTIME="$r"; break; }; done

# =============================================================== 0. orientation
cat <<BANNER

  ${B}Fedora wizard${R}  (Fedora's own repositories: dnf install, GNOME Software…)

  Six stages:
    1. your app        — shared with the other distros; in Fedora already?
    2. the spec        — to Fedora's Packaging Guidelines, for your build system
    3. build + check   — offline in a Fedora Rawhide container, rpmlint; you read it
    4. online copy     — spec and SRPM built on COPR, links for the reviewers
    5. review request  — filed in Red Hat Bugzilla, or the exact text for you
    6. hand-off        — what only a person can do: account, sponsor, review, fedpkg

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: written and test-built; nothing goes to COPR or Bugzilla"
for t in git curl python3 tar sha256sum; do have "$t" || die "$t is missing — install it and re-run"; done
[ -n "$RUNTIME" ] || die "the package is built and tested in Fedora containers: install podman or docker (NixOS: virtualisation.podman.enable = true;)"

# ============================================================== 1. the app
linux_app "1/6  Your app"
rpm_kind_ok
fedora_questions
RPM_WD="$CACHE/fedora/$PNAME"
mkdir -p "$RPM_WD/out"

fedora_where
# the same software? Fedora's URL is the project's, or its registry page
if [ -n "$FED_VER" ] && [ -n "$FED_URL" ] && ! printf '%s' "$FED_URL" | grep -qiF "$SLUG" && [ "${FED_URL%/}" != "${HOMEPAGE%/}" ] \
   && ! printf '%s' "$FED_URL" | grep -qiE "(crates\.io/crates|pypi\.org/project|npmjs\.com/package)/$PNAME/?\$|pkg\.go\.dev/"; then
  say "Fedora has a '$PNAME' whose homepage is $FED_URL"
  [ "$ASSUME_YES" = 0 ] && confirm "Is that your app?" n \
    || die "Fedora's '$PNAME' is a different project — yours needs another name: set name = … in ${LINUX_CONF#"$REPO"/}"
fi

if [ -n "$FED_VER" ]; then
  # --------------------------------------------------- already in Fedora
  RPM_VERSION="$(printf '%s' "$VERSION" | tr -- '-' '~')"
  ok "$PNAME is in Fedora: Rawhide has $FED_VER (https://src.fedoraproject.org/rpms/${FED_SRC:-$PNAME})"
  [ "$FED_VER" = "$RPM_VERSION" ] && { ok "Fedora Rawhide has $VERSION already — nothing to do"; exit 0; }
  [ "$(printf '%s\n%s\n' "$FED_VER" "$RPM_VERSION" | sort -V | tail -1)" = "$RPM_VERSION" ] \
    || die "Fedora Rawhide has $FED_VER, newer than $VERSION — nothing to update"
  say "Updates in Fedora are made by the package's maintainers, with fedpkg and Bodhi."
  [ -n "$FED_MAINT" ] && say "Its maintainers: $FED_MAINT"
  ME=0; [ -n "$FAS_USER" ] && case " $FED_MAINT " in *" $FAS_USER "*) ME=1 ;; esac
  step "2/6  The spec, bumped"
  SRC_REPO="${FED_SRC:-$PNAME}"
  rm -rf "$RPM_WD"; mkdir -p "$RPM_WD/out"
  # Fedora's dist-git, read anonymously: the spec, its patches and other files
  run_logged "$WORK/distgit.log" "fetching https://src.fedoraproject.org/rpms/$SRC_REPO" \
    git clone -q --depth 1 "https://src.fedoraproject.org/rpms/$SRC_REPO.git" "$RPM_WD/dist-git" \
    || die "couldn't fetch https://src.fedoraproject.org/rpms/$SRC_REPO"
  (cd "$RPM_WD/dist-git" && find . -maxdepth 1 -type f ! -name sources ! -name '.*' -exec cp {} "$RPM_WD/" \;)
  RPM_SPECNAME="$SRC_REPO"; SPECF="$RPM_WD/$SRC_REPO.spec"
  [ -f "$SPECF" ] || die "dist-git has no $SRC_REPO.spec"
  sed -i -E "s/^(Version:[[:space:]]*).*/\\1$RPM_VERSION/" "$SPECF"
  if grep -qE '^Release:[[:space:]]*[0-9]' "$SPECF"; then
    sed -i -E 's/^(Release:[[:space:]]*)[0-9]+/\11/' "$SPECF"
    if ! grep -q '^%autochangelog' "$SPECF"; then
      sed -i "/^%changelog/a * $(LC_ALL=C date +'%a %b %d %Y') $MAINT_NAME <${MAINT_EMAIL:-$BZ_EMAIL}> - $RPM_VERSION-1\\
- Update to $VERSION\\
" "$SPECF"
    fi
  fi
  ok "Fedora's spec, Version $RPM_VERSION: $SPECF"
  if grep -qE '^Source[0-9]*:.*vendor' "$SPECF"; then
    warn "it vendors its dependencies: the maintainers make a new vendor archive for $VERSION (rust2rpm / go_vendor_archive)"
  elif [ "$NO_TEST" = 0 ]; then
    step "3/6  Build + check"
    RPM_FETCH=1
    rpm_build "$RPM_FEDORA_IMG:rawhide" fedora
  fi
  if [ "$ME" = 1 ]; then
    handoff_add "fedpkg clone $SRC_REPO && cd $SRC_REPO — then copy in $SPECF"
    handoff_add "fedpkg new-sources <the new tarball> (spectool -g $SRC_REPO.spec downloads it); fedpkg commit -m \"Update to $VERSION\" --push"
    handoff_add "fedpkg build — then for each stable release: fedpkg switch-branch f<N>, git merge rawhide, git push, fedpkg build, fedpkg update"
  else
    handoff_add "Open a pull request on https://src.fedoraproject.org/rpms/$SRC_REPO (Fork, then change the spec to $SPECF) — or ask the maintainers in a bug: $BZ_URL/enter_bug.cgi?product=Fedora&component=$SRC_REPO"
    handoff_add "Fedora's Release Monitoring may have opened a \"$PNAME-$VERSION is available\" bug already — add to it rather than opening another"
  fi
  save_answers
  handoff_show "Your turn — updates in Fedora go through its maintainers" "https://src.fedoraproject.org/rpms/$SRC_REPO"
  exit 0
fi
[ -n "$FED_SRC" ] && warn "Fedora had $FED_SRC once and retired it — a re-review brings it back (Bugzilla: add Unretirement to the Whiteboard)"
ok "$PNAME is not in Fedora — a new package goes through a review"

# --- a review request for it already?
MODE=new; BUG=""
REVIEWS="$(fedora_reviews)"
while IFS='|' read -r id st res who; do
  [ -n "$id" ] || continue
  case "$st" in
    CLOSED) note "an earlier review request was closed ($res): $BZ_URL/show_bug.cgi?id=$id — worth reading" ;;
    *) if [ "$who" = "${BZ_EMAIL%@*}" ] || [ "$who" = "$BZ_EMAIL" ] || { [ -n "$FAS_USER" ] && [ "$who" = "$FAS_USER" ]; }; then
         MODE=update-review; BUG="$id"; ok "your review request is open: $BZ_URL/show_bug.cgi?id=$id — this run posts a new spec and SRPM to it"
       else
         say "$PNAME is under review already, requested by $who: $BZ_URL/show_bug.cgi?id=$id"
         note "help there instead (an informal review is welcome), or ask its submitter"
         die "someone else is packaging $PNAME for Fedora"
       fi ;;
  esac
done <<EOF
$REVIEWS
EOF

# ============================================================== 2. the spec
step "2/6  The spec"
rm -rf "$RPM_WD"; mkdir -p "$RPM_WD/out"
RPM_REL=1; RPM_FETCH=0
case "$KIND" in
  rust) note "Fedora's Rust guidelines prefer crates packaged in Fedora (SHOULD NOT bundle \"whenever possible\");"
        note "this spec vendors them, which they allow — reviewers may ask which crates could come from Fedora" ;;
  go)   note "Fedora's Go guidelines require vendored modules (go-vendor-tools); new Go library packages aren't accepted" ;;
  python) note "every Python dependency must be packaged in Fedora already — the build below checks" ;;
  node) note "Fedora's Node.js guidelines have apps bundle their npm modules; the bundled licenses are listed" ;;
esac
if ! rpm_own_spec fedora; then
  rpm_prepare fedora
fi

# ========================================================== 3. build + check
step "3/6  Build + check"
IMG="$RPM_FEDORA_IMG:rawhide"
if [ "$NO_TEST" = 1 ]; then
  warn "--no-test: not test-built — reviewers check that it builds, so this is worth doing"
  rpm_srpm "$IMG" fedora
else
  rpm_build "$IMG" fedora
  if [ "$TESTED" = 1 ]; then
    rpm_try "$IMG"
    [ "${RPMLINT_E:-0}" -gt 0 ] && warn "Fedora's rpmlint setup fails on any error (E:) — the reviewers will ask to fix them or explain them"
  else
    grep -q '^MISSING: python3dist' "$WORK/test.log" 2>/dev/null \
      && handoff_add "These Python dependencies aren't in Fedora: $(grep '^MISSING: python3dist' "$WORK/test.log" | sed 's/^MISSING: //' | tr '\n' ' ')— each needs its own review first (pyp2spec makes a start)"
  fi
fi
SRPM="$(ls "$RPM_WD"/out/*.src.rpm 2>/dev/null | head -1 || true)"
[ -n "$SRPM" ] || die "no source RPM came out — see $WORK/test.log"
if have fedora-review && have mock; then
  if [ "$ASSUME_YES" = 0 ] && confirm "Run fedora-review on it now (mock, a few minutes)?" n; then
    ( cd "$RPM_WD/out" && fedora-review --rpm-spec --name "$SRPM" ) > "$WORK/fedora-review.log" 2>&1 \
      && ok "fedora-review: $RPM_WD/out/review-$PNAME/review.txt" || warn "fedora-review failed — log: $WORK/fedora-review.log"
  fi
else
  note "fedora-review isn't run here — Fedora's Review Service runs it on the review request by itself"
fi

# --- you read it: Fedora wants packagers who understand their packages
echo; sed 's/^/     /' "$RPM_WD/$PNAME.spec"; echo
REVIEWED=0
if [ "$ASSUME_YES" = 1 ]; then
  [ "$DRYRUN" = 1 ] || { warn "--yes: nobody has read the spec — Fedora's reviewers expect you to understand every line"
    die "run once without --yes to read and submit it (it's ready in $RPM_WD)"; }
elif confirm "Have you read the spec, and do you stand behind it?" n; then
  REVIEWED=1
else
  note "edit it in $RPM_WD/$PNAME.spec and re-run, or ask in Fedora's packaging chat: https://matrix.to/#/#devel:fedoraproject.org"
  exit 1
fi

save_answers
ABOUT="${ABOUT:-$(rpm_about)}"
SUMMARY="Review Request: $PNAME - $DESC"
if [ "$DRYRUN" = 1 ]; then
  warn "dry run — nothing went to COPR or Bugzilla; it's all in $RPM_WD"
  note "the review request would be: $SUMMARY"
  exit 0
fi

# ============================================================ 4. online copy
step "4/6  The spec and SRPM online (COPR)"
note "Fedora's docs recommend COPR for this: the reviewers download both from there"
copr_login
COPR_PROJECT="$(cfg_get copr-project)"; COPR_PROJECT="${COPR_PROJECT:-$PNAME}"
COPR_CHROOTS="fedora-rawhide-x86_64"
copr_split
copr_project
go "Upload $(basename "$SRPM") to $COPR_FULL (public) and build it for Fedora Rawhide?" || { note "the spec and SRPM are in $RPM_WD"; exit 0; }
copr_build "$SRPM" fedora-rawhide-x86_64
copr_wait || die "COPR couldn't build it for Fedora Rawhide (above) — reviewers would see the same; fix the spec and re-run"
ID8="$(printf '%08d' "$COPR_BUILD")"
SPEC_URL="$COPR_DL/$COPR_FULL/srpm-builds/$ID8/$PNAME.spec"
SRPM_URL="$(copr_api "build/$COPR_BUILD" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("source_package") or {}).get("url") or "")' 2>/dev/null || true)"
[ -n "$SRPM_URL" ] || SRPM_URL="$COPR_DL/$COPR_FULL/srpm-builds/$ID8/$(basename "$SRPM")"
for u in "$SPEC_URL" "$SRPM_URL"; do
  curl -sfIL --max-time 30 -o /dev/null "$u" || warn "not downloadable (yet?): $u"
done
ok "Spec URL: $SPEC_URL"
ok "SRPM URL: $SRPM_URL"

# ========================================================= 5. review request
step "5/6  The review request"
TEXT="$RPM_WD/review-request.txt"
{
  printf 'Spec URL: %s\nSRPM URL: %s\n\nDescription:\n' "$SPEC_URL" "$SRPM_URL"
  rpm_wrap "$ABOUT"
  printf '\nFedora Account System Username: %s\n' "${FAS_USER:-(none yet)}"
  printf '\nUpstream: %s\n' "$WEB"
  [ "$FE_PACKAGER" = yes ] || printf '\nThis is my first package for Fedora; I need a sponsor.\n'
  printf 'COPR build: %s/coprs/build/%s/\n' "$COPR_URL" "$COPR_BUILD"
  [ "$TESTED" = 1 ] && printf 'rpmlint: %s error(s); it builds offline in Fedora Rawhide and installs cleanly.\n' "${RPMLINT_E:-0}"
  [ "$REVIEWED" = 1 ] && printf '\nThe spec was generated with linux-submit.sh (https://github.com/by-architect/StoreHelper) from the project; I have read it and stand behind it.\n'
} > "$TEXT"
printf '   %sSummary:%s %s\n\n' "$B" "$R" "$SUMMARY"
sed 's/^/     /' "$TEXT"; echo

# --- your Bugzilla API key: from the last time, or now (optional)
BZ_KEY=""
[ -f "$BZ_KEY_FILE" ] && BZ_KEY="$(cat "$BZ_KEY_FILE")"
if [ -z "$BZ_KEY" ] && [ "$ASSUME_YES" = 0 ]; then
  say "The wizard can file it for you with a Bugzilla API key (or you file it yourself):"
  note "make one at $BZ_URL/userprefs.cgi?tab=apikey (log in with your Fedora account's email) — blank to skip"
  printf '   %sBugzilla API key%s (hidden): ' "$B" "$R" >&2
  IFS= read -rs BZ_KEY || BZ_KEY=""; printf '\n' >&2
fi
if [ -n "$BZ_KEY" ]; then
  if bz GET "bug/$FE_NEEDSPONSOR?include_fields=id" | grep -q '"code":306'; then
    warn "Bugzilla doesn't accept that API key"; BZ_KEY=""; rm -f "$BZ_KEY_FILE"
  else
    mkdir -p "$CONF_DIR"; ( umask 077; printf '%s' "$BZ_KEY" > "$BZ_KEY_FILE" ); chmod 600 "$BZ_KEY_FILE"
    ok "Bugzilla API key works (kept in $BZ_KEY_FILE, readable only by you)"
  fi
fi

BUG_LINK=""
if [ -n "$BZ_KEY" ] && [ "$MODE" = update-review ]; then
  if go "Post the new Spec and SRPM URLs to $BZ_URL/show_bug.cgi?id=$BUG?"; then
    RESP="$(bz POST "bug/$BUG/comment" "$(bz_json "comment=$(printf 'Spec URL: %s\nSRPM URL: %s\n\nUpdated with linux-submit.sh: %s %s.' "$SPEC_URL" "$SRPM_URL" "$PNAME" "$VERSION")")")"
    printf '%s' "$RESP" | grep -q '"id"' && ok "posted — Fedora's Review Service builds it again by itself" \
      || { printf '%s\n' "$RESP" | head -3 | sed 's/^/     /'; warn "Bugzilla didn't take the comment"; handoff_add "Post the new Spec URL and SRPM URL (in $TEXT) as a comment on $BZ_URL/show_bug.cgi?id=$BUG"; }
  fi
  BUG_LINK="$BZ_URL/show_bug.cgi?id=$BUG"
elif [ -n "$BZ_KEY" ]; then
  if go "File \"$SUMMARY\" in Red Hat Bugzilla?"; then
    RESP="$(bz POST bug "$(bz_json product=Fedora "component=Package Review" version=rawhide "summary=$SUMMARY" "description=$(cat "$TEXT")")")"
    BUG="$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
    if [ -n "$BUG" ]; then
      ok "filed: $BZ_URL/show_bug.cgi?id=$BUG"
      if [ "$FE_PACKAGER" != yes ]; then
        bz PUT "bug/$BUG" "{\"ids\": [$BUG], \"blocks\": {\"add\": [$FE_NEEDSPONSOR]}}" | grep -q '"bugs"' \
          && ok "it blocks FE-NEEDSPONSOR, where sponsors look for new packagers" \
          || handoff_add "Add FE-NEEDSPONSOR to the \"Blocks\" field of $BZ_URL/show_bug.cgi?id=$BUG"
      fi
      BUG_LINK="$BZ_URL/show_bug.cgi?id=$BUG"
    else
      printf '%s\n' "$RESP" | head -3 | sed 's/^/     /'
      warn "Bugzilla didn't take it"
    fi
  fi
fi
if [ -z "$BUG_LINK" ]; then
  BUG_LINK="$BZ_URL/enter_bug.cgi?product=Fedora&format=fedora-review"
  if [ "$MODE" = update-review ]; then
    handoff_add "Post the new Spec URL and SRPM URL (in $TEXT) as a comment on $BZ_URL/show_bug.cgi?id=$BUG"
  else
    handoff_add "File the review request: open the link below, Summary: $SUMMARY — and paste $TEXT as the description"
    [ "$FE_PACKAGER" = yes ] || handoff_add "In it, put FE-NEEDSPONSOR in the \"Blocks\" field (new packagers need a sponsor)"
  fi
fi

# ============================================================== 6. hand-off
step "6/6  Hand-off"
[ -n "$FAS_USER" ] || handoff_add "Create your Fedora account at https://accounts.fedoraproject.org and sign the Fedora Project Contributor Agreement there"
handoff_add "Log in to $BZ_URL with your Fedora account's email ($BZ_EMAIL) — reviews from other addresses get closed"
if [ "$FE_PACKAGER" != yes ]; then
  handoff_add "Find a sponsor: $FEDORA_DOCS/How_to_Get_Sponsored_into_the_Packager_Group/ — reviewing others' packages (informal reviews) helps"
fi
handoff_add "Answer the reviewers on the bug. After a fix, run linux-submit.sh fedora again: it builds the new spec on COPR and posts the new links"
handoff_add "Approved (fedora-review+)? Make a Fedora Forge API token (issues: read and write) into ~/.config/rpkg/fedpkg.conf as [fedpkg.forgejo] token = …, then: fedpkg request-repo $PNAME ${BUG:-<bug number>}"
handoff_add "When the repository exists: fedpkg clone $PNAME; cd $PNAME; fedpkg import $RPM_WD/out/$(basename "$SRPM"); git commit -m \"Initial import (fedora#${BUG:-<bug>}).\"; git push; fedpkg build"
handoff_add "For stable Fedora releases: fedpkg request-branch f<N>, then fedpkg switch-branch f<N>, git merge rawhide, git push, fedpkg build, fedpkg update"
handoff_add "Add $PNAME to https://release-monitoring.org so Fedora tells you about new versions"
handoff_show "Your turn — Fedora's package review is done by people" "$BUG_LINK"
}

# ##########################################################################
#   openSUSE Build Service — questions shared with a Linux run, and helpers
# ##########################################################################
OBS_API="${OBS_API:-https://api.opensuse.org}"
OBS_WEB="${OBS_WEB:-https://build.opensuse.org}"
OBS_DL="https://download.opensuse.org/repositories"
OSCRC="${XDG_CONFIG_HOME:-$HOME/.config}/osc/oscrc"
[ -f "$OSCRC" ] || { [ -f "$HOME/.oscrc" ] && OSCRC="$HOME/.oscrc"; }

# oscx <args…> — osc, OBS's own client (and login): yours, or from nixpkgs
oscx() {
  if have osc; then osc -A "$OBS_API" "$@"; else tool osc osc -A "$OBS_API" "$@"; fi
}

# obs_targets — the openSUSE releases OBS builds for (its /distributions,
# which needs the login), as "reponame|name|project|repository|archs" lines
obs_targets() {
  oscx api /distributions > "$WORK/dists.xml" 2>/dev/null || return 1
  python3 - "$WORK/dists.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
for d in ET.parse(sys.argv[1]).getroot().findall("distribution"):
    if d.get("vendor") != "openSUSE":
        continue
    archs = [a.text for a in d.findall("architecture") if a.text in ("x86_64", "aarch64")]
    if archs:
        print("|".join([d.findtext("reponame"), d.findtext("name"), d.findtext("project"), d.findtext("repository"), " ".join(archs)]))
PY
}

# obs_questions — your OBS account, and (once osc is logged in) the openSUSE
# releases to build for. Part of "Your app" whenever OBS is among the distros.
obs_questions() {
  local guess
  guess="$(cfg_get obs-user)"
  [ -n "$guess" ] || guess="$(sed -nE 's/^[[:space:]]*user[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$OSCRC" 2>/dev/null | head -1)"
  if [ -n "$(cfg_get obs-user)" ] && [ "$ASK_ALL" = 0 ]; then OBS_USER="$guess"
  else
    note "your openSUSE account (no account yet? sign up on $OBS_WEB) — your packages live in home:<you>"
    ask OBS_USER "openSUSE (OBS) username" "$guess"
    [ "${SAVE:-1}" = 1 ] && cfg_set obs-user "$OBS_USER"
  fi
  ok "OBS: home:$OBS_USER"
  OBS_TARGETS="$(cfg_get obs-targets)"
  [ -n "$OBS_TARGETS" ] && [ "$ASK_ALL" = 0 ] && { ok "builds for: $OBS_TARGETS"; return 0; }
  # the list needs osc's login: without one yet, it's asked after logging in
  [ -f "$OSCRC" ] || { note "the openSUSE releases are asked once osc is logged in"; OBS_TARGETS=""; return 0; }
  obs_pick_targets
}
# obs_pick_targets — the openSUSE releases to build for, from OBS's own list
obs_pick_targets() {
  local items="" pre="" rn name repo archs keep=""
  obs_targets > "$WORK/targets.txt" 2>/dev/null && [ -s "$WORK/targets.txt" ] \
    || { warn "couldn't read OBS's list of releases — using openSUSE Tumbleweed"
         printf 'openSUSE_Tumbleweed|openSUSE Tumbleweed|openSUSE:Factory|snapshot|x86_64\n' > "$WORK/targets.txt"
         OBS_TARGETS="openSUSE_Tumbleweed"; return 0; }
  while IFS='|' read -r rn name _ repo archs; do
    items="$items$rn|$name|1|$archs"$'\n'
    case "$rn" in *Tumbleweed*) pre="$pre $rn" ;; esac
  done < "$WORK/targets.txt"
  if [ "$ASSUME_YES" = 1 ]; then keep="$(printf '%s' "$pre" | xargs)"
  else say "Which openSUSE releases should OBS build for? (Fedora: linux-submit.sh copr fits better)"; multi_select keep "$items" "$pre"; fi
  OBS_TARGETS="$keep"
  [ "${SAVE:-1}" = 1 ] && cfg_set obs-targets "$OBS_TARGETS"
  ok "builds for: $OBS_TARGETS"
}

# obs_changes <file> <entry> — a new entry on top of the .changes file (osc vc's format)
obs_changes() {
  local f="$1" old=""
  if [ -f "$f" ]; then old="$(cat "$f")"; fi
  { printf -- '-------------------------------------------------------------------\n'
    printf '%s - %s <%s>\n\n' "$(LC_ALL=C date -u +'%a %b %e %H:%M:%S UTC %Y')" "$MAINT_NAME" "$RPM_EMAIL"
    printf -- '- %s\n' "$2"
    if [ -n "$old" ]; then printf '\n%s\n' "$old"; fi; } > "$f.new"
  mv "$f.new" "$f"
}

# ##########################################################################
#   openSUSE (OBS) wizard — linux-submit.sh obs [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_obs() {
#
# linux-submit.sh obs — publish an app for openSUSE through the Open Build
# Service (build.opensuse.org), in your home:<you> project, or a new version.
#
# Follows openSUSE's documentation:
#   https://openbuildservice.org/help/manuals/obs-user-guide/
#   https://en.opensuse.org/openSUSE:Packaging_guidelines
#   https://en.opensuse.org/openSUSE:Packaging_Rust_Software (and _Go, _Python)
#   https://en.opensuse.org/openSUSE:How_to_contribute_to_Factory
#
# Writes an openSUSE-style spec (Release: 0, a .changes file, vendored Rust,
# Go and npm dependencies in the layout OBS's own services make), test-builds
# it offline in a Tumbleweed container with rpmlint, sets up the releases in
# your home project with osc (OBS's client and login), commits the package
# and waits for OBS's builds. Getting into openSUSE itself (Factory) goes
# through a devel project's maintainers: shown at the end, yours to do.

set -eu

DRYRUN=0
SAVE=1
ASSUME_YES=0
ASK_ALL=0
NO_TEST=0
REPO_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/obs-submit"
CONF="$CONF_DIR/last.conf"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/store-submit"

usage() {
  cat <<'USAGE'
linux-submit.sh obs — publish an app for openSUSE through the Open Build Service.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask (osc's first
                      login still needs you)
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --config FILE   the shared answers (default: .store-submit.conf in the repo)
      --no-test       skip the offline test build in a Tumbleweed container
  -n, --dry-run       write, vendor and test-build; commit nothing to OBS
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
    --no-test)    NO_TEST=1 ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF"; printf 'forgot %s\n' "$CONF"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WIZ_NAME=obs-submit
linux_common

SAVED_REPO=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  { printf '# written by linux-submit.sh obs — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n' "${REPO:-${SAVED_REPO:-}}"; } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}

RUNTIME=""
for r in podman docker; do have "$r" && "$r" info >/dev/null 2>&1 && { RUNTIME="$r"; break; }; done

# =============================================================== 0. orientation
cat <<BANNER

  ${B}openSUSE Build Service wizard${R}  (zypper — Tumbleweed, Leap…)

  Six stages:
    1. your app        — shared with the other distros, plus your OBS account
    2. osc + login     — OBS's client (yours, or from nixpkgs) and its own login;
                         the openSUSE releases to build for
    3. spec + sources  — openSUSE-style spec, the release tarball, vendored
                         dependencies, a .changes entry
    4. test build      — offline in a Tumbleweed container, rpmlint, installed
    5. commit          — the releases set up in home:<you>, the package committed
    6. results         — OBS builds it for each release; how people install it

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: written and test-built; nothing is committed to OBS"
for t in git curl python3 tar sha256sum; do have "$t" || die "$t is missing — install it and re-run"; done
[ -n "$RUNTIME" ] || die "the package is made and tested in openSUSE containers: install podman or docker (NixOS: virtualisation.podman.enable = true;)"
have osc || have nix-build || die "osc (OBS's client) is missing — install it: zypper in osc / dnf install osc / pip install osc"

# ============================================================== 1. the app
linux_app "1/6  Your app"
rpm_kind_ok
obs_questions

# =========================================================== 2. osc + login
step "2/6  osc and your OBS login"
if have osc; then ok "osc: $(command -v osc)"; else ok "osc: from nixpkgs"; fi
if [ "$DRYRUN" = 1 ] && [ ! -f "$OSCRC" ]; then
  note "dry run: not logging in"
else
  while :; do
    if [ ! -f "$OSCRC" ]; then
      [ "$ASSUME_YES" = 1 ] && die "log in to OBS once without --yes (osc asks for your username and password)"
      say "osc asks for your openSUSE username and password itself, once, and keeps them"
      note "(in your desktop's keyring if there is one; otherwise it offers to store them in $OSCRC)"
      oscx whois || true
      [ -f "$OSCRC" ] || { [ -f "$HOME/.oscrc" ] && OSCRC="$HOME/.oscrc"; }
    fi
    WHO="$(oscx whois 2>"$WORK/osc.err" < /dev/null | head -1 || true)"
    [ -n "$WHO" ] && break
    tail -n 3 "$WORK/osc.err" | sed 's/^/     /'
    warn "osc couldn't log in to $OBS_API"
    [ "$ASSUME_YES" = 1 ] && die "check osc's login: osc -A $OBS_API whois"
    confirm "Try again?" y || die "OBS needs your login"
  done
  LOGIN="${WHO%%:*}"
  ok "logged in to OBS as $WHO"
  if [ "$LOGIN" != "$OBS_USER" ]; then
    warn "osc is logged in as $LOGIN, the config says $OBS_USER — using $LOGIN"
    OBS_USER="$LOGIN"; [ "$SAVE" = 1 ] && cfg_set obs-user "$OBS_USER"
  fi
fi
PRJ="home:$OBS_USER"
if [ -z "$OBS_TARGETS" ]; then
  if [ -f "$OSCRC" ]; then obs_pick_targets
  else
    OBS_TARGETS="openSUSE_Tumbleweed"
    printf 'openSUSE_Tumbleweed|openSUSE Tumbleweed|openSUSE:Factory|snapshot|x86_64\n' > "$WORK/targets.txt"
    note "OBS's list of releases needs the login — openSUSE Tumbleweed for now"
  fi
fi

# ========================================================= 3. spec + sources
step "3/6  Spec and sources"
RPM_WD="$CACHE/obs/$PNAME"
rm -rf "$RPM_WD"; mkdir -p "$RPM_WD/out"
RPM_REL=1; RPM_FETCH=0
rpm_prepare suse
RPM_EMAIL="${MAINT_EMAIL:-$(git -C "$REPO" config user.email 2>/dev/null || echo "$(id -un)@localhost")}"
obs_changes "$RPM_WD/$PNAME.changes" "Update to version $VERSION"
ok "a .changes entry (openSUSE keeps the changelog there, not in the spec)"

# ============================================================ 4. test build
step "4/6  Test build"
case " $OBS_TARGETS " in *Leap*) note "tested on Tumbleweed; OBS builds the Leap releases itself (older compilers there may need changes)" ;; esac
if [ "$NO_TEST" = 1 ]; then
  warn "--no-test: not test-built"
  rpm_srpm "$RPM_SUSE_IMG" suse
else
  rpm_build "$RPM_SUSE_IMG" suse
  rpm_try "$RPM_SUSE_IMG"
fi
echo; sed 's/^/     /' "$RPM_WD/$PNAME.spec"; echo

save_answers
if [ "$DRYRUN" = 1 ]; then
  warn "dry run — nothing committed to OBS; it's all in $RPM_WD"
  exit 0
fi

# ================================================================ 5. commit
step "5/6  Commit to $PRJ"
# --- the releases in your home project (made if it doesn't exist); their
# OBS paths come from OBS's list of releases
if [ ! -s "$WORK/targets.txt" ]; then
  obs_targets > "$WORK/targets.txt" 2>/dev/null || true
  [ -s "$WORK/targets.txt" ] || printf 'openSUSE_Tumbleweed|openSUSE Tumbleweed|openSUSE:Factory|snapshot|x86_64\n' > "$WORK/targets.txt"
fi
oscx meta prj "$PRJ" > "$WORK/prj.xml" 2>/dev/null || : > "$WORK/prj.xml"
for t in $OBS_TARGETS; do grep "^$t|" "$WORK/targets.txt" || true; done > "$WORK/chosen.txt"
python3 - "$WORK/prj.xml" "$OBS_USER" "$WORK/chosen.txt" > "$WORK/prj.new.xml" 2>"$WORK/prj.changed" <<'PY'
import sys, xml.etree.ElementTree as ET
meta, user, chosen = sys.argv[1:4]
try:
    root = ET.parse(meta).getroot()
except Exception:
    root = ET.fromstring('<project name="home:%s"><title>%s\'s home project</title><description/>'
                         '<person userid="%s" role="maintainer"/></project>' % (user, user, user))
have = {r.get("name") for r in root.findall("repository")}
for line in open(chosen):
    rn, name, prj, repo, archs = line.rstrip("\n").split("|")
    if rn in have:
        continue
    r = ET.SubElement(root, "repository", name=rn)
    ET.SubElement(r, "path", project=prj, repository=repo)
    for a in archs.split():
        ET.SubElement(r, "arch").text = a
    sys.stderr.write(rn + " ")
ET.indent(root)
sys.stdout.write(ET.tostring(root, encoding="unicode") + "\n")
PY
if [ -s "$WORK/prj.changed" ]; then
  go "Add $(cat "$WORK/prj.changed")to $PRJ's build targets?" || die "the package needs releases to build for"
  oscx meta prj "$PRJ" -F "$WORK/prj.new.xml" > "$WORK/meta.log" 2>&1 \
    || { tail -n 4 "$WORK/meta.log" | sed 's/^/     /'; die "OBS didn't take the project settings"; }
  ok "$PRJ builds for: $OBS_TARGETS"
else
  ok "$PRJ builds for: $OBS_TARGETS already"
fi
# --- the package
python3 - "$PNAME" "$PRJ" "$DESC" "$(rpm_about)" "$HOMEPAGE" > "$WORK/pkg.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
name, prj, title, about, url = sys.argv[1:6]
p = ET.Element("package", name=name, project=prj)
ET.SubElement(p, "title").text = title
ET.SubElement(p, "description").text = about
ET.SubElement(p, "url").text = url
ET.indent(p)
print(ET.tostring(p, encoding="unicode"))
PY
if oscx meta pkg "$PRJ" "$PNAME" >/dev/null 2>&1; then
  MODE=update; ok "$PRJ/$PNAME exists — this is an update"
else
  MODE=new
  go "Create the package $PRJ/$PNAME?" || die "nothing to commit to"
  oscx meta pkg "$PRJ" "$PNAME" -F "$WORK/pkg.xml" > "$WORK/meta.log" 2>&1 \
    || { tail -n 4 "$WORK/meta.log" | sed 's/^/     /'; die "OBS didn't create $PRJ/$PNAME"; }
  ok "created $OBS_WEB/package/show/$PRJ/$PNAME"
fi
# --- a working copy in the cache, the new files in it
WC="$CACHE/obs/wc/$PRJ/$PNAME"
if [ -d "$WC/.osc" ]; then (cd "$WC" && oscx update >"$WORK/up.log" 2>&1) || { rm -rf "$WC"; }; fi
if [ ! -d "$WC/.osc" ]; then
  mkdir -p "$(dirname "$WC")"
  (cd "$(dirname "$WC")" && oscx checkout -o "$PNAME" "$PRJ" "$PNAME" >"$WORK/co.log" 2>&1) \
    || { tail -n 4 "$WORK/co.log" | sed 's/^/     /'; die "couldn't check out $PRJ/$PNAME"; }
fi
find "$WC" -maxdepth 1 -type f \( -name '*.spec' -o -name '*.tar.*' -o -name '*.tgz' -o -name '*bundled-licenses.txt' -o -name 'vendor.tar.*' \) -delete
cp "$RPM_WD/$PNAME.spec" "$WC/"
for f in $(cd "$RPM_WD" && ls "$SRC_FILE" vendor.tar.zst "$PNAME-$VERSION"-nm-*.tgz "$PNAME-$VERSION-bundled-licenses.txt" 2>/dev/null); do cp "$RPM_WD/$f" "$WC/"; done
if [ "$MODE" = new ]; then obs_changes "$WC/$PNAME.changes" "Initial package of $PNAME $VERSION"
else obs_changes "$WC/$PNAME.changes" "Update to version $VERSION${CHANGELOG_REAL:+ — changes: $CHANGELOG_REAL}"; fi
(cd "$WC" && oscx addremove >/dev/null 2>&1) || true
(cd "$WC" && oscx status 2>/dev/null | sed 's/^/     /') || true
# OBS's own local build, when its build tool is installed (openSUSE has it
# with osc): the same build OBS runs, before anything is committed
if [ "$ASSUME_YES" = 0 ] && { [ -x /usr/bin/build ] || [ -x /usr/lib/build/build ]; }; then
  T1="${OBS_TARGETS%% *}"
  if confirm "Also run osc build $T1 $(uname -m) here first? (OBS's own local build — sudo, a buildroot download)" n; then
    (cd "$WC" && oscx build "$T1" "$(uname -m)") && ok "osc build: it builds" \
      || { warn "osc build failed (above)"; confirm "Commit anyway?" n || { note "the working copy is in $WC"; exit 1; }; }
  fi
fi
go "Commit $PNAME $VERSION to $PRJ?" || { note "the working copy is in $WC"; exit 0; }
(cd "$WC" && oscx commit -m "$( [ "$MODE" = new ] && echo "Initial package of $PNAME $VERSION" || echo "Update to $VERSION")" >"$WORK/ci.log" 2>&1) \
  || { tail -n 6 "$WORK/ci.log" | sed 's/^/     /'; die "the commit failed — the working copy is in $WC"; }
ok "committed: $OBS_WEB/package/show/$PRJ/$PNAME"

# =============================================================== 6. results
step "6/6  OBS builds it"
t0="$(date +%s)"; i=0; spin='|/-\'
while :; do
  oscx results "$PRJ" "$PNAME" --csv --format repository,arch,state,dirty,details > "$WORK/results.csv" 2>/dev/null || true
  PENDING="$(python3 -c '
import csv, sys
n = 0
for r in csv.reader(open(sys.argv[1])):
    if len(r) >= 4 and r[0] != "repository" and (r[2] not in ("succeeded", "failed", "unresolvable", "broken", "disabled", "excluded", "locked") or r[3].lower() in ("true", "1")):
        n += 1
print(n)' "$WORK/results.csv" 2>/dev/null || echo 1)"
  [ "$PENDING" = 0 ] && [ -s "$WORK/results.csv" ] && break
  el=$(( $(date +%s) - t0 ))
  if [ "$el" -gt 10800 ]; then warn "still building after 3 hours — check $OBS_WEB/package/show/$PRJ/$PNAME"; break; fi
  if [ -t 1 ]; then printf '\r\033[K   %s %sOBS is building%s %s%d of the releases pending — %dm%02ds (Ctrl-C is safe: OBS carries on)%s' "${spin:i%4:1}" "$B" "$R" "$DIM" "$PENDING" $((el / 60)) $((el % 60)) "$R"
  elif [ $((i % 10)) = 0 ]; then say "OBS: $PENDING pending ($((el / 60)) min)"; fi
  i=$((i + 1)); sleep 20
done
[ -t 1 ] && printf '\r\033[K'
FAILED=0
while IFS=, read -r repo arch state _ details; do
  [ -n "$repo" ] && [ "$repo" != repository ] || continue
  case "$state" in
    succeeded) ok "$repo $arch: built" ;;
    disabled|excluded) note "$repo $arch: $state" ;;
    *) bad "$repo $arch: $state${details:+ — $details}"; FAILED=1
       oscx remotebuildlog "$PRJ" "$PNAME" "$repo" "$arch" 2>/dev/null | grep -vE '^\s*$' | tail -n 10 | cut -c1-200 | sed 's/^/       /' || true ;;
  esac
done < "$WORK/results.csv"
[ "$FAILED" = 0 ] || { warn "fix the spec (it's in $WC), then run the wizard again"; note "$OBS_WEB/package/show/$PRJ/$PNAME"; exit 1; }

printf '\n   %sDone.%s %s %s → %s\n   %s/package/show/%s/%s\n\n' "$B" "$R" "$PNAME" "$VERSION" "$PRJ" "$OBS_WEB" "$PRJ" "$PNAME"
say "  • People install it with (Tumbleweed shown; each release has its own):"
say "      sudo zypper addrepo $OBS_DL/home:/$OBS_USER/$(printf '%s' "${OBS_TARGETS%% *}")/home:$OBS_USER.repo"
say "      sudo zypper refresh && sudo zypper install $PNAME"
say "    or with one click: https://software.opensuse.org//download.html?project=home%3A$OBS_USER&package=$PNAME"
say "  • Next release: run linux-submit.sh obs (or linux-submit.sh) again."
say "  • Optional — into openSUSE itself (Tumbleweed): packages enter Factory through a devel"
say "    project that fits (osc develproject openSUSE:Factory <a similar package> names it):"
say "      osc submitrequest $PRJ $PNAME <devel project>"
say "    its maintainers review it and pass it on to openSUSE:Factory, which reviews it again"
say "    (https://en.opensuse.org/openSUSE:How_to_contribute_to_Factory)."
echo
}

# ##########################################################################
#   Alpine Linux (aports) — questions shared with a Linux run, and helpers
# ##########################################################################
ALP_GL_HOST="${ALPINE_GITLAB_HOST:-gitlab.alpinelinux.org}"
ALP_UPSTREAM="alpine/aports"
ALP_CDN="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"

# alp_ver_ok <version> — true if apk takes it as a pkgver: digits and dots, an
# optional letter, then _alpha/_beta/_pre/_rc/_p… suffixes (never "-": that
# separates the -r<pkgrel>)
alp_ver_ok() { printf '%s' "$1" | grep -qE '^[0-9]+(\.[0-9]+)*[a-z]?(_(alpha|beta|pre|rc|cvs|svn|git|hg|p)[0-9]*)*$'; }
# alp_ver <upstream version> — the same version in apk's format
# (1.2.0-rc.1 → 1.2.0_rc1), or nothing when there's no safe translation
alp_ver() {
  local v
  v="$(printf '%s' "$1" | tr 'A-Z' 'a-z' \
       | sed -E 's/[-.]?(alpha|beta|pre|rc)[-.]?([0-9]*)$/_\1\2/; s/[-.]?(post|patch)[-.]?([0-9]+)$/_p\2/')"
  if alp_ver_ok "$v"; then printf '%s' "$v"; fi
}
# alp_key <apk version> — a `sort -V` key in apk's order: 1.0_rc1 < 1.0 < 1.0_p1
alp_key() { printf '%s' "$1" | sed -E 's/_alpha/~a/g; s/_beta/~b/g; s/_pre/~c/g; s/_rc/~d/g; s/_(cvs|svn|git|hg|p)/+\1/g'; }

# alpine_questions — what Alpine needs beyond "Your app": an app it can build,
# an email for the APKBUILD's maintainer line, and a release tarball (worked
# out for GitHub, GitLab and Codeberg; looked for, or asked, elsewhere)
alpine_questions() {
  local u guess
  case "$KIND" in
    flutter) die "Alpine's Flutter is only in its testing repository (x86_64 and aarch64), and every Flutter app needs patches written by hand to build against it (its engine and pubspec.lock pinned to Alpine's Flutter; see testing/goguma or testing/sly in aports) — this wizard can't write those. Alpine users can install the app from Flathub (flatpak is in Alpine's community repository)" ;;
  esac

  # abuild refuses a maintainer line without an email address
  ALP_EMAIL="${MAINT_EMAIL:-$(cfg_get alpine-email)}"
  if [ -z "$MAINT_EMAIL" ] && { [ -z "$ALP_EMAIL" ] || [ "$ASK_ALL" = 1 ]; }; then
    note "Alpine's APKBUILD names its maintainer with an email address (abuild insists) — it is public"
    [ "$ASSUME_YES" = 1 ] && [ -z "$ALP_EMAIL" ] && die "--yes: set maintainer-email (or alpine-email, for Alpine only) in the config"
    while :; do
      ask ALP_EMAIL "Email for Alpine" "$ALP_EMAIL"
      case "$ALP_EMAIL" in *[[:space:]]*) ;; ?*@?*.?*) break ;; esac
      warn "an email address, like you@example.org"; ALP_EMAIL=""
    done
    if [ "${SAVE:-1}" = 1 ]; then cfg_set alpine-email "$ALP_EMAIL"; fi
    ok "Alpine maintainer: $MAINT_NAME <$ALP_EMAIL>"
  fi

  # the release tarball abuild downloads: known for the big forges; on other
  # hosts GitLab's and Gitea/Forgejo's tarball addresses are tried, else asked
  ALP_SOURCE=""
  [ "$FORGE" = git ] || return 0
  ALP_SOURCE="$(cfg_get alpine-source)"
  if [ -n "$ALP_SOURCE" ] && [ "$ASK_ALL" = 0 ]; then ok "release tarball: $ALP_SOURCE"; return 0; fi
  guess=""
  if [ -n "$HOST" ] && [ "${DRY_NO_TAG:-0}" = 0 ]; then
    for u in "https://$HOST/$SLUG/-/archive/$TAG/$REPONAME-$TAG.tar.gz" "https://$HOST/$SLUG/archive/$TAG.tar.gz"; do
      curl -sfIL --max-time 20 -o /dev/null "$u" 2>/dev/null && { guess="$u"; break; }
    done
  fi
  if [ -n "$guess" ] && [ "$ASK_ALL" = 0 ]; then
    u="$guess"; ok "release tarball: $u"
  else
    note "abuild builds from a release tarball; for ${WEB:-this repository} the wizard can't tell where it is"
    [ "$ASSUME_YES" = 1 ] && die "--yes: set alpine-source in the config (a release tarball's URL, {version} where the version goes)"
    while :; do
      ask u "URL of the source tarball of $TAG" "${guess:-$(printf '%s' "$ALP_SOURCE" | sed "s|{version}|$VERSION|g")}"
      case "$u" in http://*|https://*|ftp://*) break ;; esac
      warn "an http(s) or ftp URL"
    done
  fi
  # kept with {version} where the version is, so the next release just works
  ALP_SOURCE="$(printf '%s' "$u" | sed "s|$(printf '%s' "$VERSION" | sed 's/[][\.*^$|]/\\&/g')|{version}|g")"
  case "$ALP_SOURCE" in *"{version}"*) ;; *) warn "that URL doesn't contain $VERSION — every release needs a tarball of its own" ;; esac
  if [ "${SAVE:-1}" = 1 ]; then cfg_set alpine-source "$ALP_SOURCE"; fi
}

# ##########################################################################
#   Alpine Linux (aports) wizard — linux-submit.sh alpine [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_alpine() {
#
# linux-submit.sh alpine — get an app into Alpine Linux's aports (a new
# package goes to testing/), or ship a new version of one already there.
#
# Follows Alpine's own guides:
#   https://wiki.alpinelinux.org/wiki/Creating_an_Alpine_package
#   https://wiki.alpinelinux.org/wiki/APKBUILD_Reference
#   https://wiki.alpinelinux.org/wiki/Creating_patches  (merge requests on gitlab.alpinelinux.org)
#   https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/CODINGSTYLE.md
#   https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/COMMITSTYLE.md
#   https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/README.md  (main, community, testing)
#
# It checks the name against aports and Alpine's package index, writes
# testing/<name>/APKBUILD for the build system (an aport already there is
# bumped instead: new pkgver, pkgrel=0), fills in sha512sums the way `abuild
# checksum` does, builds it with `abuild -r` in an alpine:edge container with a
# throwaway signing key, and runs the checks aports' CI runs on a merge request
# (abuild validate, apkbuild-lint, apkbuild-shellcheck). Then it commits in
# aports' style ("testing/<name>: new aport", "<repo>/<name>: upgrade to <v>"),
# pushes a branch to your fork on gitlab.alpinelinux.org and opens the merge
# request. GitLab is driven with glab (GitLab's CLI) and its own login: this
# wizard never sees your token.
#
# aports lives in the cache as a blob-less clone (all of its history, file
# contents only when needed) with just the aport being worked on checked out.
#
# Nothing leaves your machine without asking first, unless you pass --yes.

set -eu
# NOTE: deliberately no `set -o pipefail` — `cmd | head` would SIGPIPE and abort.

DRYRUN=0
SAVE=1
ASSUME_YES=0   # --yes: take every detected answer, only stop on problems
ASK_ALL=0      # --ask: ask every question, even the ones it can answer itself
NO_TEST=0      # --no-test: no build in an Alpine container
DRAFT=0        # --draft: open the merge request as a draft
REPO_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/alpine-submit"
CONF="$CONF_DIR/last.conf"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/store-submit"
# where aports is cloned from (overridable for testing)
APORTS_GIT="${APORTS_UPSTREAM:-https://$ALP_GL_HOST/$ALP_UPSTREAM.git}"
ALPINE_IMAGE="${ALPINE_IMAGE:-docker.io/library/alpine:edge}"
# named in the merge request, which says how the APKBUILD was made
TOOL_URL="https://github.com/by-architect/StoreHelper"

usage() {
  cat <<'USAGE'
linux-submit.sh alpine — get an app into Alpine Linux (aports), or update it there.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask; stops only on
                      problems. A new package's merge request is then opened
                      as a draft, for you to review first.
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --config FILE   the shared answers (default: .store-submit.conf in the repo)
      --no-test       skip the build and the checks in an Alpine container
      --draft         open the merge request as a draft
  -n, --dry-run       write, build, check and commit locally; push nothing
      --no-save       do not remember the answers for next time
      --forget        delete the remembered answers and exit

New packages go to testing/, as Alpine asks; the merge request goes to
alpine/aports on gitlab.alpinelinux.org.
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
    --no-test)    NO_TEST=1 ;;
    --draft)      DRAFT=1 ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF"; printf 'forgot %s\n' "$CONF"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WIZ_NAME=alpine-submit
linux_common

# ------------------------------------------------------- remembered answers
SAVED_REPO=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  { printf '# written by linux-submit.sh alpine — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n' "${REPO:-${SAVED_REPO:-}}"; } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}

# ------------------------------------------------------------------ helpers
T=$'\t'   # APKBUILDs are indented with tabs
RUNTIME=""
for r in podman docker; do have "$r" && "$r" info >/dev/null 2>&1 && { RUNTIME="$r"; break; }; done
jqr() { tool jq jq -r "$@"; }
enc() { printf '%s' "$1" | sed -e 's#/#%2F#g' -e 's/+/%2B/g'; }   # a project path or name in an API URL
gl_get() { curl -sf --max-time 25 "https://$ALP_GL_HOST/api/v4/$1"; }   # anonymous API read
# glab: yours, or GitLab's CLI from nixpkgs when it isn't installed. Its path
# is needed as a file: it is git's credential helper for the push too.
GLAB=""
glab_find() {
  [ -n "$GLAB" ] && return 0
  GLAB="$(command -v glab 2>/dev/null || true)"
  [ -n "$GLAB" ] && return 0
  local d
  for d in $(nix_tool_paths glab 2>/dev/null || true); do [ -x "$d/bin/glab" ] && { GLAB="$d/bin/glab"; return 0; }; done
  return 0
}
gl_api() { "$GLAB" api --hostname "$ALP_GL_HOST" "$@"; }
gl_ready() { "$GLAB" auth status --hostname "$ALP_GL_HOST" >/dev/null 2>&1; }
# dq <text> — escaped for a "…" string in the APKBUILD
dq() { printf '%s' "$1" | sed -e 's/[\\"$`]/\\&/g'; }

# --- Alpine's package index (edge: main, community, testing): every package
# name, subpackages included, and what each provides (pc:gtk4, cmd:msgfmt…).
# Kept in the cache for half a day; a download cut short counts as none.
alp_index() {
  local r idx="$CACHE/alpine/apkidx"
  if [ -s "$idx" ] && [ -n "$(find "$idx" -mmin -720 2>/dev/null)" ]; then cp "$idx" "$WORK/apkidx"; return 0; fi
  : > "$WORK/apkidx.new"
  for r in main community testing; do
    run_logged "$WORK/index.log" "reading Alpine's package index ($r)" \
      curl -sSf --retry 2 --max-time 300 -o "$WORK/APKINDEX-$r.tar.gz" "$ALP_CDN/edge/$r/x86_64/APKINDEX.tar.gz" || return 1
    tar -xzOf "$WORK/APKINDEX-$r.tar.gz" APKINDEX 2>/dev/null | awk -v r="$r" '
      function flush(  k, i, a) {
        if (n == "") return
        print "P", n, (o != "" ? o : n), r
        k = split(pv, a, " ")
        for (i = 1; i <= k; i++) { sub(/[=<>~].*/, "", a[i]); print "p", a[i], n, r }
        n = ""; o = ""; pv = ""
      }
      /^P:/ { n = substr($0, 3) } /^o:/ { o = substr($0, 3) } /^p:/ { pv = substr($0, 3) }
      /^$/ { flush() } END { flush() }' >> "$WORK/apkidx.new"
    grep -q " $r\$" "$WORK/apkidx.new" || return 1
  done
  mv "$WORK/apkidx.new" "$WORK/apkidx"
  mkdir -p "$CACHE/alpine" && cp "$WORK/apkidx" "$idx"
}
alp_has() { awk -v n="$1" '$1 == "P" && $2 == n { f = 1; exit } END { exit !f }' "$WORK/apkidx" 2>/dev/null; }
alp_origin() { awk -v n="$1" '$1 == "P" && $2 == n { print $3 " " $4; exit }' "$WORK/apkidx" 2>/dev/null; }
# alp_provider <pc:module | cmd:program> — the package that provides it (main and community before testing)
alp_provider() {
  awk -v p="$1" '$1 == "p" && $2 == p { print ($4 == "testing" ? 2 : 1), $3 }' "$WORK/apkidx" 2>/dev/null \
    | sort -n | head -1 | cut -d' ' -f2
}
# alp_py <python distribution or module> — its Alpine package (py3-…), if packaged
alp_py() {
  local n c
  n="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  for c in "py3-$(printf '%s' "$n" | tr '_.' '--')" "py3-$(printf '%s' "$n" | tr '.-' '__')" "py3-${n#py}" "py3-${n#python-}" "$n"; do
    alp_has "$c" && { printf '%s' "$c"; return 0; }
  done
  return 0
}

# --- the APKBUILD's variables, written the way aports writes them
# lst <variable> <items…> — `var="a b"`, or one item per line when it's long
lst() {
  local k="$1" one i
  shift
  # shellcheck disable=SC2046   # one word per item, duplicates dropped
  set -- $(printf '%s\n' "$@" | awk 'NF && !seen[$0]++')
  [ "$#" -gt 0 ] || return 0
  one="$*"
  if [ "$#" -le 3 ] && [ $(( ${#k} + ${#one} + 3 )) -le 80 ]; then printf '%s="%s"\n' "$k" "$one"; return 0; fi
  printf '%s="\n' "$k"
  for i in "$@"; do printf '\t%s\n' "$i"; done
  printf '\t"\n'
}
# apk_raw <variable> — its words as written in the APKBUILD (not expanded)
apk_raw() {
  awk -v k="$1" '
    !on && index($0, k "=\"") == 1 { on = 1; $0 = substr($0, length(k) + 3) }
    on {
      line = $0; q = index(line, "\"")
      if (q) { line = substr(line, 1, q - 1); on = 0 }
      n = split(line, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (w[i] != "") print w[i]
      if (!on) exit
    }' "$AP/$APDIR/APKBUILD"
}
# apk_var <variable> <items…> — replace it (one line or a block) where it is;
# a new one goes where aports' order puts it (depends, makedepends,
# checkdepends, install, subpackages, source; options after source/builddir)
apk_var() {
  local f="$AP/$APDIR/APKBUILD" k="$1" at later
  shift
  lst "$k" "$@" > "$WORK/var.new"
  later="$(printf '%s\n' depends makedepends checkdepends install subpackages source | sed -n "/^$k\$/,\$p" | sed 1d | tr '\n' ' ')"
  at="$(awk -v k="$k" -v later="$later" '
    BEGIN { n = split(later, L, " ") }
    index($0, k "=\"") == 1 { print NR; found = 1; exit }
    !first { for (i = 1; i <= n; i++) if (index($0, L[i] "=") == 1) { first = NR; break } }
    /^source="/ { if (index(substr($0, 9), "\"")) e = NR; else insrc = 1; next }
    insrc && index($0, "\"") { e = NR; insrc = 0; next }
    e && NR == e + 1 && /^builddir=/ { e = NR }
    END { if (!found) print (first ? first : e + 1) }' "$f")"
  awk -v k="$k" -v at="${at:-1}" -v nf="$WORK/var.new" '
    function emit(  l) { while ((getline l < nf) > 0) print l; close(nf); done = 1 }
    NR == at + 0 { emit() }
    skip { if (index($0, "\"")) skip = 0; next }
    index($0, k "=\"") == 1 { if (!index(substr($0, length(k) + 3), "\"")) skip = 1; next }
    { print }
    END { if (!done) emit() }' "$f" > "$f.new" && mv "$f.new" "$f"
}
apk_list_add() {  # apk_list_add <variable> <item> — false if it was there already
  local items
  items="$(apk_raw "$1")"
  printf '%s\n' "$items" | grep -qxF "$2" && return 1
  # shellcheck disable=SC2086
  apk_var "$1" $items "$2"
}
apk_set() {  # apk_set <variable> <word> — a one-line variable (a comment after it stays)
  local f="$AP/$APDIR/APKBUILD"
  if grep -q "^$1=\"[^\"]*\"" "$f"; then
    sed -i -E "s/^$1=\"[^\"]*\"/$1=\"$2\"/" "$f"
  else
    apk_var "$1" "$2"
  fi
}
# apk_options <words> <why> — options="…" # why
apk_options() {
  local f="$AP/$APDIR/APKBUILD"
  apk_var options "$1"
  [ -n "${2-}" ] && sed -i -E "s|^options=\"([^\"]*)\".*|options=\"\\1\" # $(printf '%s' "$2" | sed 's/[|&\\]/\\&/g')|" "$f"
  return 0
}

# apk_sums <aport dir> — what `abuild checksum` does: every source (the remote
# ones fetched into the cache) and its sha512, appended in abuild's own format
apk_sums() {
  local d="$1" s name f sums=""
  mkdir -p "$DISTFILES"
  for s in $( (cd "$d" && env -i PATH="$PATH" CARCH=x86_64 CBUILD=x86_64-alpine-linux-musl CHOST=x86_64-alpine-linux-musl \
                CTARGET=x86_64-alpine-linux-musl srcdir=/src startdir="$d" bash --norc --noprofile -c \
                '. ./APKBUILD >/dev/null 2>&1; printf "%s\n" $source') ); do
    name="${s%%::*}"; name="${name##*/}"
    case "${s#*::}" in
      http://*|https://*|ftp://*)
        f="$DISTFILES/$name"
        if [ ! -s "$f" ]; then
          run_logged "$WORK/fetch.log" "downloading $name" curl -fL --retry 3 -o "$f.part" "${s#*::}" && mv "$f.part" "$f" \
            || { rm -f "$f.part"; tail -n 3 "$WORK/fetch.log" | sed 's/^/     /'; bad "couldn't download ${s#*::}"; return 1; }
        fi ;;
      *) f="$d/$name"
         [ -f "$f" ] || { bad "$name is in source= but not in $APDIR"; return 1; } ;;
    esac
    sums="$sums$(sha512sum "$f" | cut -d' ' -f1)  $name"$'\n'
  done
  sed -E -i -e '/^sha[0-9]+sums=".*"$/d' -e '/^sha[0-9]+sums="/,/"$/d' \
    -e "/^sha[0-9]+sums='.*'\$/d" -e "/^sha[0-9]+sums='/,/'\$/d" "$d/APKBUILD"
  [ -n "$sums" ] && printf 'sha512sums="\n%s"\n' "$sums" >> "$d/APKBUILD"
  return 0
}

# =============================================================== 0. orientation
cat <<BANNER

  ${B}Alpine Linux (aports) wizard${R}

  Six stages:
    1. your app         — shared with the other distros (.store-submit.conf)
    2. GitLab + aports  — glab's login, your fork, aports (cached), new or upgrade
    3. APKBUILD         — written for your build system (or bumped), checksums
    4. build + checks   — abuild -r and aports' CI checks in an alpine:edge container
    5. review + commit  — you read the change; committed in aports' style
    6. merge request    — branch pushed to your fork, merge request opened

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: everything up to the commit; nothing is pushed or opened"
[ "$ASSUME_YES" = 1 ] && note "--yes: using everything detected; stopping only on problems"
for t in git curl tar sha512sum awk; do
  have "$t" || die "$t is missing — install it and re-run"
done

# ============================================================== 1. the app
linux_app "1/6  Your app"
alpine_questions
MAINT_LINE="$(printf '%s <%s>' "$MAINT_NAME" "$ALP_EMAIL" | tr -d '"`$\\')"

# apk's version format has no "-" (it separates -r<pkgrel>): 1.0-rc.1 is 1.0_rc1
PKGVER="$(alp_ver "$VERSION")"
if [ "$PKGVER" != "$VERSION" ]; then
  if [ -n "$PKGVER" ]; then
    note "in apk's version format $VERSION is $PKGVER (pkgver)"
  else
    warn "$VERSION isn't a version apk understands (https://wiki.alpinelinux.org/wiki/APKBUILD_Reference#pkgver)"
    [ "$ASSUME_YES" = 1 ] && die "--yes: no apk version for $VERSION — run without --yes to give one"
    while :; do
      ask PKGVER "Alpine version (pkgver) for $VERSION, like 1.2.0_rc1" ""
      alp_ver_ok "$PKGVER" && break
      warn "digits and dots, then _alpha, _beta, _pre, _rc or _p with a number"
    done
  fi
fi
[ "$(printf '%s\n' "$DESC" | wc -c)" -le 128 ] || die "the description is ${#DESC} characters — abuild allows at most 127 (description = … in the config)"

# ============================================================ 2. GitLab + aports
step "2/6  Alpine's GitLab and aports"
DISTFILES="$CACHE/alpine/distfiles"
AP="$CACHE/alpine/aports"

# --- you on gitlab.alpinelinux.org: glab's own login (a personal access token)
GL_USER=""
glab_find
if [ -z "$GLAB" ]; then
  [ "$DRYRUN" = 1 ] || die "glab (GitLab's CLI) is missing — it makes the fork and the merge request. Install it (Alpine: apk add glab; Arch: pacman -S glab; Debian/Ubuntu: apt install glab) and re-run"
  note "dry run: glab (GitLab's CLI) isn't installed — the merge request will need it"
elif gl_ready; then
  :
elif [ "$DRYRUN" = 1 ]; then
  note "dry run: not logging in to $ALP_GL_HOST"
else
  warn "glab isn't logged in to $ALP_GL_HOST yet"
  say "Alpine takes merge requests on its own GitLab; glab logs in there once, with a token:"
  note "1. an account: https://$ALP_GL_HOST/users/sign_in (Register, if you have none)"
  note "2. a token with the 'api' scope: https://$ALP_GL_HOST/-/user_settings/personal_access_tokens?name=linux-submit&scopes=api"
  note "3. paste it when glab asks — glab keeps it in its own config; this wizard never sees it"
  [ "$ASSUME_YES" = 1 ] && die "log in once without --yes (glab auth login --hostname $ALP_GL_HOST)"
  while ! gl_ready; do
    confirm "Log in now (glab auth login)?" y || die "the merge request needs glab logged in to $ALP_GL_HOST"
    "$GLAB" auth login --hostname "$ALP_GL_HOST" --git-protocol https --api-protocol https || true
  done
fi
if [ -n "$GLAB" ] && gl_ready; then
  GL_USER="$(gl_api user 2>/dev/null | jqr '.username // ""' 2>/dev/null || true)"
  [ -n "$GL_USER" ] || die "could not ask $ALP_GL_HOST who you are (glab api user) — check your connection"
  ok "$ALP_GL_HOST: $GL_USER"
fi

# --- your fork of alpine/aports: the merge request comes from it
FORK_PATH=""
if [ -n "$GL_USER" ]; then
  FORK_PATH="$(gl_api "projects/$(enc "$ALP_UPSTREAM")/forks?owned=true&per_page=100" 2>/dev/null \
    | jqr '[.[] | select(.namespace.kind == "user")][0].path_with_namespace // ""' 2>/dev/null || true)"
  if [ -n "$FORK_PATH" ]; then
    ok "fork: https://$ALP_GL_HOST/$FORK_PATH"
  elif [ "$DRYRUN" = 1 ]; then
    warn "dry run — would fork $ALP_UPSTREAM to $GL_USER/aports"
  elif go "Fork $ALP_UPSTREAM to $GL_USER/aports on $ALP_GL_HOST?"; then
    if ! gl_api --method POST "projects/$(enc "$ALP_UPSTREAM")/fork" > "$WORK/fork.json" 2> "$WORK/fork.err"; then
      cat "$WORK/fork.err" "$WORK/fork.json" 2>/dev/null | grep -v '^\s*$' | tail -4 | sed 's/^/     /'
      grep -qiE "limit|can.?t create|not allowed" "$WORK/fork.err" "$WORK/fork.json" 2>/dev/null \
        && note "new accounts may not be allowed to create projects yet — ask on IRC (#alpine-devel on OFTC), or wait a while"
      die "GitLab refused the fork — try https://$ALP_GL_HOST/$ALP_UPSTREAM/-/forks/new, then re-run"
    fi
    FORK_PATH="$(jqr '.path_with_namespace // ""' < "$WORK/fork.json" 2>/dev/null || true)"
    [ -n "$FORK_PATH" ] || die "GitLab didn't say where the fork is — check https://$ALP_GL_HOST/$GL_USER and re-run"
    # GitLab copies it in the background; wait until it's done
    for _ in $(seq 1 120); do
      st="$(gl_api "projects/$(enc "$FORK_PATH")" 2>/dev/null | jqr '.import_status // "none"' 2>/dev/null || true)"
      case "$st" in finished|none) break ;; failed) die "GitLab couldn't make the fork — see https://$ALP_GL_HOST/$FORK_PATH" ;; esac
      sleep 5
    done
    ok "forked: https://$ALP_GL_HOST/$FORK_PATH"
  else
    die "a fork is needed for the merge request"
  fi
fi

# --- aports, in a cache the wizard owns: a blob-less clone (all of the
# history, file contents fetched when needed) with only the aport at hand checked out
if [ -d "$AP/.git" ]; then
  ok "aports: $AP"
else
  mkdir -p "$(dirname "$AP")"
  while ! run_logged "$WORK/clone.log" "cloning aports (blob-less, ~250 MB the first time; a few minutes)" \
      git clone --filter=blob:none --sparse --single-branch --branch master -o upstream "$APORTS_GIT" "$AP"; do
    rm -rf "$AP"
    tail -n 3 "$WORK/clone.log" | sed 's/^/     /'
    warn "the clone was cut off — usually a network hiccup"
    [ "$ASSUME_YES" = 1 ] || confirm "Try again?" y || die "no aports checkout"
  done
  ok "cloned aports into $AP"
fi
git -C "$AP" remote get-url upstream >/dev/null 2>&1 || git -C "$AP" remote add upstream "$APORTS_GIT"
git -C "$AP" remote set-url upstream "$APORTS_GIT"
while ! run_logged "$WORK/fetch.log" "fetching the latest aports master" \
    git -C "$AP" fetch upstream "+refs/heads/master:refs/remotes/upstream/master"; do
  tail -n 3 "$WORK/fetch.log" | sed 's/^/     /'
  warn "the fetch failed — usually a network hiccup"
  [ "$ASSUME_YES" = 1 ] || confirm "Try again?" y || die "could not fetch aports master"
done
BASE=upstream/master
ok "master at $(git -C "$AP" rev-parse --short "$BASE") ($(git -C "$AP" log -1 --format=%cr "$BASE"))"

# --- new aport, or an upgrade? aports says where each aport lives; Alpine's
# index knows every package name, subpackages included. A name used by other
# software is taken.
alp_index || warn "couldn't read Alpine's package index ($ALP_CDN) — names are checked against aports only"
PKG="$(cfg_get alpine-name)"; PKG="${PKG:-$PNAME}"
MODE=new; APREPO=testing
while :; do
  FOUND="$(git -C "$AP" ls-tree -d --name-only "$BASE" -- "main/$PKG" "community/$PKG" "testing/$PKG" 2>/dev/null | head -1)"
  if [ -n "$FOUND" ]; then
    git -C "$AP" show "$BASE:$FOUND/APKBUILD" > "$WORK/old.APKBUILD" 2>/dev/null || die "couldn't read $FOUND/APKBUILD from aports"
    if { [ -n "$SLUG" ] && grep -E '^(url|source)=|^[[:space:]]+[a-z0-9._$-]*(::)?https?://' "$WORK/old.APKBUILD" | grep -qiF "$SLUG"; } \
       || grep -qixF "url=\"$HOMEPAGE\"" "$WORK/old.APKBUILD"; then
      MODE=update; APREPO="${FOUND%%/*}"; break
    fi
    warn "aports has a different '$PKG' ($FOUND: $(sed -nE 's/^url="?([^"]*)"?.*/\1/p' "$WORK/old.APKBUILD" | head -1)) — the name is taken"
  else
    ORIG="$(alp_origin "$PKG")"
    [ -z "$ORIG" ] || [ "${ORIG%% *}" = "$PKG" ] && break
    warn "Alpine already has a package '$PKG': a subpackage of ${ORIG%% *} (${ORIG#* }) — the name is taken"
  fi
  [ "$ASSUME_YES" = 1 ] && die "pick another package name (run without --yes)"
  ask PKG "Another package name" "$PKG-$(printf '%s' "${OWNER##*/}" | tr 'A-Z' 'a-z')"
  PKG="$(printf '%s' "$PKG" | tr 'A-Z' 'a-z')"
  printf '%s' "$PKG" | grep -qE '^[a-z0-9][a-z0-9._+-]*$' || { warn "lowercase letters, digits and . _ + - only"; PKG="$PNAME"; }
done
[ "$SAVE" = 1 ] && { if [ "$PKG" != "$PNAME" ]; then cfg_set alpine-name "$PKG"; else cfg_set alpine-name ""; fi; }
APDIR="$APREPO/$PKG"

OLD_VER=""
if [ "$MODE" = update ]; then
  OLD_VER="$(sed -nE "s/^pkgver=[\"']?([^\"'[:space:]]+).*/\\1/p" "$WORK/old.APKBUILD" | head -1)"
  OLD_MAINT="$(sed -nE 's/^maintainer="([^"]*)".*/\1/p; s/^# *Maintainer: *(.*[^[:space:]])[[:space:]]*$/\1/p' "$WORK/old.APKBUILD" | head -1)"
  ok "$PKG is in Alpine's $APREPO at $OLD_VER ($APDIR) — this is an upgrade"
  [ "$OLD_VER" = "$PKGVER" ] && die "aports already has $PKG $PKGVER — nothing to do"
  if [ "$(printf '%s\n%s\n' "$(alp_key "$OLD_VER")" "$(alp_key "$PKGVER")" | sort -V | tail -1)" != "$(alp_key "$PKGVER")" ]; then
    die "$PKGVER is older than aports' $OLD_VER"
  fi
  grep -q '^_commit=' "$WORK/old.APKBUILD" && die "$APDIR builds a git commit (_commit=…), not a release — upgrade it by hand"
  if [ -n "$OLD_MAINT" ] && [ "$OLD_MAINT" != "$MAINT_LINE" ]; then note "it's maintained by $OLD_MAINT — they review upgrades to it"; fi
  BRANCH="$PKG-$PKGVER"
else
  ok "'$PKG' is new to Alpine → testing/$PKG (new packages start in testing)"
  BRANCH="$PKG"
fi

# --- someone may be on it already: open merge requests for this aport
OPEN_MRS="$(gl_get "projects/$(enc "$ALP_UPSTREAM")/merge_requests?state=opened&in=title&per_page=100&search=$(enc "$PKG")" 2>/dev/null \
  | jqr --arg n "$PKG" '.[] | select((.title | sub("^(Draft: |Draft:|\\[Draft\\] )"; "") | split(":")[0] | split("/")) as $p
      | ($p | length) == 2 and $p[1] == $n) | "!\(.iid) \(.title)  \(.web_url)  (\(.author.username))|\(.author.username)|\(.source_branch)"' 2>/dev/null || true)"
OWN_MR=""; OTHERS=""
while IFS='|' read -r line who br; do
  [ -n "$line" ] || continue
  if [ -n "$GL_USER" ] && [ "$who" = "$GL_USER" ] && [ "$br" = "$BRANCH" ]; then OWN_MR="$line"; else OTHERS="$OTHERS$line"$'\n'; fi
done <<EOF
$OPEN_MRS
EOF
[ -n "$OWN_MR" ] && note "your merge request is open already — this run updates it: $OWN_MR"
if [ -n "$OTHERS" ]; then
  warn "there are open merge requests for $PKG already:"
  printf '%s' "$OTHERS" | sed 's/^/       /'
  confirm "Carry on anyway?" n || { note "worth a look first — maybe test or review that one"; exit 0; }
fi

# --- a branch from current master, with just this aport checked out
if git -C "$AP" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null 2>&1; then
  note "branch $BRANCH from an earlier run is started over from current master"
fi
git -C "$AP" sparse-checkout set "$APDIR" >/dev/null 2>&1 || die "git couldn't check out $APDIR (git 2.25 or newer is needed)"
git -C "$AP" checkout -q -f -B "$BRANCH" "$BASE" || die "could not check out $BASE in $AP"
git -C "$AP" clean -qfdx -- "$APDIR" 2>/dev/null || true
ok "branch $BRANCH, from master ($AP)"

# ================================================================ 3. APKBUILD
step "3/6  APKBUILD"
A="$AP/$APDIR/APKBUILD"
mkdir -p "$AP/$APDIR"
RESUMED=0
# a merge request under review: start from your branch on GitLab, so the
# changes the review asked for stay
if [ -n "$FORK_PATH" ] \
   && git -C "$AP" fetch -q "https://$ALP_GL_HOST/$FORK_PATH.git" "refs/heads/$BRANCH" 2>/dev/null \
   && git -C "$AP" cat-file -e "FETCH_HEAD:$APDIR/APKBUILD" 2>/dev/null; then
  note "your fork's branch $BRANCH has an APKBUILD from an earlier run (with any changes you made since)"
  if confirm "Start from it, keeping your changes?" y; then
    git -C "$AP" checkout -q FETCH_HEAD -- "$APDIR" && RESUMED=1
    ok "$APDIR from your branch $BRANCH"
  fi
fi

if [ "$MODE" = update ] || [ "$RESUMED" = 1 ]; then
  # ---------------------------------------------------------------- bump
  OLD_IN="$(sed -nE "s/^pkgver=[\"']?([^\"'[:space:]]+).*/\\1/p" "$A" | head -1)"
  sed -i -E "s/^pkgver=.*/pkgver=$PKGVER/; s/^pkgrel=.*/pkgrel=0/" "$A"
  grep -qx "pkgver=$PKGVER" "$A" || die "couldn't set pkgver in $APDIR/APKBUILD — update it by hand in $AP"
  if [ -n "$OLD_IN" ] && [ "$OLD_IN" != "$PKGVER" ]; then
    # (licenses carry versions of their own: GPL-2.0, CC0-1.0)
    sed '/^sha512sums=/,$d' "$A" | grep -vE '^(pkgver=|license=|#)' | grep -qF "$OLD_IN" \
      && warn "the APKBUILD mentions $OLD_IN somewhere else too — check it in the change below"
    ok "pkgver $OLD_IN → $PKGVER, pkgrel=0"
  fi
  if [ "${DRY_NO_TAG:-0}" = 1 ]; then
    echo; sed 's/^/     /' "$A"; echo
    warn "dry run stops here: tag $TAG isn't online, so the new sources can't be fetched for their checksums"
    exit 0
  fi
  apk_sums "$AP/$APDIR" || die "couldn't fill in the checksums"
  ok "sha512sums for every source, like abuild checksum"
else
  # ---------------------------------------------------------- new aport
  # --- the source: the forge's tarball of the tag, in terms of $pkgver
  if [ "$PKGVER" = "$VERSION" ]; then TAGX="${TAG/"$VERSION"/\$pkgver}"; VX='$pkgver'; else TAGX="$TAG"; VX="$VERSION"; fi
  case "$FORGE" in
    github)   SRC_FILE="$PKG-$VX.tar.gz"; SRC_URL="https://github.com/$SLUG/archive/refs/tags/$TAGX.tar.gz"
              SRC_ENTRY="$SRC_FILE::$SRC_URL" ;;
    gitlab)   SRC_URL="https://gitlab.com/$SLUG/-/archive/$TAGX/$REPONAME-$TAGX.tar.gz"
              SRC_FILE="$REPONAME-$TAGX.tar.gz"; SRC_ENTRY="$SRC_URL" ;;
    codeberg) SRC_FILE="$PKG-$VX.tar.gz"; SRC_URL="https://codeberg.org/$SLUG/archive/$TAGX.tar.gz"
              SRC_ENTRY="$SRC_FILE::$SRC_URL" ;;
    *)        SRC_URL="${ALP_SOURCE//\{version\}/$VX}"
              case "${SRC_URL##*/}" in
                *.tar.*) EXT=".tar.${SRC_URL##*.tar.}" ;; *.tgz) EXT=.tgz ;; *.zip) EXT=.zip ;; *) EXT=.tar.gz ;;
              esac
              SRC_FILE="$PKG-$VX$EXT"; SRC_ENTRY="$SRC_FILE::$SRC_URL" ;;
  esac
  REAL_FILE="${SRC_FILE//\$pkgver/$PKGVER}"; REAL_URL="${SRC_URL//\$pkgver/$PKGVER}"
  BUILDDIR=""
  if [ "${DRY_NO_TAG:-0}" = 1 ]; then
    warn "dry run and the tag isn't online: the source can't be fetched yet"
  else
    mkdir -p "$DISTFILES"; rm -f "$DISTFILES/$REAL_FILE"
    run_logged "$WORK/download.log" "downloading $REAL_URL" curl -fL --retry 3 -o "$DISTFILES/$REAL_FILE" "$REAL_URL" \
      || { tail -n 3 "$WORK/download.log" | sed 's/^/     /'; die "couldn't download $REAL_URL — is tag $TAG pushed?"; }
    TOP="$(tar -tf "$DISTFILES/$REAL_FILE" 2>/dev/null | head -1 | cut -d/ -f1)"
    [ -n "$TOP" ] || warn "couldn't look inside $REAL_FILE — the build will say whether builddir is right"
    # the directory it unpacks to (abuild's default is $srcdir/$pkgname-$pkgver)
    if [ -n "$TOP" ] && [ "$TOP" != "$PKG-$PKGVER" ]; then
      if [ "$PKGVER" = "$VERSION" ]; then BUILDDIR="\$srcdir/${TOP//"$VERSION"/\$pkgver}"; else BUILDDIR="\$srcdir/$TOP"; fi
    fi
    ok "source: $REAL_FILE → ${TOP:-?}/"
  fi

  ARCH=all; LICENSE="$(printf '%s' "$SPDX" | sed -E 's# */ *# OR #g')"
  DEPENDS=(); MAKEDEPS=(); CHECKDEPS=(); SUBPKGS=(); UNKNOWN=()
  OPTS=""; WHY=""; EXPORTS=""; PREPARE=""; BUILD=""; CHECK=""; PACKAGE=""
  opt() { OPTS="${OPTS:+$OPTS }$1"; WHY="${WHY:+$WHY; }$2"; }
  add_pc() {  # a pkg-config module the build uses → the -dev package that has it
    local p; p="$(alp_provider "pc:$1")"
    if [ -n "$p" ]; then MAKEDEPS+=("$p"); else UNKNOWN+=("pc:$1"); fi
  }
  add_cmd() {  # a program the build runs → the package that has it
    local p; p="$(alp_provider "cmd:$1")"
    if [ -n "$p" ]; then MAKEDEPS+=("$p"); else UNKNOWN+=("cmd:$1"); fi
  }
  case "$KIND" in
    rust)
      MAKEDEPS+=(cargo cargo-auditable)
      # -sys crates that link a system library: its -dev package, up front
      for crate in $(at "$TAG_REF" Cargo.lock | sed -nE 's/^name = "([a-z0-9_-]+-sys(-rs)?)"$/\1/p' | sort -u); do
        case "$crate" in
          openssl-sys) add_pc openssl ;; alsa-sys) add_pc alsa ;; libdbus-sys) add_pc dbus-1 ;; libudev-sys) add_pc libudev ;;
          gtk4-sys) add_pc gtk4 ;; gtk-sys) add_pc gtk+-3.0 ;; libadwaita-sys) add_pc libadwaita-1 ;;
          webkit2gtk-sys) add_pc webkit2gtk-4.1 ;; glib-sys|gio-sys|gobject-sys) add_pc glib-2.0 ;; cairo-sys-rs) add_pc cairo ;;
          pango-sys) add_pc pango ;; gdk-pixbuf-sys) add_pc gdk-pixbuf-2.0 ;; yeslogic-fontconfig-sys|servo-fontconfig-sys) add_pc fontconfig ;;
          freetype-sys) add_pc freetype2 ;; wayland-sys) add_pc wayland-client ;; libpulse-sys) add_pc libpulse ;;
        esac
      done
      opt net "cargo fetch"
      PREPARE="${T}cargo fetch --target=\"\$CHOST\" --locked"
      BUILD="${T}cargo auditable build --release --frozen"
      CHECK="${T}cargo test --frozen"
      BINS="$( { at "$TAG_REF" Cargo.toml | awk '/^\[\[bin\]\]/{b=1;next} /^\[/{b=0} b && /^name[[:space:]]*=/{gsub(/.*=[[:space:]]*"|".*/,"");print}'
                 printf '%s\n' "$MAIN_GUESS"; } | awk 'NF && !seen[$0]++')"
      for b in $BINS; do PACKAGE="${PACKAGE:+$PACKAGE
}${T}install -Dm755 target/release/$b -t \"\$pkgdir\"/usr/bin/"; done ;;
    go)
      MAKEDEPS+=(go)
      opt net "Go modules"
      GOTARGET=.; grep -qE '^cmd/[^/]+/main\.go$' "$WORK/tree.txt" && GOTARGET='./cmd/...'
      LDF=""
      if git -C "$REPO" grep -qE '^[[:space:]]*(var[[:space:]]+)?version[[:space:]]+(=|string)' "$TAG_REF" -- main.go 'cmd/*/main.go' 2>/dev/null; then
        LDF=' -ldflags "-X main.version=$pkgver"'
      fi
      BUILD="${T}mkdir -p bin
${T}go build -v$LDF -o bin/ $GOTARGET"
      CHECK="${T}go test ./..."
      PACKAGE="${T}install -Dm755 bin/* -t \"\$pkgdir\"/usr/bin/" ;;
    python)
      ARCH=noarch
      at "$TAG_REF" pyproject.toml > "$WORK/pyproject.toml"
      tool python3 python3 - "$WORK/pyproject.toml" > "$WORK/pydeps" <<'PY' || die "could not read pyproject.toml"
import re, sys
try:
    import tomllib
except ImportError:
    sys.exit("python 3.11 or newer is needed to read pyproject.toml")
d = tomllib.load(open(sys.argv[1], "rb"))
name = lambda s: re.match(r"[A-Za-z0-9._-]+", s.strip()).group(0)
print("backend", d.get("build-system", {}).get("build-backend", ""))
for r in d.get("build-system", {}).get("requires", []):
    print("build", name(r))
for r in d.get("project", {}).get("dependencies", []):
    if not (";" in r and "extra ==" in r):
        print("dep", name(r))
opt = d.get("project", {}).get("optional-dependencies", {})
for k in ("test", "tests", "testing"):
    for r in opt.get(k, []):
        print("check", name(r))
PY
      MAKEDEPS+=(py3-gpep517)
      grep -q '^build ' "$WORK/pydeps" || MAKEDEPS+=(py3-setuptools py3-wheel)
      while read -r k dname; do
        [ -n "$dname" ] || continue
        case "$k" in
          backend) case "$dname" in maturin|scikit_build_core*|mesonpy|setuptools_rust*) ARCH=all ;; esac; continue ;;
        esac
        case "$(printf '%s' "$dname" | tr 'A-Z_' 'a-z-')" in
          setuptools-scm|hatch-vcs) EXPORTS='export SETUPTOOLS_SCM_PRETEND_VERSION="$pkgver"' ;;
          pytest) [ "$k" = check ] && continue ;;
        esac
        a="$(alp_py "$dname")"
        if [ -z "$a" ]; then
          [ "$k" = check ] && { note "test dependency '$dname' isn't in Alpine — left out"; continue; }
          UNKNOWN+=("py:$dname"); continue
        fi
        case "$k" in build) MAKEDEPS+=("$a") ;; dep) DEPENDS+=("$a") ;; check) CHECKDEPS+=("$a") ;; esac
      done < "$WORK/pydeps"
      SUBPKGS+=('$pkgname-pyc')
      BUILD="${T}gpep517 build-wheel \\
${T}${T}--wheel-dir .dist \\
${T}${T}--output-fd 3 3>&1 >&2"
      if in_tree_re '^(tests?/|pytest\.ini$|tox\.ini$|conftest\.py$)' || at "$TAG_REF" pyproject.toml | grep -q '^\[tool\.pytest'; then
        CHECKDEPS=(py3-pytest ${CHECKDEPS[@]+"${CHECKDEPS[@]}"})
        CHECK="${T}python3 -m venv --clear --without-pip --system-site-packages .testenv
${T}.testenv/bin/python3 -m installer .dist/*.whl
${T}.testenv/bin/python3 -m pytest"
      else
        opt '!check' "no test suite"
      fi
      PACKAGE="${T}python3 -m installer -d \"\$pkgdir\" \\
${T}${T}.dist/*.whl" ;;
    node)
      ARCH=noarch; DEPENDS+=(nodejs); MAKEDEPS+=(npm)
      at "$TAG_REF" package.json > "$WORK/package.json"
      NODE_NAME="$(jqr '.name // ""' < "$WORK/package.json")"
      [ -n "$NODE_NAME" ] || die "package.json has no name"
      opt net "npm"
      EXPORTS='export npm_config_cache="$srcdir/npm-cache"'
      BUILD="${T}npm ci --foreground-scripts"
      [ -n "$(jqr '.scripts.build // ""' < "$WORK/package.json")" ] && BUILD="$BUILD
${T}npm run build"
      TESTS="$(jqr '.scripts.test // ""' < "$WORK/package.json")"
      case "$TESTS" in ''|*"no test specified"*) opt '!check' "no test suite" ;; *) CHECK="${T}npm test" ;; esac
      # the files npm would publish (npm pack), plus the production dependencies
      PACKAGE="${T}local destdir=\"\$pkgdir\"/usr/lib/node_modules/$NODE_NAME

${T}npm prune --omit=dev
${T}mkdir -p \"\$srcdir\"/pack \"\$destdir\" \"\$pkgdir\"/usr/bin
${T}npm pack --ignore-scripts --pack-destination \"\$srcdir\"/pack
${T}tar -xzf \"\$srcdir\"/pack/*.tgz --strip-components=1 -C \"\$destdir\"
${T}cp -r node_modules \"\$destdir\"/"
      NODE_BINS="$(jqr 'if (.bin | type) == "string" then "\(.name | sub("^@[^/]*/"; ""))\t\(.bin)"
                        elif (.bin | type) == "object" then (.bin | to_entries[] | "\(.key)\t\(.value)") else empty end' < "$WORK/package.json")"
      [ -n "$NODE_BINS" ] || warn "package.json has no \"bin\" — nothing goes in /usr/bin"
      while IFS="$T" read -r bn bp; do
        [ -n "$bn" ] || continue
        bp="${bp#./}"
        PACKAGE="$PACKAGE
${T}chmod 755 \"\$destdir\"/$bp
${T}ln -s ../lib/node_modules/$NODE_NAME/$bp \"\$pkgdir\"/usr/bin/$bn"
      done <<EOF
$NODE_BINS
EOF
      ;;
    meson)
      MAKEDEPS+=(meson)
      MB="$(for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done)"
      for pc in $(printf '%s' "$MB" | grep -oE "dependency\([[:space:]]*'[^']+'" | sed -E "s/.*'([^']+)'/\\1/" | sort -u); do
        case "$pc" in threads|m|dl|rt|dependency|intl|iconv|libm) continue ;; esac
        add_pc "$pc"
      done
      for p in $(printf '%s' "$MB" | grep -oE "find_program\([[:space:]]*'[^']+'" | sed -E "s/.*'([^']+)'/\\1/" | sort -u); do
        case "$p" in python|python3|sh|bash|meson|ninja|git) continue ;; esac
        add_cmd "$p"
      done
      printf '%s' "$MB" | grep -q "import('i18n')" && add_cmd msgfmt
      BUILD="${T}abuild-meson \\
${T}${T}. output
${T}meson compile -C output"
      CHECK="${T}meson test --print-errorlogs -C output"
      PACKAGE="${T}DESTDIR=\"\$pkgdir\" meson install --no-rebuild -C output" ;;
    cmake)
      MAKEDEPS+=(cmake samurai)
      CM="$(for f in $(grep -E '(^|/)CMakeLists\.txt$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done)"
      PCS="$(printf '%s' "$CM" | tr '\n' ' ' | grep -oE 'pkg_check_modules\([^)]*\)' \
             | sed -E 's/^pkg_check_modules\(//; s/\)$//' \
             | awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^(REQUIRED|QUIET|IMPORTED_TARGET|GLOBAL|NO_CMAKE_PATH|NO_CMAKE_ENVIRONMENT_PATH)$/) { m = $i; sub(/[<>=].*/, "", m); if (m != "") print m } }' | sort -u)"
      [ -n "$PCS" ] && MAKEDEPS+=(pkgconf)
      for pc in $PCS; do add_pc "$pc"; done
      printf '%s' "$CM" | grep -qiE 'find_package\([[:space:]]*Qt6' && MAKEDEPS+=(qt6-qtbase-dev)
      printf '%s' "$CM" | grep -qiE 'find_package\([[:space:]]*Qt5' && MAKEDEPS+=(qt5-qtbase-dev)
      # newapkbuild's CMake recipe (abuild sets CMAKE_GENERATOR=Ninja)
      BUILD="${T}if [ \"\$CBUILD\" != \"\$CHOST\" ]; then
${T}${T}local crossopts=\"-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_HOST_SYSTEM_NAME=Linux\"
${T}fi
${T}cmake -B build \\
${T}${T}-DCMAKE_INSTALL_PREFIX=/usr \\
${T}${T}-DCMAKE_INSTALL_LIBDIR=lib \\
${T}${T}-DCMAKE_BUILD_TYPE=None \\
${T}${T}\$crossopts
${T}cmake --build build"
      if printf '%s' "$CM" | grep -qiE 'enable_testing|add_test[[:space:]]*\(|include\([[:space:]]*CTest'; then CHECK="${T}ctest --test-dir build"
      else opt '!check' "no test suite"; fi
      PACKAGE="${T}DESTDIR=\"\$pkgdir\" cmake --install build" ;;
    make)
      BUILD="${T}make"
      MK="$(at "$TAG_REF" Makefile)"
      if printf '%s\n' "$MK" | grep -qE '^check:'; then CHECK="${T}make check"
      elif printf '%s\n' "$MK" | grep -qE '^test:'; then CHECK="${T}make test"
      else opt '!check' "no test suite"; fi
      PACKAGE="${T}make DESTDIR=\"\$pkgdir\" PREFIX=/usr install" ;;
  esac
  # MIT, BSD, ISC… want their text shipped with the program: in -doc, as Alpine does
  case "$LICENSE" in
    *MIT*|*BSD*|*ISC*|*BSL-1.0*)
      LIC="$(grep -m1 -xE '(LICENSE|LICENSE\.md|LICENSE\.txt|LICENCE|COPYING)' "$WORK/tree.txt" || true)"
      if [ -n "$LIC" ]; then
        PACKAGE="$PACKAGE
${T}install -Dm644 $LIC -t \"\$pkgdir\"/usr/share/licenses/\$pkgname/"
        SUBPKGS=('$pkgname-doc' ${SUBPKGS[@]+"${SUBPKGS[@]}"})
      fi ;;
  esac
  if [ "${#UNKNOWN[@]}" -gt 0 ]; then
    case " ${UNKNOWN[*]}" in
      *" py:"*) bad "not in Alpine yet: $(printf '%s\n' "${UNKNOWN[@]}" | sed -n 's/^py://p' | tr '\n' ' ')"
                die "those Python packages need aports of their own first (py3-<name> in testing), each its own merge request" ;;
    esac
    warn "no Alpine package found for: ${UNKNOWN[*]} — the build will say if they're needed"
  fi
  [ -n "$CHECK" ] || case " $OPTS " in *" !check "*) ;; *) opt '!check' "no test suite" ;; esac

  {
    printf 'maintainer="%s"\n' "$(dq "$MAINT_LINE")"
    printf 'pkgname=%s\npkgver=%s\npkgrel=0\n' "$PKG" "$PKGVER"
    printf 'pkgdesc="%s"\n' "$(dq "$DESC")"
    printf 'url="%s"\n' "$(dq "$HOMEPAGE")"
    printf 'arch="%s"\n' "$ARCH"
    printf 'license="%s"\n' "$LICENSE"
    lst depends ${DEPENDS[@]+"${DEPENDS[@]}"}
    lst makedepends ${MAKEDEPS[@]+"${MAKEDEPS[@]}"}
    lst checkdepends ${CHECKDEPS[@]+"${CHECKDEPS[@]}"}
    lst subpackages ${SUBPKGS[@]+"${SUBPKGS[@]}"}
    printf 'source="%s"\n' "$SRC_ENTRY"
    [ -n "$BUILDDIR" ] && printf 'builddir="%s"\n' "$BUILDDIR"
    [ -n "$OPTS" ] && printf 'options="%s" # %s\n' "$OPTS" "$WHY"
    [ -n "$EXPORTS" ] && printf '\n%s\n' "$EXPORTS"
    [ -n "$PREPARE" ] && printf '\nprepare() {\n\tdefault_prepare\n\n%s\n}\n' "$PREPARE"
    printf '\nbuild() {\n%s\n}\n' "$BUILD"
    [ -n "$CHECK" ] && printf '\ncheck() {\n%s\n}\n' "$CHECK"
    printf '\npackage() {\n%s\n}\n\n' "$PACKAGE"
  } > "$A"
  bash -n "$A" 2>"$WORK/syntax.err" || { cat "$WORK/syntax.err"; KEEP_WORK=1; die "the written APKBUILD isn't valid shell — this is a bug in the wizard"; }
  if [ "${DRY_NO_TAG:-0}" = 1 ]; then
    echo; sed 's/^/     /' "$A"; echo
    warn "dry run stops here: tag $TAG isn't online, so abuild couldn't fetch the source"
    note "the draft is in $A; push the tag and run without -n"
    exit 0
  fi
  apk_sums "$AP/$APDIR" || die "couldn't fill in the checksums"
  ok "wrote $APDIR/APKBUILD ($KIND), checksums like abuild checksum"
fi
echo; sed 's/^/     /' "$A"; echo

# ========================================================== 4. build + checks
step "4/6  Build and checks"
BIN_MAIN="$(cfg_get main-program)"; BIN_MAIN="${BIN_MAIN:-$MAIN_GUESS}"
# runs as root in alpine:edge: a throwaway build user and signing key, the
# checks aports' CI runs on a merge request (lint job), then abuild -r
cat > "$WORK/alpine-build.sh" <<'SH'
set -e
trap '[ -n "$OWNER" ] && chown -R "$OWNER" /out /etc/apk/cache 2>/dev/null; :' EXIT
{ echo "$MIRROR/edge/main"; echo "$MIRROR/edge/community"; if [ "$APREPO" = testing ]; then echo "$MIRROR/edge/testing"; fi; } > /etc/apk/repositories
echo "==> setting up abuild"
apk add --no-progress -q alpine-sdk atools shellcheck || { echo "STORE-SUBMIT: setup failed"; exit 3; }
adduser -D builder 2>/dev/null || true
addgroup builder abuild 2>/dev/null || true
if su builder -c true 2>/dev/null; then
  B=/home/builder; asb() { su builder -c "$1"; }; F=""
else
  # a container that can't switch users: build as root, which abuild -F allows
  B=/root; asb() { sh -c "$1"; }; F="-F"
fi
export PACKAGER="$MAINT"
asb "abuild-keygen -a -n -q" >/dev/null 2>&1 || { echo "STORE-SUBMIT: abuild-keygen failed"; exit 3; }
for k in "$B"/.config/abuild/*.rsa.pub "$B"/.abuild/*.rsa.pub; do if [ -f "$k" ]; then cp "$k" /etc/apk/keys/; fi; done
for c in "$B"/.config/abuild/abuild.conf "$B"/.abuild/abuild.conf; do if [ -f "$c" ]; then printf 'PACKAGER="%s"\n' "$MAINT" >> "$c"; fi; done
D="$B/aports/$APREPO/$NAME"
mkdir -p "$B/aports/$APREPO" "$B/distfiles" "$B/packages"
cp -r /aport "$D"
cp /distfiles/* "$B/distfiles/" 2>/dev/null || true
if [ -z "$F" ]; then chown -R builder:builder "$B"; fi
cd "$D"
echo "==> checks, as aports' CI runs them"
( . ./APKBUILD ) >/dev/null 2>"$B/parse.err" || { sed 's/^/LINT: parse: /' "$B/parse.err"; echo "STORE-SUBMIT: the APKBUILD doesn't parse"; exit 4; }
asb "cd '$D' && abuild $F validate" >"$B/validate.log" 2>&1 || { sed 's/^/VALIDATE: /' "$B/validate.log"; echo "STORE-SUBMIT: abuild validate failed"; exit 4; }
sed 's/^/VALIDATE: /' "$B/validate.log"
v="arch builddir checkdepends depends depends_dev depends_doc depends_lang depends_libs depends_openrc depends_static install install_if langdir ldpath license maintainer makedepends makedepends_build makedepends_host options patch_args pcprefix pkgbasedir pkgdesc pkgdir pkgname pkgrel pkgver pkggroups pkgusers provides provider_priority replaces replaces_priority sha256sums sha512sums somask sonameprefix source srcdir tmpdir startdir subpackages subpkgdir subpkgname triggers url CFLAGS CXXFLAGS CPPFLAGS LDFLAGS DFLAGS JOBS MAKEFLAGS CMAKE_CROSSOPTS"
{ echo '#!/bin/sh'; echo 'set -e'; for x in $v; do echo "$x="; done; echo '. ./APKBUILD'; for x in $v; do echo ": \"\$$x\""; done; } > /usr/share/abuild/APKBUILD_SHIM
shellcheck -s busybox -e SC3043,SC2016,SC2086,SC2169,SC2155,SC2100,SC2209,SC2030,SC2031,SC1090 -xa /usr/share/abuild/APKBUILD_SHIM 2>&1 | sed 's/^/SHELLCHECK: /' || true
SKIP_AL31=1 apkbuild-lint APKBUILD 2>&1 | sed 's/^/LINT: /' || true
echo "==> abuild -r"
asb "cd '$D' && abuild $F -r -s '$B/distfiles' -P '$B/packages'" 2>&1 || { echo "STORE-SUBMIT: abuild failed"; exit 5; }
echo "==> the packages"
for p in "$B/packages/$APREPO"/*/*.apk; do if [ -f "$p" ]; then echo "APK: ${p##*/}"; cp "$p" /out/; fi; done
if apk add --no-progress -q -X "$B/packages/$APREPO" "$NAME" >"$B/add.log" 2>&1; then
  apk info -qL "$NAME" 2>/dev/null | grep -v '^$' | sed 's#^/*#FILE: /#'
  if [ -n "$MAIN" ] && command -v "$MAIN" >/dev/null 2>&1; then
    echo "==> $MAIN --version"
    timeout 10 "$MAIN" --version </dev/null 2>&1 | head -n 3 | sed 's/^/VERSION: /' || true
  fi
else
  sed 's/^/INSTALL: /' "$B/add.log"
fi
echo "STORE-SUBMIT: OK"
SH
alp_build() {
  local owner=""
  [ "$RUNTIME" = docker ] && owner="$(id -u):$(id -g)"   # docker's root owns what it writes: hand it back
  mkdir -p "$WORK/out" "$CACHE/alpine/apk-cache" "$DISTFILES"
  rm -f "$WORK/out"/*.apk
  "$RUNTIME" run --rm -v "$AP/$APDIR:/aport:ro" -v "$DISTFILES:/distfiles:ro" -v "$WORK/out:/out" \
    -v "$CACHE/alpine/apk-cache:/etc/apk/cache" -v "$WORK/alpine-build.sh:/build.sh:ro" \
    -e APREPO="$APREPO" -e NAME="$PKG" -e MAIN="$BIN_MAIN" -e MAINT="$MAINT_LINE" -e MIRROR="$ALP_CDN" -e OWNER="$owner" \
    "$ALPINE_IMAGE" sh /build.sh
}

FIXED=" "
fix_once() { case "$FIXED" in *" $1 "*) return 1 ;; esac; FIXED="$FIXED$1 "; }
add_sub() {  # add_sub <subpackage> — files in the main package that Alpine splits off
  apk_raw subpackages | grep -qxF "$1" && return 1
  fix_once "sub:$1" || return 1
  apk_list_add subpackages "$1" && ok "it installs $2: added $1 to subpackages"
}
# layout_fixes — after a build: what abuild and Alpine's habits put elsewhere
layout_fixes() {
  local L="$WORK/build.log" c=1
  grep -qE '^FILE: /usr/share/(man|doc|info|licenses)/' "$L" && add_sub '$pkgname-doc' "documentation" && c=0
  grep -q '^FILE: /usr/share/bash-completion/' "$L" && add_sub '$pkgname-bash-completion' "bash completions" && c=0
  grep -q '^FILE: /usr/share/zsh/site-functions/' "$L" && add_sub '$pkgname-zsh-completion' "zsh completions" && c=0
  grep -q '^FILE: /usr/share/fish/vendor_completions.d/' "$L" && add_sub '$pkgname-fish-completion' "fish completions" && c=0
  grep -q '^FILE: /usr/share/locale/' "$L" && add_sub '$pkgname-lang' "translations" && c=0
  grep -qE '^FILE: /etc/(init|conf)\.d/' "$L" && add_sub '$pkgname-openrc' "OpenRC services" && c=0
  if grep -q 'should probably be set to "noarch"' "$L" && [ "$(apk_raw arch)" != noarch ] && fix_once arch:noarch; then
    apk_set arch noarch; ok "abuild found no machine code: arch=\"noarch\""; c=0
  fi
  return $c
}
# fail_fixes — the build failures with an unambiguous fix: apply it and say so
fail_fixes() {
  local L="$WORK/build.log" n p
  if grep -q 'Arch specific binaries found so arch must not be set to' "$L" && fix_once arch:all; then
    apk_set arch all; ok "it has machine code after all: arch=\"all\""; return 0
  fi
  n="$(grep -oE "(Package '[^']+',? required by|No package '[^']+' found|Dependency \"[^\"]+\" not found|Run-time dependency [^ ]+ found: NO|The system library \`[^\`]+\` required by)" "$L" \
        | head -1 | sed -E "s/^Package '([^']+)'.*/\\1/; s/^No package '([^']+)'.*/\\1/; s/^Dependency \"([^\"]+)\".*/\\1/; s/^Run-time dependency ([^ ]+).*/\\1/; s/^The system library \`([^\`]+)\`.*/\\1/")"
  if [ -n "$n" ] && fix_once "pc:$n"; then
    p="$(alp_provider "pc:$n")"
    if [ -n "$p" ] && apk_list_add makedepends "$p"; then ok "the build needs '$n': added $p to makedepends"; return 0; fi
    bad "the build needs the library '$n', and no Alpine package provides pc:$n"; return 1
  fi
  # a program the build runs (meson says Program 'x' not found; sh says x: not found)
  n="$(grep -oE "Program '[^']+' not found" "$L" | head -1 | sed -E "s/^Program '([^']+)'.*/\\1/")"
  [ -n "$n" ] || n="$(grep -oE "(^|[[:space:]:])[A-Za-z0-9._+-]+: (command )?not found" "$L" | head -1 | sed -E 's/^[[:space:]:]*//; s/: (command )?not found$//')"
  if [ -n "$n" ] && fix_once "cmd:$n"; then
    p="$(alp_provider "cmd:$n")"
    if [ -n "$p" ] && apk_list_add makedepends "$p"; then ok "the build runs '$n': added $p to makedepends"; return 0; fi
    bad "the build runs '$n', and no Alpine package provides it"; return 1
  fi
  n="$(sed -nE "s/.*ModuleNotFoundError: No module named '([^'.]+).*/\\1/p" "$L" | head -1)"
  if [ -n "$n" ] && fix_once "py:$n"; then
    p="$(alp_py "$n")"
    if [ -n "$p" ] && apk_list_add depends "$p"; then ok "the code imports '$n': added $p to depends"; return 0; fi
    bad "the code imports '$n', which isn't packaged in Alpine"; return 1
  fi
  return 1
}
explain_failure() {
  local L="$WORK/build.log"
  if grep -q "STORE-SUBMIT: setup failed" "$L"; then bad "the container couldn't install abuild (is the network up?)"
  elif grep -q "abuild validate failed" "$L"; then bad "abuild validate refuses the APKBUILD:"; grep -E '^VALIDATE: .*(ERROR|WARNING)' "$L" | head -5 | sed 's/^VALIDATE: /       /'
  elif grep -q "doesn't parse" "$L"; then bad "the APKBUILD doesn't parse"
  elif grep -qE "\(no such package\)|unable to select packages" "$L"; then
    bad "a dependency name doesn't exist in Alpine: $(grep -oE '[^ :]+ \(no such package\)' "$L" | sed 's/ (no such package)//' | sort -u | tr '\n' ' ')"
  elif grep -qiE "checksum failed|checksums? (do not|don't) match" "$L"; then bad "a checksum doesn't match the download"
  elif grep -qE "Could not resolve host|Temporary failure in name resolution|unable to download" "$L"; then bad "a download failed — is the network up, and tag $TAG pushed?"
  elif grep -q ">>> ERROR: $PKG: check failed" "$L"; then
    bad "it builds, but the tests fail"
    note "Alpine wants the tests run; skipping them needs a reason next to options=\"!check\""
  else bad "the build failed"; fi
  printf '   %s── last lines of the build log ──%s\n' "$DIM" "$R"
  grep -vE '^\s*$|^(LINT|SHELLCHECK|VALIDATE|FILE|APK): ' "$L" | tail -n 15 | cut -c1-200 | sed 's/^/     /'
}

TESTED=0
if [ "$NO_TEST" = 1 ]; then
  warn "--no-test: not built here — aports' CI builds it on the merge request"
elif [ -z "$RUNTIME" ]; then
  warn "no podman or docker here to build it in an Alpine container"
  note "install one (e.g. podman) to have it built and checked before it's sent; aports' CI will build it either way"
else
  say "A clean build in Alpine's own container catches what aports' CI would, before reviewers see it."
  if [ "$ASSUME_YES" = 1 ] || confirm "Build it with $RUNTIME? (first time: fetches alpine:edge and abuild)" y; then
    ATTEMPT=0
    while :; do
      ATTEMPT=$((ATTEMPT + 1))
      [ "$ATTEMPT" -le 15 ] || { KEEP_WORK=1; die "still failing after 15 builds — the log is in $WORK/build.log"; }
      if run_logged "$WORK/build.log" "abuild -r in alpine:edge (build $ATTEMPT — a first build takes a while)" alp_build \
         && grep -q "STORE-SUBMIT: OK" "$WORK/build.log"; then
        ok "built in alpine:edge: $(grep '^APK: ' "$WORK/build.log" | sed 's/^APK: //' | tr '\n' ' ')"
        if layout_fixes; then apk_sums "$AP/$APDIR" || die "couldn't refresh the checksums"; continue; fi
        TESTED=1
        break
      fi
      if fail_fixes; then apk_sums "$AP/$APDIR" || die "couldn't refresh the checksums"; continue; fi
      explain_failure
      [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "the build needs a person (log: $WORK/build.log)"; }
      CHECKFAIL=0; grep -q ">>> ERROR: $PKG: check failed" "$WORK/build.log" && CHECKFAIL=1
      while :; do
        [ "$CHECKFAIL" = 1 ] && say "t) skip the tests, with the reason in a comment (reviewers ask for one)"
        say "e) edit the APKBUILD (in ${EDITOR:-vi}), then build again     l) read the whole log"
        say "r) build again as it is     s) skip the build     q) quit"
        ask CHOICE "Choice" "e"
        case "$CHOICE" in
          t|T) [ "$CHECKFAIL" = 1 ] || continue
               ask WHY_NOCHECK "Why do the tests fail?" "they need network access"
               OLD_WHY="$(sed -nE 's/^options="[^"]*"[[:space:]]*#[[:space:]]*(.*)$/\1/p' "$A" | head -1)"
               apk_options "$(apk_raw options | grep -vx '!check' | tr '\n' ' ')!check" "${OLD_WHY:+$OLD_WHY; }$WHY_NOCHECK"
               ok "tests skipped: !check # $WHY_NOCHECK"; break ;;
          e|E) "${EDITOR:-vi}" "$A"
               bash -n "$A" 2>"$WORK/syntax.err" || { head -5 "$WORK/syntax.err"; warn "that isn't valid shell — edit again"; continue; }
               apk_sums "$AP/$APDIR" || warn "the checksums couldn't be refreshed"; break ;;
          l|L) "${PAGER:-less}" "$WORK/build.log" || cat "$WORK/build.log" ;;
          r|R) break ;;
          s|S) warn "not built — aports' CI will build it"; break 2 ;;
          q|Q) note "your work is in $AP (branch $BRANCH); re-run to pick it up again"; exit 1 ;;
        esac
      done
    done
  fi
fi
if [ "$TESTED" = 1 ]; then
  L="$WORK/build.log"
  # what aports' CI lint job would say (it doesn't block a merge; reviewers read it)
  if grep -qE '^(LINT|SHELLCHECK): .' "$L"; then
    warn "aports' linters (apkbuild-lint, apkbuild-shellcheck) say:"
    grep -E '^(LINT|SHELLCHECK): .' "$L" | sed -E 's/^(LINT|SHELLCHECK): /       /' | head -15
  else
    ok "apkbuild-lint and apkbuild-shellcheck have no complaints"
  fi
  grep -E '^VALIDATE: .*WARNING' "$L" | sed 's/^VALIDATE: /   ! /' | head -5
  grep -E '^>>> WARNING:' "$L" | sort -u | head -8 | sed 's/^/   /'
  BINS="$(sed -nE 's#^FILE: /usr/bin/##p' "$L")"
  if [ -n "$BINS" ]; then ok "installs: $(printf '%s' "$BINS" | tr '\n' ' ')"
  elif grep -q '^FILE: ' "$L"; then warn "it installs no programs (nothing in /usr/bin)"; fi
  if grep -q '^VERSION: ' "$L"; then
    if grep '^VERSION: ' "$L" | grep -qF "$VERSION"; then ok "$BIN_MAIN --version → $(grep -m1 '^VERSION: ' "$L" | sed 's/^VERSION: //' | cut -c1-60)"
    else note "$BIN_MAIN --version said: $(grep -m1 '^VERSION: ' "$L" | sed 's/^VERSION: //' | cut -c1-60)"; fi
  fi
  ls "$WORK/out"/*.apk >/dev/null 2>&1 && { mkdir -p "$CACHE/alpine/packages"; cp "$WORK/out"/*.apk "$CACHE/alpine/packages/"; note "the packages (signed with a throwaway key) are in $CACHE/alpine/packages"; }
fi

# ========================================================= 5. review + commit
step "5/6  Review and commit"
git -C "$AP" add -A -- "$APDIR"
git -C "$AP" --no-pager diff --cached --stat | sed 's/^/   /'
[ -n "$(git -C "$AP" diff --cached --name-only -- "$APDIR")" ] || die "nothing changed in $APDIR"
REVIEWED=0
if [ "$MODE" = update ] && [ "$RESUMED" = 0 ]; then
  # a version bump and new checksums: the usual tooling change, reviewed upstream
  REVIEWED=1
  [ "$ASSUME_YES" = 0 ] && { echo; git -C "$AP" --no-pager diff --cached --color=auto -- "$APDIR" | head -60; echo; }
elif [ "$ASSUME_YES" = 1 ]; then
  warn "--yes: nobody has read the APKBUILD — the merge request is opened as a draft"
  note "review it, then mark it ready on GitLab: you are its maintainer"
  DRAFT=1
else
  say "You'll be this package's maintainer: read the APKBUILD before it's sent."
  echo; git -C "$AP" --no-pager diff --cached --color=auto -- "$APDIR"; echo
  if confirm "Have you read it, and do you stand behind it?" n; then
    REVIEWED=1
  else
    note "edit it in $AP/$APDIR and re-run, or open the merge request as a draft and review it there"
    confirm "Open it as a draft merge request instead?" y || exit 1
    DRAFT=1
  fi
fi
if [ "$MODE" = new ]; then
  SUBJECT="testing/$PKG: new aport"
  # the commit template from the wiki: url, then pkgdesc
  git -C "$AP" -c user.name="$MAINT_NAME" -c user.email="$ALP_EMAIL" commit -q -m "$SUBJECT" -m "$HOMEPAGE
$DESC" || die "git couldn't commit in $AP"
else
  SUBJECT="$APREPO/$PKG: upgrade to $PKGVER"
  git -C "$AP" -c user.name="$MAINT_NAME" -c user.email="$ALP_EMAIL" commit -q -m "$SUBJECT" || die "git couldn't commit in $AP"
fi
ok "committed: $SUBJECT"

save_answers
if [ "$DRYRUN" = 1 ]; then
  warn "dry run — stopping before the push"
  note "branch $BRANCH is committed in $AP"
  exit 0
fi

# =========================================================== 6. merge request
step "6/6  Merge request"
[ -n "$GL_USER" ] && [ -n "$FORK_PATH" ] || die "not logged in to $ALP_GL_HOST — run again without --dry-run to log in"
FORK_URL="https://$ALP_GL_HOST/$FORK_PATH.git"
go "Push $BRANCH to $FORK_PATH and open the merge request on $ALP_GL_HOST?" || { note "branch $BRANCH is committed in $AP"; exit 0; }

# Bring your fork's master up to date first: then the push only sends the new
# commit (fast, and fine from a blob-less clone).
gl_api graphql -f query='mutation($p: ID!) { projectSyncFork(input: {projectPath: $p, targetBranch: "master"}) { details { behind } errors } }' \
  -f p="$FORK_PATH" > "$WORK/sync.json" 2>&1 || true
if [ "$(jqr '(.data.projectSyncFork.errors // ["?"]) | length' < "$WORK/sync.json" 2>/dev/null || true)" = 0 ]; then ok "fork synced with $ALP_UPSTREAM"
else note "couldn't sync your fork with $ALP_UPSTREAM first — pushing anyway (it may take longer)"; fi

# glab does the authentication for the https push: no SSH key needed
push_branch() {
  git -C "$AP" -c credential.helper= -c "credential.helper=!$(printf '%q' "$GLAB") auth git-credential" \
    push -f "$FORK_URL" "HEAD:refs/heads/$BRANCH"
}
while ! run_logged "$WORK/push.log" "pushing $BRANCH" push_branch; do
  tail -n 4 "$WORK/push.log" | sed 's/^/     /'
  warn "the push failed — usually the network, or glab's login expired (glab auth status --hostname $ALP_GL_HOST)"
  [ "$ASSUME_YES" = 0 ] && confirm "Try again?" y || die "not pushed; the branch is committed in $AP"
done
[ "$(git -C "$AP" ls-remote "$FORK_URL" "refs/heads/$BRANCH" | cut -f1)" = "$(git -C "$AP" rev-parse HEAD)" ] \
  || die "your fork's $BRANCH doesn't match what was pushed"
ok "pushed: https://$ALP_GL_HOST/$FORK_PATH/-/tree/$BRANCH"

# --- the merge request, from your fork into alpine/aports master
MR_URL="$(gl_get "projects/$(enc "$ALP_UPSTREAM")/merge_requests?state=opened&source_branch=$(enc "$BRANCH")&author_username=$GL_USER" 2>/dev/null \
  | jqr '.[0].web_url // ""' 2>/dev/null || true)"
if [ -n "$MR_URL" ]; then
  ok "updated your open merge request: $MR_URL"
else
  UP_ID="$(gl_get "projects/$(enc "$ALP_UPSTREAM")" | jqr '.id // ""' 2>/dev/null || true)"
  [ -n "$UP_ID" ] || die "couldn't look up $ALP_UPSTREAM on $ALP_GL_HOST"
  BODY="$WORK/mr.md"
  {
    if [ "$MODE" = new ]; then printf '%s\n\nHomepage: %s\n' "$DESC" "$HOMEPAGE"
    else printf 'Upgrade %s from %s to %s.\n' "$PKG" "$OLD_VER" "$PKGVER"; fi
    [ -n "$CHANGELOG_REAL" ] && printf 'Changelog: %s\n' "$CHANGELOG_REAL"
    printf '\n'
    if [ "$TESTED" = 1 ]; then
      printf 'Built with `abuild -r` and checked with `abuild validate`, `apkbuild-lint` and `apkbuild-shellcheck` in an alpine:edge container (x86_64).\n'
    else
      printf 'Not built locally — this relies on CI.\n'
    fi
    printf '\n---\n\n'
    if [ "$MODE" = update ] && [ "$RESUMED" = 0 ]; then
      printf 'Bumped (pkgver, pkgrel, sha512sums) by [linux-submit.sh](%s).\n' "$TOOL_URL"
    else
      printf 'The APKBUILD was written by [linux-submit.sh](%s), a script (no AI involved when it runs) that fills it in from the project'"'"'s own files and checks it as above.' "$TOOL_URL"
      [ "$REVIEWED" = 1 ] && printf ' I reviewed it before submitting.\n' || printf ' Not reviewed yet — this stays a draft until it is.\n'
    fi
  } > "$BODY"
  TITLE="$SUBJECT"; [ "$DRAFT" = 1 ] && TITLE="Draft: $SUBJECT"
  if ! gl_api --method POST "projects/$(enc "$FORK_PATH")/merge_requests" \
        -f source_branch="$BRANCH" -f target_branch=master -F target_project_id="$UP_ID" \
        -f title="$TITLE" -F description="@$BODY" -F remove_source_branch=true -F allow_collaboration=true \
        > "$WORK/mr.json" 2> "$WORK/mr.err"; then
    cat "$WORK/mr.err" "$WORK/mr.json" 2>/dev/null | grep -v '^\s*$' | tail -4 | sed 's/^/     /'
    KEEP_WORK=1
    die "GitLab didn't open the merge request — the text is in $BODY; open it on https://$ALP_GL_HOST/$FORK_PATH/-/merge_requests/new?merge_request%5Bsource_branch%5D=$BRANCH"
  fi
  MR_URL="$(jqr '.web_url // ""' < "$WORK/mr.json" 2>/dev/null || true)"
  [ -n "$MR_URL" ] || die "GitLab didn't say where the merge request is — check https://$ALP_GL_HOST/$ALP_UPSTREAM/-/merge_requests"
  if [ "$DRAFT" = 1 ]; then ok "merge request opened (draft): $MR_URL"; else ok "merge request opened: $MR_URL"; fi
fi

# ================================================================ hand-off
handoff_add "Watch the merge request's pipeline: aports' CI builds it for every architecture Alpine has. If one fails for a reason you can't fix, leave it out with a comment, e.g. arch=\"all !s390x\" # tests fail on s390x — then run this wizard again (it starts from your branch and pushes to it)"
handoff_add "Answer the reviewers on the merge request yourself — Alpine's developers merge it when they're happy"
[ "$DRAFT" = 1 ] && handoff_add "It's a draft: read the APKBUILD, then press \"Mark as ready\" on the merge request"
if [ "$MODE" = new ]; then
  handoff_add "testing/ is only in edge. Once people have used it, move it to community (a commit titled \"community/$PKG: move from testing\"): aports removes testing packages that aren't moved within 9 months"
  handoff_add "Add the project to https://release-monitoring.org (Anitya), so Alpine hears about your new releases"
fi
handoff_show "Your turn — what Alpine's review needs from you" "$MR_URL"

printf '   %sDone.%s %s\n   %s\n\n' "$B" "$R" "$SUBJECT" "$MR_URL"
if [ "$APREPO" = testing ]; then
  say "  • Once merged, people on Alpine edge install it with: apk add $PKG"
  say "    (with the testing repository enabled: $ALP_CDN/edge/testing in /etc/apk/repositories)"
else
  say "  • Once merged it reaches edge, and the next Alpine release: apk add $PKG"
fi
say "  • Next release: run linux-submit.sh alpine (or linux-submit.sh) again — it bumps pkgver."
echo
}

# ##########################################################################
#   GURU (Gentoo) — questions shared with a Linux run, and helpers. The
#   category and what GURU asks of you (a Gentoo user, its rules, a Gentoo
#   Bugzilla address) are part of "Your app" whenever GURU is among the
#   distros. Needs linux_common and linux_app's globals.
# ##########################################################################
GURU_RULES_DATE="2026-07-19"   # GURU's rules last changed then (its pull request form says so)
GURU_RAW_GENTOO="https://codeberg.org/gentoo/gentoo/raw/branch/master"
GURU_RAW_GURU="https://codeberg.org/gentoo/guru/raw/branch/dev"
GURU_ME="${XDG_CONFIG_HOME:-$HOME/.config}/guru-submit/me.conf"

# guru_me_get <key> / guru_me_set <key> <value> — what you told GURU about
# yourself (not about the app, so it stays out of .store-submit.conf)
guru_me_get() {
  [ -f "$GURU_ME" ] || return 0
  sed -nE "s/^$1 = (.*)\$/\\1/p" "$GURU_ME" | tail -1
}
guru_me_set() {
  [ "${SAVE:-1}" = 1 ] || return 0
  mkdir -p "$(dirname "$GURU_ME")"
  {
    printf '# written by linux-submit.sh guru: what you told it about yourself — safe to delete (or run --forget)\n'
    [ -f "$GURU_ME" ] && grep -vE "^(#|$1 = )" "$GURU_ME" || true
    printf '%s = %s\n' "$1" "$2"
  } > "$GURU_ME.new" && mv "$GURU_ME.new" "$GURU_ME"
}

# guru_categories — Gentoo's package categories (::gentoo's and GURU's own):
# from the local trees once they're there, else from their Codeberg mirrors
guru_categories() {
  local cats="$WORK/guru-categories.txt"
  if [ ! -s "$cats" ]; then
    {
      if [ -f "${GURU_SNAP:-/nonexistent}/profiles/categories" ]; then cat "$GURU_SNAP/profiles/categories"
      else curl -sf --max-time 20 "$GURU_RAW_GENTOO/profiles/categories" || true; fi
      if [ -f "${GURU_DIR:-/nonexistent}/profiles/categories" ]; then cat "$GURU_DIR/profiles/categories"
      else curl -sf --max-time 20 "$GURU_RAW_GURU/profiles/categories" || true; fi
    } | grep -E '^[a-z0-9]' | sort -u > "$cats" || true
  fi
  cat "$cats"
}

# guru_suggest_category — a first guess from the description; you confirm it
guru_suggest_category() {
  local t
  t=" $(printf '%s %s' "$DESC" "$PNAME" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' ' ' | tr -s ' ') "
  case "$t" in
    *" music "*|*" audio "*|*" sound "*|*" podcast "*|*" podcasts "*|*" radio "*) echo media-sound ;;
    *" video "*|*" videos "*|*" movie "*|*" movies "*|*" youtube "*)             echo media-video ;;
    *" image "*|*" images "*|*" photo "*|*" photos "*|*" picture "*|*" drawing "*|*" paint "*) echo media-gfx ;;
    *" game "*|*" games "*|*" puzzle "*)                                          echo games-misc ;;
    *" editor "*)                                                                 echo app-editors ;;
    *" git "*|*" version control "*)                                              echo dev-vcs ;;
    *" shell "*)                                                                  echo app-shells ;;
    *" chat "*|*" messenger "*|*" matrix "*|*" xmpp "*|*" irc "*)                 echo net-im ;;
    *" mail "*|*" email "*)                                                       echo mail-client ;;
    *" backup "*|*" backups "*)                                                   echo app-backup ;;
    *" password "*|*" passwords "*|*" encryption "*|*" encrypt "*|*" otp "*)      echo app-crypt ;;
    *" pdf "*|*" markdown "*|*" ebook "*|*" epub "*|*" latex "*|*" document "*|*" documents "*) echo app-text ;;
    *" font "*|*" fonts "*)                                                       echo media-fonts ;;
    *" download "*|*" downloader "*|*" http "*|*" ftp "*|*" vpn "*|*" proxy "*|*" dns "*|*" network "*) echo net-misc ;;
    *" process "*|*" processes "*)                                                echo sys-process ;;
    *" disk "*|*" disks "*|*" hardware "*|*" battery "*|*" kernel "*)             echo sys-apps ;;
    *" developer "*|*" developers "*|*" programming "*|*" compiler "*|*" debugger "*|*" linter "*|*" json "*|*" yaml "*) echo dev-util ;;
    *" wayland "*)                                                                echo gui-apps ;;
    *" window manager "*)                                                         echo x11-wm ;;
    *)                                                                            echo app-misc ;;
  esac
}

# guru_bugzilla <e-mail> — 0: Gentoo Bugzilla has an account with that
# address; 1: it hasn't; 2: couldn't ask
guru_bugzilla() {
  local r
  r="$(curl -s --max-time 20 -G --data-urlencode "names=$1" "https://bugs.gentoo.org/rest/user" 2>/dev/null)" || return 2
  case "$r" in
    *'"users":[{'*) return 0 ;;
    *'"code":51'*)  return 1 ;;
    *)              return 2 ;;
  esac
}

# guru_questions — up front: what can't work, you and GURU's rules, the
# category, you as maintainer
guru_questions() {
  local first=1 sugg rc
  # --- what Portage can't build from source: said before anything else
  case "$KIND" in
    flutter) die "Gentoo has no Flutter SDK (it isn't packaged in ::gentoo or GURU) and Portage builds without internet — a Flutter app can't be built from source there. GURU carries Flutter apps only as -bin repackages of a prebuilt Linux bundle (like net-im/fluffychat-bin), which this wizard doesn't write. Gentoo users get it from Flathub" ;;
    node)    die "Portage builds without internet and Gentoo has no npm eclass — this wizard can't write an ebuild for an npm app (its node_modules would have to be a tarball you host). Gentoo users get it from Flathub or the Snap Store" ;;
  esac

  # --- GURU is for Gentoo users: its rules let them publish software they
  # wrote, and forbid others using it to advertise theirs
  if [ "$(guru_me_get gentoo-user)" != yes ] || [ "$ASK_ALL" = 1 ]; then
    note "GURU's rules: Gentoo users may publish software they wrote there; others must not use it to advertise theirs"
    [ "$ASSUME_YES" = 1 ] && die "--yes: GURU needs a few answers from you once — run without --yes"
    confirm "Do you use Gentoo yourself?" n \
      || die "GURU is for software its Gentoo-using authors maintain there (https://wiki.gentoo.org/wiki/Project:GURU#Rules). Gentoo users can install your app from Flathub instead"
    guru_me_set gentoo-user yes
  fi
  # --- its rules: agreed to before contributing, and again when they change
  GURU_RULES_AGREED="$(guru_me_get rules)"
  if [ -z "$GURU_RULES_AGREED" ] || [[ "$GURU_RULES_AGREED" < "$GURU_RULES_DATE" ]]; then
    say "GURU asks everyone to read and agree to its rules before contributing"
    say "(they last changed on $GURU_RULES_DATE): https://wiki.gentoo.org/wiki/Project:GURU#Rules"
    note "among them: Gentoo's copyright and AI policies apply, ~arch keywords only, only packages you can maintain"
    [ "$ASSUME_YES" = 1 ] && die "--yes: agree to GURU's rules once without --yes"
    confirm "Have you read them, and do you agree?" n || die "GURU takes contributions only from people who agree to its rules"
    GURU_RULES_AGREED="$GURU_RULES_DATE"; guru_me_set rules "$GURU_RULES_DATE"
  fi
  ok "you use Gentoo and agree to GURU's rules (as of $GURU_RULES_AGREED)"

  # --- the category: Gentoo files every package under one
  sugg="${GURU_CATEGORY_ARG:-$(cfg_get guru-category)}"
  [ -n "$sugg" ] || sugg="$(guru_suggest_category)"
  while :; do
    if [ "$first" = 1 ] && { [ -n "${GURU_CATEGORY_ARG:-}" ] || { [ -n "$(cfg_get guru-category)" ] && [ "$ASK_ALL" = 0 ]; }; }; then
      CAT="$sugg"; ok "category: $CAT"
    else
      [ "$first" = 1 ] && note "Gentoo files packages by category — app-misc, dev-util, net-misc, media-sound… (https://packages.gentoo.org/categories)"
      ask CAT "Category" "$sugg"
    fi
    first=0
    guru_categories | grep -qxF "$CAT" && break
    if [ -z "$(guru_categories)" ] && printf '%s' "$CAT" | grep -qE '^([a-z0-9]+-[a-z0-9]+|virtual)$'; then
      warn "couldn't fetch Gentoo's category list to check '$CAT' — pkgcheck checks it later"; break
    fi
    warn "'$CAT' isn't one of Gentoo's categories"
    [ "$ASSUME_YES" = 1 ] && die "fix guru-category in the config (or pass --category)"
    sugg="$(guru_categories | grep -E "^${CAT%%-*}-" | head -1 || true)"
    [ -n "$sugg" ] || sugg="$(guru_suggest_category)"
  done
  if [ "${SAVE:-1}" = 1 ]; then cfg_set guru-category "$CAT"; fi

  # --- you as maintainer: metadata.xml may only list addresses Gentoo
  # Bugzilla knows (bug reports reach you there); none is fine too
  GURU_MAINT="$(cfg_get guru-maintainer)"
  if [ -z "${MAINT_EMAIL:-}" ]; then
    GURU_MAINT=no; note "no maintainer e-mail: metadata.xml lists no one (GURU as a whole maintains it)"
  elif [ "$GURU_MAINT" = no ] && [ "$ASK_ALL" = 0 ]; then
    note "metadata.xml lists no maintainer (your earlier choice; guru-maintainer in the config)"
  else
    while :; do
      rc=0; guru_bugzilla "$MAINT_EMAIL" || rc=$?
      if [ "$rc" = 0 ]; then GURU_MAINT=yes; ok "maintainer: $MAINT_EMAIL has a Gentoo Bugzilla account"; break; fi
      if [ "$rc" = 2 ]; then
        GURU_MAINT=yes; warn "couldn't ask Gentoo Bugzilla about $MAINT_EMAIL — it must be the address of your account there"; break
      fi
      warn "$MAINT_EMAIL has no Gentoo Bugzilla account — GURU lists only addresses known there as maintainers"
      note "make one with this address: https://bugs.gentoo.org/createaccount.cgi — or leave yourself out of metadata.xml"
      [ "$ASSUME_YES" = 1 ] && die "the maintainer e-mail needs a Gentoo Bugzilla account (or set guru-maintainer = no in the config)"
      confirm "Check again? (no: leave yourself out of metadata.xml)" y || { GURU_MAINT=no; break; }
    done
  fi
  if [ "${SAVE:-1}" = 1 ]; then cfg_set guru-maintainer "$GURU_MAINT"; fi
  return 0
}

# ##########################################################################
#   GURU wizard — linux-submit.sh guru [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_guru() {
#
# linux-submit.sh guru — publish an app to GURU, Gentoo's official repository
# of packages maintained by Gentoo users, or ship a new version of it there.
#
# Follows GURU's and Gentoo's own rules and documentation:
#   https://wiki.gentoo.org/wiki/Project:GURU                     (the rules)
#   https://wiki.gentoo.org/wiki/Project:GURU/Information_for_Contributors
#   https://wiki.gentoo.org/wiki/Project:Codeberg/Pull_requests   (AGit)
#   https://devmanual.gentoo.org/                                 (ebuilds, eclasses, metadata.xml)
#   https://www.gentoo.org/glep/glep-0076.html                    (Certificate of Origin)
#   https://www.gentoo.org/glep/glep-0063.html                    (OpenPGP keys)
#   https://wiki.gentoo.org/wiki/Project:Council/AI_policy
#
# Writes <category>/<name>/<name>-<version>.ebuild with the eclass for your
# build system (cargo, go-module, distutils-r1, meson, cmake) and its
# metadata.xml — or takes your own ebuild, or copies the one already in GURU
# to the new version and drops the old one. Makes the Manifest with pkgdev,
# checks with pkgcheck, test-builds with `ebuild … merge` offline in a clean
# Gentoo container, and makes a signed, signed-off commit in GURU's style.
# With push access it goes to GURU's dev branch; without, as GURU asks of
# newcomers, as a pull request on Codeberg — and the to-do list says how to
# ask for access.
#
# Gentoo's AI policy (which GURU follows) forbids content made with the help
# of AI tools. This script is fixed code — no AI runs when it writes your
# ebuild — but the script itself was written with AI help; the wizard says so
# before you sign off, and uses your own ebuild when your app has one.
#
# Nothing leaves your machine without asking first, unless you pass --yes.

set -eu

DRYRUN=0
SAVE=1
ASSUME_YES=0
ASK_ALL=0
NO_TEST=0
FORCE_PR=0
REPO_ARG=""
SSHKEY_ARG=""
GPG_ARG=""
GURU_CATEGORY_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/guru-submit"
CONF="$CONF_DIR/last.conf"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/store-submit"
# GURU's git: read from the Codeberg mirror, push to Gentoo's server (with
# access), pull requests to Codeberg (all overridable for testing)
GURU_GIT_READ="${GURU_GIT_READ:-https://codeberg.org/gentoo/guru.git}"
GURU_GIT_PUSH="${GURU_GIT_PUSH:-git@git.gentoo.org:repo/proj/guru.git}"
GURU_GIT_PR="${GURU_GIT_PR:-git@codeberg.org:gentoo/guru.git}"
GENTOO_SNAPSHOT_URL="${GENTOO_SNAPSHOT_URL:-https://distfiles.gentoo.org/snapshots/gentoo-latest.tar.xz}"
# the key Gentoo signs its repository snapshots with (infrastructure@gentoo.org)
GENTOO_SNAPSHOT_KEY="DCD05B71EAB94199527F44ACDB6B8C1F96D8BF6D"
STAGE3_IMAGE="${GENTOO_STAGE3_IMAGE:-docker.io/gentoo/stage3:latest}"

usage() {
  cat <<'USAGE'
linux-submit.sh guru — publish an app to GURU (Gentoo's user repository), or
update it there.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask; a new ebuild
                      the wizard wrote still stops for your review, and your
                      Signed-off-by needs you once (a run without --yes)
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --config FILE   the shared answers (default: .store-submit.conf in the repo)
      --category CAT  the Gentoo category (default: from the config, or asked)
      --key FILE      the SSH key for git.gentoo.org and codeberg.org
      --gpg-key ID    the OpenPGP key to sign with (default: remembered, or found)
      --pr            send a pull request even if you can push to dev
      --no-test       skip the test build in a Gentoo container
  -n, --dry-run       write, check, build and commit locally; send nothing
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
    --category)   GURU_CATEGORY_ARG="${2-}"; shift ;;
    --key)        SSHKEY_ARG="${2-}"; shift ;;
    --gpg-key)    GPG_ARG="${2-}"; shift ;;
    --pr)         FORCE_PR=1 ;;
    --no-test)    NO_TEST=1 ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF" "$GURU_ME"; printf 'forgot %s and %s\n' "$CONF" "$GURU_ME"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WIZ_NAME=guru-submit
linux_common

# ------------------------------------------------------- remembered answers
SAVED_REPO=""; SAVED_SSH_KEY=""; SAVED_GPG_KEY=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  {
    printf '# written by linux-submit.sh guru — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n'    "${REPO:-${SAVED_REPO:-}}"
    printf 'SAVED_SSH_KEY=%q\n' "${SSHKEY:-${SAVED_SSH_KEY:-}}"
    printf 'SAVED_GPG_KEY=%q\n' "${GPGKEY:-${SAVED_GPG_KEY:-}}"
  } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  chmod 600 "$CONF" 2>/dev/null || true
}

# ------------------------------------------------------------------ helpers
# Gentoo's own tools (pkgdev, pkgcheck, pycargoebuild) run in a Gentoo
# container (podman or docker); on a Gentoo machine without one, yours are
# used instead (the test build then needs a container, so it's skipped).
RUNTIME=""
for r in podman docker; do
  have "$r" && "$r" info >/dev/null 2>&1 && { RUNTIME="$r"; break; }
done
GX_HOST=0
[ -z "$RUNTIME" ] && have pkgdev && have pkgcheck && GX_HOST=1
# a rootful docker writes root-owned files: the scripts hand them back to you
GX_OWNER=""
if [ "$RUNTIME" = docker ] && ! docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
  GX_OWNER="$(id -u):$(id -g)"
fi
case "$(uname -m)" in
  x86_64) GARCH=amd64 ;; aarch64|arm64) GARCH=arm64 ;; riscv64) GARCH=riscv ;;
  ppc64le|ppc64) GARCH=ppc64 ;; i?86) GARCH=x86 ;; *) GARCH=amd64 ;;
esac
YEAR="$(date +%Y)"
GURU_SNAP="$CACHE/gentoo/repo"        # Gentoo's tree, from its signed daily snapshot
DIST="$CACHE/gentoo/distfiles"        # sources, as Portage keeps them
BINPKGS="$CACHE/gentoo/binpkgs"       # Gentoo's prebuilt packages, kept between test builds
GURU_DIR="$CACHE/guru"                # the wizard's own GURU checkout
GX="$WORK/gx"                         # scripts and results shared with the container
mkdir -p "$DIST" "$BINPKGS" "$GX"

# gpg: yours, or GnuPG from nixpkgs; git signs with the same program
gpg_program() {
  if have gpg; then command -v gpg; return 0; fi
  local d
  for d in $(nix_tool_paths gnupg 2>/dev/null); do [ -x "$d/bin/gpg" ] && { printf '%s' "$d/bin/gpg"; return 0; }; done
  return 1
}
gpgk() { "$GPGPROG" "$@"; }
# key_fpr <name, e-mail or ID> — the primary fingerprint of a secret key that
# can sign (not expired or revoked; the newest such); "" if none
key_fpr() {
  local f
  for f in $(gpgk --list-secret-keys --with-colons ${1:+-- "$1"} 2>/dev/null | awk -F: '$1 == "sec" { s = 1; next } s && $1 == "fpr" { print $10; s = 0 }' | tac); do
    glep63 "$f" | grep -qE '^(EXPIRED|REVOKED)$' || { printf '%s' "$f"; return 0; }
  done
  return 0
}
# glep63 <fingerprint> — one line per GLEP 63 rule the key breaks
glep63() {
  gpgk --list-keys --with-colons --fixed-list-mode -- "$1" 2>/dev/null | awk -F: -v now="$(date +%s)" '
    function strong(algo, len, curve) { return (algo == 1 && len >= 2048) || (algo == 22 && curve == "ed25519") }
    $1 == "pub" { pa = $4; pl = $3; pc = $17; pe = $7; pcap = $12; pv = $2 }
    $1 == "sub" && $2 !~ /[rei]/ {
      if ($12 == "s") { sign = 1; if (!strong($4, $3, $17)) weak = 1 }
      if ($12 == "e") enc = 1
      if ($7 == "" || $7 - now > 900 * 86400) longsub = 1
    }
    END {
      if (pv ~ /r/) print "REVOKED"
      if (pv ~ /e/) print "EXPIRED"
      if (!strong(pa, pl, pc)) print "the primary key should be RSA (2048 bits or more) or Ed25519"
      if (pe == "" || pe - now > 900 * 86400) print "it should expire within 900 days (and be renewed before it does)"
      if (!sign) print "it should have a signing subkey that does nothing else"
      else if (weak) print "its signing subkey should be RSA (2048 bits or more) or Ed25519"
      if (!enc) print "it should have an encryption subkey that does nothing else"
      if (longsub) print "every subkey should expire within 900 days"
      cap = pcap; gsub(/[A-Z]/, "", cap)
      if (cap != "c") print "(recommended) the primary key should only certify"
    }'
}

# eb_q <text> — for a "…" string in an ebuild; xml_q <text> — for XML
eb_q() { printf '%s' "$1" | sed -e 's/[\\"$`]/\\&/g'; }
xml_q() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
# exists <atom> — the package is in ::gentoo or GURU (slot, USE and := ignored)
exists() { local a="${1%%[:[]*}"; [ -d "$GURU_SNAP/$a" ] || [ -d "$GURU_DIR/$a" ]; }
# block <VAR> <item>... — VAR="…" on one line, or one item per line
block() {
  local var="$1"; shift
  [ "$#" -gt 0 ] || return 0
  if [ "$#" = 1 ]; then printf '%s="%s"\n' "$var" "$1"
  else printf '%s="\n' "$var"; printf '\t%s\n' "$@"; printf '"\n'; fi
}
sorted() { printf '%s\n' "$@" | awk 'NF && !seen[$0]++' | LC_ALL=C sort; }

# eapi_for <eclass>... — the newest EAPI all of them support (8 at least)
eapi_for() {
  local e s n best=9
  for e in "$@"; do
    s="$(sed -nE 's/^# @SUPPORTED_EAPIS: //p' "$GURU_SNAP/eclass/$e.eclass" 2>/dev/null | head -1)"
    [ -n "$s" ] || continue
    n="$(printf '%s\n' $s | sort -n | tail -1)"
    if [ "$n" -lt "$best" ]; then best="$n"; fi
  done
  if [ "$best" -lt 8 ]; then best=8; fi
  printf '%s' "$best"
}

# python_compat — the profile's default Python and the two before it, as far
# as the eclass still supports them
python_compat() {
  local def all lo
  def="$(sed -nE 's/^PYTHON_TARGETS="python3_([0-9]+)".*/\1/p' "$GURU_SNAP/profiles/base/make.defaults" 2>/dev/null | head -1)"
  # the eclass's own list, brace expansions and all
  # shellcheck disable=SC2016
  all="$(bash -c 'eval "$(sed -n "/^_PYTHON_ALL_IMPLS=(/,/^)/p" "$1")"; printf "%s\n" "${_PYTHON_ALL_IMPLS[@]}"' _ "$GURU_SNAP/eclass/python-utils-r1.eclass" 2>/dev/null \
         | sed -nE 's/^python3_([0-9]+)$/\1/p' | sort -n || true)"
  def="${def:-14}"
  lo="$(printf '%s\n' "$all" | awk -v d="$def" 'NF && $1 <= d && $1 >= d - 2' | head -1)"
  lo="${lo:-$def}"
  if [ "$lo" = "$def" ]; then printf 'python3_%s' "$def"; else printf 'python3_{%s..%s}' "$lo" "$def"; fi
}

# gentoo_license <SPDX expression> — the same in Gentoo's LICENSE syntax, from
# ::gentoo's own mapping (metadata/license-mapping.conf); UNKNOWN:<id> if an
# id has no Gentoo name
gentoo_license() {
  python3 - "$1" "$GURU_SNAP/metadata/license-mapping.conf" <<'PY'
import configparser, re, sys
expr, mapfile = sys.argv[1], sys.argv[2]
cp = configparser.ConfigParser(delimiters=("=",), interpolation=None, strict=False)
cp.optionxform = str
cp.read(mapfile)
m = {k.lower(): v.strip() for k, v in cp["spdx-to-ebuild"].items()}
toks = re.findall(r"\(|\)|[^\s()]+", expr)
pos = 0
def peek():
    return toks[pos] if pos < len(toks) else None
def take():
    global pos
    pos += 1
    return toks[pos - 1]
def one():
    t = take()
    if t == "(":
        r = anyof(); take(); return r
    key = t
    if peek() and peek().upper() == "WITH":
        take(); key += " WITH " + take()
    v = m.get(key.lower()) or m.get(key.lower().rstrip("+"))
    if v is None:
        raise KeyError(key)
    return v
def allof():
    parts = [one()]
    while peek() and peek().upper() == "AND":
        take(); parts.append(one())
    return " ".join(parts)
def anyof():
    parts = [allof()]
    while peek() and peek().upper() == "OR":
        take(); parts.append(allof())
    if len(parts) == 1:
        return parts[0]
    return "|| ( " + " ".join("( %s )" % p if " " in p else p for p in parts) + " )"
try:
    print(anyof())
except KeyError as e:
    print("UNKNOWN:" + e.args[0])
except Exception:
    print("UNKNOWN:" + expr)
PY
}

# pc_dep <pkg-config module> / prog_dep <program> / cmake_dep <find_package
# name> — the Gentoo package that provides it ("" if not in the table)
pc_dep() {
  case "$1" in
    gtk4) echo gui-libs/gtk:4 ;; gtk+-3.0) echo x11-libs/gtk+:3 ;; libadwaita-1) echo gui-libs/libadwaita:1 ;;
    glib-2.0|gio-2.0|gobject-2.0|gio-unix-2.0|gmodule-2.0) echo dev-libs/glib:2 ;; json-glib-1.0) echo dev-libs/json-glib ;;
    libsoup-3.0) echo net-libs/libsoup:3.0 ;; webkitgtk-6.0) echo net-libs/webkit-gtk:6 ;; webkit2gtk-4.1) echo net-libs/webkit-gtk:4.1 ;;
    gtksourceview-5) echo gui-libs/gtksourceview:5 ;; sqlite3) echo dev-db/sqlite:3 ;; openssl|libssl|libcrypto) echo dev-libs/openssl:= ;;
    libcurl) echo net-misc/curl ;; zlib) echo virtual/zlib:= ;; x11) echo x11-libs/libX11 ;;
    wayland-client|wayland-cursor|wayland-server|wayland-egl) echo dev-libs/wayland ;; xkbcommon) echo x11-libs/libxkbcommon ;;
    dbus-1) echo sys-apps/dbus ;; libpulse|libpulse-simple) echo media-libs/libpulse ;; alsa) echo media-libs/alsa-lib ;;
    libxml-2.0) echo dev-libs/libxml2:= ;; cairo) echo x11-libs/cairo ;; pango|pangocairo) echo x11-libs/pango ;;
    gdk-pixbuf-2.0) echo x11-libs/gdk-pixbuf:2 ;; fontconfig) echo media-libs/fontconfig ;; freetype2) echo media-libs/freetype:2 ;;
    libpng) echo media-libs/libpng:= ;; libjpeg) echo media-libs/libjpeg-turbo:= ;; sdl2) echo media-libs/libsdl2 ;; sdl3) echo media-libs/libsdl3 ;;
    vulkan) echo media-libs/vulkan-loader ;; libsystemd) echo sys-apps/systemd:= ;; libudev) echo virtual/libudev:= ;;
    libsecret-1) echo app-crypt/libsecret ;; libnotify) echo x11-libs/libnotify ;; gstreamer-1.0) echo media-libs/gstreamer:1.0 ;;
    gstreamer-plugins-base-1.0) echo media-libs/gst-plugins-base:1.0 ;; epoxy) echo media-libs/libepoxy ;;
    libarchive) echo app-arch/libarchive:= ;; libzstd) echo app-arch/zstd:= ;; liblzma) echo app-arch/xz-utils ;;
    libpcre2-8) echo dev-libs/libpcre2:= ;; libportal) echo dev-libs/libportal ;; libportal-gtk4) echo 'dev-libs/libportal[gtk]' ;;
    libdrm) echo x11-libs/libdrm ;; gl|opengl) echo virtual/opengl ;; gee-0.8) echo dev-libs/libgee:0.8= ;;
    harfbuzz) echo media-libs/harfbuzz:= ;; libpipewire-0.3) echo media-video/pipewire:= ;; jansson) echo dev-libs/jansson:= ;;
    libuv) echo dev-libs/libuv:= ;; libsodium) echo dev-libs/libsodium:= ;; ncurses|ncursesw) echo sys-libs/ncurses:= ;;
    readline) echo sys-libs/readline:= ;; icu-uc|icu-i18n) echo dev-libs/icu:= ;; gnutls) echo net-libs/gnutls:= ;;
    libusb-1.0) echo dev-libs/libusb:1 ;; sndfile) echo media-libs/libsndfile ;; libevdev) echo dev-libs/libevdev ;;
    libinput) echo dev-libs/libinput:= ;; protobuf) echo dev-libs/protobuf:= ;;
    libavcodec|libavformat|libavutil|libswscale|libswresample) echo media-video/ffmpeg:= ;;
  esac
}
prog_dep() {
  case "$1" in
    pkg-config|pkgconf) echo virtual/pkgconfig ;;
    glib-compile-resources|glib-compile-schemas) echo dev-libs/glib:2 ;; glib-mkenums|gdbus-codegen) echo dev-util/glib-utils ;;
    msgfmt|xgettext|msgmerge) echo sys-devel/gettext ;; desktop-file-validate|update-desktop-database) echo dev-util/desktop-file-utils ;;
    appstreamcli) echo dev-libs/appstream ;; appstream-util) echo dev-libs/appstream-glib ;;
    blueprint-compiler) echo dev-util/blueprint-compiler ;; wayland-scanner) echo dev-util/wayland-scanner ;;
    sassc) echo dev-lang/sassc ;; itstool) echo dev-util/itstool ;; scdoc) echo app-text/scdoc ;; protoc) echo dev-libs/protobuf ;;
    gtk4-update-icon-cache|gtk4-builder-tool) echo gui-libs/gtk:4 ;;
  esac
}
cmake_dep() {
  case "$1" in
    Qt6) echo 'dev-qt/qtbase:6[gui,widgets]' ;; OpenSSL) echo dev-libs/openssl:= ;; CURL) echo net-misc/curl ;;
    ZLIB) echo virtual/zlib:= ;; SQLite3) echo dev-db/sqlite:3 ;; PNG) echo media-libs/libpng:= ;; JPEG) echo media-libs/libjpeg-turbo:= ;;
    Freetype) echo media-libs/freetype:2 ;; X11) echo x11-libs/libX11 ;; OpenGL) echo virtual/opengl ;; SDL2) echo media-libs/libsdl2 ;;
    SDL3) echo media-libs/libsdl3 ;; Boost) echo dev-libs/boost:= ;; fmt) echo dev-libs/libfmt:= ;; spdlog) echo dev-libs/spdlog:= ;;
    nlohmann_json) echo dev-cpp/nlohmann_json ;; LibArchive) echo app-arch/libarchive:= ;;
  esac
}

# gx <log> "label" <script> — one of the scripts below, with Gentoo's tools:
# in the tools container, or on this machine (host mode). Paths reach them as
# $GURU (the GURU checkout), $DIST (distfiles), $GENTOO (::gentoo) and $GX.
gx() {
  local log="$1" label="$2" script="$3"
  tools_image
  if [ "$GX_HOST" = 1 ]; then
    run_logged "$log" "$label" env GX="$GX" GURU="$GURU_DIR" DIST="$DIST" GENTOO="$GURU_SNAP" GX_HOST=1 \
      CAT="$CAT" PN="$PN" PV="$PV" P="$P" OWNER="" GXENV="${GXENV:-}" bash "$GX/$script"
  else
    run_logged "$log" "$label" "$RUNTIME" run --rm \
      -v "$GURU_SNAP:/var/db/repos/gentoo:ro" -v "$GURU_DIR:/var/db/repos/guru" -v "$DIST:/var/cache/distfiles" \
      -v "$BINPKGS:/var/cache/binpkgs" -v "$GX:/gx" \
      -e GX=/gx -e GURU=/var/db/repos/guru -e DIST=/var/cache/distfiles -e GENTOO=/var/db/repos/gentoo \
      -e CAT="$CAT" -e PN="$PN" -e PV="$PV" -e P="$P" -e OWNER="$GX_OWNER" -e GXENV="${GXENV:-}" \
      "$TOOLS_IMG" bash "/gx/$script"
  fi
}
# gx_ok <log> — the script got to its end
gx_ok() { grep -q '^STORE-SUBMIT: OK' "$1"; }
gx_fail() {  # gx_fail <log> "what failed" — the log's last lines, then stop
  grep -vE '^\s*$' "$1" | tail -n 15 | cut -c1-200 | sed 's/^/     /'
  KEEP_WORK=1; die "$2 (log: $1)"
}

# tools_image — stage3 plus pkgcheck, pkgdev, pycargoebuild and git, made
# once per stage3 image (and kept by podman/docker as a local image)
TOOLS_IMG=""
tools_image() {
  [ "$GX_HOST" = 1 ] && return 0
  [ -n "$TOOLS_IMG" ] && return 0
  local id created
  # the stage3 image: fetched once, and again when it's a month old (Gentoo
  # publishes a new one every week)
  created="$("$RUNTIME" image inspect --format '{{.Created}}' "$STAGE3_IMAGE" 2>/dev/null | cut -c1-10 || true)"
  if [ -z "$created" ] || [ "$(( ($(date +%s) - $(date -d "$created" +%s 2>/dev/null || date +%s)) / 86400 ))" -gt 30 ]; then
    run_logged "$WORK/pull.log" "fetching Gentoo's stage3 image ($STAGE3_IMAGE, ~450 MB)" "$RUNTIME" pull "$STAGE3_IMAGE" \
      || { tail -n 4 "$WORK/pull.log" | sed 's/^/     /'; [ -n "$created" ] || die "couldn't fetch $STAGE3_IMAGE"; warn "couldn't refresh $STAGE3_IMAGE — using the one from $created"; }
  fi
  id="$("$RUNTIME" image inspect --format '{{.Id}}' "$STAGE3_IMAGE" | sed 's/^sha256://' | cut -c1-12)"
  TOOLS_IMG="localhost/store-submit-gentoo-tools:$id"
  if "$RUNTIME" image inspect "$TOOLS_IMG" >/dev/null 2>&1; then ok "Gentoo tools image: $TOOLS_IMG"; return 0; fi
  cat > "$GX/tools.sh" <<'SH'
set -e
. "$GX/common.sh"
. "$GX/portage-setup.sh"
echo "==> emerge pkgcheck pkgdev pycargoebuild git requests"
emerge --oneshot --noreplace dev-util/pkgcheck dev-util/pkgdev app-portage/pycargoebuild dev-vcs/git dev-python/requests \
  || { echo "STORE-SUBMIT: the tools didn't install"; exit 4; }
git config --system --add safe.directory '*'
echo "STORE-SUBMIT: OK"
SH
  "$RUNTIME" rm -f store-submit-gentoo-tools >/dev/null 2>&1 || true
  run_logged "$WORK/tools.log" "making the Gentoo tools image (pkgcheck, pkgdev, pycargoebuild; first time only)" \
    "$RUNTIME" run --name store-submit-gentoo-tools \
      -v "$GURU_SNAP:/var/db/repos/gentoo:ro" -v "$BINPKGS:/var/cache/binpkgs" -v "$DIST:/var/cache/distfiles" -v "$GX:/gx" \
      -e GX=/gx -e DIST=/var/cache/distfiles -e OWNER="$GX_OWNER" -e NPROC="$(nproc 2>/dev/null || echo 2)" \
      "$STAGE3_IMAGE" bash /gx/tools.sh \
    && gx_ok "$WORK/tools.log" || { "$RUNTIME" rm -f store-submit-gentoo-tools >/dev/null 2>&1 || true; gx_fail "$WORK/tools.log" "couldn't install Gentoo's tools in the container"; }
  "$RUNTIME" commit store-submit-gentoo-tools "$TOOLS_IMG" >/dev/null || die "couldn't save the tools image"
  "$RUNTIME" rm -f store-submit-gentoo-tools >/dev/null 2>&1 || true
  # tools images made for older stage3s go
  "$RUNTIME" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '(^|/)store-submit-gentoo-tools:' \
    | grep -vF ":$id" | while read -r old; do "$RUNTIME" rmi "$old" >/dev/null 2>&1 || true; done
  ok "Gentoo tools image: $TOOLS_IMG"
}

# every script starts with this: what a rootful docker wrote as root goes back
# to you when it ends (only the wizard's own directories)
cat > "$GX/common.sh" <<'SH'
give_back() {
  [ -n "${OWNER:-}" ] || return 0
  for p in "${DIST:-}" "${GX:-}" /var/cache/binpkgs; do
    if [ -n "$p" ] && [ -d "$p" ]; then chown -R "$OWNER" "$p"; fi
  done
  [ -n "${GURU:-}" ] && [ -n "${CAT:-}" ] && [ -n "${PN:-}" ] && [ -d "$GURU/$CAT/$PN" ] && chown -R "$OWNER" "$GURU/$CAT/$PN"
  return 0
}
trap give_back EXIT
SH

# Portage set up for a container: GURU as a repository, Gentoo's prebuilt
# packages, no namespaces of its own (the container is one), fetch as root
cat > "$GX/portage-setup.sh" <<'SH'
mkdir -p /etc/portage/repos.conf /etc/portage/env /etc/portage/package.env /etc/portage/package.use /etc/portage/package.accept_keywords
printf '[guru]\nlocation = /var/db/repos/guru\n' > /etc/portage/repos.conf/guru.conf
{
  printf 'FEATURES="${FEATURES} getbinpkg -ipc-sandbox -network-sandbox -pid-sandbox -userfetch -news"\n'
  printf 'MAKEOPTS="-j%s"\n' "${NPROC:-2}"
  printf 'EMERGE_DEFAULT_OPTS="--quiet-build=y --jobs=%s --load-average=%s"\n' "${NPROC:-2}" "${NPROC:-2}"
} >> /etc/portage/make.conf
getuto >/dev/null 2>&1 || true
SH

# the dependency licenses of a Go program: what its modules' LICENSE files say
cat > "$GX/golicenses.py" <<'PY'
import os, re, sys
root = sys.argv[1]
pats = [
    ("AGPL-3", r"GNU AFFERO GENERAL PUBLIC LICENSE Version 3"),
    ("LGPL-3", r"GNU LESSER GENERAL PUBLIC LICENSE Version 3"),
    ("LGPL-2.1", r"GNU LESSER GENERAL PUBLIC LICENSE Version 2\.1"),
    ("GPL-3", r"GNU GENERAL PUBLIC LICENSE Version 3"),
    ("GPL-2", r"GNU GENERAL PUBLIC LICENSE Version 2"),
    ("Apache-2.0", r"Apache License,? Version 2\.0"),
    ("MPL-2.0", r"Mozilla Public License,? (?:Version|v\.?) ?2\.0"),
    ("Boost-1.0", r"Boost Software License"),
    ("CC0-1.0", r"CC0 1\.0 Universal"),
    ("Unlicense", r"This is free and unencumbered software released into the public domain"),
    ("ZLIB", r"This software is provided 'as-is', without any express or implied warranty"),
    ("MIT", r"Permission is hereby granted, free of charge, to any person"),
    ("BSD", r"Redistribution and use in source and binary forms.*(?:Neither the name|names of its contributors)"),
    ("BSD-2", r"Redistribution and use in source and binary forms"),
    ("ISC", r"Permission to use, copy, modify, and(?:/or)? distribute this software for any purpose with or without fee is hereby granted, provided that"),
    ("0BSD", r"Permission to use, copy, modify, and(?:/or)? distribute this software for any purpose with or without fee is hereby granted"),
]
found = set()
for dirpath, dirnames, filenames in os.walk(root):
    if os.path.relpath(dirpath, root).split(os.sep)[0] == "cache":
        dirnames[:] = []
        continue
    if "@" not in os.path.basename(dirpath):
        continue
    dirnames[:] = []  # a module's own directory: its LICENSE is at the top
    lic = set()
    for f in filenames:
        if re.match(r"(?i)^(licen[cs]e|copying|unlicense)", f):
            t = " ".join(open(os.path.join(dirpath, f), errors="replace").read(100000).split())
            for name, pat in pats:
                if re.search(pat, t):
                    lic.add(name)
                    break
    if lic:
        found |= lic
    else:
        print("UNKNOWN " + os.path.relpath(dirpath, root))
for name in sorted(found):
    print("LIC " + name)
PY

# =============================================================== 0. orientation
cat <<BANNER

  ${B}GURU wizard${R}  (Gentoo's user repository)

  Seven stages:
    1. your app        — shared with the other distros, plus GURU's own questions
    2. GURU            — Gentoo's tree and GURU's dev branch; new or update;
                         your way in (push access, or a pull request); your key
    3. ebuild          — for your build system (or yours, or the last one bumped)
    4. Manifest + QA   — pkgdev manifest and pkgcheck scan, in a Gentoo container
    5. test build      — ebuild … merge, offline, in a clean Gentoo container
    6. review + commit — you read it; a signed, signed-off commit in GURU's style
    7. publish         — pushed to dev, or a pull request on Codeberg

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: everything up to the commit; nothing is pushed or uploaded"
[ "$ASSUME_YES" = 1 ] && note "--yes: using everything detected; stopping only on problems"
for t in git curl tar xz python3 ssh; do have "$t" || die "$t is missing — install it and re-run"; done
if [ -z "$RUNTIME" ] && [ "$GX_HOST" = 0 ]; then
  die "Gentoo's tools run in a Gentoo container: install podman or docker (NixOS: virtualisation.podman.enable = true; Gentoo: emerge app-containers/podman — or emerge dev-util/pkgdev dev-util/pkgcheck to use your own)"
fi
[ "$GX_HOST" = 1 ] && note "no podman or docker: using your own pkgdev and pkgcheck; the test build needs a container and is skipped"
GPGPROG="$(gpg_program || true)"
[ -n "$GPGPROG" ] || die "gpg is missing — GURU's commits are signed: install GnuPG (or Nix, for the wizard to fetch it)"

# ============================================================== 1. the app
linux_app "1/7  Your app"
# Gentoo's version and name rules (PMS): the release has to fit them
PV="$VERSION"
printf '%s' "$PV" | grep -qE '^[0-9]+(\.[0-9]+)*[a-z]?(_(alpha|beta|pre|rc|p)[0-9]*)*$' \
  || die "version '$VERSION' isn't one Gentoo can name (like 1.2.3, 1.2.3_rc1 or 1.2.3_p2) — release a plain version number"
PN="$(cfg_get guru-name)"; PN="${PN:-$PNAME}"
guru_questions
[ -n "$SPDX" ] || die "the app has no license — Gentoo needs one (LICENSE): add a LICENSE file and release again"

# ================================================================= 2. GURU
step "2/7  GURU"

# --- Gentoo's own tree: a signed daily snapshot, refreshed once a day. It's
# what the containers build against, and where packages are looked up.
gentoo_snapshot() {
  local ts="$GURU_SNAP/metadata/timestamp.chk" gh="$CACHE/gentoo/gnupg" st
  if [ -f "$ts" ] && [ -z "$(find "$ts" -mmin +1440 2>/dev/null)" ]; then
    ok "Gentoo's tree: snapshot of $(head -1 "$ts")"; return 0
  fi
  snap_fetch() {
    curl -fL --retry 3 -o "$CACHE/gentoo/snap.tar.xz" "$GENTOO_SNAPSHOT_URL" \
      && curl -fL --retry 3 -o "$CACHE/gentoo/snap.tar.xz.gpgsig" "$GENTOO_SNAPSHOT_URL.gpgsig"
  }
  run_logged "$WORK/snap.log" "downloading Gentoo's tree (today's snapshot, ~50 MB)" snap_fetch \
    || { tail -n 3 "$WORK/snap.log" | sed 's/^/     /'; die "couldn't download $GENTOO_SNAPSHOT_URL"; }
  # checked against Gentoo's signing key, in a keyring of its own (yours is
  # untouched): from Gentoo's published service keys, else its WKD
  mkdir -p "$gh"; chmod 700 "$gh"
  if ! gpgk --homedir "$gh" --list-keys "$GENTOO_SNAPSHOT_KEY" >/dev/null 2>&1; then
    curl -fsL --retry 3 --max-time 60 -o "$WORK/service-keys.gpg" "https://qa-reports.gentoo.org/output/service-keys.gpg" \
      && gpgk --homedir "$gh" --batch --import "$WORK/service-keys.gpg" >/dev/null 2>&1 || true
    gpgk --homedir "$gh" --list-keys "$GENTOO_SNAPSHOT_KEY" >/dev/null 2>&1 \
      || gpgk --homedir "$gh" --batch --auto-key-locate=clear,nodefault,wkd --locate-keys infrastructure@gentoo.org >/dev/null 2>&1 \
      || die "couldn't fetch Gentoo's snapshot signing key (infrastructure@gentoo.org)"
  fi
  st="$(gpgk --homedir "$gh" --batch --status-fd 1 --verify "$CACHE/gentoo/snap.tar.xz.gpgsig" "$CACHE/gentoo/snap.tar.xz" 2>/dev/null || true)"
  printf '%s\n' "$st" | grep -qE "^\[GNUPG:\] VALIDSIG .* $GENTOO_SNAPSHOT_KEY\$" \
    || die "the snapshot's signature doesn't verify against Gentoo's key — not using it"
  rm -rf "$GURU_SNAP.new"; mkdir -p "$GURU_SNAP.new"
  run_logged "$WORK/untar.log" "unpacking Gentoo's tree" tar xJf "$CACHE/gentoo/snap.tar.xz" -C "$GURU_SNAP.new" --strip-components=1 \
    || die "couldn't unpack the snapshot"
  rm -rf "$GURU_SNAP"; mv "$GURU_SNAP.new" "$GURU_SNAP"
  rm -f "$CACHE/gentoo/snap.tar.xz" "$CACHE/gentoo/snap.tar.xz.gpgsig"
  ok "Gentoo's tree: snapshot of $(head -1 "$ts"), signature verified"
}
gentoo_snapshot

# --- GURU itself: the dev branch (where all new commits land), latest only
tries=0
if [ -d "$GURU_DIR/.git" ]; then
  git -C "$GURU_DIR" remote set-url upstream "$GURU_GIT_READ" 2>/dev/null || git -C "$GURU_DIR" remote add upstream "$GURU_GIT_READ"
  while ! run_logged "$WORK/fetch.log" "fetching GURU's dev branch" \
      git -C "$GURU_DIR" fetch -q --depth 1 upstream "+refs/heads/dev:refs/remotes/upstream/dev"; do
    tail -n 3 "$WORK/fetch.log" | sed 's/^/     /'
    warn "the fetch failed — usually a network hiccup"
    tries=$((tries + 1)); [ "$ASSUME_YES" = 1 ] && [ "$tries" -ge 3 ] && die "could not fetch GURU"
    [ "$ASSUME_YES" = 1 ] || confirm "Try again?" y || die "could not fetch GURU"
  done
else
  mkdir -p "$(dirname "$GURU_DIR")"
  while ! run_logged "$WORK/clone.log" "cloning GURU (dev branch, latest only — ~90 MB)" \
      git clone -q --depth 1 --single-branch --branch dev -o upstream "$GURU_GIT_READ" "$GURU_DIR"; do
    rm -rf "$GURU_DIR"
    tail -n 3 "$WORK/clone.log" | sed 's/^/     /'
    warn "the clone was cut off — usually a network hiccup"
    tries=$((tries + 1)); [ "$ASSUME_YES" = 1 ] && [ "$tries" -ge 3 ] && die "could not clone GURU"
    [ "$ASSUME_YES" = 1 ] || confirm "Try again?" y || die "could not clone GURU"
  done
fi
git -C "$GURU_DIR" checkout -q -f -B guru-submit upstream/dev && git -C "$GURU_DIR" clean -qfdx \
  || die "could not check out GURU's dev branch in $GURU_DIR"
ok "GURU: $GURU_DIR at $(git -C "$GURU_DIR" rev-parse --short HEAD) ($(git -C "$GURU_DIR" log -1 --format=%cr))"
# (guru_categories reads the local trees from here on)
rm -f "$WORK/guru-categories.txt"
# GURU's pull request form names the day its rules last changed: newer than
# what you agreed to means reading them again
TPL="$(git -C "$GURU_DIR" show upstream/dev:.github/pull_request_template.md 2>/dev/null \
       || git -C "$GURU_DIR" show upstream/dev:.forgejo/pull_request_template.md 2>/dev/null || true)"
RULES_NOW="$(printf '%s' "$TPL" | grep -oE 'last updated [0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 | sed 's/last updated //' || true)"
if [ -n "$RULES_NOW" ] && [[ "$GURU_RULES_AGREED" < "$RULES_NOW" ]]; then
  say "GURU's rules changed on $RULES_NOW — please read them again: https://wiki.gentoo.org/wiki/Project:GURU#Rules"
  [ "$ASSUME_YES" = 1 ] && die "--yes: agree to GURU's new rules once without --yes"
  confirm "Have you read them, and do you agree?" n || die "GURU takes contributions only from people who agree to its rules"
  GURU_RULES_AGREED="$RULES_NOW"; guru_me_set rules "$RULES_NOW"
fi
RULES_OK=0
if [ -n "$RULES_NOW" ] && ! [[ "$GURU_RULES_AGREED" < "$RULES_NOW" ]]; then RULES_OK=1; fi

# --- new, an update, or taken? GURU doesn't duplicate ::gentoo, and a name
# already used by other software needs changing
pkg_dirs() {  # pkg_dirs <repo dir> <name> — the category/name directories holding that package
  local d
  for d in "$1"/*/"$2"; do
    if [ -d "$d" ] && ls "$d"/*.ebuild >/dev/null 2>&1; then printf '%s\n' "${d#"$1"/}"; fi
  done
  return 0
}
same_upstream() {  # same_upstream <package dir> — its ebuilds or metadata.xml point at this app's repository
  grep -qiF -e "$HOST/$SLUG" -e ">$SLUG</remote-id>" "$1"/*.ebuild "$1"/metadata.xml 2>/dev/null
}
MODE=new
while :; do
  printf '%s' "$PN" | grep -qE -- '-[0-9]+(\.[0-9]+)*[a-z]?(_(alpha|beta|pre|rc|p)[0-9]*)*(-r[0-9]+)?$' \
    && die "'$PN' ends like a version number, which Gentoo package names can't (set guru-name in the config)"
  GH="$(pkg_dirs "$GURU_SNAP" "$PN" | head -1)"
  if [ -n "$GH" ] && same_upstream "$GURU_SNAP/$GH"; then
    die "Gentoo itself has your app: $GH (https://packages.gentoo.org/packages/$GH) — GURU doesn't duplicate ::gentoo's packages; for new versions, ask its maintainers (https://bugs.gentoo.org)"
  fi
  UH="$(pkg_dirs "$GURU_DIR" "$PN" | head -1)"
  if [ -n "$UH" ] && same_upstream "$GURU_DIR/$UH"; then
    MODE=update
    [ "${UH%%/*}" != "$CAT" ] && note "GURU has it in ${UH%%/*}, not $CAT — staying there"
    CAT="${UH%%/*}"; break
  fi
  # the same app under another name?
  OTHER="$(grep -liF ">$SLUG</remote-id>" "$GURU_DIR"/*/*/metadata.xml 2>/dev/null | head -1 || true)"
  if [ -n "$OTHER" ] && [ "$FORGE" != git ]; then
    OTHER="${OTHER#"$GURU_DIR"/}"; OTHER="${OTHER%/metadata.xml}"
    ok "GURU has your app as $OTHER — this updates that"
    CAT="${OTHER%%/*}"; PN="${OTHER#*/}"; MODE=update; break
  fi
  [ -z "$GH" ] && [ -z "$UH" ] && break
  if [ -n "$UH" ]; then warn "GURU already has a different package called $PN: $UH"
  else
    if [ "${GH%%/*}" = "$CAT" ]; then warn "::gentoo has a different $GH — the same category and name would override it, which GURU forbids"
    else warn "::gentoo has a different package called $PN ($GH) — 'emerge $PN' would become ambiguous"; fi
  fi
  [ "$ASSUME_YES" = 1 ] && die "pick another package name (guru-name in the config)"
  ask PN "Another package name" "$PN-$(printf '%s' "${OWNER##*/}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-')"
  PN="$(printf '%s' "$PN" | tr 'A-Z' 'a-z')"
done
if [ "$SAVE" = 1 ]; then
  if [ "$PN" != "$PNAME" ]; then cfg_set guru-name "$PN"; fi
  cfg_set guru-category "$CAT"
fi
P="$PN-$PV"; PKGDIR="$CAT/$PN"; EBUILD="$PKGDIR/$P.ebuild"
if [ "$MODE" = update ]; then
  OLD_PVS="$(cd "$GURU_DIR/$PKGDIR" && ls -- *.ebuild 2>/dev/null | sed -n "s/^$PN-\\(.*\\)\\.ebuild\$/\\1/p" | grep -v '^9999$' | sort -V || true)"
  LAST_PV="$(printf '%s\n' "$OLD_PVS" | tail -1)"
  [ -n "$LAST_PV" ] || die "GURU's $PKGDIR has only a live ebuild — bump it by hand"
  [ "${LAST_PV%-r[0-9]*}" = "$PV" ] && die "GURU already has $PKGDIR $PV — nothing to do"
  [ "$(printf '%s\n%s\n' "${LAST_PV%-r[0-9]*}" "$PV" | sort -V | tail -1)" = "$PV" ] || die "$PV is older than GURU's $LAST_PV"
  ok "$PKGDIR is in GURU at $LAST_PV — this is an update"
  MAINTS="$(grep -oE '<email>[^<]+</email>' "$GURU_DIR/$PKGDIR/metadata.xml" 2>/dev/null | sed -E 's#</?email>##g' | tr '\n' ' ' || true)"
  if [ -n "$MAINTS" ] && ! printf ' %s ' "$MAINTS" | grep -qiF " ${MAINT_EMAIL:-@} "; then
    note "it's maintained by $MAINTS — GURU is community-maintained, but tell them as a courtesy"
    handoff_add "Let $PKGDIR's maintainer(s) know about the update ($MAINTS) — GURU's rules ask for that courtesy"
  fi
else
  ok "$PKGDIR is new to GURU (and not in ::gentoo)"
fi
BRANCH="$CAT-$PN-$PV"
git -C "$GURU_DIR" branch -M guru-submit "$BRANCH"

# --- your way in: push access to dev, or a pull request (GURU's way for
# newcomers: after a few are merged you ask for access)
SSHKEY="${SSHKEY_ARG:-${SAVED_SSH_KEY:-}}"; SSHKEY="${SSHKEY/#\~/$HOME}"
SSH_ID=(); [ -n "$SSHKEY" ] && SSH_ID=(-i "$SSHKEY" -o IdentitiesOnly=yes)
export GIT_SSH_COMMAND="ssh${SSHKEY:+ -i $(printf '%q' "$SSHKEY") -o IdentitiesOnly=yes} -o StrictHostKeyChecking=accept-new"
gsh() { ssh "${SSH_ID[@]+"${SSH_ID[@]}"}" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$@"; }
ACCESS="pr"
CB_USER=""
gsh git@git.gentoo.org info > "$WORK/gitolite.txt" 2>&1 || true
if [ "$FORCE_PR" = 0 ] && grep -qE '^[[:space:]]*R[[:space:]]+W[[:space:]]+repo/proj/guru[[:space:]]*$' "$WORK/gitolite.txt"; then
  ACCESS=push; ok "you can push to GURU's dev branch (git.gentoo.org)"
else
  if [ "$FORCE_PR" = 1 ]; then note "--pr: sending a pull request"
  else note "no push access to GURU yet — newcomers send pull requests on Codeberg; after a few are merged you ask for access"; fi
  while :; do
    gsh -T git@codeberg.org > "$WORK/codeberg.txt" 2>&1 || true
    CB_USER="$(sed -nE 's/^Hi there, ([^!]+)!.*/\1/p' "$WORK/codeberg.txt" | head -1)"
    [ -n "$CB_USER" ] && { ok "Codeberg: $CB_USER (your SSH key works there)"; break; }
    if [ "$DRYRUN" = 1 ]; then note "dry run: no Codeberg login yet — it's needed to send the pull request"; break; fi
    warn "Codeberg doesn't accept ${SSHKEY:-your SSH key} — the pull request goes there over SSH"
    note "1. an account: https://codeberg.org/user/sign_up   2. your public key (the .pub file): https://codeberg.org/user/settings/keys"
    [ "$ASSUME_YES" = 1 ] && die "set up Codeberg SSH access once without --yes"
    confirm "Check again?" y || { note "without Codeberg the commit goes to GURU's mailing list as a patch instead"; break; }
  done
fi

# --- you in the commit: Signed-off-by (GLEP 76) needs a name and an e-mail
COMMIT_NAME="$MAINT_NAME"
COMMIT_EMAIL="${MAINT_EMAIL:-$(git -C "$REPO" config user.email 2>/dev/null || true)}"
[ -n "$COMMIT_EMAIL" ] || ask COMMIT_EMAIL "E-mail for your commits (Signed-off-by)" ""
ok "commits as: $COMMIT_NAME <$COMMIT_EMAIL>"

# --- your OpenPGP key: GURU's commits are signed. GLEP 63 (Gentoo's key
# rules) is recommended — deviations are shown, not fatal.
GPGKEY="$(key_fpr "${GPG_ARG:-${SAVED_GPG_KEY:-$COMMIT_EMAIL}}")"
if [ -z "$GPGKEY" ] && [ -n "$GPG_ARG" ]; then
  die "no usable secret key for --gpg-key $GPG_ARG (missing, expired or revoked — renew it: gpg --quick-set-expire <fingerprint> 2y '*')"
fi
[ -n "$GPGKEY" ] || GPGKEY="$(key_fpr "$COMMIT_EMAIL")"
[ -n "$GPGKEY" ] || GPGKEY="$(key_fpr "")"
if [ -z "$GPGKEY" ] && [ "$DRYRUN" = 1 ]; then
  note "dry run: no usable OpenPGP key — the local commit won't be signed"
elif [ -z "$GPGKEY" ]; then
  say "GURU's commits are signed with your OpenPGP key, and you have none yet. The wizard can"
  say "make one the way GLEP 63 (Gentoo's key rules) asks: an Ed25519 key that only certifies,"
  say "with a signing and an encryption subkey, all expiring in 2 years — for"
  say "$COMMIT_NAME <$COMMIT_EMAIL>."
  [ "$ASSUME_YES" = 1 ] && die "make your signing key once without --yes"
  confirm "Create it now? (gpg asks for a passphrase)" y || die "GURU needs signed commits — make a key (GLEP 63) and re-run"
  gpgk --quick-generate-key "$COMMIT_NAME <$COMMIT_EMAIL>" ed25519 cert 2y || die "gpg couldn't create the key"
  GPGKEY="$(gpgk --list-secret-keys --with-colons -- "$COMMIT_EMAIL" 2>/dev/null | awk -F: '$1 == "sec" { s = 1; next } s && $1 == "fpr" { print $10; s = 0 }' | tail -1)"
  [ -n "$GPGKEY" ] || die "can't find the new key"
  gpgk --quick-add-key "$GPGKEY" ed25519 sign 2y && gpgk --quick-add-key "$GPGKEY" cv25519 encr 2y \
    || die "gpg couldn't add the subkeys to $GPGKEY"
  ok "made key $GPGKEY (GLEP 63)"
  handoff_add "Back up your new OpenPGP key and make a revocation certificate: gpg --export-secret-keys --armor $GPGKEY > backup.asc; gpg --gen-revoke $GPGKEY > revoke.asc — keep both somewhere safe"
fi
if [ -n "$GPGKEY" ]; then
  ok "signing key: $GPGKEY"
  glep63 "$GPGKEY" | while IFS= read -r l; do warn "GLEP 63: $l"; done
  gpgk --list-keys --with-colons -- "$GPGKEY" 2>/dev/null | awk -F: '$1 == "uid" { print $10 }' | grep -qiF "<$COMMIT_EMAIL>" \
    || warn "the key has no identity with $COMMIT_EMAIL — add one (gpg --quick-add-uid $GPGKEY \"$COMMIT_NAME <$COMMIT_EMAIL>\") so it matches your commits"
fi

# ================================================================ 3. ebuild
step "3/7  The ebuild"
mkdir -p "$GURU_DIR/$PKGDIR"
rm -rf "$GX/src"; mkdir -p "$GX/src"
git -C "$REPO" archive "$TAG_REF" | tar x -C "$GX/src"

# --- the source: the forge's tarball of the tag, named as Gentoo likes it
case "$TAG" in
  "$VERSION")  TAGX='${PV}' ;;
  *"$VERSION"*) TAGX="${TAG%%"$VERSION"*}\${PV}${TAG#*"$VERSION"}" ;;
  *)           TAGX="$TAG"; warn "tag $TAG doesn't contain the version — the ebuild names it as it is; next release, edit SRC_URI" ;;
esac
SRC_URL_PATTERN="$(cfg_get guru-src-url)"
if [ "$FORGE" = git ] && [ -z "$SRC_URL_PATTERN" ]; then
  note "Gentoo downloads a release tarball; for $HOST the wizard doesn't know its address"
  ask SRC_URL_PATTERN "Tarball URL of tag $TAG (it's checked)" ""
  SRC_URL_PATTERN="${SRC_URL_PATTERN//$TAG/@TAG@}"
  if [ "$SAVE" = 1 ]; then cfg_set guru-src-url "$SRC_URL_PATTERN"; fi
fi
src_url() {  # src_url <tag> — the forge's tarball of that tag
  case "$FORGE" in
    github)   printf 'https://github.com/%s/archive/refs/tags/%s.tar.gz' "$SLUG" "$1" ;;
    gitlab)   printf 'https://gitlab.com/%s/-/archive/%s/%s-%s.tar.gz' "$SLUG" "$1" "$REPONAME" "$1" ;;
    codeberg) printf 'https://codeberg.org/%s/archive/%s.tar.gz' "$SLUG" "$1" ;;
    *)        printf '%s' "${SRC_URL_PATTERN//@TAG@/$1}" ;;
  esac
}
SUFFIX="tar.gz"
case "$(src_url "$TAG")" in *.tar.xz) SUFFIX=tar.xz ;; *.tar.bz2) SUFFIX=tar.bz2 ;; *.tar.zst) SUFFIX=tar.zst ;; *.zip) die "the tarball is a .zip — give a .tar.* URL" ;; esac
# Gentoo's Python guide names GitHub archives .gh.tar.gz (PyPI's sdists are ${P}.tar.gz)
[ "$KIND" = python ] && [ "$FORGE" = github ] && SUFFIX="gh.tar.gz"
DISTNAME="$P.$SUFFIX"
SRC_MAIN="$(src_url "$TAGX") -> \${P}.$SUFFIX"
TOP=""
if [ "${DRY_NO_TAG:-0}" = 1 ]; then
  warn "dry run and tag $TAG isn't online: the ebuild is written, then the wizard stops"
else
  if [ ! -s "$DIST/$DISTNAME" ]; then
    run_logged "$WORK/download.log" "downloading $(src_url "$TAG")" curl -fL --retry 3 -o "$DIST/$DISTNAME.part" "$(src_url "$TAG")" \
      && mv "$DIST/$DISTNAME.part" "$DIST/$DISTNAME" \
      || { tail -n 3 "$WORK/download.log" | sed 's/^/     /'; rm -f "$DIST/$DISTNAME.part"; die "couldn't download the release tarball — is tag $TAG pushed and the repository public?"; }
  fi
  TOP="$(tar tf "$DIST/$DISTNAME" 2>/dev/null | head -1 | cut -d/ -f1 || true)"
  [ -n "$TOP" ] || { rm -f "$DIST/$DISTNAME"; die "$DISTNAME isn't a tarball"; }
  ok "source: $DISTNAME → $TOP/"
fi
# S: where it unpacks, in terms of the version
S_LINE=""
if [ -n "$TOP" ] && [ "$TOP" != "$P" ]; then
  topx="$TOP"
  case "$TOP" in *"$VERSION"*) topx="${TOP%%"$VERSION"*}\${PV}${TOP#*"$VERSION"}" ;; esac
  [ "$topx" = "$PN-\${PV}" ] || S_LINE="S=\"\${WORKDIR}/$topx\""
fi

# --- a dependency tarball (Go's modules, or Rust's crates when there are
# hundreds): Gentoo builds offline and doesn't host it — you do, as an asset
# of the release; the wizard makes it, and uploads it when you say so
asset_url() {  # asset_url <tag> <file> — where the release asset will be
  case "$FORGE" in
    github)   printf 'https://github.com/%s/releases/download/%s/%s' "$SLUG" "$1" "$2" ;;
    codeberg) printf 'https://codeberg.org/%s/releases/download/%s/%s' "$SLUG" "$1" "$2" ;;
    *)        printf '' ;;
  esac
}
ASSET=""; ASSET_URL=""; ASSET_X=""
need_asset() {  # need_asset <file name> — sets ASSET, ASSET_URL (real) and ASSET_X (for the ebuild)
  ASSET="$1"
  ASSET_URL="$(asset_url "$TAG" "$ASSET")"
  ASSET_X="$(asset_url "$TAGX" "$(printf '%s' "$ASSET" | sed "s/^$P-/\${P}-/")")"
  if [ -z "$ASSET_URL" ]; then
    note "$ASSET has to be downloadable somewhere permanent — the ebuild names its address"
    ask ASSET_URL "URL $ASSET will have (e.g. an asset of release $TAG)" "$(cfg_get guru-asset-url | sed "s|@TAG@|$TAG|; s|@FILE@|$ASSET|")"
    if [ "$SAVE" = 1 ]; then cfg_set guru-asset-url "$(printf '%s' "$ASSET_URL" | sed "s|$TAG|@TAG@|; s|$ASSET|@FILE@|")"; fi
    ASSET_X="$(printf '%s' "$ASSET_URL" | sed "s|$TAG|$TAGX|; s|$P-|\${P}-|")"
  fi
  # already online (a re-run): use exactly that file, so the Manifest matches
  if curl -sfIL --max-time 20 -o /dev/null "$ASSET_URL"; then
    run_logged "$WORK/asset.log" "fetching $ASSET (already online)" curl -fL --retry 3 -o "$DIST/$ASSET" "$ASSET_URL" \
      || die "couldn't download $ASSET_URL"
    ASSET_ONLINE=1; ok "$ASSET is online already: $ASSET_URL"
  else
    ASSET_ONLINE=0
    if [ -s "$DIST/$ASSET" ]; then note "using $ASSET from an earlier run (not uploaded yet)"; fi
  fi
  return 0
}
ASSET_ONLINE=0

# --- Go: the module cache as a tarball, and the licenses of what's linked in
go_deps() {  # go_deps — makes $DIST/$P-deps.tar.xz (unless it's there already); sets GO_LICS
  [ "$GX_HOST" = 1 ] && ! have go && die "go is needed to make the dependency tarball"
  cat > "$GX/godeps.sh" <<'SH'
set -e
. "$GX/common.sh"
if [ "${GX_HOST:-0}" = 0 ] && ! command -v go >/dev/null; then
  . "$GX/portage-setup.sh"
  emerge --oneshot dev-lang/go || { echo "STORE-SUBMIT: Go didn't install"; exit 4; }
fi
rm -rf "$GX/go-mod"
if [ -s "$DIST/$P-deps.tar.xz" ]; then
  tar -xf "$DIST/$P-deps.tar.xz" -C "$GX" || { echo "STORE-SUBMIT: the dependency tarball didn't unpack"; exit 3; }
else
  cd "$GX/src"
  echo "==> go mod download"
  GOMODCACHE="$GX/go-mod" GOFLAGS=-modcacherw GOTOOLCHAIN=local go mod download -modcacherw \
    || { echo "STORE-SUBMIT: go mod download failed"; exit 3; }
  cd "$GX"
  echo "==> $P-deps.tar.xz"
  XZ_OPT='-T0 -9' tar -acf "$DIST/$P-deps.tar.xz" go-mod
fi
python3 "$GX/golicenses.py" "$GX/go-mod" > "$GX/go-licenses.txt"
echo "STORE-SUBMIT: OK"
SH
  gx "$WORK/godeps.log" "Go modules: $P-deps.tar.xz (as go-module.eclass describes)" godeps.sh && gx_ok "$WORK/godeps.log" \
    || gx_fail "$WORK/godeps.log" "couldn't make the Go dependency tarball"
  GO_LICS="$(sed -n 's/^LIC //p' "$GX/go-licenses.txt" | tr '\n' ' ' | sed 's/ $//')"
  if grep -q '^UNKNOWN ' "$GX/go-licenses.txt"; then
    warn "modules whose license the wizard couldn't tell — check them and add theirs to LICENSE:"
    sed -n 's/^UNKNOWN /       /p' "$GX/go-licenses.txt" | head -10
  fi
  ok "$P-deps.tar.xz ($(du -h "$DIST/$P-deps.tar.xz" | cut -f1)); module licenses: ${GO_LICS:-none found}"
}

# --- Rust: pycargoebuild (Gentoo's own tool) fills CRATES and the crates'
# licenses in; past 300 crates cargo.eclass wants a crate tarball instead
rust_crates() {  # rust_crates <crate dir> — fills the ebuild in $GURU_DIR/$EBUILD
  local mode=-C
  if [ -n "$ASSET" ]; then mode=-w; [ -s "$DIST/$ASSET" ] && mode=-u; fi
  cat > "$GX/crates.sh" <<'SH'
set -e
. "$GX/common.sh"
set -- $GXENV
mode="$1"; dir="$2"
args=("$mode" -i "$GURU/$CAT/$PN/$P.ebuild" -d "$DIST" -M -l "$GENTOO/metadata/license-mapping.conf")
[ "$mode" = -w ] && args+=(-f --crate-tarball-path "$DIST/$P-crates.tar.xz")
# wget is in every stage3 (aria2 isn't, and is fussier about proxies)
command -v wget >/dev/null && args+=(-F wget)
pycargoebuild "${args[@]}" "$GX/src/$dir" || { echo "STORE-SUBMIT: pycargoebuild failed"; exit 3; }
echo "STORE-SUBMIT: OK"
SH
  GXENV="$mode ${1:-.}" gx "$WORK/crates.log" "pycargoebuild: the crates and their licenses" crates.sh && gx_ok "$WORK/crates.log" \
    || gx_fail "$WORK/crates.log" "pycargoebuild couldn't fill in the crates"
  if [ "$mode" = -w ] && [ "$ASSET" != "$P-crates.tar.xz" ]; then mv "$DIST/$P-crates.tar.xz" "$DIST/$ASSET"; fi
  ok "CRATES and the crates' licenses filled in by pycargoebuild$([ "$mode" = -C ] || printf ' (crate tarball %s)' "$ASSET")"
}

OWN_EB=""; GENERATED=0; DROPPED=()
if [ "$MODE" = update ]; then
  # ------------------------------------------------------------- update
  # the release in GURU, copied to the new version — as GURU's contributors do
  cp "$GURU_DIR/$PKGDIR/$PN-$LAST_PV.ebuild" "$GURU_DIR/$EBUILD"
  first="$(sed -n 1p "$GURU_DIR/$EBUILD")"
  if [[ "$first" =~ ^\#\ Copyright\ ([0-9]{4})(-[0-9]{4})?\ Gentoo\ Authors$ ]]; then
    y0="${BASH_REMATCH[1]}"
    if [ "$y0" = "$YEAR" ]; then hdr="# Copyright $YEAR Gentoo Authors"; else hdr="# Copyright $y0-$YEAR Gentoo Authors"; fi
    sed -i "1s/.*/$hdr/" "$GURU_DIR/$EBUILD"
  fi
  ok "copied $PN-$LAST_PV.ebuild to $P.ebuild"
  EB_TEXT="$(cat "$GURU_DIR/$EBUILD")"
  # its dependency tarball, if it has one, follows the version
  for kindtar in deps crates; do
    case "$EB_TEXT" in *"-$kindtar.tar.xz"*) ;; *) continue ;; esac
    u="$(grep -oE "https://[^ \"]*-$kindtar\\.tar\\.xz( -> [^ \"]+)?" "$GURU_DIR/$EBUILD" | head -1 || true)"
    [ -n "$u" ] || die "the ebuild has a $kindtar tarball, but the wizard can't find its URL in SRC_URI — bump it by hand"
    real="$(printf '%s' "${u%% -> *}" | sed -e "s/\${PV}/$PV/g; s/\${P}/$P/g; s/\${PN}/$PN/g")"
    name="$(printf '%s' "$u" | sed -n 's/.* -> //p' | sed -e "s/\${PV}/$PV/g; s/\${P}/$P/g; s/\${PN}/$PN/g")"
    name="${name:-${real##*/}}"
    case "$real$name" in *'$'*) die "the ebuild's $kindtar tarball URL uses variables the wizard can't fill in — bump it by hand" ;; esac
    ASSET="$name"; ASSET_URL="$real"
    if curl -sfIL --max-time 20 -o /dev/null "$ASSET_URL"; then
      curl -fsL --retry 3 -o "$DIST/$ASSET" "$ASSET_URL" || die "couldn't download $ASSET_URL"; ASSET_ONLINE=1
      ok "$ASSET is online already"
    fi
  done
  case "$KIND" in
    rust)
      if grep -q '^CRATES=' "$GURU_DIR/$EBUILD"; then
        cdir=.; at "$TAG_REF" Cargo.toml | grep -q '^\[package\]' || cdir="$(dirname "$(grep -E '(^|/)Cargo\.toml$' "$WORK/tree.txt" | grep -v '^Cargo.toml$' | head -1)")"
        if [ -n "$ASSET" ] && [ "$ASSET_ONLINE" = 0 ]; then rm -f "$DIST/$ASSET"; fi
        rust_crates "$cdir"
      fi ;;
    go)
      if [ -n "$ASSET" ] && [ "$ASSET_ONLINE" = 0 ]; then
        rm -f "$DIST/$ASSET"; go_deps
        [ "$ASSET" = "$P-deps.tar.xz" ] || mv "$DIST/$P-deps.tar.xz" "$DIST/$ASSET"
      fi ;;
    python)
      # new dependencies since the last release: said, not guessed
      at "$TAG_REF" pyproject.toml > "$WORK/pyproject.toml" 2>/dev/null || true
      for d in $(python3 -c 'import re,sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); [print(re.match(r"[A-Za-z0-9._-]+",r.strip()).group(0)) for r in d.get("project",{}).get("dependencies",[]) if not ("extra ==" in r)]' "$WORK/pyproject.toml" 2>/dev/null || true); do
        n="$(printf '%s' "$d" | tr 'A-Z' 'a-z' | tr '_.' '--')"
        grep -q "dev-python/$n\\b" "$GURU_DIR/$EBUILD" || warn "pyproject.toml needs '$d' — the ebuild doesn't list dev-python/$n yet"
      done ;;
  esac
  # older releases go: GURU keeps the latest (live ebuilds stay)
  for v in $OLD_PVS; do
    [ "$v" = "$PV" ] && continue
    DROPPED+=("$v")
  done
  if [ "${#DROPPED[@]}" -gt 0 ]; then
    if [ "$ASSUME_YES" = 1 ] || confirm "Drop the older version(s) ${DROPPED[*]}? (GURU usually keeps only the newest)" y; then
      for v in "${DROPPED[@]}"; do git -C "$GURU_DIR" rm -q -- "$PKGDIR/$PN-$v.ebuild"; done
      ok "dropped: ${DROPPED[*]}"
    else
      DROPPED=()
    fi
  fi
else
  # ------------------------------------------------------------- new
  OWN_EB="$(grep -E "(^|/)$PN-[0-9][^/]*\\.ebuild\$" "$WORK/tree.txt" | grep -v -- '-9999\.ebuild$' | head -1 || true)"
  if [ -n "$OWN_EB" ]; then
    # yours: used as it is (renamed to this version)
    at "$TAG_REF" "$OWN_EB" > "$GURU_DIR/$EBUILD"
    if in_tree "$(dirname "$OWN_EB")/metadata.xml"; then at "$TAG_REF" "$(dirname "$OWN_EB")/metadata.xml" > "$GURU_DIR/$PKGDIR/metadata.xml"; fi
    ok "your ebuild: $OWN_EB (from $TAG)"
    if [ "$KIND" = rust ] && grep -q '^CRATES=' "$GURU_DIR/$EBUILD" && grep -q '^# Dependent crate licenses' "$GURU_DIR/$EBUILD"; then
      cdir=.; at "$TAG_REF" Cargo.toml | grep -q '^\[package\]' || cdir="$(dirname "$(grep -E '(^|/)Cargo\.toml$' "$WORK/tree.txt" | grep -v '^Cargo.toml$' | head -1)")"
      rust_crates "$cdir"
    fi
  else
    GENERATED=1
    LIC="$(gentoo_license "$SPDX")"
    case "$LIC" in UNKNOWN:*) die "Gentoo has no license matching SPDX '${LIC#UNKNOWN:}' (metadata/license-mapping.conf) — check license in the config" ;; esac
    ok "LICENSE=\"$LIC\" (from $SPDX)"
    PRE=""; INHERIT=""; SRCS=("$SRC_MAIN"); RDEP=(); DEP_SAME=0; BDEP=(); BODY=""; LIC_EXTRA=""; VCHECK=1; GUI=0
    UNMAPPED=()
    add_lib() {  # add_lib <atom> — a library it links against (DEPEND and RDEPEND)
      if exists "$1"; then RDEP+=("$1"); DEP_SAME=1; else UNMAPPED+=("$1"); fi
    }
    add_tool() { if exists "$1"; then BDEP+=("$1"); else UNMAPPED+=("$1"); fi; }
    case "$KIND" in
      rust)
        INHERIT="cargo"
        n_crates="$(at "$TAG_REF" Cargo.lock | grep -c '^source = "registry+' || true)"
        RMIN="$(at "$TAG_REF" Cargo.toml | toml_get package rust-version)"
        [ -n "$RMIN" ] || RMIN="$(at "$TAG_REF" Cargo.toml | toml_get workspace.package rust-version)"
        case "$RMIN" in *.*.*) ;; [0-9]*.[0-9]*) RMIN="$RMIN.0" ;; *) RMIN="" ;; esac
        if [ -n "$RMIN" ] && [ "$(printf '%s\n1.71.1\n' "$RMIN" | sort -V | tail -1)" = "$RMIN" ] && [ "$RMIN" != 1.71.1 ]; then
          PRE="CRATES=\"
\"

RUST_MIN_VER=\"$RMIN\""
        else
          PRE="CRATES=\"
\""
        fi
        if [ "${n_crates:-0}" -ge 300 ]; then
          note "$n_crates crates: cargo.eclass asks for a crate tarball above 300 (the CRATES list would be huge)"
          need_asset "$P-crates.tar.xz"
          SRCS+=("$ASSET_X")
        fi
        SRCS+=('${CARGO_CRATE_URIS}')
        for crate in $(at "$TAG_REF" Cargo.lock | sed -nE 's/^name = "([a-z0-9_-]+-sys)"$/\1/p' | sort -u); do
          case "$crate" in
            openssl-sys)    add_lib dev-libs/openssl:= ;; alsa-sys) add_lib media-libs/alsa-lib ;;
            libdbus-sys)    add_lib sys-apps/dbus ;; libudev-sys) add_lib virtual/libudev:= ;;
            gtk4-sys)       add_lib gui-libs/gtk:4; GUI=1 ;; gtk-sys) add_lib x11-libs/gtk+:3; GUI=1 ;;
            libadwaita-sys) add_lib gui-libs/libadwaita:1; GUI=1 ;; webkit2gtk-sys) add_lib net-libs/webkit-gtk:4.1; GUI=1 ;;
            *) continue ;;
          esac
          add_tool virtual/pkgconfig
        done
        at "$TAG_REF" Cargo.lock | grep -qE '^name = "(iced|egui|eframe|slint|winit|tauri|relm4|fltk|dioxus)"$' && GUI=1
        # a workspace without a package of its own: install the binary's member
        CRATE_DIR=.
        if ! at "$TAG_REF" Cargo.toml | grep -q '^\[package\]'; then
          for f in $(grep -E '(^|/)Cargo\.toml$' "$WORK/tree.txt" | grep -v '^Cargo.toml$'); do
            at "$TAG_REF" "$f" | grep -qE "^name = \"$MAIN_GUESS\"" && { CRATE_DIR="$(dirname "$f")"; break; }
          done
          [ "$CRATE_DIR" = . ] && CRATE_DIR="$(dirname "$(grep -E '(^|/)Cargo\.toml$' "$WORK/tree.txt" | grep -v '^Cargo.toml$' | head -1)")"
          BODY="src_install() {
	cargo_src_install --path $CRATE_DIR
}"
        fi
        LIC_EXTRA='# Dependent crate licenses
LICENSE+=""' ;;
      go)
        INHERIT="go-module"
        GOTARGET=.; grep -qE '^cmd/[^/]+/main\.go$' "$WORK/tree.txt" && GOTARGET='./cmd/...'
        if ! in_tree_re '^vendor/modules\.txt$'; then
          need_asset "$P-deps.tar.xz"
          SRCS+=("$ASSET_X")
          if [ "${DRY_NO_TAG:-0}" = 0 ]; then go_deps; fi
          if [ -n "${GO_LICS:-}" ]; then LIC_EXTRA="# Dependent licenses (the Go modules it links in)
LICENSE+=\" $GO_LICS\""; fi
        fi
        GOV="$(at "$TAG_REF" go.mod | sed -nE 's/^go[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1)"
        if [ -n "$GOV" ] && [ "$(printf '%s\n1.24.11\n' "$GOV" | sort -V | tail -1)" = "$GOV" ] && [ "$GOV" != 1.24.11 ]; then
          case "$GOV" in *.*.*) ;; *) GOV="$GOV.0" ;; esac
          BDEP+=(">=dev-lang/go-$GOV")
        fi
        LDF=""
        if git -C "$REPO" grep -qE '^[[:space:]]*(var[[:space:]]+)?version[[:space:]]+(=|string)' "$TAG_REF" -- main.go 'cmd/*/main.go' 2>/dev/null; then
          LDF=' -ldflags "-X main.version=${PV}"'
        fi
        BODY="src_compile() {
	mkdir -p bin || die
	ego build$LDF -o bin/ $GOTARGET
}

src_test() {
	ego test ./...
}

src_install() {
	dobin bin/*
	einstalldocs
}" ;;
      python)
        INHERIT="distutils-r1"
        at "$TAG_REF" pyproject.toml > "$WORK/pyproject.toml"
        python3 - "$WORK/pyproject.toml" > "$WORK/pyinfo" <<'PY' || die "could not read pyproject.toml"
import re, sys
try:
    import tomllib
except ImportError:
    sys.exit("python 3.11 or newer is needed to read pyproject.toml")
d = tomllib.load(open(sys.argv[1], "rb"))
bs = d.get("build-system", {})
print("backend", bs.get("build-backend", "setuptools.build_meta:__legacy__"))
name = lambda s: re.match(r"[A-Za-z0-9._-]+", s.strip()).group(0)
for r in bs.get("requires", []):
    print("build", name(r))
for r in d.get("project", {}).get("dependencies", []):
    m = r.split(";", 1)[1] if ";" in r else ""
    if re.search(r"extra\s*==|win32|darwin|python_version\s*<", m):
        continue
    print("dep", name(r))
PY
        BACKEND="$(sed -n 's/^backend //p' "$WORK/pyinfo")"
        case "$BACKEND" in
          setuptools.build_meta*) PEP517=setuptools ;; hatchling.build) PEP517=hatchling ;; flit_core.buildapi) PEP517=flit-core ;;
          flit_scm:buildapi) PEP517=flit-scm ;; poetry.core.masonry.api) PEP517=poetry-core ;; pdm.backend) PEP517=pdm-backend ;;
          mesonpy) PEP517=meson-python ;; scikit_build_core.build) PEP517=scikit-build-core ;; pbr.build) PEP517=pbr ;;
          uv_build) PEP517=uv-build ;; sipbuild.api) PEP517=sip ;; jupyter_packaging.build_api) PEP517=jupyter-packaging ;;
          maturin) die "a Python app with a Rust extension (maturin) needs cargo.eclass and distutils-r1 together — that ebuild is yours to write; put it in your repository and the wizard uses it" ;;
          *) die "unknown build backend '$BACKEND' — write the ebuild yourself and put it in your repository; the wizard uses it" ;;
        esac
        PRE="DISTUTILS_USE_PEP517=$PEP517
PYTHON_COMPAT=( $(python_compat) )"
        MISSING=(); SCM=0
        while read -r k dn; do
          n="$(printf '%s' "$dn" | tr 'A-Z' 'a-z' | tr '_.' '--')"
          case "$k:$n" in
            build:setuptools|build:wheel|build:pip|build:hatchling|build:flit-core|build:poetry-core|build:pdm-backend|build:meson-python|build:scikit-build-core|build:uv-build) continue ;;
            build:setuptools-scm|build:hatch-vcs|build:flit-scm) SCM=1 ;;
          esac
          if exists "dev-python/$n"; then
            if [ "$k" = build ]; then BDEP+=("dev-python/${n}[\${PYTHON_USEDEP}]"); else RDEP+=("dev-python/${n}[\${PYTHON_USEDEP}]"); fi
          else
            MISSING+=("$dn")
          fi
        done < <(grep -E '^(build|dep) ' "$WORK/pyinfo")
        if [ "${#MISSING[@]}" -gt 0 ]; then
          bad "not in ::gentoo or GURU yet: ${MISSING[*]}"
          die "those Python packages have to be in Gentoo first — each is an ebuild of its own (GURU takes them too)"
        fi
        BODY=""
        [ "$SCM" = 1 ] && BODY='export SETUPTOOLS_SCM_PRETEND_VERSION=${PV}'
        if in_tree_re '^(tests?/)?test_[^/]*\.py$|^tests?/.*test[^/]*\.py$'; then
          BODY="${BODY:+$BODY

}EPYTEST_PLUGINS=()
distutils_enable_tests pytest"
        fi ;;
      meson|cmake|make)
        PCS=""; PROGS=""; PKGS=""
        if [ "$KIND" = meson ]; then
          INHERIT="meson"
          MB="$(for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done)"
          PCS="$(printf '%s' "$MB" | grep -oE "dependency\\([[:space:]]*'[^']+'" | sed -E "s/.*'([^']+)'/\\1/" | sort -u)"
          PROGS="$(printf '%s' "$MB" | grep -oE "find_program\\([[:space:]]*'[^']+'" | sed -E "s/.*'([^']+)'/\\1/" | sort -u)"
          printf '%s' "$MB" | grep -q "import('i18n')" && PROGS="$PROGS msgfmt"
          printf '%s' "$MB" | grep -q "compile_resources" && PROGS="$PROGS glib-compile-resources"
          [ -n "$PCS" ] && add_tool virtual/pkgconfig
        elif [ "$KIND" = cmake ]; then
          INHERIT="cmake"
          CM="$(for f in $(grep -E '(^|/)CMakeLists\.txt$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done)"
          PCS="$(printf '%s' "$CM" | tr '\n' ' ' | grep -oE 'pkg_check_modules\([^)]*\)' | sed -E 's/^pkg_check_modules\(//; s/\)$//' \
                 | awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^(REQUIRED|QUIET|IMPORTED_TARGET|GLOBAL)$/) { m = $i; sub(/[<>=].*/, "", m); if (m != "") print m } }' | sort -u)"
          PKGS="$(printf '%s' "$CM" | grep -oE 'find_package\([[:space:]]*[A-Za-z0-9_]+' | sed -E 's/.*\([[:space:]]*//' | sort -u)"
          [ -n "$PCS" ] && add_tool virtual/pkgconfig
        else
          INHERIT="toolchain-funcs"
          if at "$TAG_REF" Makefile | grep -qE '^install:'; then
            BODY='src_compile() {
	emake CC="$(tc-getCC)" CXX="$(tc-getCXX)" PREFIX="${EPREFIX}/usr"
}

src_install() {
	emake DESTDIR="${D}" PREFIX="${EPREFIX}/usr" install
	einstalldocs
}'
          else
            BODY="src_compile() {
	emake CC=\"\$(tc-getCC)\" CXX=\"\$(tc-getCXX)\"
}

src_install() {
	dobin $MAIN_GUESS
	einstalldocs
}"
          fi
        fi
        for pc in $PCS; do
          case "$pc" in threads|m|dl|rt|dependency) continue ;; esac
          a="$(pc_dep "$pc")"
          if [ -n "$a" ]; then add_lib "$a"; else UNMAPPED+=("pkg-config:$pc"); fi
          case "$pc" in gtk4|gtk+-3.0|libadwaita-1|webkit*|sdl2|sdl3|x11|wayland-client) GUI=1 ;; esac
        done
        for pg in $PROGS; do a="$(prog_dep "$pg")"; [ -n "$a" ] && add_tool "$a"; done
        for pk in $PKGS; do
          case "$pk" in Threads|PkgConfig|GTest|Catch2|Qt5) continue ;; esac
          a="$(cmake_dep "$pk")"
          if [ -n "$a" ]; then add_lib "$a"; else UNMAPPED+=("find_package:$pk"); fi
          case "$pk" in Qt6|SDL2|SDL3|X11|OpenGL) GUI=1 ;; esac
        done
        # desktop files and icons: the menus and icon caches are updated (xdg); GSettings schemas compiled
        if in_tree_re '\.desktop(\.in)?$|(^|/)icons/|\.metainfo\.xml|\.appdata\.xml'; then INHERIT="$INHERIT xdg"; GUI=1; fi
        if in_tree_re '\.gschema\.xml$'; then
          INHERIT="$INHERIT gnome2-utils"
          case " $INHERIT " in
            *" xdg "*) BODY="${BODY:+$BODY

}pkg_postinst() {
	xdg_pkg_postinst
	gnome2_schemas_update
}

pkg_postrm() {
	xdg_pkg_postrm
	gnome2_schemas_update
}" ;;
            *) BODY="${BODY:+$BODY

}pkg_postinst() {
	gnome2_schemas_update
}

pkg_postrm() {
	gnome2_schemas_update
}" ;;
          esac
        fi ;;
    esac
    if [ "$GUI" = 1 ]; then VCHECK=0; fi
    if [ "${#UNMAPPED[@]}" -gt 0 ]; then
      warn "dependencies the wizard couldn't name in Gentoo: ${UNMAPPED[*]} — the test build shows if they're needed; add them to the ebuild"
    fi
    # shellcheck disable=SC2086
    EAPI_N="$(eapi_for $INHERIT)"
    mapfile -t RDEP < <(sorted "${RDEP[@]+"${RDEP[@]}"}")
    mapfile -t BDEP < <(sorted "${BDEP[@]+"${BDEP[@]}"}")
    {
      printf '# Copyright %s Gentoo Authors\n# Distributed under the terms of the GNU General Public License v2\n\n' "$YEAR"
      printf 'EAPI=%s\n\n' "$EAPI_N"
      if [ -n "$PRE" ]; then printf '%s\n\n' "$PRE"; fi
      printf 'inherit %s\n\n' "$INHERIT"
      printf 'DESCRIPTION="%s"\n' "$(eb_q "$DESC")"
      printf 'HOMEPAGE="%s"\n' "$(eb_q "$HOMEPAGE")"
      block SRC_URI "${SRCS[@]}"
      if [ -n "$S_LINE" ]; then printf '%s\n' "$S_LINE"; fi
      printf '\nLICENSE="%s"\n' "$LIC"
      if [ -n "$LIC_EXTRA" ]; then printf '%s\n' "$LIC_EXTRA"; fi
      printf 'SLOT="0"\nKEYWORDS="~%s"\n' "$GARCH"
      if [ "${#RDEP[@]}" -gt 0 ] || [ "${#BDEP[@]}" -gt 0 ]; then printf '\n'; fi
      block RDEPEND "${RDEP[@]+"${RDEP[@]}"}"
      # shellcheck disable=SC2016
      if [ "$DEP_SAME" = 1 ]; then printf 'DEPEND="${RDEPEND}"\n'; fi
      block BDEPEND "${BDEP[@]+"${BDEP[@]}"}"
      if [ -n "$BODY" ]; then printf '\n%s\n' "$BODY"; fi
    } > "$GURU_DIR/$EBUILD"
    bash -n "$GURU_DIR/$EBUILD" 2>"$WORK/syntax.err" || { cat "$WORK/syntax.err"; KEEP_WORK=1; die "the generated ebuild isn't valid bash — a bug in the wizard"; }
    ok "wrote $EBUILD (EAPI $EAPI_N, inherit $INHERIT)"
    if [ "$KIND" = rust ] && [ "${DRY_NO_TAG:-0}" = 0 ]; then rust_crates "$CRATE_DIR"; fi
  fi
  # --- metadata.xml: you as maintainer (a Gentoo Bugzilla address), and
  # where upstream lives
  if [ ! -f "$GURU_DIR/$PKGDIR/metadata.xml" ]; then
    {
      printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE pkgmetadata SYSTEM "https://www.gentoo.org/dtd/metadata.dtd">\n<pkgmetadata>\n'
      if [ "${GURU_MAINT:-no}" = yes ]; then
        printf '\t<maintainer type="person">\n\t\t<email>%s</email>\n\t\t<name>%s</name>\n\t</maintainer>\n' "$(xml_q "$MAINT_EMAIL")" "$(xml_q "$MAINT_NAME")"
      fi
      case "$FORGE" in
        github|gitlab|codeberg) printf '\t<upstream>\n\t\t<remote-id type="%s">%s</remote-id>\n\t</upstream>\n' "$FORGE" "$SLUG" ;;
      esac
      printf '</pkgmetadata>\n'
    } > "$GURU_DIR/$PKGDIR/metadata.xml"
    ok "wrote metadata.xml$([ "${GURU_MAINT:-no}" = yes ] && printf ' (maintainer: %s)' "$MAINT_EMAIL")"
  fi
fi
VCHECK="${VCHECK:-1}"
case "$(cat "$GURU_DIR/$EBUILD")" in *gtk*|*qtbase*|*webkit*|*libsdl*|*xdg*) VCHECK=0 ;; esac
# GURU's rules: ~arch keywords only (stable ones are for ::gentoo)
STABLE="$(sed -nE 's/^KEYWORDS="([^"]*)".*/\1/p' "$GURU_DIR/$EBUILD" | tr ' ' '\n' | grep -E '^[a-z]' | tr '\n' ' ' || true)"
if [ -n "$STABLE" ]; then
  warn "GURU allows only ~arch keywords — the ebuild has stable ones: $STABLE— made them ~arch"
  for k in $STABLE; do sed -i -E "/^KEYWORDS=/s/(\"| )$k(\"| )/\\1~$k\\2/" "$GURU_DIR/$EBUILD"; done
fi
grep -qE "^KEYWORDS=\".*~$GARCH" "$GURU_DIR/$EBUILD" \
  || note "the ebuild isn't keyworded ~$GARCH (this machine's arch) — the test build would refuse it; add it if it works here"

# show_ebuild — the ebuild as it is, with a long CRATES list folded
show_ebuild() {
  echo
  awk '/^CRATES="$/ { c = 1; n = 0; next }
       c && /^"$/ { printf "     CRATES=\"… %d crate(s), from pycargoebuild …\"\n", n; c = 0; next }
       c { n++; next }
       { print "     " $0 }' "$GURU_DIR/$EBUILD"
  echo
}
show_ebuild
if [ "${DRY_NO_TAG:-0}" = 1 ]; then
  warn "dry run stops here: tag $TAG isn't online, so the Manifest can't be made"
  note "the ebuild is in $GURU_DIR/$PKGDIR; push the tag and run without -n"
  exit 0
fi

# ===================================================== 4. Manifest + QA
step "4/7  Manifest and QA"
tools_image
cat > "$GX/manifest.sh" <<'SH'
set -e
. "$GX/common.sh"
cd "$GURU/$CAT/$PN"
pkgdev manifest -d "$DIST" || { echo "STORE-SUBMIT: pkgdev manifest failed"; exit 3; }
echo "STORE-SUBMIT: OK"
SH
cat > "$GX/pkgcheck.sh" <<'SH'
set -e
. "$GX/common.sh"
cd "$GURU/$CAT/$PN"
set -- $GXENV
rc=0
if [ "${1:-}" = commits ]; then cd "$GURU"; set -- --commits upstream/dev; else set --; fi
pkgcheck scan --net "$@" -R FormatReporter --format '{level}|{name}|{desc}' > "$GX/pkgcheck.txt" 2> "$GX/pkgcheck.err" || rc=$?
cat "$GX/pkgcheck.err" >&2
if [ "$rc" -ge 2 ] && grep -q 'network checks require' "$GX/pkgcheck.err"; then
  # its network checks need dev-python/requests: the rest still runs
  echo "STORE-SUBMIT: NONET"; rc=0
  pkgcheck scan "$@" -R FormatReporter --format '{level}|{name}|{desc}' > "$GX/pkgcheck.txt" || rc=$?
fi
[ "$rc" -ge 2 ] && { echo "STORE-SUBMIT: pkgcheck didn't run (exit $rc)"; exit 3; }
cat "$GX/pkgcheck.txt"
echo "STORE-SUBMIT: OK $rc"
SH
manifest() {
  gx "$WORK/manifest.log" "pkgdev manifest (fetches and hashes every source)" manifest.sh && gx_ok "$WORK/manifest.log" && return 0
  grep -vE '^\s*$' "$WORK/manifest.log" | tail -n 8 | cut -c1-200 | sed 's/^/     /'
  return 1
}
pkgcheck_show() {  # pkgcheck_show — its errors and warnings; false if there's an error
  local lvl name desc errs=0
  while IFS='|' read -r lvl name desc; do
    case "$lvl" in
      error)   bad "pkgcheck $name: $desc"; errs=$((errs + 1)) ;;
      warning) warn "pkgcheck $name: $desc" ;;
      *)       note "pkgcheck $name: $desc" ;;
    esac
  done < "$GX/pkgcheck.txt"
  [ "$errs" = 0 ]
}
qa() {  # qa [commits] — pkgcheck scan --net, on the package or on the commits
  GXENV="${1:-}" gx "$WORK/pkgcheck.log" "pkgcheck scan --net${1:+ --commits}" pkgcheck.sh && gx_ok "$WORK/pkgcheck.log" \
    || gx_fail "$WORK/pkgcheck.log" "pkgcheck didn't run"
  QA_NET=1
  if grep -q '^STORE-SUBMIT: NONET' "$WORK/pkgcheck.log"; then
    QA_NET=0; warn "pkgcheck's network checks need dev-python/requests — scanned without them"
  fi
  pkgcheck_show
}
while :; do
  manifest || {
    [ -n "$ASSET" ] && note "($ASSET is made locally: until you upload it, the copy in $DIST is used)"
    warn "a source couldn't be fetched — every URL in SRC_URI must work"
    [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "pkgdev manifest failed (log: $WORK/manifest.log)"; }
    say "e) edit the ebuild (in ${EDITOR:-vi})     r) try again     q) quit"
    ask CHOICE "Choice" "e"
    case "$CHOICE" in e|E) "${EDITOR:-vi}" "$GURU_DIR/$EBUILD" ;; q|Q) note "the ebuild is in $GURU_DIR/$PKGDIR"; exit 1 ;; esac
    continue
  }
  ok "Manifest: $(grep -c '^DIST ' "$GURU_DIR/$PKGDIR/Manifest") distfile(s), BLAKE2B and SHA512"
  if qa; then ok "pkgcheck: no errors"; break; fi
  [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "pkgcheck found errors (✗ above)"; }
  say "e) edit the ebuild (in ${EDITOR:-vi}), then check again     c) carry on anyway     q) quit"
  ask CHOICE "Choice" "e"
  case "$CHOICE" in
    c|C) warn "carrying on with pkgcheck's errors — reviewers will see them too"; break ;;
    q|Q) note "the ebuild is in $GURU_DIR/$PKGDIR"; exit 1 ;;
    *)   "${EDITOR:-vi}" "$GURU_DIR/$EBUILD" ;;
  esac
done
LOGDIR="$CACHE/guru-logs/$P"; mkdir -p "$LOGDIR"
cp "$GX/pkgcheck.txt" "$LOGDIR/pkgcheck.txt" 2>/dev/null || true

# ========================================================= 5. test build
step "5/7  Test build"
TESTED=0; TESTS=1
cat > "$GX/testbuild.sh" <<'SH'
set -e
. "$GX/common.sh"
set -- $GXENV
ARCH="$1"; TESTS="$2"; MAIN="$3"; VCHECK="$4"
. "$GX/portage-setup.sh"
# GURU's packages are ~arch only: accepted for them (this one, and GURU dependencies)
printf '*/*::guru ~%s\n' "$ARCH" > /etc/portage/package.accept_keywords/guru
if [ "$TESTS" = 1 ]; then
  printf 'FEATURES="test"\n' > /etc/portage/env/test.conf
  printf '%s/%s test.conf\n' "$CAT" "$PN" > /etc/portage/package.env/test
  printf '%s/%s test\n' "$CAT" "$PN" > /etc/portage/package.use/test
fi
command -v ip >/dev/null || emerge --oneshot sys-apps/iproute2 >/dev/null
echo "==> dependencies"
emerge --oneshot --onlydeps --autounmask-continue=y --autounmask-keep-masks=y "=$CAT/$P" \
  || { echo "STORE-SUBMIT: dependencies failed"; exit 4; }
EB="/var/db/repos/guru/$CAT/$PN/$P.ebuild"
echo "==> sources"
ebuild "$EB" fetch || { echo "STORE-SUBMIT: fetch failed"; exit 3; }
# Portage builds without network (network-sandbox): so does this
for i in $(ls /sys/class/net | grep -v '^lo$'); do ip link set "$i" down; done
echo "==> ebuild $P.ebuild clean merge (offline)"
F=""; [ "$TESTS" = 1 ] && F=test
FEATURES="$F" ebuild "$EB" clean merge || { echo "STORE-SUBMIT: build failed"; exit 5; }
grep -E '^(obj|sym) /usr/bin/' "/var/db/pkg/$CAT/$P/CONTENTS" | awk '{ print "BIN: " $2 }' || true
if [ -n "$MAIN" ] && [ "$VCHECK" = 1 ] && [ -x "/usr/bin/$MAIN" ]; then
  echo "==> $MAIN --version"
  timeout 10 "/usr/bin/$MAIN" --version 2>&1 | head -3 | sed 's/^/VERSION: /' || echo "STORE-SUBMIT: --version failed"
fi
echo "STORE-SUBMIT: OK"
SH
test_build() {
  "$RUNTIME" run --rm --cap-add NET_ADMIN --cap-add SYS_PTRACE \
    -v "$GURU_SNAP:/var/db/repos/gentoo:ro" -v "$GURU_DIR:/var/db/repos/guru:ro" -v "$DIST:/var/cache/distfiles" \
    -v "$BINPKGS:/var/cache/binpkgs" -v "$GX:/gx" \
    -e GX=/gx -e DIST=/var/cache/distfiles -e OWNER="$GX_OWNER" \
    -e CAT="$CAT" -e PN="$PN" -e PV="$PV" -e P="$P" -e NPROC="$(nproc 2>/dev/null || echo 2)" \
    -e GXENV="$GARCH $TESTS ${MAIN_GUESS:--} $VCHECK" "$STAGE3_IMAGE" bash /gx/testbuild.sh
}
if [ "$NO_TEST" = 1 ]; then
  warn "--no-test: not test-built"
elif [ "$GX_HOST" = 1 ]; then
  warn "no podman or docker: not test-built here"
else
  say "A clean build in a Gentoo container, offline like Portage builds, catches what users would hit."
  while :; do
    if run_logged "$WORK/test.log" "test build: dependencies, then ebuild … merge offline$([ "$TESTS" = 1 ] && printf ', with tests') (first time: long)" test_build \
       && gx_ok "$WORK/test.log"; then
      ok "built and installed cleanly in Gentoo ($GARCH)$([ "$TESTS" = 1 ] && printf ', tests passed')"
      grep '^BIN: ' "$WORK/test.log" | sed 's/^BIN: /   installs /' | head -5
      grep '^VERSION: ' "$WORK/test.log" | head -1 | sed 's/^VERSION: /   ✓ --version → /'
      grep -q "STORE-SUBMIT: --version failed" "$WORK/test.log" && warn "$MAIN_GUESS --version didn't work in the container"
      if grep -q 'QA Notice' "$WORK/test.log"; then
        warn "Portage's QA notices (reviewers look at these):"
        grep -A2 'QA Notice' "$WORK/test.log" | grep -vE '^\s*$|^--$' | head -12 | cut -c1-160 | sed 's/^/       /'
      fi
      TESTED=1
      break
    fi
    L="$WORK/test.log"; TESTFAIL=0
    if grep -q "STORE-SUBMIT: dependencies failed" "$L"; then bad "a dependency can't be installed — its name, slot or USE flags in the ebuild?"
    elif grep -q "failed (test phase)" "$L"; then bad "it builds, but its tests fail"; TESTFAIL=1
    elif grep -qE "failed \((unpack|prepare|configure|compile|install) phase\)" "$L"; then bad "the build failed ($(grep -oE 'failed \([a-z]+ phase\)' "$L" | head -1))"
    elif grep -q "STORE-SUBMIT: fetch failed" "$L"; then bad "a source couldn't be fetched"
    else bad "the test build failed"; fi
    printf '   %s── last lines of the build log ──%s\n' "$DIM" "$R"
    grep -vE '^\s*$' "$L" | tail -n 15 | cut -c1-200 | sed 's/^/     /'
    [ "$ASSUME_YES" = 1 ] && { cp "$L" "$LOGDIR/build.log"; KEEP_WORK=1; die "the test build failed (log: $LOGDIR/build.log)"; }
    [ "$TESTFAIL" = 1 ] && say "t) build without running the tests     x) restrict the tests in the ebuild (RESTRICT=\"test\", with your reason)"
    say "e) edit the ebuild (in ${EDITOR:-vi}), then build again     l) read the whole log"
    say "r) build again as it is     s) skip the test build     q) quit"
    ask CHOICE "Choice" "e"
    case "$CHOICE" in
      t|T) TESTS=0 ;;
      x|X) ask REASON "Why can't the tests run in Portage?" "they need network access"
           sed -i "/^KEYWORDS=/a # $(printf '%s' "$REASON" | sed 's/[\\/&]/\\&/g')\nRESTRICT=\"test\"" "$GURU_DIR/$EBUILD"
           manifest >/dev/null || true ;;
      e|E) "${EDITOR:-vi}" "$GURU_DIR/$EBUILD"; manifest || warn "pkgdev manifest failed after the edit" ;;
      l|L) "${PAGER:-less}" "$L" || cat "$L" ;;
      s|S) warn "not test-built"; break ;;
      q|Q) cp "$L" "$LOGDIR/build.log"; note "your work is in $GURU_DIR (branch $BRANCH); the log is in $LOGDIR"; exit 1 ;;
    esac
  done
  cp "$WORK/test.log" "$LOGDIR/build.log"
fi
[ "$TESTED" = 1 ] || handoff_add "It wasn't test-built here: build it on your Gentoo system (ebuild $PKGDIR/$P.ebuild merge, in a GURU checkout) — for a pull request, add the log: GURU's form asks for build logs"

# ===================================================== 6. review + commit
step "6/7  Review and commit"
git -C "$GURU_DIR" add -A -- "$PKGDIR"
git -C "$GURU_DIR" --no-pager diff --cached --stat -M | sed 's/^/   /'
if [ "$MODE" = new ]; then
  show_ebuild
  sed 's/^/     /' "$GURU_DIR/$PKGDIR/metadata.xml"; echo
else
  echo; git -C "$GURU_DIR" --no-pager diff --cached -M --color=auto -- "$PKGDIR" ':!*/Manifest'; echo
fi
if [ "$GENERATED" = 1 ]; then
  # Gentoo's AI policy: said plainly, before you sign anything
  warn "Gentoo's AI policy, which GURU follows, forbids contributing content created with the"
  warn "help of AI tools (https://wiki.gentoo.org/wiki/Project:Council/AI_policy)."
  say "This ebuild was written by linux-submit.sh from fixed templates — no AI runs when it"
  say "does that — but linux-submit.sh itself was written with AI help. Whether that's"
  say "acceptable is GURU's call, not this wizard's: if in doubt, ask in #gentoo-guru (Libera)"
  say "first, or write the ebuild yourself — put it in your app's repository (any path ending"
  say "in $PN-<version>.ebuild) and the wizard uses yours instead."
  if [ "$ASSUME_YES" = 1 ]; then
    git -C "$GURU_DIR" reset -q
    die "--yes: nobody has read the new ebuild — run once without --yes to review and sign it off (it's in $GURU_DIR/$PKGDIR)"
  fi
fi
say "Your commit carries Signed-off-by: $COMMIT_NAME <$COMMIT_EMAIL> — with it you certify Gentoo's"
say "Certificate of Origin (GLEP 76): you made the contribution or may submit it under its"
say "license, and you accept that it and your sign-off are public and kept for good."
note "https://www.gentoo.org/glep/glep-0076.html#certificate-of-origin"
CERTIFIED=0
if [ "$ASSUME_YES" = 0 ]; then
  confirm "Have you read the change, do you stand behind it, and do you sign it off?" n \
    || { git -C "$GURU_DIR" reset -q; note "edit it in $GURU_DIR/$PKGDIR and re-run (or write your own ebuild)"; exit 1; }
  CERTIFIED=1; guru_me_set certificate-of-origin yes
elif [ "$(guru_me_get certificate-of-origin)" = yes ]; then
  CERTIFIED=1; note "--yes: signing off as you agreed in an earlier run"
else
  git -C "$GURU_DIR" reset -q
  die "--yes: your Signed-off-by is a statement only you can make — run once without --yes and give it"
fi
# GURU's message style, as pkgdev writes it
if [ "$MODE" = new ]; then MSG="$PKGDIR: new package, add $PV"
else
  MSG="$PKGDIR: add $PV"
  if [ "${#DROPPED[@]}" -gt 0 ]; then MSG="$MSG, drop $(printf '%s, ' "${DROPPED[@]}" | sed 's/, $//')"; fi
fi
SIGN=(); [ -n "$GPGKEY" ] && SIGN=(-c "gpg.program=$GPGPROG" -c "user.signingkey=$GPGKEY")
git -C "$GURU_DIR" -c user.name="$COMMIT_NAME" -c user.email="$COMMIT_EMAIL" "${SIGN[@]+"${SIGN[@]}"}" \
  commit -q -s ${GPGKEY:+-S} -m "$MSG" || die "the commit failed${GPGKEY:+ — did gpg get its passphrase?}"
git -C "$GURU_DIR" log -1 --format=%B | grep -qxF "Signed-off-by: $COMMIT_NAME <$COMMIT_EMAIL>" || die "the commit has no Signed-off-by"
if [ -n "$GPGKEY" ]; then
  case "$(git -C "$GURU_DIR" -c "gpg.program=$GPGPROG" log -1 --format=%G?)" in
    G|U) ok "committed, signed with $GPGKEY and signed off: $MSG" ;;
    *)   die "the commit's signature doesn't verify" ;;
  esac
else
  warn "committed WITHOUT a signature (dry run, no key): $MSG"
fi
save_answers

# pkgcheck on the commits too, as GURU's pull request form asks
if qa commits; then ok "pkgcheck --commits: no errors"; QA_COMMITS=1
else QA_COMMITS=0; [ "$ASSUME_YES" = 1 ] && die "pkgcheck --commits found errors"; confirm "Carry on anyway?" n || exit 1; fi
cp "$GX/pkgcheck.txt" "$LOGDIR/pkgcheck-commits.txt" 2>/dev/null || true

if [ "$DRYRUN" = 1 ]; then
  warn "dry run — committed in $GURU_DIR (branch $BRANCH); nothing pushed or uploaded"
  [ -n "$ASSET" ] && [ "$ASSET_ONLINE" = 0 ] && note "$ASSET is in $DIST — publishing uploads it first"
  exit 0
fi

# =============================================================== 7. publish
step "7/7  Publish"
# --- the dependency tarball first: the ebuild points at it
if [ -n "$ASSET" ] && [ "$ASSET_ONLINE" = 0 ]; then
  if [ "$FORGE" = github ] && have gh && gh_ready && [ "$ASSET_URL" = "$(asset_url "$TAG" "$ASSET")" ]; then
    go "Upload $ASSET to release $TAG on GitHub (created if needed)? The ebuild downloads it from there" \
      || die "the ebuild needs $ASSET online at $ASSET_URL — upload it, then re-run"
    gh release view "$TAG" -R "$SLUG" >/dev/null 2>&1 \
      || gh release create "$TAG" -R "$SLUG" --verify-tag --title "$TAG" --notes "" >/dev/null || die "couldn't create release $TAG"
    run_logged "$WORK/upload.log" "uploading $ASSET" gh release upload "$TAG" "$DIST/$ASSET" -R "$SLUG" --clobber \
      || { tail -n 3 "$WORK/upload.log" | sed 's/^/     /'; die "the upload failed"; }
  else
    say "The ebuild downloads $ASSET from $ASSET_URL — upload it there now:"
    say "  $DIST/$ASSET"
    [ "$FORGE" = codeberg ] && note "Codeberg: $WEB/releases → release $TAG → Edit → attach the file"
    [ "$ASSUME_YES" = 1 ] && die "upload $ASSET once without --yes"
    confirm "Uploaded? Check it" y || die "the ebuild needs $ASSET online — upload it, then re-run"
  fi
  # it must be exactly the file the Manifest hashed
  for _ in 1 2 3 4 5 6; do
    curl -fsL --max-time 120 -o "$WORK/asset.check" "$ASSET_URL" 2>/dev/null && cmp -s "$WORK/asset.check" "$DIST/$ASSET" && break
    sleep 5
  done
  cmp -s "$WORK/asset.check" "$DIST/$ASSET" 2>/dev/null || die "$ASSET_URL isn't (yet) the file the Manifest hashed — check the upload, then re-run"
  ok "$ASSET is online and matches the Manifest"
fi

if [ "$ACCESS" = push ]; then
  # ------------------------------------------- straight to dev (with access)
  git -C "$GURU_DIR" remote get-url gentoo >/dev/null 2>&1 || git -C "$GURU_DIR" remote add gentoo "$GURU_GIT_PUSH"
  run_logged "$WORK/fetch-dev.log" "fetching dev from git.gentoo.org" git -C "$GURU_DIR" fetch -q gentoo dev \
    || { tail -n 3 "$WORK/fetch-dev.log" | sed 's/^/     /'; die "couldn't fetch from git.gentoo.org"; }
  if ! git -C "$GURU_DIR" merge-base --is-ancestor gentoo/dev HEAD; then
    git -C "$GURU_DIR" -c user.name="$COMMIT_NAME" -c user.email="$COMMIT_EMAIL" "${SIGN[@]+"${SIGN[@]}"}" \
      rebase -q ${GPGKEY:+--gpg-sign="$GPGKEY"} gentoo/dev || { git -C "$GURU_DIR" rebase --abort 2>/dev/null || true; die "your commit doesn't apply on today's dev — re-run the wizard"; }
    ok "rebased on today's dev (as git pull --rebase would)"
  fi
  go "Push $MSG to GURU's dev branch?" || { note "the commit is in $GURU_DIR (branch $BRANCH)"; exit 0; }
  while ! run_logged "$WORK/push.log" "pushing to git.gentoo.org" \
      git -C "$GURU_DIR" "${SIGN[@]+"${SIGN[@]}"}" push --signed=if-asked gentoo HEAD:refs/heads/dev; do
    tail -n 4 "$WORK/push.log" | sed 's/^/     /'
    grep -qiE "non-fast-forward|fetch first|rejected" "$WORK/push.log" && die "dev moved meanwhile — re-run the wizard (it rebases again)"
    [ "$ASSUME_YES" = 0 ] && confirm "Try again?" y || die "not pushed; the commit is in $GURU_DIR"
  done
  ok "pushed to dev: https://gitweb.gentoo.org/repo/proj/guru.git/log/?h=dev"
  printf '\n   %sDone.%s %s\n\n   What happens now:\n' "$B" "$R" "$MSG"
  say "  • Trusted Contributors review dev and move it to master — what users get, usually"
  say "    within days; commits of newer contributors get a closer look first."
  say "  • Users install it with: eselect repository enable guru && emaint sync -r guru"
  say "    && emerge --ask $PKGDIR  (it's ~$GARCH: accept that keyword for it)"
  say "  • Bugs about it come to you through Gentoo Bugzilla; next release: run"
  say "    linux-submit.sh guru (or linux-submit.sh) again — it copies the ebuild and drops the old one."
  [ -f "$WORK/handoff.txt" ] && handoff_show "Still to do by you"
  echo
  exit 0
fi

if [ -z "$CB_USER" ]; then
  # ------------------------------------- no Codeberg: the mailing list
  OUT="$LOGDIR/patch"; rm -rf "$OUT"
  git -C "$GURU_DIR" format-patch -q -1 -o "$OUT" HEAD
  handoff_add "Send your commit as a patch to GURU's mailing list: git send-email --to gentoo-guru@lists.gentoo.org $(ls "$OUT"/*.patch)"
  handoff_add "Say in the mail that you've read and agree to GURU's rules, and answer the reviewers there"
  handoff_add "After a few are merged, ask for access: https://bugs.gentoo.org/enter_bug.cgi?product=GURU&component=Access+requests (your name, SSH key, OpenPGP key ${GPGKEY:-…}, that you agree to the rules, links to your merged work)"
  handoff_show "Your turn — GURU takes this patch by mail" "https://wiki.gentoo.org/wiki/Project:GURU/Information_for_Contributors"
  exit 0
fi

# ------------------------------------------- a pull request on Codeberg (AGit)
# GURU's own form, ticked where this run checked it or you said so here; the
# AI-policy and Bugzilla boxes are yours. "WIP:" keeps it a draft (as gagit
# does) until you mark it ready.
TOPIC="$BRANCH"
TITLE="WIP: $MSG"
DESC_MD="$WORK/pr.md"
# shellcheck disable=SC2016
{
  if [ "$MODE" = new ]; then printf '%s — %s\n\n' "$DESC" "$HOMEPAGE"; else printf 'Version bump to %s.%s\n\n' "$PV" "${CHANGELOG_REAL:+ Changelog: $CHANGELOG_REAL}"; fi
  if [ "$TESTED" = 1 ]; then
    printf 'Built and installed with `ebuild … merge` in a clean `gentoo/stage3` container (%s, Gentoo snapshot of %s), offline%s.\n\n' \
      "$GARCH" "$(head -1 "$GURU_SNAP/metadata/timestamp.chk")" "$([ "$TESTS" = 1 ] && printf ', with tests (FEATURES=test)')"
    printf '<details><summary>Build log (last 120 lines)</summary>\n\n```\n'
    grep -vE '^STORE-SUBMIT' "$LOGDIR/build.log" | tail -n 120 | cut -c1-200
    printf '```\n\n</details>\n\n'
  fi
  if [ "$QA_COMMITS" = 1 ]; then printf '`pkgcheck scan --commits%s`: no errors.\n\n' "$([ "$QA_NET" = 1 ] && printf ' --net')"; fi
  if [ "$GENERATED" = 1 ]; then
    printf 'The ebuild was generated by [linux-submit.sh](https://github.com/by-architect/StoreHelper), a fixed script — no AI runs when it writes an ebuild — which was itself written with AI help. I read it before signing off.\n\n'
  fi
  if [ -n "$TPL" ]; then
    T=(-e 's/^- \[ \] I have certified the above via adding a `Signed-off-by` line/- [x] I have certified the above via adding a `Signed-off-by` line/')
    [ "$RULES_OK" = 1 ]   && T+=(-e 's/^- \[ \] I have read the \[GURU rules\]/- [x] I have read the [GURU rules]/')
    [ "$CERTIFIED" = 1 ]  && T+=(-e 's/^- \[ \] I can submit this contribution/- [x] I can submit this contribution/')
    [ "$QA_COMMITS" = 1 ] && [ "$QA_NET" = 1 ] && T+=(-e 's/^- \[ \] I have run `pkgcheck scan --commits --net`/- [x] I have run `pkgcheck scan --commits --net`/')
    [ "$TESTED" = 1 ]     && T+=(-e 's/^- \[ \] I have included the build logs/- [x] I have included the build logs/')
    printf '%s\n' "$TPL" | sed "${T[@]}"
  fi
} > "$DESC_MD"
b64() { printf '{base64}'; base64 -w 0 < "$1"; }
printf '%s' "$TITLE" > "$WORK/pr-title.txt"
git -C "$GURU_DIR" remote get-url codeberg >/dev/null 2>&1 || git -C "$GURU_DIR" remote add codeberg "$GURU_GIT_PR"
go "Send the pull request \"$TITLE\" to GURU on Codeberg (as $CB_USER)?" || { note "the commit is in $GURU_DIR (branch $BRANCH)"; exit 0; }
# Gentoo's guide: fetch before an AGit push, or git may upload far too much
run_logged "$WORK/fetch-cb.log" "fetching dev from Codeberg" git -C "$GURU_DIR" fetch -q codeberg dev || true
run_logged "$WORK/pr.log" "pushing the pull request (AGit)" \
  git -C "$GURU_DIR" push -o "topic=$TOPIC" -o "title=$(b64 "$WORK/pr-title.txt")" -o "description=$(b64 "$DESC_MD")" \
    -o force-push=true codeberg "HEAD:refs/for/dev/$TOPIC" \
  || { tail -n 6 "$WORK/pr.log" | sed 's/^/     /'; KEEP_WORK=1; die "the pull request wasn't accepted — the text is in $DESC_MD"; }
PR_URL="$(grep -oE 'https://codeberg\.org/gentoo/guru/pulls/[0-9]+' "$WORK/pr.log" | tail -1 || true)"
ok "pull request sent${PR_URL:+: $PR_URL}"
handoff_add "Open the pull request${PR_URL:+ ($PR_URL)} and tick the boxes still empty only if they're true for you — the AI policy and the Bugzilla e-mail are yours to state; GURU merges only when every box is ticked"
handoff_add "Then remove \"WIP:\" from the title — that marks it ready for review"
[ "$GENERATED" = 1 ] && handoff_add "The description says how the ebuild was made (linux-submit.sh, itself written with AI help) — keep that; GURU's reviewers decide"
handoff_add "Answer the reviewers there; re-running linux-submit.sh guru updates the same pull request (same topic, $TOPIC)"
handoff_add "After a few merged pull requests, ask for direct access to dev: https://bugs.gentoo.org/enter_bug.cgi?product=GURU&component=Access+requests — your name, SSH public key, OpenPGP key ${GPGKEY:-…} (gpg --armor --export ${GPGKEY:-…}), that you agree to GURU's rules, and links to your merged pull requests"
handoff_show "Your turn — GURU's reviewers take it from here" "${PR_URL:-https://codeberg.org/gentoo/guru/pulls}"
}

# ##########################################################################
#   Homebrew's questions — the formula's name, homebrew/core or your own
#   tap, a description that fits, a test. Part of "Your app" whenever
#   Homebrew is among the distros, so a Linux run asks them up front and the
#   config keeps them. Needs linux_common and linux_app's globals.
# ##########################################################################
BREW_API="${BREW_API_ROOT:-https://formulae.brew.sh/api}"
BREW_CORE="Homebrew/homebrew-core"

# brew_api <formula|cask> <name> — formulae.brew.sh's JSON for it (nothing if there's none)
brew_api() { curl -sf --max-time 20 "$BREW_API/$1/$2.json" 2>/dev/null || true; }

# brew_class <name> — the formula's Ruby class, named the way Homebrew does
# it (Formulary.class_s): foo-bar → FooBar, gtk+3 → Gtkx3
brew_class() {
  printf '%s\n' "$1" | awk '{
    s = toupper(substr($0, 1, 1)) tolower(substr($0, 2)); out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1); nx = substr(s, i + 1, 1)
      if (c ~ /[-_. ]/ && nx ~ /[a-zA-Z0-9]/) { out = out toupper(nx); i++ } else out = out c
    }
    gsub(/\+/, "x", out); print out }'
}

# brew_rel <name> — where homebrew/core keeps a new formula: Formula/lib/ for
# lib…, else Formula/<first letter>/ (CoreTap#new_formula_subdirectory)
brew_rel() {
  case "$1" in
    lib*) printf 'Formula/lib/%s.rb' "$1" ;;
    *)    printf 'Formula/%s/%s.rb' "$(printf '%s' "$1" | cut -c1)" "$1" ;;
  esac
}

# brew_name_problems <name> — one line per Homebrew naming rule it breaks
brew_name_problems() {
  local n="$1"
  printf '%s' "$n" | grep -qE '^[a-z][a-z0-9._+-]*$' \
    || echo "lowercase letters, digits and - _ . + only, starting with a letter (the name becomes a Ruby class)"
  case "$n" in *--*) echo "it must not have two - in a row" ;; esac
  case "$n" in *-) echo "it must not end with -" ;; esac
}

# brew_gh — your GitHub login (GH_USER, GH_ID, GH_NAME): homebrew/core's pull
# requests and your tap both live on GitHub, and gh does the talking
brew_gh() {
  [ -n "${GH_USER:-}" ] && return 0
  have gh || die "gh (GitHub CLI) is missing — Homebrew's pull requests and taps live on GitHub. Install it, e.g.: nix profile install nixpkgs#gh"
  if ! gh_ready; then
    warn "gh is not logged in to GitHub"
    [ "$ASSUME_YES" = 1 ] && die "run 'gh auth login' first"
    if confirm "Log in now (gh auth login)?" y; then gh auth login --hostname github.com || true; fi
    gh_ready || die "still not logged in — run 'gh auth login', then re-run"
  fi
  GH_USER="$(gh api user --jq .login 2>/dev/null || true)"
  [ -n "$GH_USER" ] || die "could not ask GitHub who you are (gh api user) — check your connection"
  GH_ID="$(gh api user --jq .id 2>/dev/null || true)"
  GH_NAME="$(gh api user --jq '.name // ""' 2>/dev/null || true)"
  ok "GitHub: $GH_USER"
}

# brew_notability — homebrew/core's notability bar, on the forge's own numbers
# (Package-Acceptance-Policy.md, "Notability" — the thresholds brew audit --new
# applies): 30 forks, 30 watchers or 75 stars, three times that when the
# repository's owner submits it; 30 days old or more; not a fork. Sets NOTABLE
# (1/0), NOTE_WHY (what's missing), NOTE_BAR (the numbers it needs) and
# NOTE_LINE (the numbers it has).
brew_notability() {
  local f w s created fork archived age mult=1 forge_name wtxt wbar
  NOTABLE=0; NOTE_WHY=""; NOTE_LINE=""; NOTE_BAR=""; SELF_SUB=0
  if [ "$(printf '%s' "${SLUG%%/*}" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$GH_USER" | tr 'A-Z' 'a-z')" ]; then
    SELF_SUB=1; mult=3
  fi
  if [ "$FORGE" = git ] || [ ! -s "$WORK/forge.json" ]; then
    NOTE_WHY="its stars and forks can't be read from ${HOST:-its host} (Homebrew counts them on GitHub, GitLab and Codeberg)"
    return 0
  fi
  read -r f w s created fork archived <<EOF
$(tool jq jq -r --arg forge "$FORGE" '
    if $forge == "gitlab" then [.forks_count, -1, .star_count, .created_at, (.forked_from_project != null), .archived]
    elif $forge == "github" then [.forks_count, .subscribers_count, .stargazers_count, .created_at, .fork, .archived]
    else [.forks_count, .watchers_count, .stars_count, .created_at, .fork, .archived] end
    | map(if . == null then "0" else tostring end) | join(" ")' < "$WORK/forge.json" 2>/dev/null || true)
EOF
  case "${f:-}${w:-}${s:-}" in ''|*[!0-9-]*)
    NOTE_WHY="the forge didn't say how many stars and forks it has"; return 0 ;;
  esac
  age=$(( ( $(date +%s) - $(date -d "$created" +%s 2>/dev/null || date +%s) ) / 86400 ))
  case "$FORGE" in github) forge_name=GitHub ;; gitlab) forge_name=GitLab ;; *) forge_name=Codeberg ;; esac
  wtxt=""; wbar=""   # GitLab has no watchers count
  if [ "$w" -ge 0 ]; then wtxt=", $w watchers"; wbar=", $((30 * mult)) watchers"; fi
  NOTE_LINE="$forge_name: $s stars, $f forks$wtxt, created $(printf '%s' "$created" | cut -c1-10)"
  ok "$NOTE_LINE"
  NOTE_BAR="$((75 * mult)) stars$wbar or $((30 * mult)) forks"
  if [ "$fork" = true ]; then NOTE_WHY="the repository is a fork — Homebrew wants the original project's"
  elif [ "$archived" = true ]; then NOTE_WHY="the repository is archived — Homebrew wants software that's maintained"
  elif [ "$age" -lt 30 ]; then NOTE_WHY="the repository is $age days old — Homebrew wants 30 days or more"
  elif [ "$f" -lt $((30 * mult)) ] && [ "$s" -lt $((75 * mult)) ] && { [ "$w" -lt 0 ] || [ "$w" -lt $((30 * mult)) ]; }; then
    NOTE_WHY="it needs $NOTE_BAR"
    if [ "$SELF_SUB" = 1 ]; then NOTE_WHY="$NOTE_WHY — three times the usual bar, as you own the repository and would be submitting it yourself"; fi
  else
    NOTABLE=1
  fi
}

# brew_python — homebrew/core's current Python formula (the one called python3)
brew_python() {
  local i
  for i in $(seq 20 -1 10); do
    brew_api formula "python@3.$i" | tool jq jq -e '(.aliases // []) | index("python3")' >/dev/null 2>&1 \
      && { printf 'python@3.%s' "$i"; return 0; }
  done
  printf 'python@3.14'
}

brew_questions() {
  local first=1 guess probs d j raw
  # --- formulae are built from source, and Homebrew has no Flutter SDK for that
  case "$KIND" in
    flutter)
      bad "Homebrew builds formulae from source, and it has no Flutter SDK to build with:"
      note "Flutter is only a macOS cask there, and a formula can't depend on a cask."
      note "Homebrew's casks install ready-made builds instead (a macOS .app, a Linux AppImage);"
      note "this wizard writes formulae, not casks."
      die "a Flutter app can't be a Homebrew formula — on Linux, people get it from Flathub or the Snap Store" ;;
  esac
  brew_gh
  NOTABLE=0; NOTE_WHY=""; NOTE_LINE=""; NOTE_BAR=""; SELF_SUB=0
  BREW_MODE=new; CORE_VERSION=""; CORE_AUTOBUMP=""; CORE_REL=""; TARGET=""

  BREW_NAME="$(cfg_get brew-name)"; BREW_NAME="${BREW_NAME:-$PNAME}"
  guess=""
  while :; do
    # --- the name: Homebrew's rules, and not taken in homebrew/core by other software
    probs="$(brew_name_problems "$BREW_NAME")"
    if [ -z "$probs" ]; then
      j="$(brew_api formula "$BREW_NAME")"
      if [ -n "$j" ]; then
        if printf '%s' "$j" | tool jq jq -r '[.urls.stable.url, .urls.head.url, .homepage] | map(. // "") | join(" ")' | grep -qiF "$SLUG"; then
          BREW_MODE=core-update
          CORE_VERSION="$(printf '%s' "$j" | tool jq jq -r '.versions.stable // ""')"
          CORE_AUTOBUMP="$(printf '%s' "$j" | tool jq jq -r '.autobump // false')"
          CORE_REL="$(printf '%s' "$j" | tool jq jq -r '.ruby_source_path // ""')"
          ok "homebrew/core has $BREW_NAME $CORE_VERSION — this is an update"
        else
          probs="homebrew/core already has a different '$BREW_NAME' ($(printf '%s' "$j" | tool jq jq -r '.homepage // ""'))"
          guess="$BREW_NAME-$(printf '%s' "${SLUG%%/*}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-')"
        fi
      fi
    fi
    if [ -z "$probs" ]; then
      # --- homebrew/core or your own tap: notability decides what's possible, you decide
      if [ "$BREW_MODE" = core-update ]; then
        TARGET=core
      else
        brew_notability
        [ -n "$TARGET" ] || TARGET="${TARGET_ARG:-$(cfg_get brew-target)}"
        if [ -z "$TARGET" ] || { [ "$ASK_ALL" = 1 ] && [ -z "${TARGET_ARG:-}" ]; }; then
          if [ "$NOTABLE" = 1 ]; then
            ok "it meets homebrew/core's notability bar"
            say "core — Homebrew's maintainers review it, then anyone can 'brew install $BREW_NAME'"
            say "tap  — your own tap: published right away, 'brew install <you>/tap/$BREW_NAME'"
            d=core
          else
            warn "not for homebrew/core yet: $NOTE_WHY"
            note "Homebrew's way for that is a tap of your own: published right away, 'brew install <you>/tap/$BREW_NAME'"
            d=tap
          fi
          while :; do
            ask TARGET "homebrew/core or your own tap? (core / tap)" "${TARGET:-$d}"
            case "$TARGET" in core|c) TARGET=core; break ;; tap|t) TARGET=tap; break ;; esac
            warn "core or tap"; TARGET=""
          done
        fi
        case "$TARGET" in core|tap) ;; *) die "brew-target in the config must be core or tap (it says '$TARGET')" ;; esac
        if [ "$TARGET" = core ] && [ "$NOTABLE" = 0 ]; then
          warn "homebrew/core: $NOTE_WHY — brew audit --new flags that, and the pull request would most likely be closed"
          if confirm "Submit it to homebrew/core anyway?" n; then :; else TARGET=tap; fi
        fi
        if [ "$TARGET" = core ]; then ok "goes to: homebrew/core"; else ok "goes to: your own tap"; fi
        [ "$TARGET" = tap ] && [ "$NOTABLE" = 1 ] && note "(it meets homebrew/core's notability bar — --core sends it there)"
        [ "${SAVE:-1}" = 1 ] && cfg_set brew-target "$TARGET"
      fi
      # --- homebrew/core: formulae and casks share one namespace there
      if [ "$TARGET" = core ] && [ "$BREW_MODE" = new ] && j="$(brew_api cask "$BREW_NAME")" && [ -n "$j" ]; then
        if printf '%s' "$j" | tool jq jq -r '[.url, .homepage] | map(. // "") | join(" ")' | grep -qiF "$SLUG"; then
          die "your app is in Homebrew as a cask already (brew install --cask $BREW_NAME) — a formula can't have the same name"
        fi
        probs="homebrew/cask has a different '$BREW_NAME' — a homebrew/core formula can't have the same name"
        guess="$BREW_NAME-$(printf '%s' "${SLUG%%/*}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-')"
      fi
    fi
    [ -z "$probs" ] && break
    printf '%s\n' "$probs" | while read -r l; do warn "formula name: $l"; done
    [ "$ASSUME_YES" = 1 ] && die "set brew-name in the config (another name for the formula), or run once without --yes"
    ask BREW_NAME "Formula name" "${guess:-$(printf '%s' "$BREW_NAME" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9._+-]+/-/g; s/^[^a-z]+//; s/-+/-/g; s/-$//')}"
    BREW_MODE=new; guess=""
  done
  if [ "${SAVE:-1}" = 1 ]; then
    if [ "$BREW_NAME" != "$PNAME" ]; then cfg_set brew-name "$BREW_NAME"; else cfg_set brew-name ""; fi
  fi
  [ "$BREW_NAME" != "$PNAME" ] && ok "formula name: $BREW_NAME"

  # --- your tap: a GitHub repository named homebrew-<something>
  BREW_TAP=""; TAPREF=""
  if [ "$TARGET" = tap ]; then
    # the app's owner's tap when that's you (or an organisation you can push for), else yours
    guess="$(cfg_get brew-tap)"
    if [ -z "$guess" ]; then
      guess="$GH_USER/homebrew-tap"
      if [ "$FORGE" = github ]; then
        if [ "$(printf '%s' "${SLUG%%/*}" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$GH_USER" | tr 'A-Z' 'a-z')" ] \
           || [ "$(tool jq jq -r '.permissions.push // false' < "$WORK/forge.json" 2>/dev/null || true)" = true ]; then
          guess="${SLUG%%/*}/homebrew-tap"
        fi
      fi
    fi
    first=1
    while :; do
      if [ "$first" = 1 ]; then auto BREW_TAP "Your tap (a GitHub repository)" "$guess"
      else ask BREW_TAP "Your tap (owner/homebrew-name)" "$guess"; fi
      first=0
      BREW_TAP="$(printf '%s' "$BREW_TAP" | sed -E 's#^https?://github\.com/##; s#\.git$##; s#/$##')"
      if printf '%s' "$BREW_TAP" | grep -qE '^[A-Za-z0-9-]+/homebrew-[A-Za-z0-9._-]+$'; then
        # one that exists has to take your pushes; a missing one is made in stage 7
        [ "$(gh api "repos/$BREW_TAP" --jq '.permissions.push' 2>/dev/null || true)" = false ] || break
        warn "you can't push to https://github.com/$BREW_TAP — it isn't yours"
      else
        warn "a GitHub repository named homebrew-<something>, e.g. $GH_USER/homebrew-tap (the prefix is what lets people 'brew tap $GH_USER/tap')"
      fi
      [ "$ASSUME_YES" = 1 ] && die "set brew-tap in the config to a tap of yours (owner/homebrew-name)"
      guess="$GH_USER/homebrew-tap"
    done
    TAPREF="$(printf '%s/%s' "${BREW_TAP%%/*}" "${BREW_TAP#*/homebrew-}" | tr 'A-Z' 'a-z')"
    [ "${SAVE:-1}" = 1 ] && cfg_set brew-tap "$BREW_TAP"
    ok "people will install it with: brew install $TAPREF/$BREW_NAME"
  fi

  # --- the description: Homebrew's rules match the shared ones, but 80 characters at most
  BDESC="$(cfg_get brew-desc)"; BDESC="${BDESC:-$DESC}"
  BDESC="$(printf '%s' "$BDESC" | sed -E 's/([Cc])ommand ?line/\1ommand-line/g')"
  while [ "${#BDESC}" -gt 80 ]; do
    warn "Homebrew's descriptions are 80 characters at most — this one has ${#BDESC}"
    [ "$ASSUME_YES" = 1 ] && die "--yes: set brew-desc in the config (80 characters at most), or run once without --yes"
    ask BDESC "A shorter description, for Homebrew" "$(printf '%s' "$BDESC" | cut -c1-80 | sed -E 's/[[:space:]]+[^[:space:]]*$//')"
  done
  if [ "${SAVE:-1}" = 1 ]; then
    if [ "$BDESC" != "$DESC" ]; then cfg_set brew-desc "$BDESC"; else cfg_set brew-desc ""; fi
  fi

  # --- the test: Homebrew wants one that uses the app, not only --version
  raw="$(cfg_get brew-test)"; BREW_EXPECT="$(cfg_get brew-test-expect)"
  BREW_TEST="$raw"; [ "$BREW_TEST" = - ] && BREW_TEST=""
  if [ "$BREW_MODE" = new ] && [ "$ASSUME_YES" = 0 ] && { [ -z "$raw" ] || [ "$ASK_ALL" = 1 ]; }; then
    say "Homebrew wants the formula's test to use $MAIN_GUESS for real — checking --version alone is"
    say "a \"bad test\" in its words. It runs in an empty temporary folder, without network."
    note "e.g. '$MAIN_GUESS --help' and a word its output must contain; Enter skips it"
    ask_opt BREW_TEST "A command that exercises $MAIN_GUESS" "$BREW_TEST"
    if [ -n "$BREW_TEST" ]; then ask BREW_EXPECT "Text its output should contain" "$BREW_EXPECT"; else BREW_EXPECT=""; fi
    if [ "${SAVE:-1}" = 1 ]; then cfg_set brew-test "${BREW_TEST:--}"; cfg_set brew-test-expect "$BREW_EXPECT"; fi
  fi
  [ -n "$BREW_TEST" ] && ok "test: $BREW_TEST → output contains \"$BREW_EXPECT\""
  return 0
}

# ##########################################################################
#   Homebrew wizard — linux-submit.sh brew [options]
#   (body unindented on purpose: its here-documents start at column 0)
# ##########################################################################
wizard_brew() {
#
# linux-submit.sh brew — publish an app to Homebrew (macOS and Linux), or ship
# a new version of it: a formula in homebrew/core when the app is notable
# enough for it, otherwise in a tap of your own.
#
# Follows Homebrew's own documentation:
#   https://docs.brew.sh/Adding-Software-to-Homebrew
#   https://docs.brew.sh/Acceptable-Formulae
#   https://docs.brew.sh/Package-Acceptance-Policy   (notability)
#   https://docs.brew.sh/Formula-Cookbook
#   https://docs.brew.sh/Language-Specific-Formulae
#   https://docs.brew.sh/How-To-Open-a-Homebrew-Pull-Request
#   https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap
#   https://docs.brew.sh/Responsible-AI-Usage
#
# Checks the app against homebrew/core's notability bar on the forge's own
# numbers and lets you choose: a pull request to homebrew/core, or your own
# tap (<you>/homebrew-tap, created with gh — from brew tap-new's template —
# when it's missing). Writes the formula with Homebrew's helpers for the build
# system (std_cargo_args, std_go_args, a virtualenv for Python, std_npm_args,
# std_meson_args, std_cmake_args) and a real `test do` block, then builds it
# from source and runs brew test, brew audit --new --strict --online and brew
# style — with your Homebrew, or in Homebrew's own container
# (ghcr.io/homebrew/brew) when brew isn't installed. Updates are made with
# brew bump-formula-pr; homebrew/core formulae that BrewTestBot bumps by
# itself (autobump) are left to it.
#
# Homebrew takes pull requests made with tools, but wants a person to review
# generated code and to answer the reviewers themselves, and AI involvement
# disclosed (Responsible-AI-Usage.md): the wizard shows you the formula, asks,
# and says in the pull request how the formula was made.
#
# Flutter apps can't be formulae — Homebrew has no Flutter SDK to build them
# with — and the wizard says so and stops.
#
# Nothing leaves your machine without asking first, unless you pass --yes.

set -eu
# NOTE: deliberately no `set -o pipefail` — `cmd | head` would SIGPIPE and abort.

DRYRUN=0
SAVE=1
ASSUME_YES=0
ASK_ALL=0
NO_TEST=0
REPO_ARG=""
TARGET_ARG=""
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/brew-submit"
CONF="$CONF_DIR/last.conf"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/store-submit"
# Homebrew's own image, for when brew isn't installed (overridable)
BREW_IMAGE="${BREW_IMAGE:-ghcr.io/homebrew/brew:latest}"
# named in the pull request, as Homebrew's AI policy asks
TOOL_URL="https://github.com/by-architect/StoreHelper"

usage() {
  cat <<'USAGE'
linux-submit.sh brew — publish an app to Homebrew (macOS and Linux), or update it.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask; a new formula
                      for homebrew/core still stops for you to review it
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --config FILE   the shared answers (default: .store-submit.conf in the repo)
      --core          send it to homebrew/core (it must meet Homebrew's notability bar)
      --tap           put it in your own tap (<you>/homebrew-tap)
      --no-test       don't build and check it (your own tap only)
  -n, --dry-run       write, build and check, commit locally; push nothing
      --no-save       do not remember the answers for next time
      --forget        delete the remembered answers and exit

Homebrew runs in its own container (podman or docker) when brew isn't installed.
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
    --core)       TARGET_ARG=core ;;
    --tap)        TARGET_ARG=tap ;;
    --no-test)    NO_TEST=1 ;;
    --no-save)    SAVE=0 ;;
    --forget)     rm -f "$CONF"; printf 'forgot %s\n' "$CONF"; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

WIZ_NAME=brew-submit
linux_common

SAVED_REPO=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF" || warn "could not read $CONF"
fi
save_answers() {
  [ "$SAVE" = 1 ] || return 0
  mkdir -p "$CONF_DIR"
  { printf '# written by linux-submit.sh brew — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n' "${REPO:-${SAVED_REPO:-}}"; } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}

# ------------------------------------------------------------------ helpers
HOST_BREW=0; have brew && HOST_BREW=1
RUNTIME=""
if [ "$HOST_BREW" = 0 ]; then
  for r in podman docker; do have "$r" && "$r" info >/dev/null 2>&1 && { RUNTIME="$r"; break; }; done
fi
SESSION=0   # 1 once Homebrew (yours, or the container's) is ready
CTR=""      # the container, while it runs

# bx <command…> — run it where Homebrew is: your brew, or the container.
# Formulae are read from the taps' files rather than Homebrew's API, as the
# contribution guides ask (HOMEBREW_NO_INSTALL_FROM_API).
bx() {
  if [ "$HOST_BREW" = 1 ]; then
    env HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 "$@" </dev/null
  else
    "$RUNTIME" exec "$CTR" "$@" </dev/null
  fi
}
# bxi <command…> — the same, reading our input: files go into the container
# this way, without mounts, so nothing depends on user ids or SELinux labels
bxi() {
  if [ "$HOST_BREW" = 1 ]; then
    env HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 "$@"
  else
    "$RUNTIME" exec -i "$CTR" "$@"
  fi
}
# bxt <command…> — like bx, for commands that ask GitHub's API: the container
# gets your gh login's token in its environment for that one command (never on
# a command line, never saved); your own brew finds gh's login by itself
bxt() {
  if [ "$HOST_BREW" = 1 ]; then bx "$@"; return; fi
  ( HOMEBREW_GITHUB_API_TOKEN="$(gh auth token 2>/dev/null || true)"; export HOMEBREW_GITHUB_API_TOKEN
    "$RUNTIME" exec -e HOMEBREW_GITHUB_API_TOKEN "$CTR" "$@" </dev/null )
}
# brew_put <local file> <path in the session> / brew_get <path in the session>
# <local file> — the formula in and out (nothing to do when they're one file)
brew_put() { [ "$1" = "$2" ] && return 0; bxi sh -c 'mkdir -p "$(dirname "$1")" && cat > "$1"' sh "$2" < "$1"; }
brew_get() { [ "$1" = "$2" ] && return 0; bx cat "$1" > "$2.new" && mv "$2.new" "$2"; }
# Homebrew 6 loads other people's taps only once trusted: this one formula of yours
trust_it() { [ "$TARGET" = tap ] && bx brew trust --formula "$FREF" >/dev/null 2>&1; return 0; }

# rb_str <text> — escaped for a "…" Ruby string
rb_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/#\([{$@]\)/\\#\1/g'; }

# brew_license <SPDX expression> — the formula's `license` argument (false if
# it needs writing by hand)
brew_license() {
  local e
  e="$(printf '%s' "$1" | sed -E 's# */ *# OR #g; s/ or / OR /g; s/ and / AND /g; s/ with / WITH /g')"
  case "$e" in
    ''|*"("*|*" OR "*" AND "*|*" AND "*" OR "*|*" WITH "*" WITH "*) return 1 ;;
    *" WITH "*) printf '"%s" => { with: "%s" }' "${e%% WITH *}" "${e#* WITH }" ;;
    *" OR "*)   printf 'any_of: ["%s"]' "$(printf '%s' "$e" | sed 's/ OR /", "/g')" ;;
    *" AND "*)  printf 'all_of: ["%s"]' "$(printf '%s' "$e" | sed 's/ AND /", "/g')" ;;
    *)          printf '"%s"' "$e" ;;
  esac
}

# brew_pc <pkg-config module> — the formula that ships it: dep:<name>,
# mac:<name> (uses_from_macos: macOS has it) or linux:<name> (Linux only)
brew_pc() {
  case "$1" in
    gtk4) echo dep:gtk4 ;; gtk+-3.0) echo dep:gtk+3 ;; libadwaita-1) echo dep:libadwaita ;;
    glib-2.0|gio-2.0|gobject-2.0|gio-unix-2.0|gmodule-2.0) echo dep:glib ;; json-glib-1.0) echo dep:json-glib ;;
    libsoup-3.0) echo dep:libsoup ;; gtksourceview-5) echo dep:gtksourceview5 ;; libsecret-1) echo dep:libsecret ;;
    sqlite3) echo mac:sqlite ;; libcurl) echo mac:curl ;; zlib) echo mac:zlib ;; libxml-2.0) echo mac:libxml2 ;;
    expat) echo mac:expat ;; libffi) echo mac:libffi ;; ncurses|ncursesw) echo mac:ncurses ;; bzip2) echo mac:bzip2 ;;
    openssl|libssl|libcrypto) echo dep:openssl@3 ;; x11) echo dep:libx11 ;; xkbcommon) echo dep:libxkbcommon ;;
    dbus-1) echo dep:dbus ;; libpulse|libpulse-simple) echo dep:pulseaudio ;; cairo) echo dep:cairo ;;
    pango|pangocairo) echo dep:pango ;; gdk-pixbuf-2.0) echo dep:gdk-pixbuf ;; fontconfig) echo dep:fontconfig ;;
    freetype2) echo dep:freetype ;; libpng) echo dep:libpng ;; libjpeg) echo dep:jpeg-turbo ;; sdl2) echo dep:sdl2 ;;
    sdl3) echo dep:sdl3 ;; vulkan) echo dep:vulkan-loader ;; libnotify) echo dep:libnotify ;; epoxy) echo dep:libepoxy ;;
    gstreamer-1.0) echo dep:gstreamer ;; gstreamer-plugins-base-1.0) echo dep:gst-plugins-base ;;
    libarchive) echo dep:libarchive ;; libzstd) echo dep:zstd ;; liblzma) echo dep:xz ;; libpcre2-8) echo dep:pcre2 ;;
    wayland-client|wayland-server|wayland-cursor) echo linux:wayland ;; alsa) echo linux:alsa-lib ;;
    libsystemd|libudev) echo linux:systemd ;; libdrm) echo linux:libdrm ;; gl|egl) echo linux:mesa ;;
    *) echo "dep:$1" ;;
  esac
}

# brew_explain <log> — what a failed build says, in plain words, and its last lines
brew_explain() {
  local l="$1"
  if grep -qE "SHA-?256 mismatch|[Cc]hecksum mismatch" "$l"; then
    bad "the download doesn't match the formula's sha256 — was tag $TAG moved after it was published?"
  elif grep -qE "No available formula with the name" "$l"; then
    bad "a dependency isn't a Homebrew formula: $(grep -oE 'No available formula with the name "[^"]+"' "$l" | head -1 | sed 's/.*name //')"
  elif grep -qiE "Could not resolve host|failed to lookup address|dial tcp|Temporary failure in name resolution|network is unreachable" "$l" \
       && grep -q '^  deny_network_access!' "$FILE_LOCAL"; then
    bad "the build tried to use the network — Homebrew's install step runs offline; downloads belong in def fetch"
  elif grep -qE "Failed to download resource|curl: \([0-9]+\)" "$l"; then
    bad "a download failed — is tag $TAG pushed, and is the network up?"
  elif grep -qE "^error(\[E[0-9]+\])?: |error: could not compile" "$l"; then
    bad "the code didn't compile with Homebrew's toolchain:"
  else
    bad "the build failed:"
  fi
  printf '   %s── last lines of the log ──%s\n' "$DIM" "$R"
  grep -vE '^\s*$' "$l" | tail -n 15 | cut -c1-200 | sed 's/^/     /'
}

# brew_test_block — the formula's `test do`: the version check the build
# showed works ($T_KIND), and your own check ($BREW_TEST)
T_KIND=version; T_ERR=""; BINS=""
brew_test_block() {
  local first rest cmd
  printf '  test do\n'
  case "$T_KIND" in
    version) printf '    assert_match version.to_s, shell_output("#{bin}/%s --version%s")\n' "$MAIN" "$T_ERR" ;;
    help)    printf '    system bin/"%s", "--help"\n' "$MAIN" ;;
  esac
  if [ -n "$BREW_TEST" ]; then
    first="${BREW_TEST%% *}"; rest=""; [ "$first" != "$BREW_TEST" ] && rest=" ${BREW_TEST#* }"
    if printf '%s\n%s\n' "$MAIN" "$BINS" | grep -qxF "$first"; then cmd="#{bin}/$first$(rb_str "$rest")"
    else cmd="$(rb_str "$BREW_TEST")"; fi
    printf '    assert_match "%s", shell_output("%s")\n' "$(rb_str "$BREW_EXPECT")" "$cmd"
  elif [ "$T_KIND" = none ]; then
    printf '    assert_path_exists bin/"%s"\n' "$MAIN"
  fi
  printf '  end\n'
}
# set_test_block — the formula's test do … end replaced by brew_test_block's
set_test_block() {
  brew_test_block > "$WORK/test.rb"
  awk -v blk="$WORK/test.rb" '
    /^  test do$/ { while ((getline l < blk) > 0) print l; skip = 1; next }
    skip && /^  end$/ { skip = 0; next }
    !skip { print }' "$FILE_LOCAL" > "$FILE_LOCAL.new" && mv "$FILE_LOCAL.new" "$FILE_LOCAL"
}

# what the run leaves behind in your own Homebrew is undone when it ends: the
# formula put into your homebrew/core checkout, its test install, a bump
HOST_PLACED=""; HOST_INSTALLED=""; HOST_RESTORE=""; CORE_TAP=""
brew_cleanup() {
  [ -n "$CTR" ] && "$RUNTIME" rm -f "$CTR" >/dev/null 2>&1
  [ -n "$HOST_INSTALLED" ] && bx brew uninstall --formula --ignore-dependencies "$HOST_INSTALLED" >/dev/null 2>&1
  [ -n "$HOST_PLACED" ] && rm -f "$HOST_PLACED"
  [ -n "$HOST_RESTORE" ] && git -C "$CORE_TAP" checkout -q -- "$HOST_RESTORE" 2>/dev/null
  cleanup
}
trap brew_cleanup EXIT

# =============================================================== 0. orientation
cat <<BANNER

  ${B}Homebrew wizard${R}  (macOS and Linux)

  Seven stages:
    1. your app       — shared with the other distros (.store-submit.conf)
    2. where          — homebrew/core if it meets Homebrew's bar, else your own tap
    3. Homebrew       — yours, or Homebrew's own container (ghcr.io/homebrew/brew)
    4. formula        — written for your build system (an update: brew bump-formula-pr)
    5. build + check  — from source; brew test, brew audit --new --strict, brew style
    6. review         — you read it (Homebrew's rule for generated code)
    7. publish        — a pull request to homebrew/core, or pushed to your tap

BANNER
[ "$DRYRUN" = 1 ] && warn "dry run: everything up to the commit; nothing is pushed"
[ "$ASSUME_YES" = 1 ] && note "--yes: using everything detected; stopping only on problems"
for t in git curl tar sha256sum; do have "$t" || die "$t is missing — install it and re-run"; done
if [ "$HOST_BREW" = 0 ] && [ -z "$RUNTIME" ]; then
  if [ "$DRYRUN" = 1 ]; then
    warn "no brew, and no podman or docker: the formula is written, but not built or checked"
  else
    die "the formula is built and checked with Homebrew before it's published: install Homebrew (https://brew.sh), or podman or docker for Homebrew's own container (NixOS: virtualisation.podman.enable = true;)"
  fi
fi
brew_gh

# ============================================================== 1. the app
linux_app "1/7  Your app"
MAIN="$MAIN_GUESS"
GIT_EMAIL="${MAINT_EMAIL:-$(git -C "$REPO" config user.email 2>/dev/null || true)}"
[ -n "$GIT_EMAIL" ] || GIT_EMAIL="$GH_ID+$GH_USER@users.noreply.github.com"
GIT_ID=(-c "user.name=${MAINT_NAME:-$GH_USER}" -c "user.email=$GIT_EMAIL")
# the commits carry your name only — Homebrew forbids naming AI tools in commits
bcommit() { local d="$1"; shift; git -C "$d" "${GIT_ID[@]}" commit -q "$@"; }

# ================================================================= 2. where
step "2/7  homebrew/core, or your own tap"
brew_questions
[ "$NO_TEST" = 1 ] && [ "$TARGET" = core ] && die "homebrew/core asks for a local build and brew test first — --no-test is for your own tap"
if [ "$TARGET" = core ] && [ "$BREW_MODE" = new ] && [ -z "$SPDX" ]; then
  die "homebrew/core takes no formula without a license — add a LICENSE file to your app, release, and re-run"
fi

if [ "$BREW_MODE" = core-update ]; then
  [ "$CORE_VERSION" = "$VERSION" ] && { ok "homebrew/core has $BREW_NAME $VERSION already — nothing to do"; save_answers; exit 0; }
  if [ "$(printf '%s\n%s\n' "$CORE_VERSION" "$VERSION" | sort -V | tail -1)" != "$VERSION" ]; then
    die "$VERSION is older than homebrew/core's $CORE_VERSION"
  fi
  if [ "$CORE_AUTOBUMP" = true ]; then
    # BrewTestBot looks for new releases every few hours and opens the pull
    # request itself; bump-formula-pr refuses these formulae (docs.brew.sh/Autobump)
    ok "BrewTestBot updates $BREW_NAME by itself — it checks for new releases every few hours"
    BUMPPR="$(gh search prs "$BREW_NAME $VERSION" --repo "$BREW_CORE" --match title --limit 10 --json title,url,state \
      --jq ".[] | select(.title == \"$BREW_NAME $VERSION\") | \"\(.url) (\(.state))\"" 2>/dev/null | head -1 || true)"
    if [ -n "$BUMPPR" ]; then ok "its pull request for $VERSION: $BUMPPR"; else note "its pull request for $VERSION comes within hours of the release"; fi
    note "nothing to do here — https://docs.brew.sh/Autobump"
    save_answers
    exit 0
  fi
fi

PR_CHECKED=0
if [ "$TARGET" = core ]; then
  # --- someone may be on it already (the pull request template asks you to check)
  if OPEN_PRS="$(gh search prs "$BREW_NAME" --repo "$BREW_CORE" --state open --match title --limit 30 --json number,title,url \
      --jq ".[] | select((.title | startswith(\"$BREW_NAME \")) or (.title | startswith(\"$BREW_NAME:\"))) | \"#\(.number) \(.title)  \(.url)\"" 2>/dev/null)"; then
    PR_CHECKED=1
  else
    OPEN_PRS=""
  fi
  if [ -n "$OPEN_PRS" ]; then
    warn "there are open pull requests for $BREW_NAME already:"
    printf '%s\n' "$OPEN_PRS" | sed 's/^/       /'
    confirm "Carry on anyway?" n || { note "worth a look first — maybe help that one along"; exit 0; }
  fi
  if [ "$BREW_MODE" = new ]; then
    CLOSED="$(gh search prs "$BREW_NAME" --repo "$BREW_CORE" --state closed --match title --limit 30 --json number,title,url \
      --jq ".[] | select((.title | startswith(\"$BREW_NAME \")) and (.title | contains(\"new formula\"))) | \"#\(.number) \(.title)  \(.url)\"" 2>/dev/null || true)"
    if [ -n "$CLOSED" ]; then
      warn "$BREW_NAME was proposed before — Homebrew asks you to read why it wasn't taken:"
      printf '%s\n' "$CLOSED" | head -3 | sed 's/^/       /'
    fi
  fi
  # --- one AI-assisted pull request at a time, for people who aren't maintainers
  MINE="$(gh search prs --author "@me" --repo "$BREW_CORE" --state open --limit 30 --json number,title,url \
    --jq '.[] | "#\(.number) \(.title)  \(.url)"' 2>/dev/null || true)"
  if [ -n "$MINE" ]; then
    warn "you have pull requests open in homebrew/core:"
    printf '%s\n' "$MINE" | sed 's/^/       /'
    note "Homebrew lets people who aren't maintainers have one AI-assisted pull request open at a time;"
    note "this one says it was made by a script that was itself written with AI help, so it may count"
    confirm "Carry on?" n || exit 0
  fi
fi

# ============================================================== 3. Homebrew
step "3/7  Homebrew"
if [ "$HOST_BREW" = 1 ]; then
  ok "$(brew --version 2>/dev/null | head -1) — yours"
  SESSION=1
elif [ -n "$RUNTIME" ]; then
  if ! "$RUNTIME" image inspect "$BREW_IMAGE" >/dev/null 2>&1; then
    run_logged "$WORK/pull.log" "fetching Homebrew's container, $BREW_IMAGE (about 1 GB, first time only)" "$RUNTIME" pull "$BREW_IMAGE" \
      || { tail -n 4 "$WORK/pull.log" | sed 's/^/     /'; die "couldn't fetch $BREW_IMAGE"; }
  fi
  CTR="store-submit-brew-$$"
  if ! "$RUNTIME" run -d --rm --name "$CTR" -e HOMEBREW_NO_ANALYTICS=1 -e HOMEBREW_NO_AUTO_UPDATE=1 \
       -e HOMEBREW_NO_INSTALL_FROM_API=1 -e HOMEBREW_NO_ENV_HINTS=1 "$BREW_IMAGE" sleep infinity >"$WORK/ctr.log" 2>&1; then
    CTR=""; tail -n 3 "$WORK/ctr.log" | sed 's/^/     /'; die "couldn't start $BREW_IMAGE with $RUNTIME"
  fi
  ok "Homebrew's own container: $BREW_IMAGE (via $RUNTIME)"
  SESSION=1
else
  warn "no Homebrew here (dry run): the formula is written, not built or checked"
fi
BREW_VERSION=""
if [ "$SESSION" = 1 ]; then
  # the contribution guides start from an up-to-date Homebrew and homebrew/core
  run_logged "$WORK/update.log" "brew update (Homebrew and its formulae, as of now)" bx brew update \
    || { tail -n 3 "$WORK/update.log" | sed 's/^/     /'; warn "brew update failed — carrying on with what's there"; }
  BREW_VERSION="$(bx brew --version 2>/dev/null | head -1 || true)"
fi

FREF=""; REL=""; FILE_SESSION=""
mkdir -p "$CACHE/brew"
if [ "$TARGET" = core ]; then
  # --- homebrew/core: the formula is checked inside Homebrew's own core checkout
  if [ "$BREW_MODE" = core-update ]; then REL="${CORE_REL:-$(brew_rel "$BREW_NAME")}"; else REL="$(brew_rel "$BREW_NAME")"; fi
  FREF="$BREW_NAME"
  FILE_LOCAL="$CACHE/brew/$BREW_NAME.rb"
  if [ "$SESSION" = 1 ]; then
    CORE_TAP="$(bx brew --repository homebrew/core)" || die "brew --repository homebrew/core failed — is Homebrew working?"
    if ! bx test -d "$CORE_TAP/.git"; then
      [ "$HOST_BREW" = 1 ] || die "the container has no homebrew/core checkout — is $BREW_IMAGE Homebrew's own image?"
      say "Checking a formula the way homebrew/core does needs its git checkout (brew tap --force homebrew/core)."
      confirm "Tap homebrew/core now? (a clone of all its formulae, around 1 GB)" y || die "the checks need homebrew/core tapped"
      run_logged "$WORK/tap.log" "brew tap --force homebrew/core (a few minutes)" bx brew tap --force homebrew/core \
        || { tail -n 4 "$WORK/tap.log" | sed 's/^/     /'; die "couldn't tap homebrew/core"; }
    fi
    FILE_SESSION="$CORE_TAP/$REL"
    if [ "$HOST_BREW" = 1 ]; then
      if [ "$BREW_MODE" = new ]; then
        # put there for the checks only; taken out again when the wizard ends
        git -C "$CORE_TAP" ls-files --error-unmatch "$REL" >/dev/null 2>&1 || HOST_PLACED="$FILE_SESSION"
      else
        git -C "$CORE_TAP" diff --quiet -- "$REL" || die "$CORE_TAP has changes of yours in $REL — commit or discard them, then re-run"
        HOST_RESTORE="$REL"
      fi
    fi
    ok "homebrew/core: $REL"
  fi
else
  # --- your tap: a clone of it, or a new one from Homebrew's template
  FREF="$TAPREF/$BREW_NAME"
  TAP_EXISTS=0; TAP_BRANCH=main
  if gh api "repos/$BREW_TAP" >/dev/null 2>&1; then
    TAP_EXISTS=1; TAP_BRANCH="$(gh api "repos/$BREW_TAP" --jq .default_branch 2>/dev/null || echo main)"
  fi
  # made on GitHub but still empty: a first push that didn't go through
  if [ "$TAP_EXISTS" = 1 ] && [ -z "$(git ls-remote --heads "https://github.com/$BREW_TAP.git" 2>/dev/null)" ]; then
    TAP_EXISTS=2; TAP_BRANCH=main
  fi
  # your own brew works on its tap directory, which is yours: brought up to
  # GitHub's state, never overwritten. The container works on the wizard's own
  # clone in the cache, which starts from GitHub's state every run.
  if [ "$HOST_BREW" = 1 ]; then TAP_WT="$(brew --repository "$BREW_TAP")" || die "brew --repository $BREW_TAP failed"; else TAP_WT="$CACHE/brew/tap/$BREW_TAP"; fi
  if [ "$TAP_EXISTS" = 1 ]; then
    if [ "$HOST_BREW" = 1 ] && [ -d "$TAP_WT/.git" ]; then
      [ -z "$(git -C "$TAP_WT" status --porcelain)" ] || die "$TAP_WT has changes of yours that aren't committed — commit or discard them, then re-run"
      git -C "$TAP_WT" fetch -q "https://github.com/$BREW_TAP.git" "$TAP_BRANCH" || die "couldn't fetch https://github.com/$BREW_TAP"
      git -C "$TAP_WT" checkout -q "$TAP_BRANCH" 2>/dev/null || git -C "$TAP_WT" checkout -q -b "$TAP_BRANCH" FETCH_HEAD
      { git -C "$TAP_WT" merge -q --ff-only FETCH_HEAD 2>/dev/null \
          && [ "$(git -C "$TAP_WT" rev-parse HEAD)" = "$(git -C "$TAP_WT" rev-parse FETCH_HEAD)" ]; } \
        || die "your tap in $TAP_WT has commits that aren't on GitHub — push or drop them, then re-run"
    else
      [ "$HOST_BREW" = 1 ] && [ -e "$TAP_WT" ] && die "$TAP_WT exists but isn't a git checkout — move it aside and re-run"
      rm -rf "$TAP_WT"; mkdir -p "$(dirname "$TAP_WT")"
      run_logged "$WORK/tapclone.log" "fetching your tap ($BREW_TAP)" git clone -q --branch "$TAP_BRANCH" "https://github.com/$BREW_TAP.git" "$TAP_WT" \
        || { tail -n 3 "$WORK/tapclone.log" | sed 's/^/     /'; die "couldn't clone https://github.com/$BREW_TAP"; }
    fi
    ok "your tap: https://github.com/$BREW_TAP"
  elif [ "$HOST_BREW" = 1 ] && [ -d "$TAP_WT/.git" ] && [ -z "$(git -C "$TAP_WT" remote)" ]; then
    ok "your new tap, from an earlier run: $TAP_WT (it goes to GitHub when you publish)"
  else
    if [ -e "$TAP_WT" ]; then
      [ "$HOST_BREW" = 1 ] && die "$TAP_WT exists, but https://github.com/$BREW_TAP has nothing — push it there, or move it aside, then re-run"
      rm -rf "$TAP_WT"
    fi
    if [ "$SESSION" = 1 ]; then
      # Homebrew's template: README and the GitHub Actions that test the tap (brew tap-new)
      if [ "$HOST_BREW" = 1 ]; then
        bx brew tap-new --no-git "$BREW_TAP" >"$WORK/tapnew.log" 2>&1 \
          || { tail -n 3 "$WORK/tapnew.log" | sed 's/^/     /'; die "brew tap-new failed"; }
      else
        mkdir -p "$TAP_WT"
        bx sh -c 'brew tap-new --no-git "$1" >/dev/null && tar -C "$(brew --repository "$1")" -cf - .' sh "$BREW_TAP" \
          | tar -xf - -C "$TAP_WT"
        [ -f "$TAP_WT/README.md" ] || die "brew tap-new failed in the container"
      fi
    else
      # no Homebrew in this dry run: the README brew tap-new writes; its
      # GitHub Actions workflows come with a real run
      mkdir -p "$TAP_WT/Formula"
      printf '# %s\n\n## How do I install these formulae?\n\n`brew install %s/<formula>`\n\nOr `brew tap %s` and then `brew install <formula>`.\n' \
        "$BREW_TAP" "$TAPREF" "$TAPREF" > "$TAP_WT/README.md"
      warn "without Homebrew, the new tap gets no GitHub Actions workflows (brew tap-new adds them in a real run)"
    fi
    git -C "$TAP_WT" init -q -b "$TAP_BRANCH"
    git -C "$TAP_WT" add -A
    bcommit "$TAP_WT" -m "Create $TAPREF tap"
    ok "new tap $BREW_TAP, from Homebrew's template — it goes to GitHub when you publish"
  fi
  # the formula in it: an update if your tap has it already
  REL=""
  for f in "Formula/$BREW_NAME.rb" "Formula/$(printf '%s' "$BREW_NAME" | cut -c1)/$BREW_NAME.rb" "HomebrewFormula/$BREW_NAME.rb" "$BREW_NAME.rb"; do
    [ -f "$TAP_WT/$f" ] && { REL="$f"; break; }
  done
  if [ -n "$REL" ]; then
    grep -qiF "$SLUG" "$TAP_WT/$REL" || die "your tap's $REL is a different app (it doesn't mention $SLUG) — pick another formula name (brew-name in the config)"
    BREW_MODE=tap-update
  else
    REL="Formula/$BREW_NAME.rb"
  fi
  FILE_LOCAL="$TAP_WT/$REL"
  if [ "$SESSION" = 1 ]; then
    TAP_IN="$(bx brew --repository "$BREW_TAP")" || die "brew --repository $BREW_TAP failed"
    if [ "$HOST_BREW" = 0 ]; then
      tar -C "$TAP_WT" -cf - . | bxi sh -c 'rm -rf "$1" && mkdir -p "$1" && tar -xf - -C "$1"' sh "$TAP_IN" \
        || die "couldn't copy your tap into the container"
    fi
    FILE_SESSION="$TAP_IN/$REL"
  fi
  if [ "$BREW_MODE" = tap-update ]; then
    OLD_VERSION=""
    if [ "$SESSION" = 1 ]; then
      trust_it
      OLD_VERSION="$(bx brew info --json=v2 "$FREF" 2>/dev/null | tool jq jq -r '.formulae[0].versions.stable // ""' 2>/dev/null || true)"
    fi
    if [ -n "$OLD_VERSION" ]; then
      [ "$OLD_VERSION" = "$VERSION" ] && { ok "your tap has $BREW_NAME $VERSION already — nothing to do"; save_answers; exit 0; }
      [ "$(printf '%s\n%s\n' "$OLD_VERSION" "$VERSION" | sort -V | tail -1)" = "$VERSION" ] || die "$VERSION is older than your tap's $OLD_VERSION"
    fi
    ok "your tap has $BREW_NAME${OLD_VERSION:+ $OLD_VERSION} — this is an update"
  fi
fi

# =============================================================== 4. formula
step "4/7  The formula"
if [ "$BREW_MODE" != new ]; then
  # ------------------------------------------------------------------ update
  # brew bump-formula-pr is Homebrew's tool for this: the new version, the
  # URL, its sha256 and (for Python) the resources. It edits the formula only
  # here (--write-only); stage 7 makes the commit and the pull request.
  [ "$SESSION" = 1 ] || { warn "dry run without Homebrew: brew bump-formula-pr makes the update, and needs Homebrew"; save_answers; exit 0; }
  [ "${DRY_NO_TAG:-0}" = 1 ] && { warn "dry run stops here: tag $TAG isn't online, so the update can't fetch it"; save_answers; exit 0; }
  if [ "$TARGET" = core ]; then
    bx git -C "$CORE_TAP" show "HEAD:$REL" > "$WORK/base.rb" || die "can't read $REL in homebrew/core"
    cp "$WORK/base.rb" "$FILE_LOCAL"
  else
    cp "$FILE_LOCAL" "$WORK/base.rb"
  fi
  trust_it
  if run_logged "$WORK/bump.log" "brew bump-formula-pr --write-only $FREF → $VERSION" \
      bxt brew bump-formula-pr --write-only --no-audit --version="$VERSION" "$FREF"; then
    brew_get "$FILE_SESSION" "$FILE_LOCAL"
    cmp -s "$WORK/base.rb" "$FILE_LOCAL" && die "brew bump-formula-pr changed nothing — see $WORK/bump.log"
    ok "bumped to $VERSION by brew bump-formula-pr"
  else
    tail -n 8 "$WORK/bump.log" | sed 's/^/     /'
    KEEP_WORK=1; die "brew bump-formula-pr couldn't update $FREF — log: $WORK/bump.log"
  fi
else
  # ------------------------------------------------------------- new formula
  # --- the license, as Homebrew writes it
  LICENSE_RB="$(brew_license "$SPDX" || true)"
  if [ -z "$LICENSE_RB" ]; then
    if [ -z "$SPDX" ]; then warn "no license found — the formula goes without one (homebrew/core wouldn't take that)"
    else warn "'$SPDX' needs writing by hand in Homebrew's terms (any_of:, all_of:, with:) — https://docs.brew.sh/Licence-Guidelines"; LICENSE_RB="\"$SPDX\""; fi
  fi

  # --- the source: PyPI's or npm's release when it's published there (Homebrew
  # prefers those), else the forge's tarball of the tag, checksummed
  SRC_URL=""; SRC_SHA=""; SRC_SPEC=""; SRC_FROM=forge
  case "$KIND" in
    python)
      PYNAME="$(at "$TAG_REF" pyproject.toml | toml_get project name)"
      if [ -n "$PYNAME" ] && PJ="$(curl -sf --max-time 20 "https://pypi.org/pypi/$PYNAME/$VERSION/json")"; then
        SRC_URL="$(printf '%s' "$PJ" | tool jq jq -r '[.urls[] | select(.packagetype == "sdist")][0].url // ""' || true)"
        SRC_SHA="$(printf '%s' "$PJ" | tool jq jq -r '[.urls[] | select(.packagetype == "sdist")][0].digests.sha256 // ""' || true)"
        [ -n "$SRC_URL" ] && SRC_FROM=pypi
      fi ;;
    node)
      NPMNAME="$(at "$TAG_REF" package.json | tool jq jq -r '.name // ""' 2>/dev/null || true || true)"
      if [ -n "$NPMNAME" ] && NJ="$(curl -sf --max-time 20 "https://registry.npmjs.org/$(printf '%s' "$NPMNAME" | sed 's#/#%2F#')/$VERSION")"; then
        SRC_URL="$(printf '%s' "$NJ" | tool jq jq -r '.dist.tarball // ""' || true)"
        [ -n "$SRC_URL" ] && SRC_FROM=npm
      fi ;;
  esac
  if [ -z "$SRC_URL" ]; then
    case "$FORGE" in
      github)   SRC_URL="https://github.com/$SLUG/archive/refs/tags/$TAG.tar.gz" ;;
      gitlab)   SRC_URL="https://gitlab.com/$SLUG/-/archive/$TAG/$REPONAME-$TAG.tar.gz" ;;
      codeberg) SRC_URL="https://codeberg.org/$SLUG/archive/$TAG.tar.gz" ;;
      *)        SRC_FROM=git
                SRC_URL="$(printf '%s' "$ORIGIN" | sed -E 's#^[^@/]+@([^:]+):#https://\1/#')"
                SRC_SPEC=", tag: \"$(rb_str "$TAG")\", revision: \"$(git -C "$REPO" rev-parse "$TAG_REF^{commit}")\"" ;;
    esac
  fi
  if [ -z "$SRC_SHA" ] && [ "$SRC_FROM" != git ]; then
    if [ "${DRY_NO_TAG:-0}" = 1 ]; then
      warn "dry run, and tag $TAG isn't online: no checksum yet"
    else
      run_logged "$WORK/download.log" "downloading $SRC_URL" curl -fL --retry 3 -o "$WORK/src.tar.gz" "$SRC_URL" \
        || { tail -n 3 "$WORK/download.log" | sed 's/^/     /'; die "couldn't download $SRC_URL — is tag $TAG pushed?"; }
      SRC_SHA="$(sha256sum "$WORK/src.tar.gz" | cut -d' ' -f1)"
    fi
  fi
  case "$SRC_FROM" in
    pypi) ok "source: PyPI's release of $PYNAME $VERSION" ;;
    npm)  ok "source: npm's release of $NPMNAME $VERSION" ;;
    *)    ok "source: $SRC_URL" ;;
  esac
  HEAD_URL=""; DEFBRANCH=""
  if [ "$FORGE" != git ] && [ -s "$WORK/forge.json" ]; then
    DEFBRANCH="$(tool jq jq -r '.default_branch // ""' < "$WORK/forge.json" 2>/dev/null || true)"
    [ -n "$DEFBRANCH" ] && HEAD_URL="$WEB.git"
  fi

  # --- how it builds: Homebrew's helpers for each build system
  BDEPS=(); DEPS=(); MDEPS=(); LDEPS=(); ENVS=(); FETCH=(); INSTALL=()
  NET="deny_network_access!"; INC=""
  case "$KIND" in
    rust)
      BDEPS+=(rust)
      # -sys crates that link a system library: the formula for it
      for crate in $(at "$TAG_REF" Cargo.lock | sed -nE 's/^name = "([a-z0-9_-]+-sys)"$/\1/p' | sort -u); do
        case "$crate" in
          openssl-sys)    BDEPS+=(pkgconf); DEPS+=(openssl@3) ;;
          libgit2-sys)    BDEPS+=(pkgconf); DEPS+=(libgit2); ENVS+=('ENV["LIBGIT2_NO_VENDOR"] = "1"') ;;
          libssh2-sys)    BDEPS+=(pkgconf); DEPS+=(libssh2) ;;
          zstd-sys)       BDEPS+=(pkgconf); DEPS+=(zstd) ;;
          lzma-sys)       DEPS+=(xz) ;;
          libz-sys)       MDEPS+=(zlib) ;;
          bzip2-sys)      MDEPS+=(bzip2) ;;
          libsqlite3-sys) MDEPS+=(sqlite) ;;
          curl-sys)       MDEPS+=(curl) ;;
          libdbus-sys)    BDEPS+=(pkgconf); DEPS+=(dbus) ;;
          alsa-sys)       BDEPS+=(pkgconf); LDEPS+=(alsa-lib) ;;
          libudev-sys)    BDEPS+=(pkgconf); LDEPS+=(systemd) ;;
          gtk4-sys)       BDEPS+=(pkgconf); DEPS+=(gtk4) ;;
          gtk-sys)        BDEPS+=(pkgconf); DEPS+=(gtk+3) ;;
          libadwaita-sys) BDEPS+=(pkgconf); DEPS+=(libadwaita) ;;
          glib-sys)       BDEPS+=(pkgconf); DEPS+=(glib) ;;
        esac
      done
      # a workspace: the member that builds the program
      CRATE=""
      if ! at "$TAG_REF" Cargo.toml | grep -q '^\[package\]'; then
        for m in $(grep -E '^[^/]+(/[^/]+)?/Cargo\.toml$' "$WORK/tree.txt" | sed 's#/Cargo\.toml$##'); do
          n="$(at "$TAG_REF" "$m/Cargo.toml" | toml_get package name)"
          if [ "$n" = "$MAIN" ] || [ "$n" = "$BREW_NAME" ] || [ "$n" = "$PNAME" ]; then CRATE="$m"; break; fi
        done
        [ -n "$CRATE" ] || CRATE="$(grep -E '^[^/]+(/[^/]+)?/src/main\.rs$' "$WORK/tree.txt" | head -1 | sed 's#/src/main\.rs$##')"
        if [ -n "$CRATE" ]; then ok "a Cargo workspace: the formula builds $CRATE"
        else warn "a Cargo workspace, and no member builds $MAIN — give std_cargo_args the path by hand"; fi
      fi
      FETCH=('system "cargo", "fetch", *std_cargo_fetch_args')
      INSTALL=("system \"cargo\", \"install\", *std_cargo_args${CRATE:+(path: \"$CRATE\")}") ;;
    go)
      BDEPS+=(go)
      GOTARGET=""
      if in_tree "cmd/$MAIN/main.go"; then GOTARGET="./cmd/$MAIN"
      elif ! in_tree main.go && grep -qE '^cmd/[^/]+/main\.go$' "$WORK/tree.txt"; then
        GOTARGET="./$(grep -E '^cmd/[^/]+/main\.go$' "$WORK/tree.txt" | head -1 | sed 's#/main\.go$##')"
      fi
      GOARGS=""
      [ "$MAIN" != "$BREW_NAME" ] && GOARGS="output: bin/\"$MAIN\""
      if git -C "$REPO" grep -qE '^[[:space:]]*(var[[:space:]]+)?version[[:space:]]+(=|string)' "$TAG_REF" -- main.go 'cmd/*/main.go' 2>/dev/null; then
        GOARGS="${GOARGS:+$GOARGS, }ldflags: \"-X main.version=#{version}\""
      fi
      # vendored modules build as they are; otherwise def fetch downloads them
      in_tree vendor/modules.txt || FETCH=('system "go", "mod", "download"')
      INSTALL=("system \"go\", \"build\", *std_go_args${GOARGS:+($GOARGS)}${GOTARGET:+, \"$GOTARGET\"}") ;;
    python)
      INC="  include Language::Python::Virtualenv"
      DEPS+=("$(brew_python)")
      NET=""   # pip fetches the build backend while it builds
      if [ "$SRC_FROM" != pypi ] && at "$TAG_REF" pyproject.toml | grep -qiE 'setuptools[-_]scm|hatch-vcs'; then
        ENVS+=('ENV["SETUPTOOLS_SCM_PRETEND_VERSION"] = version.to_s')
      fi
      INSTALL=('virtualenv_install_with_resources') ;;
    node)
      DEPS+=(node)
      NET=""   # npm installs the dependencies while it builds
      if [ "$SRC_FROM" != npm ] && [ -n "$(at "$TAG_REF" package.json | tool jq jq -r '.scripts.build // ""' 2>/dev/null || true)" ]; then
        INSTALL=('system "npm", "install", *std_npm_args(prefix: false)' 'system "npm", "run", "build"'
                 'system "npm", "install", *std_npm_args' 'bin.install_symlink libexec.glob("bin/*")')
      else
        INSTALL=('system "npm", "install", *std_npm_args' 'bin.install_symlink libexec.glob("bin/*")')
      fi ;;
    meson|cmake)
      if [ "$KIND" = meson ]; then
        BDEPS+=(meson ninja)
        PCS="$(for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done \
               | grep -oE "dependency\([[:space:]]*'[^']+'" | sed -E "s/.*'([^']+)'/\\1/" | sort -u)"
        INSTALL=('system "meson", "setup", "build", *std_meson_args' 'system "meson", "compile", "-C", "build", "--verbose"'
                 'system "meson", "install", "-C", "build"')
      else
        BDEPS+=(cmake)
        PCS="$(at "$TAG_REF" CMakeLists.txt | tr '\n' ' ' | grep -oE 'pkg_check_modules\([^)]*\)' \
               | sed -E 's/^pkg_check_modules\(//; s/\)$//' \
               | awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^(REQUIRED|QUIET|IMPORTED_TARGET|GLOBAL)$/) { m = $i; sub(/[<>=].*/, "", m); if (m != "") print m } }' | sort -u)"
        INSTALL=('system "cmake", "-S", ".", "-B", "build", *std_cmake_args' 'system "cmake", "--build", "build"'
                 'system "cmake", "--install", "build"')
      fi
      [ -n "$PCS" ] && BDEPS+=(pkgconf)
      for pc in $PCS; do
        case "$pc" in threads|m|dl|rt|dependency) continue ;; esac
        d="$(brew_pc "$pc")"
        case "$d" in mac:*) MDEPS+=("${d#mac:}") ;; linux:*) LDEPS+=("${d#linux:}") ;; *) DEPS+=("${d#dep:}") ;; esac
      done ;;
    make)
      INSTALL=('system "make", "install", "PREFIX=#{prefix}"') ;;
  esac
  # every dependency has to be a Homebrew formula
  KEEP=()
  for d in $(printf '%s\n' ${DEPS[@]+"${DEPS[@]}"} | awk 'NF' | sort -u); do
    case "$d" in python@*|node|openssl@3) KEEP+=("$d"); continue ;; esac
    if [ -n "$(brew_api formula "$d")" ]; then KEEP+=("$d")
    else warn "no Homebrew formula named '$d' — left out; the build will say if it's needed"; fi
  done
  DEPS=(${KEEP[@]+"${KEEP[@]}"})

  # --- the formula, in the order Homebrew's style checks want
  uniq_sorted() { printf '%s\n' "$@" | awk 'NF' | sort -u; }
  {
    printf 'class %s < Formula\n' "$(brew_class "$BREW_NAME")"
    [ -n "$INC" ] && printf '%s\n\n' "$INC"
    printf '  desc "%s"\n' "$(rb_str "$BDESC")"
    printf '  homepage "%s"\n' "$(rb_str "$HOMEPAGE")"
    printf '  url "%s"%s\n' "$(rb_str "$SRC_URL")" "$SRC_SPEC"
    [ "$SRC_FROM" != git ] && printf '  sha256 "%s"\n' "$SRC_SHA"
    [ -n "$LICENSE_RB" ] && printf '  license %s\n' "$LICENSE_RB"
    [ -n "$HEAD_URL" ] && printf '  head "%s", branch: "%s"\n' "$HEAD_URL" "$(rb_str "$DEFBRANCH")"
    printf '\n'
    g=0
    for d in $(uniq_sorted ${BDEPS[@]+"${BDEPS[@]}"}); do printf '  depends_on "%s" => :build\n' "$d"; g=1; done
    for d in $(uniq_sorted ${DEPS[@]+"${DEPS[@]}"}); do printf '  depends_on "%s"\n' "$d"; g=1; done
    [ "$g" = 1 ] && printf '\n'
    g=0
    for d in $(uniq_sorted ${MDEPS[@]+"${MDEPS[@]}"}); do printf '  uses_from_macos "%s"\n' "$d"; g=1; done
    [ "$g" = 1 ] && printf '\n'
    if [ "${#LDEPS[@]}" -gt 0 ]; then
      printf '  on_linux do\n'
      for d in $(uniq_sorted "${LDEPS[@]}"); do printf '    depends_on "%s"\n' "$d"; done
      printf '  end\n\n'
    fi
    [ -n "$NET" ] && printf '  %s\n\n' "$NET"
    if [ "${#FETCH[@]}" -gt 0 ]; then printf '  def fetch\n'; printf '    %s\n' "${FETCH[@]}"; printf '  end\n\n'; fi
    printf '  def install\n'
    [ "${#ENVS[@]}" -gt 0 ] && printf '    %s\n' "${ENVS[@]}"
    printf '    %s\n' "${INSTALL[@]}"
    printf '  end\n\n'
    brew_test_block
    printf 'end\n'
  } > "$FILE_LOCAL"
  ok "wrote $BREW_NAME.rb ($KIND)"

  if [ "${DRY_NO_TAG:-0}" = 1 ]; then
    echo; sed 's/^/     /' "$FILE_LOCAL"; echo
    warn "dry run stops here: tag $TAG isn't online, so Homebrew can't fetch the source to build it"
    note "the draft is in $FILE_LOCAL; push the tag and run without -n"
    save_answers
    exit 0
  fi

  if [ "$SESSION" = 1 ]; then
    brew_put "$FILE_LOCAL" "$FILE_SESSION"; trust_it
    # Python: every dependency becomes a resource with its own checksum, as
    # homebrew/core requires — written by Homebrew's own tool
    if [ "$KIND" = python ]; then
      PYARGS=(--install-dependencies); [ "$TARGET" = tap ] && PYARGS+=(--ignore-main-package-cooldown)
      if run_logged "$WORK/pyres.log" "brew update-python-resources (each Python dependency, pinned)" \
          bxt brew update-python-resources "${PYARGS[@]}" "$FREF"; then
        brew_get "$FILE_SESSION" "$FILE_LOCAL"
        ok "$(grep -c '^  resource "' "$FILE_LOCAL" || true) Python resources, each with its checksum"
      else
        tail -n 8 "$WORK/pyres.log" | sed 's/^/     /'
        KEEP_WORK=1; die "brew update-python-resources failed — log: $WORK/pyres.log"
      fi
    fi
    # the version Homebrew reads from the URL must be the release's
    BV="$(bx brew info --json=v2 "$FREF" 2>"$WORK/info.err" | tool jq jq -r '.formulae[0].versions.stable // ""' 2>/dev/null || true)"
    if [ -z "$BV" ]; then
      tail -n 5 "$WORK/info.err" | sed 's/^/     /'
      KEEP_WORK=1; die "Homebrew can't read the formula — a bug in the wizard; it's in $FILE_LOCAL"
    fi
    if [ "$BV" != "$VERSION" ]; then
      awk -v v="$(rb_str "$VERSION")" '{ print } !done && /^  url / { print "  version \"" v "\""; done = 1 }' "$FILE_LOCAL" > "$FILE_LOCAL.new" \
        && mv "$FILE_LOCAL.new" "$FILE_LOCAL"
      brew_put "$FILE_LOCAL" "$FILE_SESSION"
      ok "version \"$VERSION\" written out (Homebrew reads $BV from the URL)"
    fi
  fi
fi

# ========================================================= 5. build + check
step "5/7  Build and check"
BUILT=0; TESTED=0; AUDIT_OK=0; STYLE_OK=0; CHECKS_OK=0
if [ "$SESSION" = 0 ]; then
  warn "not built or checked — no Homebrew here"
elif [ "$NO_TEST" = 1 ]; then
  warn "--no-test: not built or checked"
else
  brew_put "$FILE_LOCAL" "$FILE_SESSION"; trust_it
  # --- built from source, the way the pull request template asks
  while :; do
    if run_logged "$WORK/install.log" "building $BREW_NAME from source (brew install --build-from-source — a while)" \
        bx sh -c 'if brew list --formula "$1" >/dev/null 2>&1; then exec brew reinstall --build-from-source --verbose "$1"; fi
                  exec brew install --build-from-source --verbose "$1"' sh "$FREF"; then
      ok "built from source and installed"
      BUILT=1
      # in your own Homebrew, a formula that isn't published yet comes off again at the end
      if [ "$HOST_BREW" = 1 ] && [ "$BREW_MODE" = new ] && { [ "$TARGET" = core ] || [ "$DRYRUN" = 1 ]; }; then
        HOST_INSTALLED="$FREF"
      fi
      break
    fi
    brew_explain "$WORK/install.log"
    [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "the build failed (log: $WORK/install.log)"; }
    say "e) edit the formula (in ${EDITOR:-vi}), then build again     l) read the whole log"
    say "r) build again as it is     q) quit"
    ask CHOICE "Choice" "e"
    case "$CHOICE" in
      e|E) "${EDITOR:-vi}" "$FILE_LOCAL"; brew_put "$FILE_LOCAL" "$FILE_SESSION" ;;
      l|L) "${PAGER:-less}" "$WORK/install.log" || cat "$WORK/install.log" ;;
      q|Q) note "the formula is in $FILE_LOCAL; re-run to pick it up again"; exit 1 ;;
    esac
  done

  # --- the programs it installs, and what they answer — that picks the test
  BINS="$(bx sh -c 'for f in "$(brew --prefix "$1")"/bin/*; do [ -x "$f" ] && printf "%s\n" "${f##*/}"; done; true' sh "$FREF" 2>/dev/null || true)"
  if [ -z "$BINS" ]; then
    warn "it installs no programs (nothing in bin/)"
  elif printf '%s\n' "$BINS" | grep -qxF "$MAIN" || [ "$BREW_MODE" != new ]; then
    ok "installs: $(printf '%s' "$BINS" | tr '\n' ' ')"
  else
    say "It installs: $(printf '%s' "$BINS" | tr '\n' ' ')"
    ask MAIN "Which one is the main program? (the test uses it)" "$(printf '%s\n' "$BINS" | head -1)"
  fi
  if [ "$BREW_MODE" = new ]; then
    T_KIND=none; T_ERR=""
    if [ -n "$BINS" ]; then
      bx sh -c 'p="$(brew --prefix "$1")/bin/$2"; [ -x "$p" ] || exit 0
        o="$(timeout 20 "$p" --version </dev/null 2>/dev/null)"; r=$?
        printf "V1: %s %s\n" "$r" "$(printf "%s" "$o" | head -c 300 | tr "\n" " ")"
        o="$(timeout 20 "$p" --version </dev/null 2>&1)"; r=$?
        printf "V2: %s %s\n" "$r" "$(printf "%s" "$o" | head -c 300 | tr "\n" " ")"
        timeout 20 "$p" --help </dev/null >/dev/null 2>&1; printf "H: %s\n" "$?"' sh "$FREF" "$MAIN" > "$WORK/probe.txt" 2>&1 || true
      V1="$(sed -n 's/^V1: //p' "$WORK/probe.txt")"; V2="$(sed -n 's/^V2: //p' "$WORK/probe.txt")"
      if [ "${V1%% *}" = 0 ] && printf '%s' "$V1" | grep -qF "$VERSION"; then T_KIND=version
      elif [ "${V2%% *}" = 0 ] && printf '%s' "$V2" | grep -qF "$VERSION"; then T_KIND=version; T_ERR=" 2>&1"
      elif [ "$(sed -n 's/^H: //p' "$WORK/probe.txt")" = 0 ]; then T_KIND=help; fi
    fi
    case "$T_KIND" in
      version) ok "$MAIN --version prints $VERSION — the test checks it" ;;
      help)    warn "$MAIN --version doesn't print $VERSION; the test runs $MAIN --help" ;;
      none)    warn "${MAIN:-it} answers neither --version nor --help here" ;;
    esac
    if [ -z "$BREW_TEST" ] && [ "$TARGET" = core ]; then
      warn "homebrew/core's reviewers ask for a test that uses the app — --version alone is a \"bad test\" to them"
      if [ "$ASSUME_YES" = 0 ] && [ -n "$MAIN" ]; then
        ask_opt BREW_TEST "A command that exercises $MAIN (in an empty folder, no network; Enter skips)" ""
        if [ -n "$BREW_TEST" ]; then
          ask BREW_EXPECT "Text its output should contain" ""
          [ "$SAVE" = 1 ] && { cfg_set brew-test "$BREW_TEST"; cfg_set brew-test-expect "$BREW_EXPECT"; }
        fi
      fi
    fi
    set_test_block
    brew_put "$FILE_LOCAL" "$FILE_SESSION"
  fi

  # --- brew test: the formula's own test
  while :; do
    if run_logged "$WORK/test.log" "brew test $FREF" bx brew test --verbose "$FREF"; then ok "brew test passes"; TESTED=1; break; fi
    bad "brew test fails:"
    grep -vE '^\s*$' "$WORK/test.log" | tail -n 12 | cut -c1-200 | sed 's/^/     /'
    [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "brew test failed (log: $WORK/test.log)"; }
    say "e) edit the test (in ${EDITOR:-vi}), then test again     r) test again     s) skip     q) quit"
    ask CHOICE "Choice" "e"
    case "$CHOICE" in
      e|E) "${EDITOR:-vi}" "$FILE_LOCAL"; brew_put "$FILE_LOCAL" "$FILE_SESSION" ;;
      s|S) warn "brew test doesn't pass — Homebrew's CI runs it too"; break ;;
      q|Q) note "the formula is in $FILE_LOCAL; re-run to pick it up again"; exit 1 ;;
    esac
  done

  # --- brew style: Homebrew's RuboCop rules; what it can fix, it fixes
  bx brew style --fix --formula "$FREF" >"$WORK/style.log" 2>&1 || true
  brew_get "$FILE_SESSION" "$FILE_LOCAL"
  if bx brew style --formula "$FREF" >"$WORK/style.log" 2>&1; then
    ok "brew style: no offenses"; STYLE_OK=1
  else
    bad "brew style has offenses it can't fix by itself:"
    grep -E ':[0-9]+:[0-9]+: ' "$WORK/style.log" | head -10 | cut -c1-200 | sed 's/^/       /'
  fi

  # --- brew audit: what Homebrew's CI and reviewers check
  AUDIT_ARGS=(--strict --online --formula); [ "$BREW_MODE" = new ] && AUDIT_ARGS=(--new "${AUDIT_ARGS[@]}")
  if run_logged "$WORK/audit.log" "brew audit ${AUDIT_ARGS[*]} $FREF" bxt brew audit "${AUDIT_ARGS[@]}" "$FREF"; then
    ok "brew audit: no problems"; AUDIT_OK=1
  else
    bad "brew audit found problems:"
    grep -E '^[[:space:]]+\* |^Error: ' "$WORK/audit.log" | head -15 | cut -c1-200 | sed 's/^/       /'
  fi
  [ "$BUILT" = 1 ] && [ "$TESTED" = 1 ] && [ "$STYLE_OK" = 1 ] && [ "$AUDIT_OK" = 1 ] && CHECKS_OK=1
  if [ "$CHECKS_OK" = 0 ]; then
    [ "$ASSUME_YES" = 1 ] && { KEEP_WORK=1; die "checks failed (✗ above) — logs in $WORK"; }
    note "the formula is in $FILE_LOCAL — edit it and run again, or carry on and fix it in review"
    confirm "Some checks failed (✗). Carry on anyway?" n || { KEEP_WORK=1; exit 1; }
  fi
  [ -n "$HOST_INSTALLED" ] && note "the test install comes off your Homebrew again when the wizard ends"
fi

# ================================================================ 6. review
step "6/7  Review"
if [ "$BREW_MODE" = new ]; then
  echo; sed 's/^/     /' "$FILE_LOCAL"; echo
else
  echo; diff -u "$WORK/base.rb" "$FILE_LOCAL" | tail -n +3 | sed 's/^/     /'; echo
fi
SELF_OK=0
if [ "$TARGET" = core ]; then
  if [ "$BREW_MODE" = new ] && [ "$ASSUME_YES" = 1 ]; then
    handoff_add "Read the formula ($FILE_LOCAL) — Homebrew wants a person to review generated code before anyone else is asked to"
    handoff_add "Run linux-submit.sh brew again without --yes: it opens the pull request once you say you stand behind it"
    save_answers
    handoff_show "Your turn — homebrew/core wants you to review the formula first"
    exit 0
  elif [ "$ASSUME_YES" = 0 ]; then
    say "Homebrew's rules for pull requests made with tools (docs.brew.sh/Responsible-AI-Usage):"
    say "you review generated code before asking anyone else to, and you answer the reviewers"
    say "yourself, without AI. The pull request says how the formula was made."
    if [ "$BREW_MODE" = new ]; then
      confirm "Have you read it, and will you answer Homebrew's reviewers yourself?" n \
        || { note "the formula is in $FILE_LOCAL — run again when you're ready"; exit 1; }
      SELF_OK=1
    else
      confirm "Will you answer Homebrew's reviewers yourself?" y && SELF_OK=1
    fi
  fi
fi

# ================================================================ 7. publish
if [ "$TARGET" = core ]; then
step "7/7  Pull request to homebrew/core"
# --- your fork: usually <you>/homebrew-core; else any fork of it you own
FORK_NAME=""
if [ "$(gh api "repos/$GH_USER/homebrew-core" --jq 'select(.fork) | .parent.full_name' 2>/dev/null || true)" = "$BREW_CORE" ]; then
  FORK_NAME=homebrew-core
else
  FORK_NAME="$(gh repo list "$GH_USER" --fork --limit 1000 --json name,parent \
    --jq '.[] | select(.parent.owner.login == "Homebrew" and .parent.name == "homebrew-core") | .name' 2>/dev/null | head -1 || true)"
fi
if [ -n "$FORK_NAME" ]; then
  ok "fork: https://github.com/$GH_USER/$FORK_NAME"
elif [ "$DRYRUN" = 1 ]; then
  warn "dry run — would fork $BREW_CORE to $GH_USER/homebrew-core"; FORK_NAME=homebrew-core
elif go "Fork $BREW_CORE to $GH_USER/homebrew-core (main branch only)?"; then
  gh repo fork "$BREW_CORE" --clone=false --default-branch-only >"$WORK/fork.log" 2>&1 \
    || gh repo fork "$BREW_CORE" --clone=false >"$WORK/fork.log" 2>&1 \
    || { sed 's/^/     /' "$WORK/fork.log"; die "GitHub refused the fork — try https://github.com/$BREW_CORE/fork, then re-run"; }
  FORK_NAME="$(grep -oE "$GH_USER/[A-Za-z0-9._-]+" "$WORK/fork.log" | head -1 | cut -d/ -f2)"
  FORK_NAME="${FORK_NAME:-homebrew-core}"
  # GitHub copies it in the background; wait until it answers
  for _ in $(seq 1 60); do gh api "repos/$GH_USER/$FORK_NAME" >/dev/null 2>&1 && break; sleep 3; done
  gh api "repos/$GH_USER/$FORK_NAME" >/dev/null 2>&1 || die "the fork didn't appear after 3 minutes — check https://github.com/$GH_USER?tab=repositories and re-run"
  ok "forked: https://github.com/$GH_USER/$FORK_NAME"
else
  die "the pull request comes from a fork"
fi

# --- the branch: homebrew-core's latest commit only, and of its files only
# the ones this needs (sparse) — a few MB instead of a full clone
CORE_WT="$CACHE/brew/homebrew-core"
if [ -d "$CORE_WT/.git" ]; then
  run_logged "$WORK/corefetch.log" "fetching homebrew-core's latest commit" git -C "$CORE_WT" fetch -q --depth 1 origin main \
    || { tail -n 3 "$WORK/corefetch.log" | sed 's/^/     /'; die "couldn't fetch homebrew-core"; }
else
  rm -rf "$CORE_WT"
  run_logged "$WORK/coreclone.log" "fetching homebrew-core (its latest commit only)" \
      git clone -q --depth 1 --single-branch --branch main --sparse "https://github.com/$BREW_CORE.git" "$CORE_WT" \
    || { tail -n 3 "$WORK/coreclone.log" | sed 's/^/     /'; rm -rf "$CORE_WT"; die "couldn't fetch homebrew-core"; }
fi
git -C "$CORE_WT" sparse-checkout set .github "$(dirname "$REL")" >/dev/null 2>&1 || die "git sparse-checkout failed in $CORE_WT"
if [ "$BREW_MODE" = new ]; then BRANCH="$BREW_NAME-new"; TITLE="$BREW_NAME $VERSION (new formula)"
else BRANCH="$BREW_NAME-$VERSION"; TITLE="$BREW_NAME $VERSION"; fi
git -C "$CORE_WT" checkout -q -f -B "$BRANCH" origin/main || die "couldn't make the branch $BRANCH in $CORE_WT"
if [ "$BREW_MODE" != new ]; then
  cmp -s "$WORK/base.rb" "$CORE_WT/$REL" || die "homebrew/core changed $REL while the wizard ran — run it again"
fi
mkdir -p "$CORE_WT/$(dirname "$REL")"
cp "$FILE_LOCAL" "$CORE_WT/$REL"
git -C "$CORE_WT" add -- "$REL"
# one commit for the formula, in Homebrew's message style
bcommit "$CORE_WT" -m "$TITLE" -- "$REL"
ok "committed: $TITLE"
save_answers
if [ "$DRYRUN" = 1 ]; then
  warn "dry run — stopping before the push"
  note "branch $BRANCH is committed in $CORE_WT"
  exit 0
fi
go "Push $BRANCH to $GH_USER/$FORK_NAME and open the pull request?" || { note "branch $BRANCH is committed in $CORE_WT"; exit 0; }

# Bring the fork's main up to date first: then the push only sends the new
# commit (fast, and fine from a shallow checkout).
if run_logged "$WORK/sync.log" "syncing your fork with $BREW_CORE" gh repo sync "$GH_USER/$FORK_NAME" --branch main; then
  ok "fork synced"
else
  warn "couldn't sync the fork ($(tail -n 1 "$WORK/sync.log")) — pushing anyway"
fi
# gh does the authentication for an https remote: no SSH key needed
push_core() {
  git -C "$CORE_WT" -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    push -f "https://github.com/$GH_USER/$FORK_NAME.git" "HEAD:refs/heads/$BRANCH"
}
while ! run_logged "$WORK/push.log" "pushing $BRANCH" push_core; do
  tail -n 4 "$WORK/push.log" | sed 's/^/     /'
  if grep -qE "shallow update not allowed|did not receive expected object" "$WORK/push.log"; then
    warn "your fork is behind $BREW_CORE and couldn't be synced — sync it on https://github.com/$GH_USER/$FORK_NAME"
  else
    warn "the push failed — usually the network, or gh's login expired (gh auth status)"
  fi
  [ "$ASSUME_YES" = 0 ] && confirm "Try again?" y || die "not pushed; the branch is committed in $CORE_WT"
done
[ "$(git -C "$CORE_WT" ls-remote "https://github.com/$GH_USER/$FORK_NAME.git" "refs/heads/$BRANCH" | cut -f1)" = "$(git -C "$CORE_WT" rev-parse HEAD)" ] \
  || die "the fork's $BRANCH doesn't match what was pushed"
ok "pushed: https://github.com/$GH_USER/$FORK_NAME/tree/$BRANCH"

# --- the pull request: Homebrew's template, with only what was done ticked
PR_URL="$(gh pr list -R "$BREW_CORE" --head "$BRANCH" --author "@me" --state open --json url --jq '.[0].url // ""' 2>/dev/null || true)"
if [ -n "$PR_URL" ]; then
  gh pr edit "$PR_URL" --title "$TITLE" >/dev/null 2>&1 || true
  ok "updated the open pull request: $PR_URL"
else
  VERIFIED=""
  [ "$BUILT" = 1 ]    && VERIFIED="\`HOMEBREW_NO_INSTALL_FROM_API=1 brew install --build-from-source $BREW_NAME\`"
  [ "$TESTED" = 1 ]   && VERIFIED="${VERIFIED:+$VERIFIED, }\`brew test $BREW_NAME\`"
  [ "$AUDIT_OK" = 1 ] && VERIFIED="${VERIFIED:+$VERIFIED, }\`brew audit ${AUDIT_ARGS[*]} $BREW_NAME\`"
  [ "$STYLE_OK" = 1 ] && VERIFIED="${VERIFIED:+$VERIFIED, }\`brew style $BREW_NAME\`"
  if [ "$HOST_BREW" = 1 ]; then PLATFORM="$(uname -s) $(uname -m), ${BREW_VERSION:-Homebrew}"
  else PLATFORM="$(uname -m) Linux, in Homebrew's own $BREW_IMAGE container (${BREW_VERSION:-Homebrew})"; fi
  TPL="$CORE_WT/.github/PULL_REQUEST_TEMPLATE.md"
  TICK=(-e 's/^- \[ \] Have you ensured that your commits follow/- [x] Have you ensured that your commits follow/')
  [ "$PR_CHECKED" = 1 ] && TICK+=(-e "s/^- \[ \] Have you checked that there aren't other open/- [x] Have you checked that there aren't other open/")
  [ "$BUILT" = 1 ]      && TICK+=(-e 's/^- \[ \] Have you built your formula locally/- [x] Have you built your formula locally/')
  [ "$TESTED" = 1 ]     && TICK+=(-e 's/^- \[ \] Is your test running fine/- [x] Is your test running fine/')
  [ "$AUDIT_OK" = 1 ]   && TICK+=(-e 's/^- \[ \] Does your build pass/- [x] Does your build pass/')
  [ "$SELF_OK" = 1 ]    && TICK+=(-e 's/^- \[ \] Have you followed the \[guidelines/- [x] Have you followed the [guidelines/'
                                  -e 's#^- \[ \] I did not use AI/LLM#- [x] I did not use AI/LLM#')
  BODY="$WORK/pr.md"
  {
    if [ "$BREW_MODE" = new ]; then
      printf '%s\n\n- Homepage: %s\n- Source: %s\n' "$BDESC" "$HOMEPAGE" "$WEB"
      [ -n "$NOTE_LINE" ] && printf -- '- %s\n' "$NOTE_LINE"
    else
      printf 'Update %s from %s to %s.\n' "$BREW_NAME" "$CORE_VERSION" "$VERSION"
      [ -n "$CHANGELOG_REAL" ] && printf '\nChangelog: %s\n' "$CHANGELOG_REAL"
    fi
    printf '\n'
    [ -f "$TPL" ] && sed "${TICK[@]}" "$TPL"
    printf '\n'
    if [ "$BREW_MODE" = new ]; then
      printf 'AI/automation disclosure: this formula was generated by [linux-submit.sh](%s), a deterministic shell script — no AI/LLM runs when it writes a formula (the script itself was written with AI help). I reviewed the formula before opening this pull request, and I answer review comments myself.\n' "$TOOL_URL"
    else
      printf 'Made with `brew bump-formula-pr --write-only`, run by [linux-submit.sh](%s), a deterministic script (no AI/LLM involved when it runs).\n' "$TOOL_URL"
    fi
    [ -n "$VERIFIED" ] && printf '\nVerified locally on %s: %s.\n' "$PLATFORM" "$VERIFIED"
  } > "$BODY"
  if ! PR_URL="$(gh pr create -R "$BREW_CORE" --base main --head "$GH_USER:$BRANCH" --title "$TITLE" --body-file "$BODY" 2>"$WORK/pr.err")"; then
    sed 's/^/     /' "$WORK/pr.err" | tail -5
    KEEP_WORK=1
    die "gh couldn't open the pull request — the text is in $BODY; open it on https://github.com/$BREW_CORE/compare/main...$GH_USER:$FORK_NAME:$BRANCH"
  fi
  PR_URL="$(printf '%s' "$PR_URL" | grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' | tail -1)"
  ok "pull request opened: $PR_URL"
fi

# ================================================================ summary
printf '\n   %sDone.%s %s\n   %s\n\n   What happens now:\n' "$B" "$R" "$TITLE" "$PR_URL"
say "  • Homebrew's CI builds it on macOS and Linux and makes the bottles. If it can't"
say "    build on macOS, say why in the pull request (depends_on :linux needs a reason)."
say "  • A maintainer reviews it — answer them yourself, without AI (Homebrew's rule);"
say "    running this wizard again updates the same pull request."
[ "$SELF_OK" = 1 ] || say "  • The AI/LLM box in the pull request is left for you to tick: it's your promise."
if [ "$BREW_MODE" = new ]; then
  say "  • Once merged, anyone can 'brew install $BREW_NAME', and BrewTestBot bumps it for"
  say "    each new release by itself (autobump) — nothing to do then."
else
  say "  • Next release: run linux-submit.sh brew (or linux-submit.sh) again."
fi
echo
else
# ------------------------------------------------------------- your tap
step "7/7  Publish to your tap"
git -C "$TAP_WT" add -- "$REL"
if [ "$BREW_MODE" = new ]; then MSG="$BREW_NAME $VERSION (new formula)"; else MSG="$BREW_NAME $VERSION"; fi
COMMITTED=0
if git -C "$TAP_WT" diff --cached --quiet; then
  note "nothing changed in your tap"
else
  bcommit "$TAP_WT" -m "$MSG" -- "$REL"
  ok "committed: $MSG"; COMMITTED=1
fi
save_answers
if [ "$DRYRUN" = 1 ]; then
  warn "dry run — stopping before the push"
  if [ "$HOST_BREW" = 1 ]; then
    # your own tap is left as it was; the formula is kept aside
    cp "$FILE_LOCAL" "$CACHE/brew/$BREW_NAME.rb"
    [ "$COMMITTED" = 1 ] && git -C "$TAP_WT" reset -q --hard HEAD~1
    note "the formula is in $CACHE/brew/$BREW_NAME.rb; your tap is as it was"
  else
    note "your tap is committed in $TAP_WT"
  fi
  exit 0
fi
if [ "$TAP_EXISTS" = 0 ]; then
  go "Create the public repository $BREW_TAP on GitHub and push your tap?" || { note "your tap is committed in $TAP_WT"; exit 0; }
  gh repo create "$BREW_TAP" --public --description "Homebrew formulae — brew install $TAPREF/<formula>" >"$WORK/create.log" 2>&1 \
    || { sed 's/^/     /' "$WORK/create.log" | tail -3; die "gh couldn't create $BREW_TAP — do you have the right to make repositories for ${BREW_TAP%%/*}?"; }
  ok "created https://github.com/$BREW_TAP"
elif [ "$TAP_EXISTS" = 2 ]; then
  go "Push your tap to https://github.com/$BREW_TAP (it's empty there)?" || { note "your tap is committed in $TAP_WT"; exit 0; }
else
  go "Push $MSG to $BREW_TAP?" || { note "your tap is committed in $TAP_WT"; exit 0; }
fi
# gh does the authentication for an https remote: no SSH key needed
push_tap() {
  git -C "$TAP_WT" -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    push "https://github.com/$BREW_TAP.git" "HEAD:refs/heads/$TAP_BRANCH"
}
while ! run_logged "$WORK/push.log" "pushing to $BREW_TAP" push_tap; do
  tail -n 4 "$WORK/push.log" | sed 's/^/     /'
  if grep -q "workflow" "$WORK/push.log"; then
    # the tap's GitHub Actions workflows need gh's 'workflow' permission to be pushed
    warn "GitHub wants the 'workflow' permission for this push (the tap's GitHub Actions)"
    confirm "Grant it now (gh auth refresh -s workflow)?" y && gh auth refresh -h github.com -s workflow && continue
  else
    warn "the push failed — usually the network, or gh's login expired (gh auth status)"
  fi
  [ "$ASSUME_YES" = 0 ] && confirm "Try again?" y || die "not pushed; your tap is committed in $TAP_WT"
done
[ "$(git -C "$TAP_WT" ls-remote "https://github.com/$BREW_TAP.git" "refs/heads/$TAP_BRANCH" | cut -f1)" = "$(git -C "$TAP_WT" rev-parse HEAD)" ] \
  || die "GitHub's $TAP_BRANCH doesn't match what was pushed"
ok "pushed: https://github.com/$BREW_TAP/blob/$TAP_BRANCH/$REL"
# from now on brew update keeps this checkout in step with GitHub
[ -n "$(git -C "$TAP_WT" remote)" ] || git -C "$TAP_WT" remote add origin "https://github.com/$BREW_TAP.git"

printf '\n   %sDone.%s %s %s is in your tap.\n   https://github.com/%s\n\n' "$B" "$R" "$BREW_NAME" "$VERSION" "$BREW_TAP"
say "  • People install it with: brew install $TAPREF/$BREW_NAME"
say "    (Homebrew 6 trusts just that formula when it's named in full like this)"
[ -f "$TAP_WT/.github/workflows/tests.yml" ] \
  && say "  • Your tap's GitHub Actions (brew tap-new's) build and test it on macOS and Linux."
say "  • Next release: run linux-submit.sh brew (or linux-submit.sh) again; it bumps the formula."
case "$NOTE_WHY" in
  "it needs "*) say "  • With $NOTE_BAR, homebrew/core can take it: run again with --core" ;;
  *"days old"*) say "  • Once the repository is 30 days old, homebrew/core can take it: run again with --core" ;;
esac
echo
fi
}

# ##########################################################################
#   linux-submit.sh [<distro>] [options] — run directly, not sourced
# ##########################################################################
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1-}" in
    nix|aur|debian|ppa|copr|fedora|obs|alpine|guru|flathub|snap|brew) WIZARD="$1"; shift; "wizard_$WIZARD" "$@" ;;
    *) wizard_linux "$@" ;;
  esac
  exit
fi
