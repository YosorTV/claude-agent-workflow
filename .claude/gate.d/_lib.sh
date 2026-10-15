# gate.d/_lib.sh - shared helpers for the diff gates. Sourced, not executed.
# Contract: the caller sets $base (the ref to diff against, e.g. origin/develop) and runs from the repo root.
# Everything compares the BASE version with the WORKING COPY (committed or not, tracked or not), so a gate
# sees exactly what the push would carry and a brand-new untracked file counts as fully added.
fail=0
red()  { echo "[gate:${GATE_TAG:-diff}] RED  $*"; fail=1; }
warn() { echo "[gate:${GATE_TAG:-diff}] WARN $*"; }
info() { echo "[gate:${GATE_TAG:-diff}] $*"; }

changed_files() {
  { git diff --name-only "$base...HEAD" 2>/dev/null; git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } \
    | sort -u | sed '/^$/d' | while IFS= read -r f; do [ -e "$f" ] && printf '%s\n' "$f"; done
}
