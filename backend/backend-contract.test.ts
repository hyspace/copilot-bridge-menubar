import {afterEach,expect,spyOn,test} from "bun:test";
import {BRIDGE_EVENT_PREFIX,emitBridgeEvent} from "../vendor/copilot-bridge/src/lib/events";
import {observeResponse} from "../vendor/copilot-bridge/src/lib/usage-telemetry";
const original=process.env.COPILOT_BRIDGE_EVENTS_TOKEN;
afterEach(()=>{
  if(original===undefined)delete process.env.COPILOT_BRIDGE_EVENTS_TOKEN;
  else process.env.COPILOT_BRIDGE_EVENTS_TOKEN=original;
});
test("pinned backend emits raw server billing on the authenticated usage channel",async()=>{
  process.env.COPILOT_BRIDGE_EVENTS_TOKEN="fake-channel";
  const output:string[]=[];
  const spy=spyOn(process.stdout,"write").mockImplementation((value:any)=>{output.push(String(value));return true});
  try {
    const body=JSON.stringify({usage:{input_tokens:100,output_tokens:20,
      copilot_usage:{total_nano_aiu:1234567891}}});
    const response=observeResponse(new Response(body,{headers:{"content-type":"application/json"}}),
      {id:"billing-contract",model:"fake-model",timestamp:1},emitBridgeEvent);
    expect(await response.text()).toBe(body);
    const events=output.filter(line=>line.startsWith(BRIDGE_EVENT_PREFIX))
      .map(line=>JSON.parse(line.slice(BRIDGE_EVENT_PREFIX.length)));
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({kind:"usage",id:"billing-contract",
      nanoAiu:1234567891,input:100,output:20,channel:"fake-channel"});
  } finally {spy.mockRestore()}
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
