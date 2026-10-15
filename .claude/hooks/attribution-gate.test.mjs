#!/usr/bin/env node
// Behavioural tests for attribution-gate.mjs (PreToolUse) and .githooks/commit-msg (git).
//
//   node .claude/hooks/attribution-gate.test.mjs
//
// Runs the REAL hooks as child processes. The PreToolUse cases feed a hook payload on stdin; the
// commit-msg cases run the git hook on a temp message file, the way git calls it.
import { spawnSync } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";

const HOOK = process.env.HOOK_PATH || fileURLToPath(new URL("./attribution-gate.mjs", import.meta.url));
const COMMIT_MSG = fileURLToPath(new URL("../../.githooks/commit-msg", import.meta.url));
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "attribution-gate-test-"));

const gate = (tool_name, tool_input) => {
  const r = spawnSync(process.execPath, [HOOK], { input: JSON.stringify({ tool_name, tool_input }), encoding: "utf8" });
  return { code: r.status, reason: (r.stderr || "").split("\n")[0] };
};
const run = (command) => gate("Bash", { command });

let pass = 0, fail = 0;
const check = (name, got, want, extra = "") => {
  const okk = got === want;
  okk ? pass++ : fail++;
  console.log(`${okk ? "PASS" : "FAIL"}  ${name}${okk ? "" : `  -> got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}${extra ? `  ${extra}` : ""}`);
};

console.log(`hook: ${HOOK}\n`);

// ---- A. attribution in anything that leaves the machine ----
check("A1 commit carrying a Claude-Session trailer denied",
  run('git commit -m "feat: cover the export\n\nClaude-Session: https://claude.ai/code/session_01x"').code, 2);
check("A2 commit carrying Co-Authored-By: Claude denied",
  run('git commit -m "fix: x" -m "Co-Authored-By: Claude <noreply@anthropic.com>"').code, 2);
check("A3 heredoc commit message with a generated-with line denied",
  run("git commit -F - <<'EOF'\nfeat: x\n\nGenerated with [Claude Code](https://claude.com/claude-code)\nEOF").code, 2);
check("A4 a PR body with a claude.ai link denied",
  run('gh pr create --title "feat: x" --body "Details: https://claude.ai/code/session_01x"').code, 2);
check("A5 a --trailer carrying attribution denied",
  run('git commit -m "fix: x" --trailer "Claude-Session: abc"').code, 2);
check("A6 a clean commit is allowed", run('git commit -m "fix: keep the cursor on null pages"').code, 0);
check("A7 writing a file that mentions attribution is not an outward write",
  run("cat > notes.md <<'EOF'\nNever add Claude-Session: trailers.\nEOF").code, 0);

// ---- B. the hooks cannot be switched off ----
check("B1 --no-verify on commit denied", run('git commit --no-verify -m "fix: x"').code, 2);
check("B2 multi-line --no-verify denied", run('git commit \\\n  --no-verify \\\n  -m "fix: x"').code, 2);
check("B3 -n inside a short-flag cluster denied", run('git commit -nm "fix: x"').code, 2);
check("B4 --no-verify after a pathspec denied", run("git commit -m 'fix: x' f --no-verify").code, 2);
check("B5 --amend --no-edit --no-verify denied", run("git commit --amend --no-edit --no-verify").code, 2);
check("B6 a prefix of --no-verify denied", run("git commit --no-verif -m 'fix: x'").code, 2);
check("B7 core.hooksPath on the command line denied", run("git -c core.hooksPath=/dev/null commit -m 'fix: x'").code, 2);
check("B8 --no-verify on push denied", run("git push --no-verify origin main").code, 2);
check("B9 -n on push is --dry-run, allowed", run("git push -n origin main").code, 0);
check("B10 grep -n before a commit is not --no-verify", run('grep -n foo bar.txt && git commit -m "fix: tidy"').code, 0);
check("B11 a message that mentions --no-verify is fine", run('git commit -m "docs: never use --no-verify"').code, 0);
check("B12 the second commit of a call is judged too", run("git commit -m 'one'; git commit --no-verify -m 'two'").code, 2);
check("B13 a commit inside a subshell is judged", run("(cd repo && git commit --no-verify -m x)").code, 2);

// ---- C. MCP writes ----
check("C1 a tracker note with a claude.ai link denied",
  gate("mcp__tracker__append_findings", { ticket_id: "STORY-101", markdown: "See https://claude.ai/code/artifact/7e79" }).code, 2);
check("C2 a clean tracker transition allowed",
  gate("mcp__tracker__transition", { ticket_id: "STORY-101", to_state: "in_review", note: "ready" }).code, 0);
check("C3 a read tool is not a write", gate("mcp__tracker__get_ticket", { ticket_id: "https://claude.ai/x" }).code, 0);

// ---- D. fail posture ----
const bad = spawnSync(process.execPath, [HOOK], { input: "not json", encoding: "utf8" });
check("D1 unparseable payload -> allow", bad.status, 0);

// ---- G. the git commit-msg hook ----
const msg = (name, text) => { const f = path.join(ROOT, name); fs.writeFileSync(f, text); return f; };
const commitMsg = (f) => spawnSync("bash", [COMMIT_MSG, f], { encoding: "utf8" }).status;
const f1 = msg("m1.txt", "feat: add export\n\nBody line.\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01x\n");
check("G1 trailer lines are stripped, the commit goes on", commitMsg(f1), 0);
check("G1 ... and the rest of the message is kept", fs.readFileSync(f1, "utf8"), "feat: add export\n\nBody line.\n");
const f2 = msg("m2.txt", "fix: x\n\nsee https://claude.ai/code/artifact/7e79 for the analysis\n");
check("G2 a claude.ai link inside a sentence is rejected", commitMsg(f2), 1);
const f3 = msg("m3.txt", "fix: keep the cursor on null pages\n");
check("G3 a clean message passes unchanged", [commitMsg(f3), fs.readFileSync(f3, "utf8")].join("|"), "0|fix: keep the cursor on null pages\n");

fs.rmSync(ROOT, { recursive: true, force: true });
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
