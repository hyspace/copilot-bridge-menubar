import { describe, expect, test } from "bun:test";
import { planConfig, PROVIDER } from "./codex-config-plan";

const token = "12345678-abcd-4000-8000-123456789abc";
const enable = (text: string) => planConfig({ action: "enable", text, port: 4142, token });
const restore = (text: string, session: any) => planConfig({ action: "disable", text, port: 4142, session }).text as string;
const fixtures = [
  "",
  'model = "a"',
  'model_provider = "openai"',
  '# keep this\r\nmodel_provider = \'other\' # comment\r\nmodel = "a"\r\n[projects."/tmp/x"]\r\ntrust_level = "trusted"\r\n',
  '"model_provider" = """openai"""\nmodel_supports_reasoning_summaries = true\n',
  'model_provider = "openai"\nnotes = """\nmodel_provider = "fake"\n[model_providers.fake]\n# Copilot Bridge Codex App BEGIN fake\n"""\n',
  'items = [\n {value = "[fake]", other = "#not-a-comment"},\n]\n[model_providers.other]\nname = "Other"\n',
  'text = \'\'\'literal\nmodel_provider = "fake"\n\'\'\'\n',
  'text = """escaped \\" and backslash \\\\ and ending quote""""\n',
];
describe("lossless Codex App config plans", () => {
  for (const [index, original] of fixtures.entries()) {
    test(`round trip preserves bytes, comments and scopes ${index}`, () => {
      const changed = enable(original);
      const parsed = Bun.TOML.parse(changed.text) as any;
      expect(parsed.model_provider).toBe(PROVIDER);
      expect(parsed.model_providers[PROVIDER]).toMatchObject({
        requires_openai_auth: true, supports_websockets: false,
        wire_api: "responses", base_url: "http://127.0.0.1:4142/v1",
      });
      expect(restore(changed.text, changed.plan)).toBe(original);
    });
  }
  test("preserves unrelated edits made while enabled", () => {
    const before = 'model = "first"\nmodel_provider = "custom"\n[model_providers.custom]\nname = "Custom"\n';
    const changed = enable(before);
    const edited = changed.text.replace('model = "first"', 'model = "second"')
      + '\n[projects."/new/project"]\ntrust_level = "trusted"\n';
    const result = restore(edited, changed.plan);
    expect(result).toContain('model = "second"');
    expect(result).toContain('[projects."/new/project"]');
    expect((Bun.TOML.parse(result) as any).model_provider).toBe("custom");
    expect(result).not.toContain(PROVIDER);
  });
  test("restores a no-newline selector safely when new root settings were inserted", () => {
    const changed = enable('model_provider = "openai"');
    const edited = changed.text.replace(changed.plan.installedSelector,
      changed.plan.installedSelector + 'model = "new"\n');
    const result = restore(edited, changed.plan);
    expect(Bun.TOML.parse(result)).toMatchObject({ model_provider: "openai", model: "new" });
  });
  test("never overwrites changes inside managed fields", () => {
    const changed = enable('model = "test"\n');
    for (const edited of [
      changed.text.replace('model_provider = "copilot_bridge_app"', 'model_provider = "other"'),
      changed.text.replace('name = "Codex Bridge"', 'name = "Edited"'),
      changed.text.replace("requires_openai_auth = true", "requires_openai_auth = false"),
      changed.text.replace(changed.plan.block, ""),
      changed.text + '\n[model_providers.copilot_bridge_app.http_headers]\nx = "edited"\n',
    ]) expect(() => restore(edited, changed.plan)).toThrow();
  });
  test("does not restore a provider selector whose old definition was removed", () => {
    const definition = '[model_providers.custom]\nname="Original"\n';
    const changed = enable('model_provider="custom"\n' + definition);
    expect(() => restore(changed.text.replace(definition, ""), changed.plan)).toThrow("previous provider definition");
  });
  test("restores a source-qualified Bridge model from the verified baseline only", () => {
    const before = 'model = "original" # keep\nmodel_reasoning_effort = "high"\n';
    const changed = enable(before);
    const edited = changed.text.replace('"original"', '"local/org/model"') + '\n[projects."/new"]\ntrust_level="trusted"\n';
    expect(() => restore(edited, changed.plan)).toThrow("verified pre-Bridge");
    const result = planConfig({ action: "disable", text: edited, port: 4142, session: changed.plan, originalText: before }).text;
    expect(result).toContain('model = "original" # keep');
    expect(result).toContain('model_reasoning_effort = "high"');
    expect(result).toContain('[projects."/new"]');
    expect(result).not.toContain("local/org/model");
  });
  test("a previously absent model returns to the original provider's default", () => {
    const changed = enable("");
    const edited = 'model="copilot/same-model"\n' + changed.text;
    const result = planConfig({ action: "disable", text: edited, port: 4142, session: changed.plan, originalText: "" }).text;
    expect((Bun.TOML.parse(result) as any).model).toBeUndefined();
  });
  test("an original custom provider's own slash-qualified model is restored verbatim", () => {
    const before = 'model_provider="original"\nmodel="local/custom-provider-model"\n';
    const changed = enable(before);
    const text = changed.text.replace("local/custom-provider-model", "copilot/another");
    const result = planConfig({ action: "disable", text, port: 4142, session: changed.plan, originalText: before }).text;
    expect(result).toBe(before);
  });
  test("rejects duplicate keys, invalid TOML and reserved data without leaking input", () => {
    for (const text of [
      'model_provider = "a"\nmodel_provider = "b"\n',
      'secret = "private-value', '[model_providers.copilot_bridge_app]\nname="User-owned"\n',
      'model_provider = "copilot_bridge_app"\n',
      '# Copilot Bridge Codex App BEGIN orphan\n',
    ]) {
      expect(() => enable(text)).toThrow();
      try { enable(text); } catch (error) { expect(String(error)).not.toContain("private-value"); }
    }
    expect(() => enable('model_provider = 123\n')).toThrow();
    expect(() => enable("#" + "x".repeat(1024 * 1024))).toThrow();
  });
  test("active profile overrides fail closed; unrelated profiles are preserved", () => {
    expect(() => enable('profile="work"\n[profiles.work]\nmodel_provider="custom"\n')).toThrow();
    const text='[profiles.work]\nmodel_provider="custom"\n';
    expect(restore(enable(text).text, enable(text).plan)).toBe(text);
  });
  test("manual Bridge adoption chooses default without deleting the user-owned provider", () => {
    const text='model_provider = "bridge"\nmodel = "keep"\n[model_providers.bridge]\nbase_url="http://127.0.0.1:4142/v1"\nwire_api="responses"\n';
    expect(planConfig({ action: "inspect", text, port: 4142 }).mode).toBe("legacy");
    expect(planConfig({ action: "inspect", text: text.replace('wire_api="responses"\n', ""), port: 4142 }).mode).toBe("legacy");
    expect(() => enable(text)).toThrow();
    const result=planConfig({ action: "legacyOff", text, port: 4142 }).text;
    expect(result).toContain("[model_providers.bridge]");
    expect(Bun.TOML.parse(result)).toMatchObject({ model: "keep" });
    expect((Bun.TOML.parse(result) as any).model_provider).toBeUndefined();
    expect(() => planConfig({ action: "legacyOff", text, port: 4143 })).toThrow();
  });
});
