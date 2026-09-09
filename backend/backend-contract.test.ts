import {afterEach,expect,spyOn,test} from "bun:test";
import {BRIDGE_EVENT_PREFIX,emitBridgeEvent} from "../vendor/copilot-bridge/src/lib/events";
const original=process.env.COPILOT_BRIDGE_EVENTS_TOKEN;
afterEach(()=>{
  if(original===undefined)delete process.env.COPILOT_BRIDGE_EVENTS_TOKEN;
  else process.env.COPILOT_BRIDGE_EVENTS_TOKEN=original;
});
test("pinned CLI exports the native application's authenticated event contract",()=>{
  const output:string[]=[];
  const spy=spyOn(process.stdout,"write").mockImplementation((value:any)=>{output.push(String(value));return true});
  try {
    delete process.env.COPILOT_BRIDGE_EVENTS_TOKEN;
    emitBridgeEvent({kind:"authSuccess"});
    expect(output).toHaveLength(0);
    process.env.COPILOT_BRIDGE_EVENTS_TOKEN="fake-channel";
    emitBridgeEvent({kind:"authSuccess"});
    expect(BRIDGE_EVENT_PREFIX).toBe("@@CBM:");
    expect(JSON.parse(output[0].slice(BRIDGE_EVENT_PREFIX.length))).toEqual({kind:"authSuccess",channel:"fake-channel"});
  } finally {spy.mockRestore()}
});
