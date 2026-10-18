/**
 * KOReader 插件真机模拟测试
 *
 * 语法检查只能证明"写得像 Lua"，证明不了"能在 KOReader 里跑起来"。
 * 这里用 fengari（Lua 虚拟机）把 KOReader 的运行时环境整套打桩出来，
 * 让 main.lua 真的执行一遍 collect() + upload()，再检查它发出去的 PUT 请求。
 *
 * 打桩的 KOReader 模块：datastorage / device / luasettings / lfs / logger /
 * ffi-sha2 / ltn12 / lua-ljsqlite3 / ssl.https / UIManager / InfoMessage /
 * Notification / NetworkMgr / WidgetContainer
 * 真实部分：sidecar 文件（metadata.*.lua）用真实文件 + 真的 dofile 解析，
 *           statistics.sqlite3 的查询结果按 KOReader 真实的列式结构返回。
 */

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { lua, lauxlib, lualib, to_luastring } = require("fengari");

const here = __dirname;
const root = path.join(here, "..");
const pluginDir = path.join(root, "plugin", "krsync.koplugin");
const tmp = path.join(here, "_tmp_plugin");

let pass = 0, fail = 0;
const log = [];
function ok(name, cond, extra) {
  if (cond) { pass++; log.push("  [OK]   " + name); }
  else { fail++; log.push("  [FAIL] " + name + (extra ? "  -> " + extra : "")); }
}

// ---------------------------------------------------------------- 造假数据
function rmrf(p) { try { fs.rmSync(p, { recursive: true, force: true }); } catch (e) { /* ignore */ } }
rmrf(tmp);

const settingsDir = path.join(tmp, "settings");
const scanDir = path.join(tmp, "books");
fs.mkdirSync(settingsDir, { recursive: true });
fs.mkdirSync(scanDir, { recursive: true });
fs.writeFileSync(path.join(settingsDir, "statistics.sqlite3"), "fake-not-a-real-db");

const LONG = "字".repeat(5000);            // 15000 字节，必然触发截断
const BOUNDARY = "a".repeat(11999) + "字"; // 第 12000 字节正好落在一个汉字的首字节上

function sidecar(name, body) {
  fs.writeFileSync(path.join(scanDir, name), "return " + body, "utf8");
}

sidecar("metadata.沙丘.epub.lua", [
  "{",
  "  doc_props = { display_title = \"沙丘\", authors = \"弗兰克·赫伯特\", pages = 512, series = \"沙丘系列\", language = \"zh\" },",
  "  percent_finished = 0.42,",
  "  annotations = {",
  "    { page = 12, text = \"恐惧是思维杀手。\", note = \"金句\", datetime = \"2026-09-10 21:03:12\", chapter = \"第一章\" },",
  "    { page = 40, text = \"\", note = \"\", highlighted = false, datetime = \"2026-09-11 08:00:00\", chapter = \"第二章\" },",
  "    { page = 88, text = \"" + LONG + "\", note = \"\", datetime = \"2026-09-12 07:00:00\" },",
  "  },",
  "}",
].join("\n"));

sidecar("metadata.三体.epub.lua", [
  "{",
  "  doc_props = { display_title = \"三体\", authors = \"刘慈欣\", pages = 400 },",
  "  percent_finished_night = 0.88, percent_finished = 0.75,",
  "  annotations = {",
  "    { page = 5, text = \"不要回答！不要回答！不要回答！\", note = \"\", datetime = \"2026-09-15 22:10:00\" },",
  "  },",
  "}",
].join("\n"));


sidecar("metadata.边界.epub.lua", [
  "{",
  "  doc_props = { display_title = \"边界测试\", authors = \"测试\" },",
  "  annotations = {",
  "    { page = 1, text = \"" + BOUNDARY + "\", note = \"\" },",
  "  },",
  "}",
].join("\n"));

// 一个不该被收进去的文件
fs.writeFileSync(path.join(scanDir, "随便一个.lua.old"), "return {}");

// ---------------------------------------------------------------- 虚拟机
const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function pushJsFn(name, fn) {
  lua.lua_pushcfunction(L, fn);
  lua.lua_setglobal(L, to_luastring(name));
}

pushJsFn("node_read_file", (LL) => {
  const p = lua.lua_tojsstring(LL, 1);
  try { lua.lua_pushstring(LL, to_luastring(fs.readFileSync(p, "utf8"))); }
  catch (e) { lua.lua_pushstring(LL, to_luastring("")); }
  return 1;
});

pushJsFn("node_md5", (LL) => {
  const s = lua.lua_tojsstring(LL, 1) || "";
  lua.lua_pushstring(LL, to_luastring(crypto.createHash("md5").update(s, "utf8").digest("hex")));
  return 1;
});

pushJsFn("node_attr_mode", (LL) => {
  const p = lua.lua_tojsstring(LL, 1);
  try {
    const st = fs.statSync(p);
    lua.lua_pushstring(LL, to_luastring(st.isDirectory() ? "directory" : "file"));
  } catch (e) {
    lua.lua_pushnil(LL);
  }
  return 1;
});

pushJsFn("node_list_dir", (LL) => {
  const p = lua.lua_tojsstring(LL, 1);
  try {
    lua.lua_pushstring(LL, to_luastring(fs.readdirSync(p).join("\n")));
  } catch (e) {
    lua.lua_pushnil(LL);
  }
  return 1;
});

const tpath = (p) => p.split(path.sep).join("/");

const BOOT = `
-- ==== KOReader 环境打桩 ====
package.loaded["datastorage"] = {
  getSettingsDir = function() return "${tpath(settingsDir)}" end,
  getHistoryDir = function() return "${tpath(scanDir)}" end,
}
package.loaded["device"] = { model = "Kindle PaperWhite 5" }
package.loaded["logger"] = { warn = function() end, info = function() end, dbg = function() end }
package.loaded["ffi/sha2"] = { md5 = function(s) return node_md5(s) end }

package.loaded["luasettings"] = {
  open = function(self, p)
    return {
      readSetting = function(_, k, d) return d end,
      saveSetting = function() end,
      flush = function() end,
      close = function() end,
    }
  end,
}

package.loaded["libs/libkoreader-lfs"] = {
  attributes = function(p, req)
    local m = node_attr_mode(p)
    if not m then return nil end
    if req == "mode" then return m end
    return { mode = m }
  end,
  dir = function(p)
    local s = node_list_dir(p)
    if not s then return function() return nil end end
    local list = {}
    for name in tostring(s):gmatch("[^\\n]+") do list[#list + 1] = name end
    local i = 0
    return function()
      i = i + 1
      if i <= #list then return list[i] end
      return nil
    end
  end,
}

-- 真的按文件内容执行 sidecar（KOReader 里就是 dofile）
dofile = function(p)
  local src = node_read_file(p)
  if src == "" then return nil end
  local f, err = load(src, "@" .. p)
  if not f then error(err) end
  return f()
end

-- statistics.sqlite3：按 KOReader 真实的列式返回结构造
local BOOK_ROWS = {
  [1] = {1, 2, 3},
  id = {1, 2, 3},
  title = {"沙丘", "三体", "1984"},
  authors = {"弗兰克·赫伯特", "刘慈欣", "乔治·奥威尔"},
  pages = {512, 400, 300},
  md5 = {"md5-a", "md5-b", "md5-c"},
  series = {"沙丘系列", "地球往事", ""},
  language = {"zh", "zh", "zh"},
  total_read_time = {3600, 7200, 1800},
  total_read_pages = {100, 200, 50},
  last_open = {1758000000, 1758100000, 1758200000},
}
local DAY_ROWS = {
  [1] = {1, 2},
  id_book = {1, 1},
  d = {"2026-09-18", "2026-09-19"},
  sec = {1200, 1800},
  pages = {20, 30},
}
-- 整本书累计时长查询的返回（GROUP BY id_book，不带日期）
local TOTAL_ROWS = {
  [1] = {1, 2},
  id_book = {1, 2},
  sec = {3600, 7200},
}
-- 24 小时时段查询的返回（strftime('%H', start_time) 那一条）
local HOUR_ROWS = {
  [1] = {1, 2},
  h = {21, 22},
  sec = {1200, 1800},
}
package.loaded["lua-ljsqlite3/init"] = {
  open = function(p)
    return {
      exec = function(self, sql)
        if sql:find("FROM book") then return BOOK_ROWS end
        if sql:find("FROM page_stat_data") then
          __cap.sqls[#__cap.sqls + 1] = sql
          if sql:find("GROUP BY id_book;") then return TOTAL_ROWS end
          if sql:find("%%H") then return HOUR_ROWS end
          return DAY_ROWS
        end
        return nil
      end,
      close = function() end,
    }
  end,
}

__cap = { sqls = {} }
package.loaded["ltn12"] = {
  source = {
    string = function(s)
      __cap.body = s
      local done = false
      return function() if not done then done = true; return s end end
    end,
  },
  sink = {
    table = function(t)
      return function(chunk)
        if chunk then t[#t + 1] = chunk end
        return 1
      end
    end,
  },
}

local function fake_http(t)
  __cap.url = t.url
  __cap.method = t.method
  __cap.headers = t.headers
  if t.source then local c = t.source(); __cap.body = c or __cap.body end
  if t.sink then t.sink('{"ok":true}') end
  return 1, 200, {}, "OK"
end
package.loaded["ssl.https"] = { request = fake_http, TIMEOUT = 0 }
package.loaded["socket.http"] = { request = fake_http, TIMEOUT = 0 }

package.loaded["ui/widget/container/widgetcontainer"] = {
  extend = function(self, t) setmetatable(t, { __index = t }) return t end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_, t) return { text = t.text } end }
package.loaded["ui/widget/multiinputdialog"] = { new = function(_, t) return {} end }
package.loaded["ui/widget/notification"] = { notify = function(_, t) __cap.notified = t end }
package.loaded["ui/uimanager"] = { show = function(_, w) __cap.shown = w and w.text or "" end }
package.loaded["ui/network/manager"] = { isConnected = function() return true end }

-- ==== 真的加载插件 ====
local KRSync = dofile("${tpath(path.join(pluginDir, "main.lua"))}")

KRSync.settings = {
  server_url = "https://readbox-demo.workers.dev",
  token = "tok-123456",
  device_name = "测试设备",
  auto_sync = true,
  scan_root = "${tpath(scanDir)}",
}

KRSync:sync(true)

__out_body = __cap.body or ""
__out_url = __cap.url or ""
__out_method = __cap.method or ""
__out_result = KRSync.last_result or ""
__out_ct = __cap.headers and __cap.headers["Content-Type"] or ""
__out_len = __cap.headers and __cap.headers["Content-Length"] or ""
__out_sqls = table.concat(__cap.sqls or {}, "@@@")
`;

const st = lauxlib.luaL_dostring(L, to_luastring(BOOT));
if (st !== lua.LUA_OK) {
  const err = lua.lua_tojsstring(L, -1);
  log.push("  [FAIL] Lua 执行报错 -> " + err);
  fail++;
  finish();
} else {
  const body = (() => { lua.lua_getglobal(L, to_luastring("__out_body")); const v = lua.lua_tojsstring(L, -1); lua.lua_pop(L, 1); return v; })();
  const url = (() => { lua.lua_getglobal(L, to_luastring("__out_url")); const v = lua.lua_tojsstring(L, -1); lua.lua_pop(L, 1); return v; })();
  const method = (() => { lua.lua_getglobal(L, to_luastring("__out_method")); const v = lua.lua_tojsstring(L, -1); lua.lua_pop(L, 1); return v; })();
  const result = (() => { lua.lua_getglobal(L, to_luastring("__out_result")); const v = lua.lua_tojsstring(L, -1); lua.lua_pop(L, 1); return v; })();
  const ct = (() => { lua.lua_getglobal(L, to_luastring("__out_ct")); const v = lua.lua_tojsstring(L, -1); lua.lua_pop(L, 1); return v; })();
  const clen = (() => { lua.lua_getglobal(L, to_luastring("__out_len")); const v = lua.lua_tojsstring(L, -1); lua.lua_pop(L, 1); return v; })();
  const sqls = (() => { lua.lua_getglobal(L, to_luastring("__out_sqls")); const v = lua.lua_tojsstring(L, -1); lua.lua_pop(L, 1); return v; })() || "";

  ok("插件能在 Lua 虚拟机里完整加载（没有 require/语法错误）", true);

  let json = null;
  try { json = JSON.parse(body); } catch (e) { /* ignore */ }

  ok("发出的请求是 PUT", method === "PUT", method);
  ok("请求地址是 /api/push 且带上设备和令牌",
    url.indexOf("https://readbox-demo.workers.dev/api/push?device=") === 0 && url.indexOf("token=tok-123456") > -1, url);
  ok("请求头 Content-Type 是 JSON", ct.indexOf("application/json") === 0, ct);
  ok("Content-Length 与实际长度一致", clen === String(Buffer.byteLength(body, "utf8")), clen + " vs " + Buffer.byteLength(body, "utf8"));

  ok("上传体是合法 JSON（自研编码器没写坏）", !!json, body.slice(0, 200));

  if (json) {
    ok("device 字段是配置里的设备名", json.device === "测试设备", String(json.device));
    ok("device_id 非空（md5 生成）", typeof json.device_id === "string" && json.device_id.length === 32, String(json.device_id));
    ok("model 带上了机型", json.model === "Kindle PaperWhite 5", String(json.model));
    ok("books 至少 3 本（sqlite 里的三本）", (json.books || []).length >= 3, String((json.books || []).length));
    ok("days 是 2 天", (json.days || []).length === 2, String((json.days || []).length));
    ok("daily 日期格式正确", (json.days || []).every((d) => /^\d{4}-\d{2}-\d{2}$/.test(d.d)));

    // 单页停留时长必须带上限，否则"书开着过夜"会让某天凭空多出十几个小时
    const statSqls = sqls.split("@@@").filter((s) => s.indexOf("duration") >= 0);
    ok("所有时长查询都带了单页上限 MIN(duration, 1800)", statSqls.length > 0
      && statSqls.every((s) => /MIN\(duration,\s*1800\)/.test(s)), sqls.slice(0, 300));
    const dune = (json.books || []).filter((b) => b.title === "沙丘")[0];
    ok("书的累计时长用的是重算值（不是 book 表里掺了挂机时间的原值）",
      !!dune && dune.total_read_time === 3600, JSON.stringify(dune && dune.total_read_time));

    // 24 小时时段分布：插件把每段阅读按开始时间归到小时里，网页上的「阅读时段」就靠它
    const hs = json.hours || [];
    ok("hours 是 24 格", hs.length === 24, String(hs.length));
    ok("小时 21 / 22 分别落到正确的格子里",
      hs[21] === 1200 && hs[22] === 1800, JSON.stringify(hs.slice(20, 23)));
    ok("没有记录的小时是 0 而不是 null/undefined",
      hs[0] === 0 && hs[23] === 0, JSON.stringify([hs[0], hs[23]]));
    ok("中文书名没有被编码破坏", (json.books || []).some((b) => b.title === "沙丘"), JSON.stringify((json.books || []).map((b) => b.title)));

    const anns = json.annotations || [];
    // 书签（highlighted=false）以前会被丢掉，现在要一并上报并打好 type 标记
    const bms = anns.filter((a) => a.type === "bookmark");
    ok("划线 4 条 + 书签 1 条", anns.length === 5, String(anns.length));
    ok("纯书签也上报了，且标成 bookmark", bms.length === 1 && bms[0].page === 40 && bms[0].text === "", JSON.stringify(bms));
    ok("其余 4 条仍是 highlight", anns.filter((a) => a.type === "highlight").length === 4);
    ok("划线文本正确且带批注", anns.some((a) => a.text === "恐惧是思维杀手。" && a.note === "金句"), JSON.stringify(anns.slice(0, 2)));
    ok("划线的书名能对应上", anns.every((a) => (json.books || []).some((b) => b.k === a.k)));
    ok("划线带页码和章节", anns.every((a) => typeof a.page === "number" && typeof a.chapter === "string"));

    // 关键：Lua 的 string.sub 按字节，中文一个字 3 字节，直接截断会切出半个字
    const longAnn = anns.filter((a) => a.text.indexOf("字字字") === 0)[0];
    ok("超长划线被截断且没有切出半个汉字", !!longAnn
      && longAnn.text.length === 4000
      && Buffer.byteLength(longAnn.text, "utf8") === 12000
      && longAnn.text.indexOf("�") === -1,
      longAnn ? (longAnn.text.length + " 字 / " + Buffer.byteLength(longAnn.text, "utf8") + " 字节") : "没找到");

    const bAnn = anns.filter((a) => a.title === "边界测试")[0];
    ok("截断点正好落在汉字上时不会留下半个字", !!bAnn
      && bAnn.text.length === 11999
      && bAnn.text.indexOf("�") === -1,
      bAnn ? (bAnn.text.length + " 字符，末字符 " + JSON.stringify(bAnn.text.slice(-1))) : "没找到");

    const prog = json.progress || [];
    ok("进度至少 1 条", prog.length >= 1, String(prog.length));
    const p3 = prog.filter((p) => p.title === "三体")[0];
    ok("进度优先取夜间百分比（0.88 而非 0.75）", p3 && Math.abs(p3.percent - 0.88) < 1e-6, JSON.stringify(p3));

    // sidecar 里的书和 sqlite 里的同一本书，key 必须相同，否则会被当成两本
    const duneKeys = new Set((json.books || []).filter((b) => b.title === "沙丘").map((b) => b.k));
    ok("同一本书在 sqlite 和 sidecar 里算出同一个 key（不会重复成两本）", duneKeys.size === 1, JSON.stringify([...duneKeys]));
  }

  ok("插件报告同步成功", result.indexOf("同步成功") === 0, result);

  finish();
}

function finish() {
  const text = "=== KOReader 插件真机模拟 " + new Date().toISOString() + " ===\n"
    + log.join("\n") + "\n\n合计：" + pass + " 通过 / " + fail + " 失败\n";
  fs.writeFileSync(path.join(here, "_plugin_runtime.log"), text, "utf8");
  console.log(text);
  rmrf(tmp);
  process.exit(fail ? 1 : 0);
}
