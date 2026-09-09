// Loaded ONLY by test-auth.py, never imported by the release app.
const mode = process.env.CBM_TEST_AUTH;
if (!mode || !process.env.HOME?.includes("cbm-auth-test-")) throw new Error("Refusing unisolated auth test");
let polls = 0;
globalThis.fetch = Object.assign(async (input: any) => {
  const url = String(input);
  if (url === "https://github.com/login/device/code") {
    return Response.json({device_code:"FAKE_DEVICE",user_code:"ABCD-1234",verification_uri:"https://github.com/login/device",expires_in:60,interval:0});
  }
  if (url === "https://github.com/login/oauth/access_token") {
    if (mode === "denied") return Response.json({error:"access_denied"});
    if (++polls < 2) return Response.json({error:"authorization_pending"});
    return Response.json({access_token:"ghp_FAKE_TEST_CREDENTIAL"});
  }
  if (url === "https://api.github.com/copilot_internal/v2/token") return Response.json({token:"FAKE_COPILOT_TOKEN",refresh_in:600});
  if (url === "https://api.githubcopilot.com/models") return Response.json({data:[]});
  if (url === "https://api.github.com/user") return Response.json({login:"test-user"});
  throw new Error(`Unexpected network call in isolated auth test: ${url}`);
}, {preconnect:()=>{}}) as typeof fetch;
