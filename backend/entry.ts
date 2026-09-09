import { emitBridgeEvent } from "../vendor/copilot-bridge/src/lib/events";

// Model, auth, LAN and accounting behavior live in the pinned CLI fork.
process.on("uncaughtException", (error) => {
  emitBridgeEvent({ kind: "fatal", message: String(error.message).slice(0, 512) });
  process.exit(1);
});
const parent = Number(process.env.CBM_PARENT_PID);
if (parent > 1) {
  setInterval(() => { if (process.ppid !== parent) process.exit(0); }, 2000).unref();
}
delete process.env.COPILOT_BRIDGE_TRACE_REQUESTS_FILE;
await import("../vendor/copilot-bridge/src/main");
