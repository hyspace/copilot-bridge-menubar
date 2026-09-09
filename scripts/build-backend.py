#!/usr/bin/env python3
"""Stage the pinned source without altering the submodule or the user's running CLI."""
import json, os, pathlib, shutil, subprocess

root = pathlib.Path(__file__).resolve().parent.parent
stage = root / ".build" / "backend-stage"
vendor = root / "vendor" / "copilot-bridge"
if not (vendor / "src/server.ts").is_file():
    raise SystemExit("Run git submodule update --init --recursive first.")
if stage.exists():
    shutil.rmtree(stage)  # Only our disposable build staging directory.
(stage / "vendor").mkdir(parents=True)
shutil.copytree(root / "backend", stage / "backend")
shutil.copytree(vendor / "src", stage / "vendor/copilot-bridge/src")
shutil.copy(vendor / "package.json", stage / "vendor/copilot-bridge/package.json")
os.symlink((vendor / "node_modules").resolve(), stage / "vendor/copilot-bridge/node_modules")
shutil.copy(root / "tsconfig.json", stage / "tsconfig.json")
server = stage / "vendor/copilot-bridge/src/server.ts"
text = server.read_text()
anchor = '  const app = new Hono<BridgeEnv>()'
if text.count(anchor) != 1:
    raise SystemExit("Pinned server changed: review the LAN guard integration before building.")
text = 'import { validBridgeKey } from "../../../backend/lan-guard"\n' + text
text = text.replace(anchor, anchor + '''
  const key = process.env.CBM_LAN_KEY
  app.use("*", async (c, next) => {
    if (key && !validBridgeKey(c.req.header("x-bridge-key"), key)) {
      return c.json({error: {message: "Missing or invalid X-Bridge-Key"}}, 401)
    }
    await next()
  })
  app.get("/__menubar/health", (c) => c.json({
    ok: true, instance: process.env.CBM_INSTANCE_ID ?? null
  }))
''')
server.write_text(text)
# Bun's node:http may emit listen failures after serve() returns. Exit this backend,
# never signal another listener, and let the UI display a bounded restart failure.
text = server.read_text()
anchor = 'export const startServer = (config: BridgeConfig) =>\n  serve({'
if text.count(anchor) != 1:
    raise SystemExit("Pinned server lifecycle changed: review listen failure handling.")
text = text.replace(anchor, 'export const startServer = (config: BridgeConfig) => {\n  const server = serve({')
text = text.rstrip() + '''
  server.on("error", (error) => {
    console.error("Bridge listener failed:", error.message)
    process.exit(1)
  })
  return server
}
'''
server.write_text(text)
responses = stage / "vendor/copilot-bridge/src/routes/responses.ts"
text = responses.read_text()
anchor = 'return new Response(normalizeResponsesSseStream(upstream.body), {'
if text.count(anchor) != 1:
    raise SystemExit("Pinned Responses route changed: review transformed response header handling.")
text = text.replace(anchor, '''
const normalizedHeaders = new Headers(upstream.headers)
      normalizedHeaders.delete("content-length")
      normalizedHeaders.delete("content-encoding")
      return new Response(normalizeResponsesSseStream(upstream.body), {''')
text = text.replace('status: upstream.status,\n        headers: upstream.headers,',
                    'status: upstream.status,\n        headers: normalizedHeaders,', 1)
responses.write_text(text)
normalizer = stage / "vendor/copilot-bridge/src/bridges/codex/normalize-stream.ts"
text = normalizer.read_text()
marker = "export const normalizeResponsesSseStream = ("
if text.count(marker) != 1:
    raise SystemExit("Pinned stream normalizer changed: review lifecycle overlay.")
text = 'import { mapSSE } from "../../../../../backend/cancellable-stream"\n' + text.split(marker)[0] + '''
export const normalizeResponsesSseStream = (upstreamBody: ReadableStream<Uint8Array>) => {
  const stableResponse: StableResponseMetadata = { created_at: 0, id: "", initialized: false, model: "" }
  const outputItems = new Map<number, StableOutputItem>()
  return mapSSE(upstreamBody,
    (frame) => transformSseChunk(frame, stableResponse, outputItems),
    () => outputItems.clear())
}
'''
normalizer.write_text(text)
version_file = stage / "vendor/copilot-bridge/src/lib/version.ts"
version_file.write_text("export const BRIDGE_VERSION = "
    + json.dumps(json.loads((vendor/"package.json").read_text())["version"]) + "\n")
(stage/"tests").mkdir()
shutil.copy(vendor/"tests/codex-stream-normalizer.test.ts", stage/"tests")
out = root / "build" / "copilot-bridge-service"
out.parent.mkdir(exist_ok=True)
bun = os.environ.get("BUN") or shutil.which("bun") or str(pathlib.Path.home()/".bun/bin/bun")
subprocess.run([bun, "build", "--compile", "--target=bun-darwin-arm64",
                "backend/entry.ts", "--outfile", str(out)], cwd=stage, check=True)
subprocess.run([bun, "test", "tests/codex-stream-normalizer.test.ts"], cwd=stage, check=True)
