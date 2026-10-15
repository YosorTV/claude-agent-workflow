#!/usr/bin/env node
// Behavioural tests for sync-due.mjs (the PostToolUse hook that makes session-sync a hard obligation).
//
//   node .claude/hooks/sync-due.test.mjs
//   HOOK_PATH=/path/to/other-build.mjs node .claude/hooks/sync-due.test.mjs   # compare builds
//
// Runs the REAL hook as a child process with an isolated CLAUDE_CONFIG_DIR, so no live .locks marker is
// read or written. The commit cases use REAL repos, because the hook asks git whether HEAD is fresh
// rather than trusting the command text.
import { spawnSync } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";

const HOOK = process.env.HOOK_PATH || fileURLToPath(new URL("./sync-due.mjs", import.meta.url));
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "sync-due-test-"));
const SANDBOX = path.join(ROOT, "config");
const LOCKS = path.join(SANDBOX, ".locks");

const reset = () => { fs.rmSync(LOCKS, { recursive: true, force: true }); fs.mkdirSync(LOCKS, { recursive: true }); };
const markers = () => { try { return fs.readdirSync(LOCKS).filter((f) => /^syncdue-/.test(f)).sort(); } catch { return []; } };
const seed = (name, body = "{}") => fs.writeFileSync(path.join(LOCKS, name), body);

function post(payload) {
  spawnSync(process.execPath, [HOOK], {
    input: JSON.stringify({ session_id: "S-test", ...payload }),
    env: { ...process.env, CLAUDE_CONFIG_DIR: SANDBOX },
    encoding: "utf8",
  });
  return markers();
}
const bash = (command, tool_response = "ok", cwd = REPO) =>
  post({ tool_name: "Bash", tool_input: { command }, tool_response, cwd });
const transition = (ticket_id, to_state, tool_response = '{"ok": true}') =>
  post({ tool_name: "mcp__tracker__transition", tool_input: { ticket_id, to_state }, tool_response });
const dispatch = (subagent_type, prompt) => post({ tool_name: "Agent", tool_input: { subagent_type, prompt } });

// FRESH has a commit made just now; STALE's HEAD is backdated past the window; BARE is not a repo.
const git = (dir, ...a) => spawnSync("git", ["-C", dir, ...a], { encoding: "utf8" });
const mkrepo = (name, when) => {
  const d = path.join(ROOT, name);
  fs.mkdirSync(d, { recursive: true });
  git(d, "init", "-q");
  git(d, "config", "user.email", "t@t");
  git(d, "config", "user.name", "t");
  fs.writeFileSync(path.join(d, "f.txt"), "x");
  git(d, "add", "f.txt");
  const env = when ? { GIT_AUTHOR_DATE: when, GIT_COMMITTER_DATE: when } : {};
  spawnSync("git", ["-C", d, "commit", "-q", "-m", "seed"], { encoding: "utf8", env: { ...process.env, ...env } });
  return d;
};
const REPO = mkrepo("fresh");
const STALE = mkrepo("stale", "2020-01-01T00:00:00Z");
const BARE = fs.mkdtempSync(path.join(ROOT, "notrepo-"));

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  ok ? pass++ : fail++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : `  -> got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
}

console.log(`hook: ${HOOK}\n`);

// ---- A. a ticket reaches a review state through the tracker MCP ----
reset();
check("A1 transition to in_review arms the ticket marker", transition("STORY-101", "in_review"), ["syncdue-STORY-101.json"]);
reset();
check("A2 a move to a non-review state arms nothing", transition("STORY-101", "in_progress"), []);
reset();
check("A3 a REFUSED transition arms nothing",
  transition("STORY-101", "in_review", '{"ok": false, "reason": "todo -> in_review is not a legal transition"}'), []);
reset();
const a4 = JSON.parse(fs.readFileSync(path.join(LOCKS, transition("STORY-101", "ready_to_merge")[0]), "utf8"));
check("A4 the ticket marker records kind, state and session", [a4.kind, a4.state, a4.sessionId], ["ticket", "ready_to_merge", "S-test"]);

// ---- B. a committed task with no ticket ----
reset();
check("B1 a git commit arms the session-wide marker", bash('git commit -m "fix: scope the capture"'), ["syncdue-session.json"]);
reset();
check("B2 nothing-to-commit leaves HEAD stale, so no task shipped",
  bash("git commit -m x", "nothing to commit, working tree clean", STALE), []);
reset();
check("B3 --dry-run is not a commit", bash("git commit --dry-run -m x"), []);
reset();
check("B4 wrapped and -C forms still count", bash('command git -C /repo commit -m "x"'), ["syncdue-session.json"]);
// prose that merely mentions git commit must not read as an invocation, even with a fresh HEAD
reset();
check("B5 prose that mentions git commit is not a commit",
  bash("cat > note.md <<'EOF'\nthe sync script never types `git commit`.\nEOF"), []);
reset();
check("B6 a quiet commit still counts (-q prints nothing to match on)", bash("git commit -q -m x", ""), ["syncdue-session.json"]);
reset();
check("B7 a commit command outside a repo arms nothing", bash("git commit -m x", "ok", BARE), []);
// the payload's cwd is the SESSION's; `cd <repo> && git commit` is the ordinary shape
reset();
check("B8 a commit after `cd <repo>` counts though the session cwd is not a repo",
  bash(`cd ${REPO} && git commit -m x`, "ok", BARE), ["syncdue-session.json"]);
reset();
check("B9 ... and a stale repo named by cd still arms nothing", bash(`cd ${STALE} && git commit -m x`, "ok", BARE), []);
if (process.platform === "win32") {
  const msys = REPO.replace(/^([A-Za-z]):[\\/]/, (_, d) => `/${d.toLowerCase()}/`).replace(/\\/g, "/");
  reset();
  check("B10 an MSYS cd target resolves to its Windows path", bash(`cd ${msys} && git commit -m x`, "ok", BARE), ["syncdue-session.json"]);
}
// the session-sync agent's own commit satisfies the obligation and must never re-arm it
const commitAs = (agent_type) =>
  post({ tool_name: "Bash", tool_input: { command: 'git commit -m "log"' }, tool_response: "ok", cwd: REPO, ...(agent_type && { agent_type }) });
reset();
check("B11 the session-sync agent's own commit arms nothing", commitAs("session-sync"), []);
reset();
check("B12 the same commit from the main session arms", commitAs(), ["syncdue-session.json"]);
reset();
check("B13 the same commit from another subagent arms", commitAs("developer"), ["syncdue-session.json"]);

// ---- C. session-sync releases the obligation ----
reset(); seed("syncdue-STORY-101.json"); seed("syncdue-session.json");
check("C1 a dispatch naming the ticket clears the ticket AND the session marker", dispatch("session-sync", "log STORY-101"), []);
reset(); seed("syncdue-STORY-101.json"); seed("syncdue-STORY-102.json");
check("C2 a named dispatch leaves an unnamed ticket outstanding", dispatch("session-sync", "log STORY-101"), ["syncdue-STORY-102.json"]);
reset(); seed("syncdue-STORY-101.json"); seed("syncdue-session.json");
check("C3 a dispatch naming nothing clears everything", dispatch("session-sync", "log this session"), []);
reset(); seed("syncdue-session.json");
check("C4 another agent clears nothing, even if its prompt mentions session-sync",
  dispatch("reviewer", "review STORY-101, then session-sync runs"), ["syncdue-session.json"]);

// ---- D. the escape hatch ----
reset(); seed("sync-due-off", "");
check("D1 sync-due-off disables the obligation", transition("STORY-101", "in_review"), []);

// ---- E. fail open ----
const bad = spawnSync(process.execPath, [HOOK], { input: "not json", env: { ...process.env, CLAUDE_CONFIG_DIR: SANDBOX }, encoding: "utf8" });
check("E1 unparseable payload exits 0", bad.status, 0);

console.log(`\n${pass} passed, ${fail} failed`);
fs.rmSync(ROOT, { recursive: true, force: true });
process.exit(fail ? 1 : 0);
