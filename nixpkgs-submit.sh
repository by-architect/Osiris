#!/usr/bin/env bash
#
# nixpkgs-submit.sh — get an app into nixpkgs (the package set Nix and NixOS
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
nixpkgs-submit.sh — get an app into nixpkgs, or update it there.

  -h, --help          show this text
  -y, --yes           use everything it detects and don't ask; stops only on
                      problems. A new package is then opened as a draft pull
                      request, since nixpkgs wants you to review it first.
      --ask           ask every question, including the ones it can answer
      --repo PATH     the app's git checkout (default: the repo you run it in)
      --nixpkgs PATH  your nixpkgs checkout (default: asked, ~/nixpkgs)
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
    --review)     RUN_REVIEW=1 ;;
    --draft)      DRAFT=1 ;;
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nixpkgs-submit.XXXXXX")"
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
    printf '# written by nixpkgs-submit.sh — safe to delete (or run --forget)\n'
    printf 'SAVED_REPO=%q\n'         "${REPO:-${SAVED_REPO:-}}"
    printf 'SAVED_NIXPKGS=%q\n'      "${NIXPKGS:-${SAVED_NIXPKGS:-}}"
    printf 'SAVED_HANDLE_NAME=%q\n'  "${M_NAME:-${SAVED_HANDLE_NAME:-}}"
    printf 'SAVED_HANDLE_EMAIL=%q\n' "${M_EMAIL:-${SAVED_HANDLE_EMAIL:-}}"
  } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  chmod 600 "$CONF" 2>/dev/null || true
}

# ------------------------------------------------------------------- helpers
# nix_str <text> — escaped for use inside a "…" Nix string
nix_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\${/\\${/g'; }

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
in_wt() { ( cd "$WT" && "$@" ); }

# nixpkgs as CI sees it: without your ~/.config/nixpkgs config and overlays
PKGS='(import ./. { config = { }; overlays = [ ]; })'
NIXARGS=(--arg config '{ }' --arg overlays '[ ]')

# neval <expr> — evaluate in the nixpkgs worktree, JSON out ("" on failure,
# with the error in $WORK/eval.err)
neval() { ( cd "$WT" && nix-instantiate --eval --strict --json -E "$1" 2>"$WORK/eval.err" ) || true; }
neval_str() { neval "$1" | sed -e 's/^"//' -e 's/"$//'; }

gh_ready() { gh auth status --hostname github.com >/dev/null 2>&1; }

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

# ============================================================== 1. the app
step "1/7  Your app"

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

# --- where does it live? nixpkgs fetches the source from there.
# The URL as configured: `remote get-url` would apply url.*.insteadOf rewrites.
ORIGIN="$(git -C "$REPO" config --get remote.origin.url 2>/dev/null || true)"
[ -n "$ORIGIN" ] || die "no 'origin' remote — nixpkgs builds from a public repository: push yours and add it as origin"
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
    github)   gh api "repos/$SLUG" 2>/dev/null ;;
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
  [ "$FORGE_PRIVATE" = true ] && die "$WEB is private — nixpkgs can only build public sources; make it public first"
  ok "the repository is public"
elif [ "$FORGE" != git ]; then
  if [ "$FORGE" = gitlab ] || [ "$FORGE" = codeberg ]; then
    die "$WEB can't be reached anonymously — nixpkgs can only build public sources (is it private?)"
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
  [ "$ASSUME_YES" = 1 ] && die "version '$VERSION' must start with a digit (nixpkgs' rule)"
  warn "a nixpkgs version must start with a digit, e.g. 1.2.3"
done

# --- the name: lowercase, as nixpkgs requires; the attribute is the same
# (with a leading _ if it starts with a digit)
PNAME_GUESS="$(name_at . | tr 'A-Z' 'a-z' | tr ' ' '-')"
FIRST=1
while :; do
  if [ "$FIRST" = 1 ]; then auto PNAME "Package name" "$PNAME_GUESS"; else ask PNAME "Package name" "$PNAME_GUESS"; fi
  FIRST=0
  printf '%s' "$PNAME" | grep -qE '^[a-z0-9][a-z0-9_-]*$' && break
  [ "$ASSUME_YES" = 1 ] && die "'$PNAME' is not a valid package name (lowercase letters, digits, - and _)"
  warn "lowercase letters, digits, - and _ only (nixpkgs forbids uppercase; . and + can't be attribute names)"
  PNAME_GUESS="$(printf '%s' "$PNAME" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n-' '-')"
done
ATTR="$PNAME"; case "$ATTR" in [0-9]*) ATTR="_$ATTR" ;; esac

# --- the release tag: nixpkgs fetches it, so it must exist, be pushed, and
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
    note "without the tag online nixpkgs can't fetch the source: the dry run stops after writing package.nix"
    TAG_REF=HEAD; DRY_NO_TAG=1
  elif go "Tag HEAD ($HEAD_SHORT) as $TAG and push it to origin?"; then
    git -C "$REPO" tag "$TAG" HEAD
    git -C "$REPO" push -q origin "refs/tags/$TAG" || die "could not push tag $TAG"
    ok "tagged and pushed $TAG"
  else
    die "nixpkgs needs the release tag — create and push $TAG, then re-run"
  fi
elif ! ref_matches "$TAG"; then
  # The classic slip: a tag made before the version bump.
  die "tag $TAG says version $(version_at "$TAG"), not $VERSION — tag the release commit, or bump the version"
elif ! tag_on_remote "$TAG"; then
  warn "tag $TAG is not on origin yet — nixpkgs would not find it"
  if [ "$DRYRUN" = 1 ]; then
    warn "dry run — would push tag $TAG"
  elif go "Push tag $TAG to origin?"; then
    git -C "$REPO" push -q origin "refs/tags/$TAG" || die "could not push tag $TAG"
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

# Everything below is read from the tag: that is what nixpkgs will build.
git -C "$REPO" ls-tree -r --name-only "$TAG_REF" > "$WORK/tree.txt"
in_tree() { grep -qxF "$1" "$WORK/tree.txt"; }
in_tree_re() { grep -qE "$1" "$WORK/tree.txt"; }

# --- what the build needs from the tagged source
BLOCKERS=0
blocker() { bad "$*"; BLOCKERS=$((BLOCKERS + 1)); }
case "$KIND" in
  flutter)
    in_tree "$(pp pubspec.lock)" || blocker "no $(pp pubspec.lock) in $TAG — commit it (nixpkgs pins every Dart package from it)"
    if in_tree "$(pp linux/CMakeLists.txt)"; then ok "Flutter Linux desktop target: $(pp linux/)"
    else blocker "no Linux desktop target in $TAG — run 'flutter create --platforms=linux .' in $PROOT, commit, and release again"; fi ;;
  rust)   in_tree Cargo.lock || blocker "no Cargo.lock in $TAG — commit it (nixpkgs builds with exactly those crates)" ;;
  node)   in_tree package-lock.json || blocker "no package-lock.json in $TAG — this wizard packages npm projects; commit the lock file" ;;
  go)     in_tree go.mod || blocker "no go.mod in $TAG" ;;
  python) in_tree pyproject.toml || blocker "no pyproject.toml in $TAG — nixpkgs builds Python apps with pyproject = true" ;;
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
SPDX_GUESS=""
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
# ambiguous, and nixpkgs has a different license for each: settle it.
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
[ -n "$SPDX_GUESS" ] || warn "no license found — nixpkgs treats software without one as unfree; add a LICENSE file"
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
DESC_RAW="$FORGE_DESC"
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
  M_NAME_GUESS="${SAVED_HANDLE_NAME:-${GH_NAME:-$(git -C "$REPO" config user.name 2>/dev/null || true)}}"
  ask M_NAME "Your name, as people know you" "$M_NAME_GUESS"
  note "the email goes into the public maintainer list; blank leaves it out"
  ask_opt M_EMAIL "Email" "${SAVED_HANDLE_EMAIL:-$(git -C "$REPO" config user.email 2>/dev/null || true)}"
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
    wayland-scanner) a=wayland-scanner ;; pkg-config|pkgconf) a=pkg-config ;; python|python3) a=python3 ;;
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
      printf 'Updated with `nix-update`, run by [nixpkgs-submit.sh](%s); built and checked locally.\n' "$TOOL_URL"
    else
      printf 'Automation disclosure: `package.nix` was generated by [nixpkgs-submit.sh](%s), a deterministic script (no AI involved when it runs) that detects the project, fills in hashes by building, and formats with treefmt.' "$TOOL_URL"
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
