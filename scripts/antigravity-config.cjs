// Native DAK plugin installation; only the three workshop servers are global.
const fs = require('node:fs');
const path = require('node:path');
const {isDeepStrictEqual: equal} = require('node:util');
const [mode, root, configDir, , , proxySuffix] = process.argv.slice(2);
const state = path.join(root, '.workshop-state');
const source = path.join(state, 'antigravity-source');
function read(p, allowEmpty = false) {
  const text = fs.readFileSync(p, 'utf8');
  // A blank global config has no settings to preserve. Only setup initializes it.
  if (allowEmpty && !text.trim()) return {};
  try { return JSON.parse(text); } catch (error) {
    if (!(error instanceof SyntaxError)) throw error;
    // Parser messages can quote credentials. Report only the path and category.
    throw new Error((text.trim() ? 'Invalid JSON in ' : 'Empty JSON file: ') + p +
      '. Setup stopped; preserve this file and repair it before retrying.');
  }
}
const exists = p => !!fs.lstatSync(p, {throwIfNoEntry:false});
function write(p, value) {
  fs.mkdirSync(path.dirname(p), {recursive:true});
  const tmp = p + '.workshop-' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n', {mode:0o600, flag:'wx'});
  fs.renameSync(tmp, p);
}
function main() {
  const configPath = path.join(configDir, 'mcp_config.json');
  const markerPath = path.join(state, 'antigravity-added-by-workshop.json');
  const pluginPath = path.join(configDir, 'plugins', 'dak');
  const legacyTarget = path.join(state, 'antigravity-plugin');
  const cfg = fs.existsSync(configPath) ? read(configPath, mode === 'setup') : {};
  if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg) ||
      (cfg.mcpServers && (typeof cfg.mcpServers !== 'object' || Array.isArray(cfg.mcpServers))))
    throw new Error('Invalid Antigravity MCP configuration; repair its JSON object before retrying.');
  cfg.mcpServers ||= {};
  const owned = fs.existsSync(markerPath) ? read(markerPath) : {servers:{}, plugin:false};
  owned.disabled ||= [];
  const ourPlugin = () => owned.plugin && exists(pluginPath) && fs.lstatSync(pluginPath).isSymbolicLink() &&
    [source,legacyTarget].includes(fs.readlinkSync(pluginPath));
  if (mode === 'teardown') {
    if (!fs.existsSync(markerPath)) return;
    let conflict = false;
    for (const [name, entry] of Object.entries(owned.servers)) {
      if (!(name in cfg.mcpServers)) { delete owned.servers[name]; continue; }
      if (!equal(cfg.mcpServers[name], entry)) { conflict=true; continue; }
      delete cfg.mcpServers[name]; delete owned.servers[name];
    }
    // Only the previous disabled flag is saved, never a copy of user credentials.
    for (const record of owned.disabled) {
      if (record.file !== configPath && !fs.existsSync(record.file)) continue;
      const doc = record.file === configPath ? cfg : read(record.file);
      const entry = doc.mcpServers?.dataproc;
      if (entry?.disabled === true) {
        if (record.present) entry.disabled=record.value; else delete entry.disabled;
        if (record.file !== configPath) write(record.file,doc);
      }
    }
    owned.disabled=[];
    write(configPath,cfg);
    if (owned.plugin) {
      if (!exists(pluginPath)) owned.plugin=false;
      else if (ourPlugin()) {
        const wasLegacy=fs.readlinkSync(pluginPath)===legacyTarget;
        fs.unlinkSync(pluginPath); owned.plugin=false;
        if (wasLegacy) fs.rmSync(legacyTarget,{recursive:true,force:true});
      } else conflict=true;
    }
    if (conflict) { write(markerPath,owned); throw new Error('Modified workshop Antigravity entries were preserved; resolve them before rerunning teardown.'); }
    fs.unlinkSync(markerPath);
    console.log('Antigravity: workshop additions removed; pre-existing plugins preserved.');
    return;
  }
  // Native manifest: upstream commit 0167f8c8421f521f39fd5d011d2243f6e90ef615
  // (test_978762497), kept as a fallback
  // until it is present on main. No other agent's MCP format is translated.
  const upstream = path.join(source, 'mcp_config.json');
  const native = read(fs.existsSync(upstream) ? upstream : path.join(root,'config/antigravity-mcp.json'));
  if (!native.mcpServers?.bigquery || !native.mcpServers?.['alloydb-postgres'] ||
      !fs.existsSync(path.join(source,proxySuffix))) throw new Error('Incomplete DAK checkout; run setup again.');
  for (const entry of Object.values(native.mcpServers)) {
    // Resolve against the installed plugin, never the attendee's current folder.
    if (entry.command) entry.cwd=source;
  }
  if (native.mcpServers.dataproc) native.mcpServers.dataproc.disabled=true;
  const extra=['google_developer_knowledge','maps_grounding_lite','cloud_run'];
  const desired=Object.fromEntries(extra.map(name=>[name,{command:path.join(root,'bin/mcp-antigravity'),args:[name]}]));
  for (const [name,entry] of Object.entries(owned.servers)) {
    if (name in cfg.mcpServers && !equal(cfg.mcpServers[name],entry)) throw new Error('Modified workshop MCP entry: '+name+'; resolve before setup.');
  }
  for (const [name,entry] of Object.entries(desired)) {
    if (name in cfg.mcpServers && !equal(cfg.mcpServers[name],entry)) throw new Error('Conflicting Antigravity MCP entry: '+name+'. Preserve or rename it before setup.');
  }
  const pluginManifest=path.join(pluginPath,'mcp_config.json');
  if (mode === 'check') {
    if (!fs.existsSync(path.join(pluginPath,'skills')) || !fs.existsSync(pluginManifest)) throw new Error('Antigravity DAK plugin missing; run setup.');
    const installed=read(pluginManifest).mcpServers || {};
    for (const name of Object.keys(native.mcpServers).filter(n=>n!=='dataproc')) {
      const entry=cfg.mcpServers[name] || installed[name];
      if (!entry || entry.disabled) throw new Error('Antigravity DAK server missing or disabled: '+name);
    }
    for (const name of extra) if (!equal(cfg.mcpServers[name],desired[name])) throw new Error('Workshop MCP entry missing: '+name+'; run setup.');
    for (const entries of [cfg.mcpServers,installed]) if (entries.dataproc && !entries.dataproc.disabled) throw new Error('Dataproc should be disabled; run setup.');
    console.log('Antigravity: DAK plugin and workshop MCP entries ready; Dataproc disabled (configuration check only).');
    return;
  }
  if (mode !== 'setup') throw new Error('Unknown operation.');
  if (exists(pluginPath) && !ourPlugin() && (!fs.existsSync(path.join(pluginPath,'skills')) || !fs.existsSync(pluginManifest)))
    throw new Error('Existing dak plugin is incomplete; repair it before setup.');
  // Migrate only DAK global entries written by the old workshop dispatcher.
  for (const name of Object.keys(owned.servers).filter(n=>!extra.includes(n))) { delete cfg.mcpServers[name]; delete owned.servers[name]; }
  for (const [name,entry] of Object.entries(desired)) if (!(name in cfg.mcpServers)) { owned.servers[name]=entry; cfg.mcpServers[name]=entry; }
  const installPlugin=!exists(pluginPath) || ourPlugin();
  if (installPlugin) owned.plugin=true;
  const disable=(file,doc)=>{
    const entry=doc.mcpServers?.dataproc;
    if (entry && entry.disabled!==true) {
      if (!owned.disabled.some(r=>r.file===file)) owned.disabled.push({file,present:Object.hasOwn(entry,'disabled'),value:entry.disabled ?? false});
      entry.disabled=true;
    }
  };
  disable(configPath,cfg);
  const existingPlugin=installPlugin?null:read(pluginManifest);
  if (existingPlugin) disable(pluginManifest,existingPlugin);
  write(markerPath,owned);
  write(upstream,native);
  if (installPlugin) {
    fs.mkdirSync(path.dirname(pluginPath),{recursive:true});
    if (exists(pluginPath) && fs.readlinkSync(pluginPath)===legacyTarget) {
      fs.unlinkSync(pluginPath);fs.rmSync(legacyTarget,{recursive:true,force:true});
    }
    if (!exists(pluginPath)) fs.symlinkSync(source,pluginPath);
  } else write(pluginManifest,existingPlugin);
  write(configPath,cfg);
  console.log('Antigravity: native DAK plugin ready; workshop servers configured; Dataproc disabled.');
}
try { main(); } catch (e) {
  console.error(e instanceof SyntaxError ? 'Invalid JSON in Antigravity configuration; repair it before retrying.' :
    e.code ? 'Antigravity file operation failed ('+e.code+'); check paths and permissions.' : e.message);
  process.exitCode=1;
}
