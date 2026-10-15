#!/usr/bin/env node
// run-guard.mjs - Stop hook. Refuses to let the session end while owed work is still open:
//   a) a session log is owed: sync-due.mjs wrote a fresh .locks/syncdue-*.json and session-sync never ran;
//   b) a declared batch is not exhausted: .locks/run.json {sessionId, batchActive, batchTarget, batchDone},
//      written by whatever runs the batch, and only binding on the session that declared it.
// Emits {"decision":"block","reason":...}, which makes the model continue instead of idling.
//
// An unattended run must never wedge a session forever, so there are two escape hatches:
//   1) a force-stop token: touch ~/.claude/.locks/force-stop-<session_id> (or the bare force-stop);
//      it is consumed on use, so it lets exactly one stop through;
//   2) a staleness ceiling: state untouched for STALE_MIN minutes is a dead run, and blocking serves nothing.
import fs from "fs"; import os from "os"; import path from "path";

const STALE_MIN = 90;
const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
const LOCKS = path.join(CLAUDE_DIR, ".locks");

let p = {}; try { p = JSON.parse(fs.readFileSync(0, "utf8").replace(/^\uFEFF/, "").trim()); } catch { process.exit(0); }
if (p.stop_hook_active) process.exit(0);                       // never loop on ourselves

// A global token is eaten by whichever session stops first, so a session-scoped one is preferred.
for (const f of [p.session_id && path.join(LOCKS, `force-stop-${p.session_id}`), path.join(LOCKS, "force-stop")])
  if (f && fs.existsSync(f)) { try { fs.unlinkSync(f); } catch {} process.exit(0); }

const fresh = (f) => { try { return (Date.now() - fs.statSync(f).mtimeMs) < STALE_MIN * 60 * 1000; } catch { return false; } };
const rj = (f, d) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch { return d; } };
const ls = (re) => { try { return fs.readdirSync(LOCKS).filter((f) => re.test(f)); } catch { return []; } };
// Findings are collected, not short-circuited: one block per Stop carries every outstanding item.
const reasons = [];

// a) a session log is owed. A marker stamped with another session's id is that session's business.
const syncDue = ls(/^syncdue-(.+)\.json$/)
  .filter((f) => fresh(path.join(LOCKS, f)))
  .map((f) => ({ f, d: rj(path.join(LOCKS, f), {}) }))
  .filter((x) => !x.d.sessionId || x.d.sessionId === p.session_id);
if (syncDue.length) {
  const tickets = syncDue.filter((x) => x.d.kind !== "commit").map((x) => x.d.id || x.f);
  const loose = syncDue.some((x) => x.d.kind === "commit");
  const what = [
    tickets.length ? `${tickets.join(", ")} reached review` : "",
    loose ? "a commit landed in this session" : "",
  ].filter(Boolean).join(" and ");
  reasons.push(`UNFINISHED: ${what}, but session-sync never ran. Run the session-sync agent now - do not ask first. Then continue. (If this genuinely needs no log, clear it: rm ~/.claude/.locks/syncdue-*.json)`);
}

// b) the batch this session declared is not exhausted
const run = rj(path.join(LOCKS, "run.json"), {});
if (run.sessionId && run.sessionId === p.session_id && run.batchActive
    && fresh(path.join(LOCKS, "run.json")) && (run.batchDone || 0) < (run.batchTarget || 0)) {
  const left = (run.batchTarget || 0) - (run.batchDone || 0);
  reasons.push(`UNFINISHED BATCH: ${left} of ${run.batchTarget} ticket(s) still to do. Do not stop and do not wait: take the next ticket and run the full pipeline on it. A ticket that needs a human is parked with a handoff note and counts as done. Record progress in ~/.claude/.locks/run.json (batchDone). (Emergency override: touch ~/.claude/.locks/force-stop-${p.session_id})`);
}

if (reasons.length) process.stdout.write(JSON.stringify({ decision: "block", reason: reasons.join("\n\n") }) + "\n");
process.exit(0);
