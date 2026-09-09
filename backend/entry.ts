import { runMain, defineCommand } from "../vendor/copilot-bridge/node_modules/citty";
import { auth } from "../vendor/copilot-bridge/src/auth";
import { start } from "../vendor/copilot-bridge/src/start";
import { observeResponse, trackedURL } from "./telemetry";

const PREFIX = "@@CBM:";
const emit = (value: object) => process.stdout.write(`${PREFIX}${JSON.stringify(value)}\n`);
process.on("uncaughtException", (error) => {
  // A listener failure must not leave a headless zombie process retrying forever.
  emit({ kind: "fatal", message: String(error.message).slice(0, 512) });
  process.exit(1);
});
const parent = Number(process.env.CBM_PARENT_PID);
if (parent > 1) {
  // A killed/crashed menu app must never leave an orphan service consuming quota.
  setInterval(() => { if (process.ppid !== parent) process.exit(0); }, 2000).unref();
}
delete process.env.COPILOT_BRIDGE_TRACE_REQUESTS_FILE;
const type = process.env.COPILOT_ACCOUNT_TYPE ?? "individual";
const origin = new URL(process.env.COPILOT_BASE_URL
  ?? (type === "individual" ? "https://api.githubcopilot.com" : `https://api.${type}.githubcopilot.com`)).origin;
const original = globalThis.fetch;
globalThis.fetch = Object.assign(async (input: string | URL | Request, init?: RequestInit) => {
  const url = String(input instanceof Request ? input.url : input);
  const tracked = trackedURL(input, origin);
  let model = "unknown";
  if (tracked && typeof init?.body === "string") {
    try { model = String(JSON.parse(init.body).model ?? "unknown").slice(0, 128); } catch {}
  }
  const metadata = { id: crypto.randomUUID(), timestamp: Date.now() / 1000, model };
  let response: Response;
  try { response = await original(input, init); }
  catch (error) {
    if (tracked) emit({ ...metadata, kind: "usage", status: 0,
      input: null, output: null, cached: null, outcome: "interrupted" });
    throw error;
  }
  if (url === "https://github.com/login/device/code" && response.ok) {
    const value = await response.clone().json() as any;
    emit({ kind: "authRequired", code: value.user_code,
      url: "https://github.com/login/device", expiresIn: value.expires_in });
  }
  if (url === "https://github.com/login/oauth/access_token" && response.ok) {
    const value = await response.clone().json() as any;
    if (["expired_token", "access_denied", "incorrect_device_code"].includes(value.error)) {
      emit({ kind: "authFailed", message: "GitHub device authorization expired or was denied. Please sign in again." });
      throw new Error("Device authorization expired or denied");
    }
  }
  if (url === "https://api.github.com/copilot_internal/v2/token" && response.ok) {
    emit({ kind: "authSuccess" });
  }
  return tracked ? observeResponse(response, metadata, emit) : response;
}, { preconnect: original.preconnect }) as typeof fetch;

await runMain(defineCommand({
  meta: { name: "copilot-bridge-menubar-service", version: "0.1.0" },
  subCommands: {
    start,
    auth: {
      ...auth,
      async run(context: any) {
        await auth.run!(context);
        emit({ kind: "authSuccess" });
        // Upstream auth installs a refresh interval; a one-shot GUI login must exit.
        process.exit(0);
      }
    }
  }
}));
