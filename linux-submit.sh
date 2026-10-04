#!/usr/bin/env bash
#
# linux-submit.sh — publish an app to Linux: NixOS (nixpkgs), Arch (AUR),
# Flathub, the Snap Store and Ubuntu (Launchpad PPA), from one set of answers.
#
#   linux-submit.sh [options]                    pick the distros, answer once,
#                                                then each distro's wizard runs
#   linux-submit.sh nix|aur|flathub|snap|ppa [options]   one distro's wizard
#   (each takes --help)
#
# Layout: the shared helpers, then each wizard as one function (wizard_<id>),
# then the few lines at the bottom that pick one. A distro's wizard always
# runs in a process of its own (wizard_linux starts `linux-submit.sh <id>`),
# so its variables, traps and exits stay its own. Their bodies are
# deliberately not indented: their here-documents must start at column 0.
#
# store-submit.sh sources this file for the distro list and its checkbox
# picker; sourced, it only defines things and runs nothing.
#
# Adding a distro: one line in DISTROS, a wizard_<id> function, its id in the
# `case` at the bottom, and a needs_<id> and tools_<id> in store-submit.sh.

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
ppa|Ubuntu (Launchpad PPA)|wizard_ppa|apt for Ubuntu, Mint, Pop!_OS…; Launchpad builds it
fedora|Fedora (COPR)||coming later
flathub|Flathub (every distro)|wizard_flathub|prepared up to the pull request; you open it
snap|Snap Store (every distro)|wizard_snap|built and uploaded; the store reviews it"

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
                       nix, aur, flathub, snap, ppa — comma-separated, or "all"
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
case " $CHOSEN " in *" snap "*) snap_questions ;; esac
case " $CHOSEN " in *" ppa "*) ppa_questions ;; esac
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
  pc_ubuntu() {  # a pkg-config module → its Ubuntu -dev package
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
      libsystemd|libudev) echo libsystemd-dev ;; epoxy) echo libepoxy-dev ;; libarchive) echo libarchive-dev ;;
      libzstd) echo libzstd-dev ;; liblzma) echo liblzma-dev ;; sdl2) echo libsdl2-dev ;; vulkan) echo libvulkan-dev ;;
      *) echo "" ;;
    esac
  }
  BDEPS="debhelper-compat (= 13)"; ARCH=any; XDEPS=""; RULES_EXTRA=""
  case "$KIND" in
    meson|cmake)
      if [ "$KIND" = meson ]; then BDEPS="$BDEPS, meson, ninja-build, pkgconf"
        PCS="$(for f in $(grep -E '(^|/)meson\.build$' "$WORK/tree.txt"); do at "$TAG_REF" "$f"; done | grep -oE "dependency\([[:space:]]*'[^']+'" | sed -E "s/.*'([^']+)'/\\1/" | sort -u)"
      else BDEPS="$BDEPS, cmake"
        PCS="$(at "$TAG_REF" CMakeLists.txt | tr '\n' ' ' | grep -oE 'pkg_check_modules\([^)]*\)' | sed -E 's/^pkg_check_modules\(//; s/\)$//' \
               | awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^(REQUIRED|QUIET|IMPORTED_TARGET|GLOBAL)$/) { m = $i; sub(/[<>=].*/, "", m); if (m != "") print m } }' | sort -u)"
        [ -n "$PCS" ] && BDEPS="$BDEPS, pkgconf"
        RULES_EXTRA='
override_dh_auto_configure:
	dh_auto_configure -- -DCMAKE_BUILD_TYPE=Release'
      fi
      for pc in $PCS; do
        case "$pc" in threads|m|dl|rt|dependency) continue ;; esac
        d="$(pc_ubuntu "$pc")"
        if [ -n "$d" ]; then BDEPS="$BDEPS, $d"; else warn "no Ubuntu package known for '$pc' — the test build will tell if it's needed"; fi
      done
      case " $PCS " in *gtk4*|*libadwaita*) BDEPS="$BDEPS, desktop-file-utils, appstream, libglib2.0-bin" ;; esac ;;
    make)
      RULES_EXTRA='
override_dh_auto_install:
	dh_auto_install -- PREFIX=/usr' ;;
    python)
      ARCH=all; BDEPS="$BDEPS, dh-sequence-python3, pybuild-plugin-pyproject, python3-all"
      at "$TAG_REF" pyproject.toml > "$WORK/pyproject.toml"
      for b in $(python3 -c 'import re,sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); [print(re.match(r"[A-Za-z0-9._-]+", r).group(0).lower().replace("_","-")) for r in d.get("build-system",{}).get("requires",[])]' "$WORK/pyproject.toml" 2>/dev/null); do
        BDEPS="$BDEPS, python3-$b"
      done
      XDEPS=', ${python3:Depends}'
      RULES_EXTRA="export PYBUILD_NAME=$PNAME"
      RULES_DH='dh $@ --buildsystem=pybuild' ;;
    rust)
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
	rm -rf target debian/cargo-home" ;;
    go)
      GOV="$(at "$TAG_REF" go.mod | sed -nE 's/^go[[:space:]]+([0-9]+\.[0-9]+).*/\1/p' | head -1)"
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
	rm -rf build debian/gocache" ;;
    *) die "the PPA wizard packages Meson, CMake, Make, Python, Rust and Go apps" ;;
  esac
  mkdir -p "$SRC/debian/source"
  echo "3.0 (quilt)" > "$SRC/debian/source/format"
  # Debian's rules for the synopsis match nixpkgs': one short line, no article, no period
  {
    printf 'Source: %s\nSection: misc\nPriority: optional\n' "$PNAME"
    printf 'Maintainer: %s <%s>\n' "$MAINT_NAME" "${MAINT_EMAIL:-$(git -C "$REPO" config user.email)}"
    printf 'Build-Depends: %s\nStandards-Version: 4.7.0\n' "$BDEPS"
    printf 'Homepage: %s\nVcs-Browser: %s\nRules-Requires-Root: no\n\n' "$HOMEPAGE" "$WEB"
    printf 'Package: %s\nArchitecture: %s\n' "$PNAME" "$ARCH"
    printf 'Depends: ${shlibs:Depends}, ${misc:Depends}%s\n' "$XDEPS"
    printf 'Description: %s\n' "$DESC"
    ABOUT="$(cfg_get about)"; [ -n "$ABOUT" ] || ABOUT="$DESC."
    printf '%s\n' "$ABOUT" | fold -s -w 78 | sed -e 's/[[:space:]]*$//' -e 's/^$/./' -e 's/^/ /'
  } > "$SRC/debian/control"
  {
    printf '#!/usr/bin/make -f\n\n'
    printf '%%:\n\t%s\n' "${RULES_DH:-dh \$@}"
    [ -n "$RULES_EXTRA" ] && printf '%s\n' "$RULES_EXTRA"
  } > "$SRC/debian/rules"
  chmod 755 "$SRC/debian/rules"
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
#   linux-submit.sh [<distro>] [options] — run directly, not sourced
# ##########################################################################
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1-}" in
    nix|aur|flathub|snap|ppa) WIZARD="$1"; shift; "wizard_$WIZARD" "$@" ;;
    *) wizard_linux "$@" ;;
  esac
  exit
fi
