---
name: feedback-never-disrupt-print
description: Never send disruptive commands to the resin printer; only receive-only status + idle-verified start-print
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 91f056c4-972f-4b31-94af-319ce5f85c8b
---

When working with the user's Phrozen resin printer, tooling must NEVER send a disruptive SDCP command (stop `Cmd 130`, pause, cancel, etc.). The ONLY write command allowed is start-print (`Cmd 128`), and only after re-verifying the printer is idle in the same request.

**Why:** During diagnostics I sent a "safety stop" (`Cmd 130`) assuming a "printing" status was caused by my own test command — but the printer had a REAL job running, and I cancelled the user's print at layer 62/245. A real, hard-to-reverse loss. The user was (rightly) upset and set explicit rules afterward.

**How to apply:**
- Detect printer state with a RECEIVE-ONLY WebSocket listen (send nothing) — it physically cannot interrupt a print. See [[reference-sdcp-revo-printer]].
- Always check whether a print is active BEFORE sending anything; if not verifiably idle, do nothing.
- In UI: Print/Delete buttons must be greyed out unless idle; the server must also refuse the action unless idle (defense in depth).
- Never leave scripts containing stop/pause commands lying around in the project.
- When the user says they're starting/restarting a print, do not contact the printer at all until they confirm it's safe.
