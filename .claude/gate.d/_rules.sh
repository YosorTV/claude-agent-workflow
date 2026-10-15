#!/usr/bin/env bash
# gate.d/_rules.sh <root> <base-ref> [<head-commit>]
# Global rule lints. bin/gate.sh runs them for every repo after a green build (repo-specific checks live in
# gate.d/<repo>.sh). Each check is a WRITTEN rule a reviewer would otherwise raise as a WARN, and a WARN
# costs a whole fix round; here it costs seconds. Only ADDED lines are judged: rules bind new and touched
# code, legacy is never mass-reformatted.
#   T1 ternary                  TS      .claude/rules/frontend.md "Branch explicitly"       ternary-ok: <why>
#   T2 doc block in a body      TS      .claude/rules/frontend.md "Doc comments"
#   C1 var                      C#      .claude/rules/backend.md "Explicit types"           var-ok: <why>
#   C2 class not sealed         C#      .claude/rules/backend.md "Sealed by default"        inherit-ok: <why>
#   M1 layout property animated CSS/TS  .claude/rules/frontend.md "Motion"                  motion-ok: <why>
#   M2 endless loop, no reduced-motion path  CSS/TS  .claude/rules/frontend.md "Motion"     loop-ok: <why>
# The opt-out marker sits on the flagged line (any comment form), so the exception is reviewable in the PR.
# TS test code (specs, tests/, e2e/) is out of scope for T1/T2. GATE_RULES_SKIP="T1 C2" (env, or
# gate.d/<repo>.env) switches rules off for a repo whose own style differs: the project decides how code looks.
# M1 reads a transition / transition-property (or Tailwind transition-[..]) naming a layout property, a layout
# declaration inside @keyframes, and a layout key in a Motion target (animate / initial / exit / while* /
# variants / animate(el, {..})). `transition: all` and Motion's `layout` prop pass. M2 is an `infinite`
# animation or `repeat|iterations: Infinity`, dropped when the file mentions prefers-reduced-motion /
# useReducedMotion / reducedMotion / MotionConfig / motion-reduce: / motion-safe:.
# Without <head-commit> the diff is merge-base(base, HEAD) -> working tree (what the push carries, untracked
# files included); with it, merge-base(base, head) -> head (lint a past commit, read-only).
set -u
root="$1"; base="$2"; head="${3:-}"
cd "$root" || exit 1
GATE_TAG=rules; . "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
skip=" $(printf '%s' "${GATE_RULES_SKIP:-}" | tr -d '\r') "    # a CRLF .env leaves a \r on the value

mb="$(git merge-base "$base" "${head:-HEAD}" 2>/dev/null || echo "$base")"
if [ -n "$head" ]; then names="$(git diff --name-only "$mb" "$head" 2>/dev/null)"; else names="$(changed_files)"; fi
files="$(printf '%s\n' "$names" | sed '/^$/d' \
  | grep -vE '(^|/)(node_modules|dist|build|bin|obj|Migrations|generated)/|\.(d\.ts|Designer\.cs|g\.cs|g\.i\.cs)$' || true)"
[ -n "$files" ] || { info "no lintable changes vs $base - nothing to lint"; exit 0; }

diffs() {   # one file per line, so names with spaces survive
  local f
  while IFS= read -r f; do
    if [ -n "$head" ]; then git diff --no-color -U4 "$mb" "$head" -- "$f"
    elif git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then git diff --no-color -U4 "$mb" -- "$f"
    else git diff --no-color --no-index -U4 /dev/null "$f"; fi
  done <<< "$files"
}

# One pass over the unified diff. Prints rule, file, line, name, source line - separated by \037, because a
# tab is IFS whitespace and `read` would collapse the empty name field - per hit on an ADDED line. Strings and
# comments are blanked first, so neither can look like code. POSIX awk only (macOS ships BSD awk):
# [[:space:]], never \s / \w.
read -r -d '' PROG <<'AWK'
function code(s,   out, i) {      # the line with comments + literals blanked; tracks /* */ across lines
  if (s ~ /^[[:space:]]*\*/ && s !~ /\*\//) return ""
  out = ""
  while (s != "") {
    if (inc) { i = index(s, "*/"); if (!i) return out; s = substr(s, i + 2); inc = 0; continue }
    i = index(s, "/*"); if (!i) { out = out s; break }
    out = out substr(s, 1, i - 1); s = substr(s, i + 2); inc = 1
  }
  gsub(/"([^"\\]|\\.)*"/, "\"\"", out); gsub(/'([^'\\]|\\.)*'/, "''", out); gsub(/`[^`]*`/, "``", out)
  sub(/\/\/.*$/, "", out)
  return out
}
function hit(r, f, n, nm, s) { gsub(/\t/, " ", s); sub(/^[[:space:]]+/, "", s); print r "\037" f "\037" n "\037" nm "\037" substr(s, 1, 140) }
function bal(s,   i, d, ch) {      # s up to the brace that closes its first {
  d = 0
  for (i = 1; i <= length(s); i++) { ch = substr(s, i, 1)
    if (ch == "{") d++
    else if (ch == "}" && --d <= 0) return substr(s, 1, i) }
  return s
}
function val(s, re,   v, q, i) {   # value of the first `re` declaration: a quoted string, a {..}, else up to ; or }
  if (!match(s, re)) return ""
  v = substr(s, RSTART + RLENGTH); sub(/^[[:space:]]*/, "", v); q = substr(v, 1, 1)
  if (q == "{") return bal(v)
  if (q == "'" || q == "\"" || q == "`") { v = substr(v, 2); i = index(v, q); if (i) v = substr(v, 1, i - 1); return v }
  sub(/[;}].*$/, "", v); return v
}
function mwalk(s,   i, ch, out) {  # text of s while Motion-target depth mo > 0; mrest = what follows the close
  out = ""
  for (i = 1; i <= length(s); i++) { ch = substr(s, i, 1)
    if (ch == "{") mo++
    else if (ch == "}") { if (--mo <= 0) { mo = 0; mrest = substr(s, i + 1); return out } }
    else if (mo == 0 && (ch == ")" || ch == ";")) break
    if (mo > 0) out = out ch }
  mrest = substr(s, i + 1); return out
}
function mtarget(s,   seg) {       # every Motion target object on the line, depth carried across lines in mo
  seg = ""
  if (mo > 0) { seg = mwalk(s); s = mrest }
  while (s != "" && match(s, MO)) { s = substr(s, RSTART + RLENGTH - 1); seg = seg " " mwalk(s); s = mrest }
  return seg
}
function motion(   m1, m2, ks, o) { # M1/M2 on the current line: code c (literals blanked), raw keeps strings
  if (c !~ /[^[:space:]]/) return
  m1 = 0; m2 = 0
  if (mc == "M1" && raw ~ LW) m1 = 1   # mc: a `transition:` / `animation:` whose values follow on the next lines
  if (mc == "M2" && raw ~ INF) m2 = 1
  if (c ~ /[;}]/) mc = ""
  if (c ~ TR && val(raw, TR) ~ LW) m1 = 1   # the property in code, its value read from raw (strings kept)
  if (match(raw, /transition-\[[^[:space:]]*/) && substr(raw, RSTART + 11, RLENGTH - 11) ~ LW) m1 = 1
  if (mtarget(c) ~ MK) m1 = 1
  ks = c
  if (!kf && match(c, /@(-[a-z]+-)?keyframes([^-A-Za-z]|$)/)) { kf = 1; kd = 0; ko = 0; ks = substr(c, RSTART) }
  if (kf) {
    if (ks ~ LD) m1 = 1
    o = gsub(/\{/, "{", ks); kd += o - gsub(/\}/, "}", ks); if (o) ko = 1
    if (ko && kd <= 0) kf = 0
  }
  if ((c ~ AN && val(raw, AN) ~ INF) || raw ~ /animate-\[[^[:space:]]*infinite/ \
      || c ~ /(^|[^A-Za-z0-9_$])(repeat|iterations)[[:space:]]*:[[:space:]]*(Infinity|Number\.POSITIVE_INFINITY)/) m2 = 1
  if (cssf && c ~ (TR "[[:space:]]*$")) mc = "M1"
  if (cssf && c ~ (AN "[[:space:]]*$")) mc = "M2"
  if (added && m1 && raw !~ /motion-ok/) hit("M1", file, ln, "", raw)
  if (added && m2 && raw !~ /loop-ok/) hit("M2", file, ln, "", raw)
}
BEGIN {
  LW = "(^|[^-A-Za-z0-9_])(width|height|top|left|right|bottom|max-height|max-width|inset(-[a-z]+)*|margin(-[a-z]+)*|padding(-[a-z]+)*)([^-A-Za-z0-9_]|$)"
  LD = "(^|[^-A-Za-z0-9_$])(width|height|top|left|right|bottom|max-height|max-width|inset(-[a-z]+)*|margin(-[a-z]+)*|padding(-[a-z]+)*)[[:space:]]*:"
  MK = "(^|[^A-Za-z0-9_$.])(width|height|top|left|right|bottom|maxHeight|maxWidth|inset[A-Za-z]*|margin[A-Za-z]*|padding[A-Za-z]*)[[:space:]]*:"
  TR = "(^|[^-A-Za-z0-9_])transition(-property|Property)?[[:space:]]*[:=]"
  AN = "(^|[^-A-Za-z0-9_])animation(-iteration-count|IterationCount)?[[:space:]]*[:=]"
  INF = "(^|[^A-Za-z])infinite([^A-Za-z]|$)"
  MO = "(^|[^A-Za-z0-9_$])((animate|initial|exit|variants|while[A-Z][A-Za-z]*)[[:space:]]*=[[:space:]]*\\{|(animate|initial|exit|while[A-Z][A-Za-z]*)[[:space:]]*:[[:space:]]*\\{|animate[[:space:]]*\\()|:[[:space:]]*Variants[[:space:]]*=[[:space:]]*\\{"
}
/^diff --git / { hdr = 1; lang = ""; mm = 0; next }
hdr && /^\+\+\+ / { f = $0; sub(/^\+\+\+ (b\/)?/, "", f); sub(/\t$/, "", f); file = f   # git tabs a name with a space
  lang = (file ~ /\.cs$/) ? "cs" : ((file ~ /\.tsx?$/) ? "ts" : "")
  # T1/T2 describe application code (adapters, JSX, hooks); specs keep doc blocks above helpers inside
  # describe() and use ternaries freely
  spec = (file ~ /(^|\/)(tests?|e2e|__tests__)\// || file ~ /[.-](spec|test|unit-spec|int-spec|e2e-spec)\.tsx?$/)
  if (lang == "ts" && spec) lang = ""
  mm = (file ~ /\.(s?css|tsx?|vue|svelte)$/ && !spec); cssf = (file ~ /\.(s?css|vue|svelte)$/)
  next }
hdr && !/^@@ / { next }
/^@@ / { hdr = 0; match($0, /\+[0-9]+/); nl = substr($0, RSTART + 1, RLENGTH - 1) + 0; inc = 0; doc = 0
  mo = 0; kf = 0; mc = ""; next }
/^\\/ { next }
{
  t = substr($0, 1, 1); raw = substr($0, 2)
  if (t == "-") next
  added = (t == "+"); ln = nl; nl++
  if (lang == "" && !mm) next     # nothing to lint in this file type: skip code() on its long lines
  c = code(raw)
  if (lang == "ts") {
    if (doc && c ~ /[^[:space:]]/) {   # the first code line after an indented doc block decides
      if (c ~ /^[[:space:]]*(const|let|var|return|if|for|while|switch|await|throw|try)([^A-Za-z0-9_$]|$)/ \
          || c ~ /^[[:space:]]*(use|set)[A-Z][A-Za-z0-9_]*[[:space:]]*(<[^>]*>)?\(/) hit("T2", file, docln, "", docraw)
      doc = 0
    }
    if (added && raw ~ /^[[:space:]]+\/\*\*/) { doc = 1; docln = ln; docraw = raw }
    if (added && raw !~ /ternary-ok/ && (c ~ /(^|[^?])[[:space:]]\?[[:space:]]/ || c ~ /^\?[[:space:]]/) \
        && c !~ /(^|[^A-Za-z0-9_$])extends[[:space:]].*\?/) hit("T1", file, ln, "", raw)
  }
  if (lang == "cs" && added) {
    if (raw !~ /var-ok/ && c ~ /(^|[^A-Za-z0-9_@.])var[[:space:]]+[A-Za-z_@(]/ && c !~ /new[[:space:]]*(\{|$)/) hit("C1", file, ln, "", raw)
    if (raw !~ /inherit-ok/ && match(c, /(^|[[:space:]])class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
      pre = substr(c, 1, RSTART); nm = substr(c, RSTART, RLENGTH); sub(/.*class[[:space:]]+/, "", nm)
      if (pre ~ /^[[:space:]]*([a-z]+[[:space:]]+)*$/ && pre !~ /(^|[[:space:]])(sealed|abstract|static)[[:space:]]/) hit("C2", file, ln, nm, raw)
    }
  }
  if (mm) motion()
}
AWK

hits="$(diffs | awk "$PROG")"

# C2 exemptions the line cannot show: a class some other class derives from is a base, and a partial class
# may carry `sealed` on another part. Test code is held to the SHOULD of the rule, not the MUST: a WARN.
c2keep() {  # $1 = class name -> exit 0 when the hit stands
  local w='[^A-Za-z0-9_]'
  # --untracked: the derived class is often in the same not-yet-added change
  git grep --untracked -qE "class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*(<[^>]*>)?[[:space:]]*:([^{]*$w)?$1($w|\$)" -- '*.cs' 2>/dev/null && return 1
  git grep --untracked -qE "sealed($w[^;{]*)?[[:space:]]class[[:space:]]+$1($w|\$)" -- '*.cs' 2>/dev/null && return 1
  return 0
}
# M2 exemption the line cannot show: a reduced-motion path anywhere in the file (the whole file at head).
m2keep() {  # $1 = file -> exit 0 when the hit stands
  { if [ -n "$head" ]; then git show "$head:$1"; else cat "$1"; fi; } 2>/dev/null \
    | grep -qE 'prefers-reduced-motion|useReducedMotion|reducedMotion|MotionConfig|motion-reduce:|motion-safe:' && return 1
  return 0
}
# bash 3.2 (macOS /bin/bash) has no associative arrays
why() { case "$1" in
  T1) echo "ternary - .claude/rules/frontend.md 'Branch explicitly': a named adapter, an early return, an 'as const' lookup, or {cond && <X/>} in JSX ('ternary-ok: <why>' on the line to keep)";;
  T2) echo "doc block inside a function body - .claude/rules/frontend.md 'Doc comments': the doc block lives ABOVE the declaration";;
  C1) echo "var - .claude/rules/backend.md 'Explicit types': state the type ('var-ok: anonymous type' on the line when var is required)";;
  C2) echo "class not sealed - .claude/rules/backend.md 'Sealed by default': add sealed, or abstract for a real base ('inherit-ok: <why>' on the line to keep)";;
  M1) echo "layout property animated - .claude/rules/frontend.md 'Motion': animate transform and opacity only; fake it with scale / clip-path / mask, or Motion's layout prop ('motion-ok: <why>' on the line to keep)";;
  M2) echo "endless animation in a file with no reduced-motion path - .claude/rules/frontend.md 'Motion' (WCAG 2.2.2): handle prefers-reduced-motion in this file ('loop-ok: <why>' on the line to keep)";;
esac; }
n=0
for r in T1 T2 C1 C2 M1 M2; do
  case "$skip" in *" $r "*) info "$r skipped (GATE_RULES_SKIP)"; continue;; esac
  rows="$(printf '%s\n' "$hits" | awk -F'\037' -v r="$r" '$1 == r')"
  [ -n "$rows" ] || continue
  shown=0; total=0
  while IFS=$'\037' read -r _ f ln nm src; do
    level=red
    if [ "$r" = C2 ]; then
      c2keep "$nm" || continue
      printf '%s' "$f" | grep -qE '(^|/)[^/]*[Tt]ests?(/|\.cs$)' && level=warn
    fi
    if [ "$r" = M2 ]; then m2keep "$f" || continue; fi
    total=$((total + 1))
    [ "$shown" -lt 25 ] || continue
    shown=$((shown + 1))
    "$level" "$r $f:$ln  $src"
  done <<< "$rows"
  [ "$total" -gt 0 ] || continue
  [ "$total" -gt "$shown" ] && info "$r ... and $((total - shown)) more"
  info "$r: $(why "$r")"
  n=$((n + total))
done
[ "$n" -eq 0 ] && info "GREEN - global rule lints satisfied ($(printf '%s\n' "$files" | wc -l | tr -d ' ') files)"
[ "$fail" -eq 0 ]
