// Stdio to HTTP for the two API-key-only workshop endpoints. Do not attach ADC:
// mixing OAuth and API-key identities can fail project/scope checks remotely.
const readline = require('node:readline');
const endpoints = {
  google_developer_knowledge: ['https://developerknowledge.googleapis.com/mcp', 'WORKSHOP_DK_API_KEY'],
  maps_grounding_lite: ['https://mapstools.googleapis.com/mcp', 'WORKSHOP_MAPS_API_KEY']
};
const selected = endpoints[process.argv[2]];
const key = selected && process.env[selected[1]];
delete process.env.WORKSHOP_DK_API_KEY;
delete process.env.WORKSHOP_MAPS_API_KEY;
if (!key) { console.error('MCP API key is unavailable; run workshop doctor.'); process.exit(1); }
let session;
const output = value => process.stdout.write(JSON.stringify(value) + '\n');
readline.createInterface({input:process.stdin, terminal:false}).on('line', async line => {
  let request;
  try { request = JSON.parse(line); } catch { return; }
  if (!request || typeof request !== 'object' || Array.isArray(request)) return;
  const hasId = Object.hasOwn(request, 'id');
  try {
    const headers = {'Content-Type':'application/json', Accept:'application/json, text/event-stream', 'X-Goog-Api-Key':key};
    if (session) headers['Mcp-Session-Id'] = session;
    const response = await fetch(selected[0], {method:'POST', headers, body:line, signal:AbortSignal.timeout(120000)});
    const newSession = response.headers.get('mcp-session-id');
    if (newSession) session = newSession;
    if (!response.ok) throw new Error('HTTP ' + response.status);
    if (!hasId || response.status === 204) { await response.body?.cancel(); return; }
    if ((response.headers.get('content-type') || '').includes('text/event-stream')) {
      // Return as soon as the matching response arrives; an SSE connection
      // need not close after a tool result. Ignore keepalive/comment events.
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      try {
        while (true) {
          const {value,done} = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, {stream:true});
          buffer = buffer.replace(/\r\n/g, '\n');
          let boundary;
          while ((boundary = buffer.indexOf('\n\n')) >= 0) {
            const event = buffer.slice(0,boundary); buffer = buffer.slice(boundary+2);
            const data = event.split('\n').filter(l=>l.startsWith('data:')).map(l=>l.slice(5).trimStart()).join('\n');
            if (!data) continue;
            const message = JSON.parse(data); output(message);
            if (message.id === request.id) return;
          }
        }
        throw new Error('Incomplete response');
      } finally { await reader.cancel(); }
    } else {
      output(await response.json());
    }
  } catch {
    // Never echo remote HTTP bodies, headers, or exceptions containing secrets.
    if (hasId) output({jsonrpc:'2.0', id:request.id, error:{code:-32603,message:'MCP request failed; check workshop doctor, API access and connectivity.'}});
  }
});
