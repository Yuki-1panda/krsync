const fs = require('fs');
const path = require('path');
const harness = fs.readFileSync(path.join(__dirname, '_plugin_dual_push.js'), 'utf8');
const prefix = harness.slice(0, harness.indexOf('\nconst st = lauxlib'));
const fixture = `fs.writeFileSync(path.join(scanDir,'cover.png'),Buffer.alloc(300));\n`;
const plugin = path.join(__dirname, '../plugin/krsync.koplugin/main.lua').replaceAll('\\','/');
const scenario = fs.readFileSync(path.join(__dirname, 'regressions.lua'), 'utf8').replace('PLUGIN_PATH', plugin);
const run = prefix + fixture + `
const boot = BOOT.replace('KRSync:sync(true)', ${JSON.stringify(scenario)});
const status = lauxlib.luaL_dostring(L, to_luastring(boot));
if(status !== lua.LUA_OK) throw new Error(lua.lua_tojsstring(L,-1));
lua.lua_getglobal(L,to_luastring('__checks'));
console.log('New regression checks passed:',lua.lua_tojsstring(L,-1));
rmrf(tmp);
`;
new Function('require','__dirname', run)(require,__dirname);
