#!/usr/bin/env node
// Behavioural tests for run-guard.mjs (the Stop hook).
//
//   node .claude/hooks/run-guard.test.mjs
//   HOOK_PATH=/path/to/other-build.mjs node .claude/hooks/run-guard.test.mjs   # compare builds
//
// Runs the REAL hook as a child process with an isolated CLAUDE_CONFIG_DIR, so no live .locks marker is
// read, written or CONSUMED - the force-stop cases delete a token, and pointing them at the real lock
// directory would eat a token another session is holding.
//
// What it guards: this hook decides whether a session may end, so both directions are dangerous. Blocking
// on something the run cannot satisfy wedges the session until someone burns a force-stop token; letting
// it end with owed work open loses the log the next session needs.
import { spawnSync } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";

const HOOK = process.env.HOOK_PATH || fileURLToPath(new URL("./run-guard.mjs", import.meta.url));
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "run-guard-test-"));
const SANDBOX = path.join(ROOT, "config");
const LOCKS = path.join(SANDBOX, ".locks");

const reset = () => { fs.rmSync(LOCKS, { recursive: true, force: true }); fs.mkdirSync(LOCKS, { recursive: true }); };
const touch = (name, body = "") => fs.writeFileSync(path.join(LOCKS, name), body);
const age = (name, minutes) => {
  const t = new Date(Date.now() - minutes * 60 * 1000);
  fs.utimesSync(path.join(LOCKS, name), t, t);
};
const exists = (name) => fs.existsSync(path.join(LOCKS, name));
const due = (id, extra = {}) => touch(`syncdue-${id}.json`, JSON.stringify({ id, sessionId: "S-test", kind: id === "session" ? "commit" : "ticket", ...extra }));

function stop(payload) {
  const r = spawnSync(process.execPath, [HOOK], {
    input: JSON.stringify({ session_id: "S-test", ...payload }),
    env: { ...process.env, CLAUDE_CONFIG_DIR: SANDBOX },
    encoding: "utf8",
  });
  let out = null;
  try { out = JSON.parse((r.stdout || "").trim()); } catch {}
  return { blocked: out?.decision === "block", reason: out?.reason || "" };
}

let pass = 0, fail = 0;
function check(name, got, want, extra = "") {
  const okk = got === want;
  okk ? pass++ : fail++;
  console.log(`${okk ? "PASS" : "FAIL"}  ${name}${okk ? "" : `  -> got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}${extra ? `  ${extra}` : ""}`);
}

console.log(`hook: ${HOOK}\n`);

// ---- N1. self-loop protection, and an empty lock dir ends the session ----
reset(); due("session");
check("N1a stop_hook_active is a no-op", stop({ stop_hook_active: true }).blocked, false);
reset();
check("N1b nothing pending -> stop allowed", stop({}).blocked, false);

// ---- S. an owed session log holds the session ----
reset(); due("session");
const s1 = stop({});
check("S1a a commit with no session-sync is BLOCKED", s1.blocked, true);
check("S1b ... and the block names the agent", s1.reason.includes("session-sync"), true);
reset(); due("STORY-101");
const s2 = stop({});
check("S2a a ticket that reached review is BLOCKED", s2.blocked, true);
check("S2b ... and the block names the ticket", s2.reason.includes("STORY-101"), true);
reset(); due("session", { sessionId: "S-other" });
check("S3 another session's marker does not hold us", stop({}).blocked, false);
reset(); touch("syncdue-session.json", JSON.stringify({ id: "session", kind: "commit" }));
check("S4 an unattributed marker holds every session", stop({}).blocked, true);

// ---- N6. staleness ceiling: a dead run must not wedge the session forever ----
reset(); due("session"); age("syncdue-session.json", 91);
check("N6 a marker older than 90 min no longer blocks", stop({}).blocked, false);

// ---- N7. force-stop tokens are honoured AND consumed ----
reset(); due("session"); touch("force-stop-S-test");
check("N7a session-scoped force-stop allows the stop", stop({}).blocked, false);
check("N7b ... and the token is consumed", exists("force-stop-S-test"), false);
reset(); due("session"); touch("force-stop");
check("N7c the bare token still works for a hand-typed touch", stop({}).blocked, false);
check("N7d ... and is consumed too", exists("force-stop"), false);

// ---- N8. batch guard: only the OWNING session is conscripted ----
const runJson = (o) => touch("run.json", JSON.stringify(o));
reset(); runJson({ sessionId: "S-test", batchActive: true, batchTarget: 3, batchDone: 1 });
const n8 = stop({});
check("N8a the owner is held until the batch is exhausted", n8.blocked, true);
check("N8b the block counts what is left", n8.reason.includes("2 of 3"), true);
reset(); runJson({ sessionId: "S-other", batchActive: true, batchTarget: 3, batchDone: 1 });
check("N8c another session's batch does not conscript us", stop({}).blocked, false);
reset(); runJson({ batchActive: true, batchTarget: 3, batchDone: 1 });
check("N8d an unattributed batch blocks nobody", stop({}).blocked, false);
reset(); runJson({ sessionId: "S-test", batchActive: true, batchTarget: 3, batchDone: 3 });
check("N8e an exhausted batch releases the session", stop({}).blocked, false);
reset(); runJson({ sessionId: "S-test", batchActive: true, batchTarget: 3, batchDone: 1 }); age("run.json", 91);
check("N8f a stale batch releases the session", stop({}).blocked, false);

// ---- N9. one block carries every outstanding item ----
reset(); due("session"); runJson({ sessionId: "S-test", batchActive: true, batchTarget: 2, batchDone: 0 });
const n9 = stop({});
check("N9 log and batch are reported together", n9.reason.includes("session-sync") && n9.reason.includes("2 of 2"), true);

fs.rmSync(ROOT, { recursive: true, force: true });
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
