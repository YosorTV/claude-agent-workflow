#!/usr/bin/env bash
# gate.test.sh - behavioural checks for bin/gate.sh (zero steps is RED, counts in the receipt, the gate.d
# hook) and for gate.d/_rules.sh (the global rule lints). Portable across BSD (macOS) and GNU tools.
#   bash .claude/bin/gate.test.sh
# Runs copies of the scripts in a temp install tree with an isolated CLAUDE_CONFIG_DIR, so no live receipt
# is read or written and no real gate.d file is touched.
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
mkdir -p "$T/inst/bin" "$T/inst/gate.d" "$T/cfg/.gate"
cp "$SRC/bin/gate.sh" "$T/inst/bin/"; cp "$SRC/gate.d/"*.sh "$T/inst/gate.d/"
export CLAUDE_CONFIG_DIR="$T/cfg"
GS="$T/inst/bin/gate.sh"; RG="$T/inst/gate.d/_rules.sh"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS  $1"; else fail=$((fail+1)); echo "FAIL  $1  -> got '$2', want '$3'"; fi; }
mkrepo() { local d="$T/$1"; mkdir -p "$d"; git -C "$d" init -q -b develop; git -C "$d" config user.email t@t; git -C "$d" config user.name t; git -C "$d" config core.autocrlf false; echo a > "$d/a.txt"; git -C "$d" add .; git -C "$d" commit -qm init; echo "$d"; }
# a fake origin/develop so the diff gates have a base
origin() { git -C "$1" update-ref refs/remotes/origin/develop HEAD; }

# ---------- gate.sh: zero steps -> RED, no receipt ----------
r="$(mkrepo empty-repo)"; origin "$r"
printf '{"name":"empty-repo","scripts":{"test:e2e":"node run.js"}}\n' > "$r/package.json"
out="$(cd "$r" && bash "$GS" 2>&1)"; rc=$?
check "G1 package.json without lint/build/test is RED (not a vacuous GREEN)" "$rc" "1"
check "G1 ... no receipt written" "$(ls "$T/cfg/.gate" | wc -l | tr -d ' ')" "0"
check "G1 ... explains the fix" "$(echo "$out" | grep -c 'gate.d/empty-repo.env')" "1"

# ---------- gate.sh: GATE_CMD runs, counts harvested, receipt carries them ----------
r="$(mkrepo counted)"; origin "$r"
out="$(cd "$r" && GATE_CMD='echo "Tests: 2 failed, 5 passed, 7 total"; true' bash "$GS" 2>&1)"; rc=$?
check "G2 GATE_CMD green" "$rc" "0"
rec="$(ls "$T/cfg/.gate"/counted-*.ok 2>/dev/null | head -1)"
check "G2 ... receipt has counts" "$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(r.counts.passed+"/"+r.counts.failed)' "$rec")" "5/2"
check "G2 ... receipt is keyed to HEAD" "$(basename "$rec")" "counted-$(git -C "$r" rev-parse HEAD).ok"

# ---------- gate.sh: a failing step is RED and leaves no receipt ----------
r="$(mkrepo failing)"; origin "$r"
out="$(cd "$r" && GATE_CMD='exit 3' bash "$GS" 2>&1)"; rc=$?
check "G3 a failing step -> RED" "$rc" "1"
check "G3 ... no receipt written" "$(ls "$T/cfg/.gate"/failing-*.ok 2>/dev/null | wc -l | tr -d ' ')" "0"

# ---------- gate.sh: gate.d/<repo>.sh runs and can turn the run RED ----------
r="$(mkrepo hooked)"; origin "$r"
printf '#!/usr/bin/env bash\necho "[gate:test] diff gate saw base=$2"; exit 1\n' > "$T/inst/gate.d/hooked.sh"
out="$(cd "$r" && GATE_CMD='true' bash "$GS" 2>&1)"; rc=$?
check "G4 gate.d script failure -> RED" "$rc" "1"
check "G4 ... base ref passed" "$(echo "$out" | grep -c 'base=origin/develop')" "1"

# ---------- global rule lints: gate.d/_rules.sh ----------
rr="$(mkrepo rules-repo)"; mkdir -p "$rr/src" "$rr/App"
printf 'export const legacy = (a: boolean) => a ? 1 : 2;\n' > "$rr/src/legacy.ts"
printf 'public class Legacy\n{\n    void M()\n    {\n        var x = 1;\n    }\n}\n' > "$rr/App/Legacy.cs"
git -C "$rr" add .; git -C "$rr" commit -qm seed; origin "$rr"
rl() { out="$(bash "$RG" "$rr" origin/develop "$@" 2>&1)"; rc=$?; }
rr_reset() { git -C "$rr" reset -q --hard origin/develop; git -C "$rr" clean -qfd; }
rr_reset; printf 'export const pick = (open: boolean) => open ? "a" : "b";\n' > "$rr/src/new.ts"; rl
check "R1 a new ternary (untracked file) -> RED" "$rc" "1"
check "R1 ... names rule, file and line" "$(echo "$out" | grep -c 'RED  T1 src/new.ts:1 ')" "1"
rr_reset; printf 'export const pick = (open: boolean) => open ? "a" : "b"; // ternary-ok: library signature\n' > "$rr/src/new.ts"; rl
check "R2 ternary-ok on the line -> GREEN" "$rc" "0"
rr_reset; cat > "$rr/src/clean.ts" <<'EOF'
/** Top-level doc is fine. */
export function f(p?: number, o?: { q?: string }): string {
  const s = 'is it ? yes : no';
  /* a ? b : c in a comment */
  return o?.q ?? String(p ?? 0) + s;
}
export type Pick<X> = X extends string ? 1 : 2;
export interface Props {
  /** shown above the field */
  label: string;
}
EOF
rl
check "R3 ??, ?., optional params, strings, comments, conditional types, member docs -> GREEN" "$rc" "0"
rr_reset; printf 'export const V = ({ open }: { open: boolean }) => (\n  <div>\n    {open\n      ? <A />\n      : <B />}\n  </div>\n);\n' > "$rr/src/View.tsx"; rl
check "R4 a multi-line JSX ternary -> RED" "$rc" "1"
rr_reset; printf 'export const legacy = (a: boolean) => a ? 1 : 2;\nexport const added = 1;\n' > "$rr/src/legacy.ts"; rl
check "R5 an untouched legacy ternary in an edited file -> GREEN (added lines only)" "$rc" "0"
rr_reset; mkdir -p "$rr/src/__tests__"; printf 'const v = flag ? 1 : 2;\n' > "$rr/src/thing.spec.ts"; printf 'const v = flag ? 1 : 2;\n' > "$rr/src/__tests__/t.ts"; rl
check "R6 ternaries in specs and __tests__ -> GREEN (application-code rule)" "$rc" "0"
rr_reset; printf 'export function useThing() {\n  /** what the flag means */\n  const flag = true;\n  return flag;\n}\n' > "$rr/src/useThing.ts"; rl
check "R7 a doc block inside a hook body -> RED at the doc line" "$rc:$(echo "$out" | grep -c 'RED  T2 src/useThing.ts:2 ')" "1:1"
rr_reset; printf 'export const v = cond ? 1 : 2;\n' > "$rr/src/new.ts"
out="$(GATE_RULES_SKIP="T1" bash "$RG" "$rr" origin/develop 2>&1)"; rc=$?
check "R8 GATE_RULES_SKIP=T1 -> GREEN, and says so" "$rc:$(echo "$out" | grep -c 'T1 skipped')" "0:1"
rr_reset; printf 'public class Thing\n{\n    void M()\n    {\n        var count = 1;\n    }\n}\n' > "$rr/App/Thing.cs"; rl
check "R9 a new unsealed class and a var -> RED, both named" "$rc:$(echo "$out" | grep -cE 'RED  (C1 App/Thing.cs:5|C2 App/Thing.cs:1) ')" "1:2"
rr_reset; cat > "$rr/App/Thing.cs" <<'EOF'
public sealed class Thing
{
    void M(System.Collections.Generic.List<int> items)
    {
        int count = 1;
        string variance = "var x = 1";
        var rows = items.Select(i => new { Id = i });
        var shaped = items.Select(i => new
        {
            Id = i
        });
        var legacyStyle = 2; // var-ok: mirrors the generated client
    }
}
public abstract class Base { }
public static class Helpers { }
public class Parent { }
public sealed class Child : Parent { }
EOF
rl
check "R10 sealed/abstract/static, a base something derives from, anonymous types, var-ok, 'variance' -> GREEN" "$rc" "0"
rr_reset; printf 'public class Legacy\n{\n    void M()\n    {\n        var x = 1;\n        int y = 2;\n    }\n}\n' > "$rr/App/Legacy.cs"; rl
check "R11 legacy var and unsealed class untouched in an edited file -> GREEN" "$rc" "0"
rr_reset; mkdir -p "$rr/tests/App.Tests"; printf 'public class ThingTests\n{\n}\n' > "$rr/tests/App.Tests/ThingTests.cs"; rl
check "R12 an unsealed test class -> WARN, not RED" "$rc:$(echo "$out" | grep -c 'WARN C2 ')" "0:1"
rr_reset; printf 'export const v = cond ? 1 : 2;\n' > "$rr/src/committed.ts"; git -C "$rr" add .; git -C "$rr" commit -qm c; rl HEAD
check "R13 head mode lints a commit -> RED" "$rc" "1"
rr_reset; printf '.panel { transition: height 0.3s ease; }\n' > "$rr/src/panel.css"; rl
check "M1 a transition on height -> RED" "$rc:$(echo "$out" | grep -c 'RED  M1 src/panel.css:1 ')" "1:1"
rr_reset; printf '.panel { transition: transform 0.3s ease, opacity 0.3s ease; }\n' > "$rr/src/panel.css"; rl
check "M1 transform and opacity -> GREEN" "$rc" "0"
rr_reset; printf '.panel { transition: width 0.3s; } /* motion-ok: one-off measured layout */\n' > "$rr/src/panel.css"; rl
check "M1 motion-ok on the line -> GREEN" "$rc" "0"
rr_reset; printf '.dot { animation: pulse 1s infinite; }\n' > "$rr/src/dot.css"; rl
check "M2 an endless animation with no reduced-motion path -> RED" "$rc:$(echo "$out" | grep -c 'RED  M2 src/dot.css:1 ')" "1:1"
rr_reset; printf '.dot { animation: pulse 1s infinite; }\n@media (prefers-reduced-motion: reduce) { .dot { animation: none; } }\n' > "$rr/src/dot.css"; rl
check "M2 ... with a prefers-reduced-motion branch in the file -> GREEN" "$rc" "0"

# ---------- gate.sh wires the rule lints ----------
gi="$(mkrepo rules-wired)"; origin "$gi"; mkdir -p "$gi/src"; printf 'export const v = c ? 1 : 2;\n' > "$gi/src/x.ts"
out="$(cd "$gi" && GATE_CMD='true' bash "$GS" 2>&1)"; rc=$?
check "W1 gate.sh runs the rule lints on a repo with no diff gate -> RED" "$rc" "1"
printf 'GATE_CMD=true\nGATE_RULES_SKIP="T1"\n' > "$T/inst/gate.d/rules-wired.env"
out="$(cd "$gi" && bash "$GS" 2>&1)"; rc=$?
check "W2 ... and its gate.d/<repo>.env switches a rule off -> GREEN" "$rc" "0"

rm -rf "$T"
echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
