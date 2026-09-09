// Pure, lossless TOML planning. File ownership, backups and commits live in Swift.
// This module never reads a config file, contacts a server, or starts the service.
export const PROVIDER = "copilot_bridge_app";
const MARK = "# Copilot Bridge Codex App ";
const MAX_CONFIG = 1024 * 1024;
export interface ManagedConfigPlan {
  token: string;
  port: number;
  installedSelector: string;
  originalSelector: string | null;
  originalProviderDefined: boolean;
  block: string;
  separator: string;
}
export interface ConfigPlanRequest {
  action: "inspect" | "enable" | "disable" | "legacyOff";
  text: string;
  port: number;
  token?: string;
  session?: ManagedConfigPlan;
}
type Statement = { start: number; end: number; text: string };
function fail(message: string): never { throw new Error(message); }
const parse = (text: string): any => {
  if (typeof text !== "string" || Buffer.byteLength(text) > MAX_CONFIG) fail("Codex config is too large to modify safely.");
  try { return Bun.TOML.parse(text); }
  catch { return fail("Codex config is not valid TOML. No configuration was changed."); }
};

/** Logical statements, not lines: ignore fake keys/markers inside strings/arrays. */
function statements(text: string): Statement[] {
  const result: Statement[] = [];
  let start = 0, quote = "", triple = false, comment = false, square = 0, curly = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (comment) {
      if (c !== "\n") continue;
      comment = false;
    } else if (quote) {
      if (quote === '"' && c === "\\") { i++; continue; }
      if (triple && text.slice(i, i + 3) === quote.repeat(3)) {
        // TOML allows a run of four/five quotes at the end of a multiline string.
        let end = i + 3;
        while (text[end] === quote) end++;
        i = end - 1; quote = ""; triple = false;
      } else if (!triple && c === quote) quote = "";
      continue;
    } else if (c === "#") { comment = true; continue; }
    else if (c === '"' || c === "'") {
      quote = c; triple = text.slice(i, i + 3) === c.repeat(3);
      if (triple) i += 2;
      continue;
    } else if (c === "[") square++;
    else if (c === "]") square--;
    else if (c === "{") curly++;
    else if (c === "}") curly--;
    if (c === "\n" && square === 0 && curly === 0) {
      result.push({ start, end: i + 1, text: text.slice(start, i + 1) }); start = i + 1;
    }
  }
  if (start < text.length) result.push({ start, end: text.length, text: text.slice(start) });
  return result;
}

function selector(text: string): Statement | undefined {
  for (const statement of statements(text)) {
    const trimmed = statement.text.trim();
    if (trimmed.startsWith("[")) break; // Subsequent assignments belong to tables.
    if (!trimmed || trimmed.startsWith("#")) continue;
    const part = parse(statement.text);
    if (Object.hasOwn(part, "model_provider")) {
      if (typeof part.model_provider !== "string") fail("Codex model_provider must be a string.");
      return statement;
    }
  }
}

function replaceSelector(statement: string, value: string): string {
  // The statement has already been checked by Bun's TOML parser. Only replace
  // its string literal; retain indentation, quoted keys, comments and line endings.
  let quote = "", equal = -1;
  for (let i = 0; i < statement.length; i++) {
    const c = statement[i];
    if (quote) {
      if (quote === '"' && c === "\\") { i++; continue; }
      if (c === quote) quote = "";
    } else if (c === '"' || c === "'") quote = c;
    else if (c === "=") { equal = i; break; }
  }
  let start = equal + 1;
  while (/\s/.test(statement[start] ?? "") && start < statement.length) start++;
  const delimiter = statement[start];
  if (equal < 0 || !['"', "'"].includes(delimiter)) fail("Unsupported provider selector syntax. No configuration was changed.");
  const triple = statement.slice(start, start + 3) === delimiter.repeat(3);
  let end = start + (triple ? 3 : 1), found = false;
  while (end < statement.length) {
    if (delimiter === '"' && statement[end] === "\\") { end += 2; continue; }
    if (triple && statement.slice(end, end + 3) === delimiter.repeat(3)) {
      end += 3; while (statement[end] === delimiter) end++; found = true; break;
    }
    if (!triple && statement[end] === delimiter) { end++; found = true; break; }
    end++;
  }
  if (!found) fail("Unsupported provider selector syntax. No configuration was changed.");
  return statement.slice(0, start) + JSON.stringify(value) + statement.slice(end);
}

function reserved(text: string, parsed: any): boolean {
  return parsed.model_provider === PROVIDER || Object.hasOwn(parsed.model_providers ?? {}, PROVIDER)
    || statements(text).some(s => s.text.trim().startsWith(MARK));
}
function profileOverride(parsed: any): boolean {
  return typeof parsed.profile === "string"
    && parsed.profiles?.[parsed.profile]?.model_provider !== undefined;
}
function legacy(parsed: any, port: number): boolean {
  if (parsed.model_provider !== "bridge") return false;
  const provider = parsed.model_providers?.bridge;
  try {
    const url = new URL(provider?.base_url);
    return url.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)
      && Number(url.port) === port && url.pathname.replace(/\/$/, "") === "/v1"
      && !url.username && !url.password && !url.search && !url.hash
      && (provider.wire_api === undefined || provider.wire_api === "responses");
  } catch { return false; }
}

export function planConfig(request: ConfigPlanRequest): any {
  const { text, port } = request;
  if (!Number.isInteger(port) || port < 1024 || port > 65535) fail("Invalid Bridge port.");
  const parsed = parse(text);
  const root = selector(text);
  const mode = parsed.model_provider === PROVIDER ? "on" : legacy(parsed, port) ? "legacy" : "off";
  if (request.action === "inspect") {
    return { ok: true, mode, reserved: reserved(text, parsed), profileOverride: profileOverride(parsed) };
  }
  if (request.action === "legacyOff") {
    if (!legacy(parsed, port) || !root || reserved(text, parsed)) fail("The manual Bridge configuration no longer matches. No configuration was changed.");
    if (profileOverride(parsed)) fail("The selected Codex profile overrides the provider. Resolve that override before switching.");
    const result = text.slice(0, root.start) + text.slice(root.end);
    parse(result);
    return { ok: true, text: result };
  }
  if (request.action === "enable") {
    if (reserved(text, parsed)) fail("A managed provider or marker already exists without a verified backup. Review backups before changing anything.");
    if (profileOverride(parsed)) fail("The selected Codex profile overrides the provider. Resolve that override before switching.");
    if (legacy(parsed, port)) fail("This is an existing manual Bridge configuration. Switch it off first to establish a safe restore point.");
    if (typeof request.token !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(request.token)) fail("Invalid configuration transaction.");
    const newline = text.includes("\r\n") ? "\r\n" : "\n";
    let installedSelector = root ? replaceSelector(root.text, PROVIDER) : `model_provider = "${PROVIDER}"${newline}`;
    let result = root ? text.slice(0, root.start) + installedSelector + text.slice(root.end) : installedSelector + text;
    const separator = result.endsWith("\n") ? newline : newline + newline;
    const block = [
      `${MARK}BEGIN ${request.token}`,
      `[model_providers.${PROVIDER}]`,
      'name = "Copilot Bridge"',
      `base_url = "http://127.0.0.1:${port}/v1"`,
      'wire_api = "responses"',
      "supports_websockets = false",
      "requires_openai_auth = true",
      `${MARK}END ${request.token}`, "",
    ].join(newline);
    result += separator + block;
    installedSelector = selector(result)!.text;
    const verified = parse(result);
    if (verified.model_provider !== PROVIDER) fail("Could not validate the planned Codex provider.");
    return { ok: true, text: result, plan: {
      token: request.token, port, installedSelector, originalSelector: root?.text ?? null, block, separator,
      originalProviderDefined: typeof parsed.model_provider === "string"
        && Object.hasOwn(parsed.model_providers ?? {}, parsed.model_provider),
    } satisfies ManagedConfigPlan };
  }
  if (request.action === "disable") {
    const session = request.session;
    if (!session || typeof session.block !== "string" || typeof session.installedSelector !== "string"
      || !["\n", "\r\n", "\n\n", "\r\n\r\n"].includes(session.separator)) fail("The managed configuration backup is invalid.");
    if (!root || root.text !== session.installedSelector || parsed.model_provider !== PROVIDER) {
      fail("The provider selector was edited outside this app. Configuration was left unchanged; review backups.");
    }
    const all = statements(text);
    const starts = all.filter(s => s.text.trim() === `${MARK}BEGIN ${session.token}`);
    const ends = all.filter(s => s.text.trim() === `${MARK}END ${session.token}`);
    if (starts.length !== 1 || ends.length !== 1 || ends[0].end <= starts[0].start
      || text.slice(starts[0].start, ends[0].end) !== session.block) {
      fail("The managed provider block was edited or removed. Configuration was left unchanged; review backups.");
    }
    let start = starts[0].start;
    if (text.slice(start - session.separator.length, start) === session.separator) start -= session.separator.length;
    let result = text.slice(0, start) + text.slice(ends[0].end);
    const current = selector(result)!;
    let original = session.originalSelector ?? "";
    if (original && !original.endsWith("\n") && current.end < result.length) {
      original += current.text.endsWith("\r\n") ? "\r\n" : "\n";
    }
    result = result.slice(0, current.start) + original + result.slice(current.end);
    const restored = parse(result);
    if (reserved(result, restored)) fail("Additional managed-provider settings were found. Configuration was left unchanged.");
    if (session.originalProviderDefined && !Object.hasOwn(restored.model_providers ?? {}, restored.model_provider)) {
      fail("The previous provider definition was removed while Bridge was enabled. Configuration was left unchanged; review backups.");
    }
    return { ok: true, text: result };
  }
  return fail("Unsupported configuration operation.");
}

export async function runConfigPlanner(): Promise<void> {
  try {
    const reader = Bun.stdin.stream().getReader();
    const chunks: Uint8Array[] = [];
    let length = 0;
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      length += chunk.value.byteLength;
      if (length > 16 * MAX_CONFIG) fail("Configuration planning request is too large.");
      chunks.push(chunk.value);
    }
    const request = JSON.parse(Buffer.concat(chunks).toString("utf8")) as ConfigPlanRequest;
    console.log(JSON.stringify(planConfig(request)));
  } catch (error) {
    // Parser errors never echo config fragments or credentials into diagnostic logs.
    const message = error instanceof SyntaxError ? "Invalid configuration planning request."
      : error instanceof Error ? error.message : "Could not plan the Codex configuration.";
    console.log(JSON.stringify({ ok: false, error: message }));
    process.exitCode = 1;
  }
}
