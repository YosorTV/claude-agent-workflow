#!/usr/bin/env bash
# gate.sh - local green gate. Runs whichever of lint / build / test the repo actually exposes, then the
# repo's own diff gate and the global rule lints. On all-green it writes a RECEIPT keyed to the HEAD
# commit, naming what ran, what was skipped and the test counts. hooks/pre-push-gate.sh denies
# `git push` when no receipt exists for the commit being pushed. Run it from the repo you are about to push.
#
# Command detection, first match wins:
#   - env GATE_CMD                      -> run exactly that (e.g. GATE_CMD='dotnet build src/App.sln && dotnet test src/App.sln')
#   - gate.d/<repo>.env                 -> sourced; sets a persistent GATE_CMD (and GATE_RULES_SKIP) for that repo
#   - .NET (*.sln / *.csproj)           -> build + `dotnet format --verify-no-changes` + test, all in Release
#   - Node (package.json)               -> lint (lint:check | lint), build, test - whichever scripts exist
#   - Dart / Flutter (pubspec.yaml)     -> `flutter analyze` once, then `flutter test` per package
#   - none of these                     -> nothing to gate, exit 0 (the push hook does not gate it either)
#
# A run where no step ran at all is RED with no receipt: a repo the gate cannot see is not a green repo.
# Receipts live in ${CLAUDE_CONFIG_DIR:-~/.claude}/.gate/<repo>-<sha>.ok. gate.d/ sits next to bin/.
set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
GATE_DIR="$CLAUDE_DIR/.gate"
GATE_D="$(cd "$(dirname "${BASH_SOURCE[0]}")/../gate.d" 2>/dev/null && pwd)"
mkdir -p "$GATE_DIR" 2>/dev/null || true

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "[gate] not inside a git repo - nothing to gate."; exit 0; }
# A worktree reports its own folder as the toplevel; the common git dir always points at the main
# checkout, so every worktree of a repo shares that repo's key, override and diff gate.
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -n "$common" ]; then
  key="$(basename "$(dirname "$common")")"
else
  key="$(basename "$root")"
fi
sha="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
[ -n "$sha" ] || { echo "[gate] no HEAD sha - allow."; exit 0; }
receipt="$GATE_DIR/${key}-${sha}.ok"

# A repo whose real gate cannot be read off its script names declares it here. Env GATE_CMD still wins,
# so a one-off override needs no file.
override="$GATE_D/$key.env"
if [ -z "${GATE_CMD:-}" ] && [ -f "$override" ]; then
  . "$override"
  echo "[gate] override: $override"
fi

echo "[gate] repo=$key  head=${sha:0:8}"
ok=1
steps=""; skipped=""

# JSON-escape for the receipt: backslash and quote break the object; newline and tab collapse to a space.
esc() { printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
add_step() { steps="${steps:+$steps,}{\"cmd\":\"$(esc "$1")\",\"exit\":$2}"; }
add_skip() { skipped="${skipped:+$skipped,}\"$(esc "$1")\""; }

# Counts are harvested from every step's output so the receipt proves work done, not only exit 0:
# a suite that passed 0 tests, or skipped everything, is a vacuous green.
passed=0; failed=0; tskipped=0
harvest() {  # $1 = captured output file
  local p f s
  # dotnet: "Passed: 12, Failed: 0, Skipped: 1" | jest/vitest: "Tests: 2 failed, 5 passed" | playwright: "5 passed (12s)"
  p="$(grep -oE '(Passed:[[:space:]]*[0-9]+|[0-9]+[[:space:]]+passed)' "$1" | grep -oE '[0-9]+' | paste -sd+ - 2>/dev/null)"
  f="$(grep -oE '(Failed:[[:space:]]*[0-9]+|[0-9]+[[:space:]]+failed)' "$1" | grep -oE '[0-9]+' | paste -sd+ - 2>/dev/null)"
  s="$(grep -oE '(Skipped:[[:space:]]*[0-9]+|[0-9]+[[:space:]]+skipped)' "$1" | grep -oE '[0-9]+' | paste -sd+ - 2>/dev/null)"
  [ -n "$p" ] && passed=$(( passed + $(( p )) ))
  [ -n "$f" ] && failed=$(( failed + $(( f )) ))
  [ -n "$s" ] && tskipped=$(( tskipped + $(( s )) ))
}
run() {
  echo "[gate] \$ $*" >&2
  local out; out="$(mktemp 2>/dev/null || echo "/tmp/gate-$$-$RANDOM.log")"
  ( cd "$root" && eval "$@" ) 2>&1 | tee "$out"; rc=${PIPESTATUS[0]}
  harvest "$out"; rm -f "$out" 2>/dev/null || true
  add_step "$*" "$rc"; return "$rc"
}

# The PATH dotnet can be unusable for this repo: no SDK at all, or global.json pins a feature band it
# lacks. Both show as `dotnet --version` failing inside the repo, so probe the usual installs there.
if ! ( cd "$root" && dotnet --version ) >/dev/null 2>&1; then
  for d in "$HOME/.dotnet" "${DOTNET_ROOT:-}" /usr/share/dotnet /usr/local/share/dotnet; do
    if [ -n "$d" ] && ( cd "$root" && "$d/dotnet" --version ) >/dev/null 2>&1; then
      export DOTNET_ROOT="$d"
      export PATH="$d:$PATH"
      echo "[gate] dotnet: $d ($( cd "$root" && dotnet --version ))"
      break
    fi
  done
fi

# The sln is often not at the repo root: search to depth 3, shallowest first, then alphabetical.
sln="$(find "$root" -maxdepth 3 -name '*.sln' \
         -not -path '*/node_modules/*' -not -path '*/bin/*' -not -path '*/obj/*' 2>/dev/null \
       | awk -F/ '{print NF"\t"$0}' | sort -k1,1n -k2,2 | cut -f2- | head -1)"

if [ -n "${GATE_CMD:-}" ]; then
  run "$GATE_CMD" || ok=0
elif [ -n "$sln" ] || find "$root" -maxdepth 3 -name '*.csproj' 2>/dev/null | grep -q .; then
  [ -n "$sln" ] && echo "[gate] sln: ${sln#$root/}"
  [ -n "$sln" ] || echo "[gate] no .sln found - building from the repo root; set GATE_CMD if that is not buildable."
  # Release, because that is what CI builds; warnings-as-errors and analyzers can differ between configurations.
  run "dotnet build ${sln:+\"$sln\"} --configuration Release" || ok=0
  # CI usually enforces formatting as its own blocking step; build and test both pass on badly ordered usings.
  [ "$ok" -eq 1 ] && { run "dotnet format ${sln:+\"$sln\"} --verify-no-changes" || ok=0; }
  [ "$ok" -eq 1 ] && { run "dotnet test ${sln:+\"$sln\"} --configuration Release --no-build --nologo" || ok=0; }
elif [ -f "$root/package.json" ]; then
  pm="npm run"
  command -v yarn >/dev/null 2>&1 && [ -f "$root/yarn.lock" ] && pm="yarn"
  command -v pnpm >/dev/null 2>&1 && [ -f "$root/pnpm-lock.yaml" ] && pm="pnpm run"
  # First match wins: a repo that namespaces its linter exposes only `lint:check`. A step the repo does
  # not expose is RECORDED as skipped, never passed over in silence.
  lint=""
  for s in lint:check lint; do grep -q "\"$s\":" "$root/package.json" && { lint="$s"; break; }; done
  if [ -n "$lint" ]; then run "$pm $lint" || ok=0
  else add_skip 'lint: no "lint:check" or "lint" script'; fi
  # `"$s":` with the colon, so a dependency that merely contains the word cannot pass for a script.
  for s in build test; do
    [ "$ok" -eq 1 ] || break
    if ! grep -q "\"$s\":" "$root/package.json"; then add_skip "$s: no \"$s\" script"; continue; fi
    if [ "$s" = "test" ]; then run "CI=true $pm test" || ok=0
    else run "$pm $s" || ok=0; fi
  done
elif find "$root" -maxdepth 3 -name pubspec.yaml \
       -not -path '*/.dart_tool/*' -not -path '*/build/*' 2>/dev/null | grep -q .; then
  # `flutter analyze` from the root walks every package; `flutter test` is per package.
  if ! command -v flutter >/dev/null 2>&1; then
    add_skip 'analyze/test: flutter not on PATH'
  else
    run "flutter analyze" || ok=0
    while IFS= read -r pub; do
      [ "$ok" -eq 1 ] || break
      d="$(dirname "$pub")"; rel="${d#$root}"; rel="${rel#/}"; rel="${rel:-.}"
      if [ -d "$d/test" ]; then run "(cd \"$rel\" && flutter test)" || ok=0
      else add_skip "test: $rel has no test/ dir"; fi
    done < <(find "$root" -maxdepth 3 -name pubspec.yaml \
               -not -path '*/.dart_tool/*' -not -path '*/build/*' 2>/dev/null | sort)
  fi
else
  echo "[gate] no .NET/Node/Flutter build detected for $key - nothing to gate (allow)."
  exit 0
fi

# Repo-specific DIFF gate gate.d/<repo>.sh <root> <base-ref>: a check written after a defect class
# shipped once in that repo. Then the global rule lints gate.d/_rules.sh for every repo. Both run only
# on a green build, and both run even if the other is red: one report, all of it.
# The rule lints never run alone: a repo where no build step ran must stay RED below.
diffgate="$GATE_D/$key.sh"
rulegate="$GATE_D/_rules.sh"
[ -n "$steps" ] || rulegate=""
if [ "$ok" -eq 1 ] && { [ -f "$diffgate" ] || [ -n "$rulegate" ]; }; then
  # base = what the PR will diff against: a long-lived branch compares with its own remote tip, any
  # other branch with the long-lived branch it forked from most recently.
  base=""; cur="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null || true)"
  case "$cur" in
    develop|main|master) cand="$cur";;
    *) best=""; bestn=""
       for b in develop main master; do
         git -C "$root" show-ref -q --verify "refs/remotes/origin/$b" || continue
         mb="$(git -C "$root" merge-base HEAD "origin/$b" 2>/dev/null)" || continue
         n="$(git -C "$root" rev-list --count "$mb..HEAD" 2>/dev/null)" || continue
         if [ -z "$bestn" ] || [ "$n" -lt "$bestn" ]; then bestn="$n"; best="$b"; fi
       done
       cand="${best:-develop}";;
  esac
  for b in "$cand" develop main master; do git -C "$root" show-ref -q --verify "refs/remotes/origin/$b" && { base="origin/$b"; break; }; done
  [ -n "$base" ] || base="$(git -C "$root" rev-list --max-parents=0 HEAD | tail -1)"
  [ -f "$diffgate" ] && { run "bash \"$diffgate\" \"$root\" \"$base\"" || ok=0; }
  [ -n "${GATE_RULES_SKIP:-}" ] && export GATE_RULES_SKIP     # may come from a sourced gate.d/<repo>.env
  [ -n "$rulegate" ] && [ -f "$rulegate" ] && { run "bash \"$rulegate\" \"$root\" \"$base\"" || ok=0; }
fi

if [ "$ok" -eq 1 ]; then
  if [ -z "$steps" ]; then
    rm -f "$receipt" 2>/dev/null || true
    echo "[gate] RED  nothing ran - this repo exposes none of lint/build/test, so there is nothing to certify."
    echo "[gate]      Set GATE_CMD or add gate.d/$key.env with the real command. No receipt written."
    exit 1
  fi
  printf '{"repo":"%s","sha":"%s","ts":"%s","steps":[%s],"skipped":[%s],"counts":{"passed":%d,"failed":%d,"skipped":%d}}\n' \
    "$(esc "$key")" "$sha" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$steps" "$skipped" "$passed" "$failed" "$tskipped" > "$receipt"
  # split the JSON fragment on its separators first, then unescape - the reverse order would eat a comma
  [ -n "$skipped" ] && echo "[gate] skipped: $(printf '%s' "$skipped" | sed 's/","/, /g; s/^"//; s/"$//; s/\\"/"/g')"
  echo "[gate] counts: passed=$passed failed=$failed skipped=$tskipped"
  echo "[gate] GREEN  receipt: $receipt - push allowed for ${sha:0:8}"
  exit 0
else
  rm -f "$receipt" 2>/dev/null || true
  echo "[gate] RED  build/tests failed - fix locally, do not push. No receipt written."
  exit 1
fi
