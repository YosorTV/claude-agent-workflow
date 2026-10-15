#!/usr/bin/env bash
# pre-push-gate.sh - PreToolUse hook (matcher Bash). Denies `git push` of a buildable repo unless a GREEN
# receipt exists for the exact HEAD commit being pushed (written by bin/gate.sh), and denies a push whose
# unpushed commits carry AI attribution. "Build and tests green before push" becomes a hard gate.
#
# Fail posture: OPEN on anything ambiguous (not a push, unparseable payload, not a git repo, no build
# system, no sha) -> allow. It only denies when it is confident the gate was not run green for this commit.
# Needs bash and python3 (python) for JSON parsing.
set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
GATE_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" 2>/dev/null && pwd)/gate.sh"
payload="$(cat 2>/dev/null || true)"

unset PYTHONHOME PYTHONPATH
PY="python"; command -v python3 >/dev/null 2>&1 && PY="python3"
# Real JSON parsing, not grep: a `"command":"[^"]*"` match stops at the first escaped quote, so
# `git commit -m "..." && git push` was never seen as a push and the gate silently allowed it.
field() { printf '%s' "$payload" | "$PY" -c 'import json,sys
k = sys.argv[1]
try: p = json.loads(sys.stdin.buffer.read().decode("utf-8-sig", "replace"))
except Exception: sys.exit(0)
v = (p.get("tool_input") or {}).get(k) if k == "command" else p.get(k)
sys.stdout.write(str(v or ""))' "$1" 2>/dev/null; }

cmd="$(field command)"
# Decide on TOKENS, not substrings: `push` must be the git SUBCOMMAND, after `git` and optionally git's own
# global flags (-C <dir>, -c k=v, --git-dir=...). `git stash push` and a commit message that mentions
# "push" are not pushes. A multi-line && chain is flattened first so it still matches.
GIT_PUSH_RE='(^|[^[:alnum:]_-])git([[:space:]]+(-[a-zA-Z][[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+push([[:space:]]|$)'
printf '%s' "${cmd//$'\n'/ }" | grep -Eq "$GIT_PUSH_RE" || exit 0

# The subject is the repo that RECEIVES the push, which is not always the session's directory. Follow the
# command's own `cd` and `git -C` first. A target the shell expands ($REPO, $(...)) stops the walk: the
# gate keeps the directory it is sure of, so a push it cannot place stays gated rather than waved through.
effdir() { printf '%s' "$payload" | "$PY" -c 'import json,os,re,sys
try: p = json.loads(sys.stdin.buffer.read().decode("utf-8-sig","replace"))
except Exception: p = {}
cmd = str((p.get("tool_input") or {}).get("command") or "")
at = str(p.get("cwd") or "")
q = "\x27"
pat = "(\"[^\"]*\"|" + q + "[^" + q + "]*" + q + "|\\S+)"
for raw in re.findall(r"(?:^|[;&|]\s*)cd\s+" + pat, cmd) + re.findall(r"\bgit\s+-C\s+" + pat, cmd):
    d = raw.strip("\"" + q)
    if re.search(r"[$`*?]", d): break
    at = os.path.abspath(os.path.join(at, os.path.expanduser(d)))
sys.stdout.write(at)' 2>/dev/null; }

cwd="$(effdir)"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
# Every worktree of a repo resolves to the main checkout's name, the same key gate.sh uses.
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -n "$common" ]; then
  key="$(basename "$(dirname "$common")")"
else
  key="$(basename "$root")"
fi

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  printf '%s\n' "$1" >&2
  exit 2
}

# Nothing carrying a claude.ai link or a Claude-Session trailer leaves the machine, in ANY repo, build or not.
leak="$(git -C "$root" log --branches --not --remotes --format='%h' 2>/dev/null | head -50 | while read -r h; do git -C "$root" log -1 --format='%B' "$h" | grep -qE 'claude\.ai/|Claude-Session:' && printf '%s ' "$h"; done)"
[ -n "$leak" ] && deny "Push blocked: unpushed commit(s) ${leak}carry a claude.ai link or a Claude-Session trailer. Reword them (git commit --amend, or rebase over the unpushed range) so no AI attribution leaves this machine."

# Only repos with a build or test system are gated; everything else is allowed.
has_build=0
ls "$root"/*.sln >/dev/null 2>&1 && has_build=1
[ -f "$root/package.json" ] && has_build=1
find "$root" -maxdepth 3 -name '*.csproj' 2>/dev/null | grep -q . && has_build=1
find "$root" -maxdepth 3 -name pubspec.yaml \
     -not -path '*/.dart_tool/*' -not -path '*/build/*' 2>/dev/null | grep -q . && has_build=1
[ "$has_build" -eq 1 ] || exit 0

sha="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
[ -n "$sha" ] || exit 0

# a green receipt for THIS commit -> allow
[ -f "$CLAUDE_DIR/.gate/${key}-${sha}.ok" ] && exit 0

deny "Green gate not satisfied for ${key} @ ${sha:0:8}. Run: bash ${GATE_SH} (build and tests must pass) and push again. A red build never ships."
