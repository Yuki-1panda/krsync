const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const root = path.join(__dirname, '..');
require('luaparse').parse(fs.readFileSync(path.join(root,'plugin/krsync.koplugin/main.lua'),'utf8'),{luaVersion:'5.1'});
console.log('Lua 5.1 syntax OK');
for (const file of ['_plugin_runtime.js','_plugin_dual_push.js','regressions.js']) {
  const result = cp.spawnSync(process.execPath,[path.join(__dirname,file)],{stdio:'inherit',cwd:root});
  if(result.status !== 0) process.exit(result.status || 1);
}
