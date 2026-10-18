local PLUGIN_VERSION = "1.1.0"
--[[--
Readbox Sync (krsync.koplugin)

把本机 KOReader 的
  * 阅读时长统计 (settings/statistics.sqlite3)
  * 划线 / 批注   (每本书的 metadata.*.lua)
  * 当前阅读进度
打包成 JSON，PUT 到你自己的服务器。
服务端先落在本地暂存箱，网页登录后取回、存进你自己的账号（一人一份，换设备也在）。
不再经过坚果云，插件这边也不用为此做任何改动。

触发方式：
  1) 菜单里手动点「立即同步」
  2) 合上书本后自动同步（默认开启，需要 WiFi 开着）
  3) 联网 / 唤醒失败重试

作者为无编程经验的场景设计：所有配置都在 KOReader 界面里填，不需要改代码。
--]]--

local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5raw = require("ffi/sha2").md5

local ltn12 = require("ltn12")

-- ---------------------------------------------------------------- 默认值

local DEFAULT_SETTINGS = {
    server_url = "",
    token = "",
    -- 备用服务器（可选）：填了之后每次同步同时推第二处，
    -- 比如主处推网页版（坚果云）、备用推小程序云函数，两边同时保持更新。
    server_url2 = "",
    token2 = "",
    device_name = "",
    auto_sync = true,
    scan_root = "",
    upload_covers = true,   -- 把本机书籍的封面也传上去（每本书只传一次）
    cover_sent = {},        -- 已经传过的书，避免每次同步重复上传
    cover_sent2 = {},       -- 备用服务器的封面已传记录（与主处分开记，两边各自补齐）
}

local MAX_ANNOTATIONS = 4000

-- 单页停留时长的上限（秒）。
-- KOReader 的 page_stat_data 记的是"在这一屏停了多少秒"。翻到某页后把机器丢在一边
-- （睡觉、待机、忘了退出阅读），那一屏就会积出几万秒，一天凭空多出十几个小时。
-- 一屏读满 30 分钟几乎不可能，所以超出的部分一律按挂机削掉 —— 这是从源头上消除异常，
-- 比在网页上事后封顶靠谱。想更严格就把它改小（比如 900 = 15 分钟）。
local PAGE_CAP = 1800

-- 每次同步最多传几张封面。Kindle 的 WiFi 不快，一次传几十张会把同步拖很久；
-- 每本书只传一次，所以分几次同步就能补齐。
local MAX_COVERS_PER_SYNC = 12
local MAX_COVER_BYTES = 1024 * 1024

-- ---------------------------------------------------------------- 小工具

local function trim(s)
    return (tostring(s or ""):match("^%s*(.-)%s*$"))
end

local function urlencode(s)
    return (tostring(s or ""):gsub("\n", "\r\n"):gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function md5(s)
    return md5raw(tostring(s or ""))
end

-- 同一本书在三台设备上必须得到同一个 key，所以用 书名+作者 做主键
local function bookKey(title, authors)
    return md5(trim(title) .. "|" .. string.lower(trim(authors)))
end

local function tonum(v)
    local n = tonumber(v)
    if n == nil then return nil end
    return n
end

-- 一条划线的文本上限（字节）。约合 4000 个汉字 / 12000 个英文字母，
-- 正常划线根本到不了，只是防止极端情况把上传体撑爆。
local MAX_TEXT_BYTES = 12000

-- 按字节截断，但绝不能切在 UTF-8 字符中间（string.sub 按字节，
-- 切在汉字中间会留下半个字节，JSON 里就成了乱码）。
local function truncate_utf8(s, max_bytes)
    s = tostring(s or "")
    if #s <= max_bytes then return s end
    local e = max_bytes
    local next_byte = string.byte(s, e + 1)
    if next_byte and next_byte >= 0x80 and next_byte < 0xC0 then
        -- 正好切在某个多字节字符的中间，往回退到这个字符的前面
        while e > 0 do
            local b = string.byte(s, e)
            e = e - 1
            if b and b >= 0xC0 then break end
        end
    end
    if e < 0 then e = 0 end
    return s:sub(1, e)
end

-- ---------------------------------------------------------------- JSON 编码
-- KOReader 自带的 JSON 库不保证存在，这里自带一个最小实现，零依赖、零风险。

local escape_map = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b",
    ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escape_str(s)
    s = tostring(s or "")
    -- 只转义 JSON 必须转义的字符，中英文 UTF-8 原样输出
    return (s:gsub('[\1-\31\127"\\]', function(c)
        return escape_map[c] or string.format("\\u%04X", string.byte(c))
    end))
end

local json_encode
json_encode = function(v)
    local t = type(v)
    if t == "string" then
        return '"' .. escape_str(v) .. '"'
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.4f", v)
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        -- 先判断：(所有键都是字符串) => 对象；否则 => 数组
        local is_object = false
        for k in pairs(v) do
            if type(k) == "string" then is_object = true break end
        end
        local out, first, empty = {}, true, true
        if is_object then
            for k, val in pairs(v) do
                if type(k) == "string" and val ~= nil then
                    if not first then out[#out + 1] = "," end
                    first = false
                    empty = false
                    out[#out + 1] = json_encode(k) .. ":" .. json_encode(val)
                end
            end
            if empty then return "{}" end
            return "{" .. table.concat(out) .. "}"
        else
            for _, item in ipairs(v) do
                if not first then out[#out + 1] = "," end
                first = false
                empty = false
                out[#out + 1] = json_encode(item)
            end
            if empty then return "[]" end
            return "[" .. table.concat(out) .. "]"
        end
    end
    return "null"
end

-- ---------------------------------------------------------------- 插件主体

local KRSync = WidgetContainer:extend{
    name = "krsync",
    settings_file = DataStorage:getSettingsDir() .. "/krsync.lua",
    last_result = "尚未同步",
    last_sync_at = 0,
    syncing = false,
}

-- Each destination remains independent, including cover history.
function KRSync:targets()
    local s = self:loadSettings()
    local out = {}
    if trim(s.server_url) ~= "" then
        out[#out + 1] = { label = "主", base = trim(s.server_url):gsub("/+$", ""),
            token = trim(s.token), sent = "cover_sent", second = false }
    end
    if trim(s.server_url2) ~= "" then
        out[#out + 1] = { label = "备用", base = trim(s.server_url2):gsub("/+$", ""),
            token = trim(s.token2), sent = "cover_sent2", second = true }
    end
    return out
end

function KRSync:loadSettings()
    if self.settings then return self.settings end
    local ok, obj = pcall(function()
        return LuaSettings:open(self.settings_file)
    end)
    if ok and obj then
        self.settings_obj = obj
        self.settings = obj:readSetting("settings", {}) or {}
    else
        self.settings = {}
    end
    for k, v in pairs(DEFAULT_SETTINGS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    if self.settings.cover_history_version ~= 2 then
        self.settings.cover_sent = {}
        self.settings.cover_sent2 = {}
        self.settings.cover_history_version = 2
        self:saveSettings()
    end
    return self.settings
end

function KRSync:saveSettings()
    local ok, obj = pcall(function()
        return LuaSettings:open(self.settings_file)
    end)
    if ok and obj then
        obj:saveSetting("settings", self.settings)
        obj:flush()
    end
end

function KRSync:deviceName()
    local s = self:loadSettings()
    if trim(s.device_name) ~= "" then return trim(s.device_name) end
    return tostring(Device.model or "KOReader")
end

function KRSync:deviceId()
    local id = nil
    if _G.G_reader_settings then
        id = _G.G_reader_settings:readSetting("device_id")
    end
    if not id or id == "" then
        id = md5(tostring(Device.model or "") .. tostring(self:deviceName()))
    end
    return tostring(id)
end

-- ---------------------------------------------------------------- 生命周期

function KRSync:init()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self:registerHooks()
end

function KRSync:registerHooks()
    local s = self:loadSettings()
    if s.auto_sync then
        self.onCloseDocument = function() self:_onCloseDocument() end
        self.onNetworkConnected = function() self:_onNetworkConnected() end
        self.onResume = function() self:_onResume() end
    else
        self.onCloseDocument = nil
        self.onNetworkConnected = nil
        self.onResume = nil
    end
end

function KRSync:_onCloseDocument()
    -- 统计插件会在关文档时写库，稍等一会再收数据
    UIManager:scheduleIn(3, function() self:autoSync() end)
end

function KRSync:_onNetworkConnected()
    UIManager:scheduleIn(5, function() self:autoSync() end)
end

function KRSync:_onResume()
    UIManager:scheduleIn(5, function() self:autoSync() end)
end

function KRSync:autoSync()
    if self.syncing then return end
    local s = self:loadSettings()
    if not s.auto_sync then return end
    if #self:targets() == 0 then return end
    if not NetworkMgr:isConnected() then return end
    self:sync(false)
end

-- ---------------------------------------------------------------- 菜单

function KRSync:addToMainMenu(menu_items)
    menu_items.krsync = {
        sorting_hint = "tools",
        text = "Readbox 同步",
        sub_item_table_func = function()
            return self:buildMenu()
        end,
    }
end

function KRSync:buildMenu()
    local s = self:loadSettings()
    return {
        {
            text = "立即同步",
            callback = function() self:sync(true) end,
        },
        {
            text = "配置（服务器 / 同步口令 / 设备名）",
            callback = function() self:showConfig() end,
        },
        {
            text = "合上书本后自动同步",
            keep_menu_open = true,
            checked_func = function() return self.settings.auto_sync end,
            callback = function()
                self.settings.auto_sync = not self.settings.auto_sync
                self:saveSettings()
                self:registerHooks()
            end,
        },
        {
            text = "同步时顺带上传本机封面",
            keep_menu_open = true,
            checked_func = function() return self.settings.upload_covers ~= false end,
            callback = function()
                self.settings.upload_covers = not (self.settings.upload_covers ~= false)
                self:saveSettings()
            end,
        },
        {
            text = "上传本机封面（补漏，一次最多 12 张）",
            callback = function() self:uploadCoversNow() end,
        },
        {
            text = "重新补传封面（清除两端上传记录）",
            callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = "下次同步将重新补传封面，每端最多 12 张。继续？",
                    ok_callback = function()
                        self.settings.cover_sent = {}
                        self.settings.cover_sent2 = {}
                        self:saveSettings()
                        self:uploadCoversNow()
                    end,
                })
            end,
        },
        {
            text = "检查插件更新（当前 " .. PLUGIN_VERSION .. "）",
            callback = function() self:checkPluginUpdate() end,
        },
        {
            text = "书籍扫描目录（可选）",
            callback = function() self:showScanRoot() end,
        },
        {
            text = "查看上次同步结果",
            callback = function()
                UIManager:show(InfoMessage:new{ text = self.last_result })
            end,
        },
        {
            text = "当前配置一览",
            callback = function()
                local info = self:deviceName()
                local chline
                if (self.ch_total or 0) == 0 then
                    chline = "同步一次后才看得到"
                else
                    chline = string.format("上次 %d 条笔记里 %d 条带章节名",
                        self.ch_total, self.ch_with or 0)
                    if (self.ch_with or 0) == 0 then
                        chline = chline .. "\n（0 条＝这台 KOReader 没往 sidecar 写章节，网页上只能按页码显示）"
                    end
                end
                UIManager:show(InfoMessage:new{
                    text = "服务器：" .. tostring(s.server_url)
                        .. "\n同步口令：" .. (trim(s.token) ~= "" and "已设置" or "未设置")
                        .. "\n备用：" .. (trim(s.server_url2 or "") ~= ""
                            and (tostring(s.server_url2) .. "（" .. (trim(s.token2 or "") ~= "" and "口令已设置" or "口令未设置") .. "）")
                            or "未配置（只推主服务器）")
                        .. "\n设备名：" .. info
                        .. "\n章节名：" .. chline
                        .. "\n上次同步：" .. (self.last_sync_at > 0
                            and os.date("%Y-%m-%d %H:%M", self.last_sync_at) or "从未")
                })
            end,
        },
    }
end

function KRSync:showConfig()
    local s = self:loadSettings()
    local dialog
    dialog = MultiInputDialog:new{
        title = "Readbox 同步 - 配置",
        fields = {
            {
                description = "你部署后台后拿到的网址（哪种部署方式都一样）",
                hint = "服务器网址",
                text = s.server_url,
            },
            {
                description = "网页「我的 → 账号 → 同步口令」里显示的那串（自己编的，和登录账号无关）",
                hint = "同步口令",
                text = s.token,
                text_type = "password",
            },
            {
                description = "给这台 Kindle 起个名字，三台设备不要重名，例如 卧室KPW5",
                hint = "设备名",
                text = (s.device_name ~= "" and s.device_name or (Device.model or "Kindle")),
            },
            {
                description = "可选。填了就每次同步同时推第二处（如主处推网页版、备用推小程序）",
                hint = "备用服务器网址（可选）",
                text = s.server_url2 or "",
            },
            {
                description = "备用服务器的同步口令（填了网址就要填这个）",
                hint = "备用同步口令（可选）",
                text = s.token2 or "",
                text_type = "password",
            },
        },
        buttons = {
            {
                { text = "取消", callback = function()
                    UIManager:close(dialog)
                end },
                { text = "保存", callback = function()
                    local fields = dialog:getFields()
                    UIManager:close(dialog)
                    if trim(self.settings.server_url):gsub("/+$", "") ~= trim(fields[1]):gsub("/+$", "")
                        or trim(self.settings.token) ~= trim(fields[2]) then self.settings.cover_sent = {} end
                    if trim(self.settings.server_url2):gsub("/+$", "") ~= trim(fields[4]):gsub("/+$", "")
                        or trim(self.settings.token2) ~= trim(fields[5]) then self.settings.cover_sent2 = {} end
                    self.settings.server_url = trim(fields[1])
                    self.settings.token = trim(fields[2])
                    self.settings.device_name = trim(fields[3])
                    self.settings.server_url2 = trim(fields[4])
                    self.settings.token2 = trim(fields[5])
                    self:saveSettings()
                    UIManager:show(InfoMessage:new{ text = "已保存" })
                end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KRSync:showScanRoot()
    local s = self:loadSettings()
    local default = trim(s.scan_root) ~= "" and trim(s.scan_root) or self:defaultBookRoot()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = "书籍扫描目录",
        input = default,
        input_hint = "留空则自动推断",
        buttons = {
            {
                { text = "取消", callback = function() UIManager:close(dialog) end },
                { text = "保存", callback = function()
                    UIManager:close(dialog)
                    self.settings.scan_root = trim(dialog:getInputText())
                    self:saveSettings()
                    UIManager:show(InfoMessage:new{ text = "已保存，下次同步生效" })
                end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KRSync:defaultBookRoot()
    local ok, full = pcall(DataStorage.getFullDataDir, DataStorage)
    if not ok or not full or full == "" then
        ok, full = pcall(DataStorage.getDataDir, DataStorage)
        if not ok then return nil end
    end
    if type(full) ~= "string" then return nil end
    local parent = full:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return nil end
    return parent .. "/documents"
end

-- ---------------------------------------------------------------- 采集：统计数据库

function KRSync:collectStats(payload)
    local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local mode = lfs.attributes(db, "mode")
    if mode ~= "file" then
        logger.warn("KRSync: statistics.sqlite3 不存在")
        return
    end

    local okmod, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not okmod or not SQ3 then
        logger.warn("KRSync: 无法加载 sqlite 模块")
        return
    end

    local conn
    local okopen, res = pcall(function() return SQ3.open(db) end)
    if not okopen or not res then
        logger.warn("KRSync: 打开数据库失败")
        return
    end
    conn = res

    -- 每本书的累计时长：同样按单页上限重新算一遍。
    -- book 表里的 total_read_time 是 KOReader 自己累加的，里面也掺着挂机时长，
    -- 直接用会让某本书显示"读了 100 小时"，所以有统计记录的都以重算值为准。
    local totalmap = {}
    local okt, tres = pcall(function()
        return conn:exec([[SELECT id_book,
                                  SUM(MIN(duration, ]] .. PAGE_CAP .. [[)) AS sec
                           FROM page_stat_data
                           GROUP BY id_book;]])
    end)
    if okt and tres and tres[1] then
        for i = 1, #tres[1] do
            local tid = tonum(tres.id_book and tres.id_book[i])
            if tid then totalmap[tid] = math.floor(tonum(tres.sec and tres.sec[i]) or 0) end
        end
    end

    -- id -> {title, authors}
    local idmap = {}
    local okb, bres = pcall(function()
        return conn:exec([[SELECT id, title, authors, pages, md5, series, language,
                                  total_read_time, total_read_pages, last_open
                           FROM book;]])
    end)
    if okb and bres and bres[1] then
        local n = #bres[1]
        for i = 1, n do
            local id = tonum(bres.id and bres.id[i])
            local title = bres.title and bres.title[i] or ""
            local authors = bres.authors and bres.authors[i] or ""
            if id then
                idmap[id] = { title = title, authors = authors }
            end
            payload.books[#payload.books + 1] = {
                k = bookKey(title, authors),
                title = trim(title),
                authors = trim(authors),
                pages = tonum(bres.pages and bres.pages[i]) or 0,
                md5 = tostring(bres.md5 and bres.md5[i] or ""),
                series = tostring(bres.series and bres.series[i] or ""),
                language = tostring(bres.language and bres.language[i] or ""),
                total_read_time = totalmap[id] or math.floor(tonum(bres.total_read_time and bres.total_read_time[i]) or 0),
                total_read_pages = math.floor(tonum(bres.total_read_pages and bres.total_read_pages[i]) or 0),
                last_open = math.floor(tonum(bres.last_open and bres.last_open[i]) or 0),
            }
        end
    end

    -- 每天的阅读秒数 / 页数
    -- 注意 MIN(duration, 1800)：KOReader 记的是"在某页停留了多少秒"，
    -- 书开着没关就去睡觉、待机/休眠没真正退出阅读，那一页就会积出几万秒，
    -- 一天凭空多出十几个小时。一屏读满 30 分钟几乎不可能，超出的部分一律当挂机削掉。
    local okd, dres = pcall(function()
        return conn:exec([[SELECT id_book,
                                  strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS d,
                                  SUM(MIN(duration, ]] .. PAGE_CAP .. [[)) AS sec,
                                  COUNT(DISTINCT page) AS pages
                           FROM page_stat_data
                           GROUP BY id_book, d;]])
    end)
    if okd and dres and dres[1] then
        local n = #dres[1]
        for i = 1, n do
            local id = tonum(dres.id_book and dres.id_book[i])
            local info = id and idmap[id]
            local date = tostring(dres.d and dres.d[i] or "")
            if info and date ~= "" then
                payload.days[#payload.days + 1] = {
                    k = bookKey(info.title, info.authors),
                    d = date,
                    sec = math.floor(tonum(dres.sec and dres.sec[i]) or 0),
                    pages = math.floor(tonum(dres.pages and dres.pages[i]) or 0),
                }
            end
        end
    end

    -- 24 小时分布：每段阅读按其开始时间落到对应的小时里。
    -- 网页上的「阅读时段」图就靠这 24 个数字，只装小时不装日期，体积可以忽略。
    local hours = {}
    for i = 1, 24 do hours[i] = 0 end
    local okh, hres = pcall(function()
        return conn:exec([[SELECT CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER) AS h,
                                  SUM(MIN(duration, ]] .. PAGE_CAP .. [[)) AS sec
                           FROM page_stat_data
                           GROUP BY h;]])
    end)
    if okh and hres and hres[1] then
        local n = #hres[1]
        for i = 1, n do
            local h = math.floor(tonum(hres.h and hres.h[i]) or 0)
            local sec = math.floor(tonum(hres.sec and hres.sec[i]) or 0)
            if h >= 0 and h <= 23 then
                hours[h + 1] = hours[h + 1] + sec
            end
        end
    end
    payload.hours = hours

    -- 最近 30 天的「哪天 × 几点」明细：网页上把时段切成「近一周 / 近 30 天」就靠它。
    -- 只留 30 天、不按书拆，通常一两百条，体积可忽略。
    local hour_days = {}
    local cutoff = os.time() - 30 * 86400
    local okhd, hdres = pcall(function()
        return conn:exec([[SELECT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS d,
                                  CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER) AS h,
                                  SUM(MIN(duration, ]] .. PAGE_CAP .. [[)) AS sec
                           FROM page_stat_data
                           WHERE start_time >= ]] .. tostring(cutoff) .. [[
                           GROUP BY d, h;]])
    end)
    if okhd and hdres and hdres[1] then
        local n = #hdres[1]
        for i = 1, n do
            if #hour_days >= 1500 then break end
            local dd = tostring(hdres.d and hdres.d[i] or "")
            local hh = math.floor(tonum(hdres.h and hdres.h[i]) or 0)
            local ss = math.floor(tonum(hdres.sec and hdres.sec[i]) or 0)
            if dd ~= "" and hh >= 0 and hh <= 23 and ss > 0 then
                hour_days[#hour_days + 1] = { d = dd, h = hh, sec = ss }
            end
        end
    end
    payload.hour_days = hour_days

    pcall(function() conn:close() end)
end

-- ---------------------------------------------------------------- 采集：划线与批注

local function normalize_datetime(v)
    if type(v) == "table" then
        return string.format("%04d-%02d-%02d %02d:%02d:%02d",
            tonum(v.year) or 1970, tonum(v.month) or 1, tonum(v.day) or 1,
            tonum(v.hour) or 0, tonum(v.min) or 0, tonum(v.sec) or 0)
    elseif type(v) == "string" then
        return v
    end
    return ""
end

local function pick_percent(t)
    local keys = { "percent_finished_night", "percent_finished", "percent" }
    local best = 0
    for _, key in ipairs(keys) do
        local v = tonum(t[key])
        if v and v > best then best = v end
    end
    if best > 0 then return best end
    return nil
end

-- ---------------------------------------------------------------- 采集：书籍封面
-- KOReader 把书的封面图放在书旁边的 .sdr 目录里（自定义封面固定叫 cover.<ext>）。
-- 把这张图原样传上去，网页上就是这本书自己的封面，不用再去网上猜。

local COVER_EXT_CT = {
    jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png", webp = "image/webp",
}

local function findCoverFile(dir)
    local ok, iter, o1, o2 = pcall(lfs.dir, dir)
    if not ok then return nil end
    local others = {}
    for name in iter, o1, o2 do
        local base, ext = name:match("^(.*)%.([%a%d]+)$")
        if base and ext then
            ext = ext:lower()
            if COVER_EXT_CT[ext] then
                local full = dir .. "/" .. name
                if base:lower() == "cover" then
                    return full, ext
                end
                others[#others + 1] = { full, ext }
            end
        end
    end
    -- 没有 cover.* 才退而求其次：目录里只有一张图，那多半就是封面
    if #others == 1 then return others[1][1], others[1][2] end
    return nil
end

-- 遍历目录，回调 (full_path, file_name)
local function walk(dir, depth, seen, cb)
    local ok, iter, o1, o2 = pcall(lfs.dir, dir)
    if not ok then return end
    local names = {}
    for name in iter, o1, o2 do
        if name ~= "." and name ~= ".." then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local full = dir .. "/" .. name
        local attr = lfs.attributes(full)
        if attr then
            if attr.mode == "directory" then
                if depth < 7 then walk(full, depth + 1, seen, cb) end
            elseif attr.mode == "file" then
                cb(full, name)
            end
        end
    end
end

function KRSync:collectAnnotations(payload)
    local s = self:loadSettings()
    -- 章节覆盖率：KOReader 只有较新版本才会把章节名写进 sidecar，
    -- 老版本这里会是 0，网页上自然也就显示不出章节。统计一下，好在菜单里自查。
    self.ch_total, self.ch_with = 0, 0
    local roots, added = {}, {}
    local function add_root(r)
        if r and r ~= "" and not added[r] and lfs.attributes(r, "mode") == "directory" then
            added[r] = true
            roots[#roots + 1] = r
        end
    end

    local function tryget(fn)
        if type(DataStorage[fn]) == "function" then
            local ok, v = pcall(DataStorage[fn], DataStorage)
            if ok and type(v) == "string" then add_root(v) end
        end
    end
    tryget("getHistoryDir")
    tryget("getDocSettingsDir")
    tryget("getBookSettingsDir")
    add_root(trim(s.scan_root))
    local auto = self:defaultBookRoot()
    if trim(s.scan_root) == "" then add_root(auto) end

    local seen_books = {}
    local scanned = 0
    -- 封面：每本书只要一张，而且只传没传过的
    local sent = (type(s.cover_sent) == "table") and s.cover_sent or {}
    local sent2 = (type(s.cover_sent2) == "table") and s.cover_sent2 or {}
    local targets = self:targets()
    local cover_want = #targets > 0 and s.upload_covers ~= false
    local covers = {}
    local cover_seen = {}

    for _, root in ipairs(roots) do
        walk(root, 0, nil, function(full, name)
            if scanned > 60000 then return end
            local is_meta = name:match("^metadata%..+%.lua$") ~= nil
            local is_hist = name:match("%.lua$") ~= nil and name:match("%.lua%.old$") == nil
            if not (is_meta or is_hist) then return end
            scanned = scanned + 1
            local ok, data = pcall(dofile, full)
            if not ok or type(data) ~= "table" then return end

            local props = data.doc_props or {}
            local title = trim(props.display_title or props.title or data.title or "")
            local authors = trim(props.authors or "")
            if title == "" then return end
            local key = bookKey(title, authors)

            -- 进度
            local percent = pick_percent(data)
            if percent and not seen_books[key] then
                payload.progress[#payload.progress + 1] = {
                    k = key,
                    title = title,
                    authors = authors,
                    percent = percent,
                }
            end

            -- 划线 / 批注 / 书签
            -- highlighted=false 的是 KOReader 书签（可能带批注，也可能只有一个位置），
            -- 以前这里直接把它们丢掉了，网页上压根看不到书签。现在一并上报，
            -- 用 type 让网页把「划线」和「书签」区分开。
            local list = data.annotations or data.bookmarks
            if type(list) == "table" then
                for _, item in ipairs(list) do
                    if type(item) == "table" and (#payload.annotations < MAX_ANNOTATIONS) then
                        local text = trim(item.text or "")
                        local note = trim(item.note or "")
                        -- 划线 = 真正选中了高亮文字；KOReader 纯书签的 highlighted 常常是 nil（不设），
                        -- 用 item.highlighted==false 去判断会被漏掉，这里直接按「有没有文字」判。
                        local highlighted = (text ~= "")
                        -- 书签本身就是一条笔记：既没选中原文、也没写批注的也要上报（网页端靠 type 区分）。
                        -- 只看 highlighted / text / note 会把纯书签漏掉，所以页码也算一个有效依据。
                        if highlighted or text ~= "" or note ~= "" or (tonum(item.page) or 0) > 0 then
                            local t = truncate_utf8(text, MAX_TEXT_BYTES)
                            note = truncate_utf8(note, MAX_TEXT_BYTES)
                            local chap = tostring(item.chapter or "")
                            self.ch_total = (self.ch_total or 0) + 1
                            if trim(chap) ~= "" then self.ch_with = (self.ch_with or 0) + 1 end
                            payload.annotations[#payload.annotations + 1] = {
                                k = key,
                                title = title,
                                authors = authors,
                                page = tonum(item.page) or 0,
                                text = t,
                                note = note,
                                datetime = normalize_datetime(item.datetime or item.time),
                                chapter = chap,
                                type = highlighted and "highlight" or "bookmark",
                            }
                        end
                    end
                end
            end

            -- 顺手找一下这本书的封面（同一个 key 只要一张）。
            -- 双推送：两处都传过才不再收，哪边缺了都会在后续同步里补上。
            local needs_cover = false
            for _, target in ipairs(targets) do
                local history = target.second and sent2 or sent
                if not history[key] then needs_cover = true end
            end
            if cover_want and not cover_seen[key] and needs_cover then
                cover_seen[key] = true
                local sdr_dir = full:match("^(.*)/[^/]+$")
                local cpath, cext
                if sdr_dir then cpath, cext = findCoverFile(sdr_dir) end
                local docfile = trim(data.doc_path)
                if docfile == "" and sdr_dir then
                    local stem = sdr_dir:match("^(.*)%.sdr$")
                    local ext = name:match("^metadata%.([%a%d]+)%.lua$")
                    if stem and ext then docfile = stem .. "." .. ext end
                end
                if not cpath and docfile ~= "" and lfs.attributes(docfile, "mode") == "file" then
                    covers[#covers + 1] = { key = key, title = title, authors = authors, document = docfile }
                elseif cpath then
                    local attr = lfs.attributes(cpath)
                    local size = (attr and attr.size) or 0
                    if size > 200 and size <= MAX_COVER_BYTES then
                        covers[#covers + 1] = {
                            key = key, title = title, authors = authors,
                            path = cpath, ext = cext,
                        }
                    end
                end
            end

            -- 只登记一次「读过这本书」
            if not seen_books[key] then
                seen_books[key] = true
                local known = false
                for _, b in ipairs(payload.books) do
                    if b.k == key then known = true break end
                end
                if not known then
                    payload.books[#payload.books + 1] = {
                        k = key, title = title, authors = authors,
                        pages = tonum(props.pages) or 0,
                        md5 = "", series = tostring(props.series or ""),
                        language = tostring(props.language or ""),
                        total_read_time = 0, total_read_pages = 0, last_open = 0,
                    }
                end
            end
        end)
    end

    self._pending_covers = covers
    payload._scanned_files = scanned
end

-- ---------------------------------------------------------------- 打包 & 上传

function KRSync:collect()
    local payload = {
        v = 1,
        device = self:deviceName(),
        device_id = self:deviceId(),
        model = tostring(Device.model or ""),
        collected_at = os.time(),
        books = {},
        days = {},
        annotations = {},
        progress = {},
        hours = {},
        hour_days = {},
    }
    pcall(function() self:collectStats(payload) end)
    pcall(function() self:collectAnnotations(payload) end)
    payload._scanned_files = nil
    return payload
end

-- useSecond = true 时推备用服务器（server_url2/token2）
function KRSync:upload(body, useSecond)
    local s = self:loadSettings()
    local base = trim(useSecond and (s.server_url2 or "") or s.server_url):gsub("/+$", "")
    local tok = useSecond and (s.token2 or "") or s.token
    local url = base .. "/api/push?device=" .. urlencode(self:deviceName())
        .. "&token=" .. urlencode(tok)

    local client
    if url:sub(1, 6) == "https:" then
        local ok, mod = pcall(require, "ssl.https")
        if not ok or not mod then return nil, "无法加载 HTTPS 模块" end
        client = mod
    else
        local ok, mod = pcall(require, "socket.http")
        if not ok or not mod then return nil, "无法加载 HTTP 模块" end
        client = mod
    end
    client.TIMEOUT = 25

    local sink = {}
    local code, status_line
    local ok, err = pcall(function()
        local _, c, _h, st = client.request{
            url = url,
            method = "PUT",
            headers = {
                ["Content-Type"] = "application/json; charset=utf-8",
                ["Content-Length"] = tostring(#body),
                ["Accept"] = "application/json",
                ["User-Agent"] = "ReadboxSync/1.0",
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
        }
        code, status_line = c, st
    end)
    if not ok then return nil, tostring(err) end
    return code, table.concat(sink)
end

-- 传二进制（封面图）。不能用 json_encode，直接把文件内容当请求体发。
function KRSync:uploadBinary(url, body, content_type)
    local client
    if url:sub(1, 6) == "https:" then
        local ok, mod = pcall(require, "ssl.https")
        if not ok or not mod then return nil, "无法加载 HTTPS 模块" end
        client = mod
    else
        local ok, mod = pcall(require, "socket.http")
        if not ok or not mod then return nil, "无法加载 HTTP 模块" end
        client = mod
    end
    client.TIMEOUT = 25

    local sink = {}
    local code
    local ok, err = pcall(function()
        local _, c = client.request{
            url = url,
            method = "PUT",
            headers = {
                ["Content-Type"] = content_type,
                ["Content-Length"] = tostring(#body),
                ["Accept"] = "application/json",
                ["User-Agent"] = "ReadboxSync/1.0",
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
        }
        code = c
    end)
    if not ok then return nil, tostring(err) end
    return code
end

-- 把本地封面一张张传上去。每张成功后就记进 cover_sent，下次不再重复传。
-- 双推送：主处成功记 cover_sent，备用（有配置时）成功记 cover_sent2，
-- 两边各自补齐 —— 哪边缺的封面会在后续同步里自动补上。
function KRSync:coverData(c)
    if c.data then return c.data, c.ext end
    local path, bb = c.path, nil
    local temporary = DataStorage:getSettingsDir() .. "/krsync-cover.tmp.jpg"
    if not path and c.document then
        local ok = pcall(function()
            local BookInfo = require("apps/filemanager/filemanagerbookinfo")
            bb = BookInfo:getCoverImage(nil, c.document)
            if not bb then return end
            local w, h = bb:getWidth(), bb:getHeight()
            local ratio = math.min(1, 600 / w, 900 / h)
            if ratio < 1 then
                local small = bb:scale(math.max(1, math.floor(w * ratio)), math.max(1, math.floor(h * ratio)))
                bb:free() bb = small
            end
            local wrote = bb:writeToFile(temporary, "jpg", 85)
            if wrote then path = temporary c.ext = "jpg" end
        end)
        if bb then pcall(function() bb:free() end) end
        if not ok then os.remove(temporary) return nil end
    end
    local fh = path and io.open(path, "rb")
    local data
    if fh then data = fh:read(MAX_COVER_BYTES + 1) fh:close() end
    if path == temporary then os.remove(temporary) end
    if data and #data > 0 and #data <= MAX_COVER_BYTES then
        c.data = data
        return data, c.ext
    end
end

function KRSync:uploadCovers(list)
    local s = self:loadSettings()
    local report, any_saved = {}, false
    for _, target in ipairs(self:targets()) do
        local item = { label = target.label, ok = 0, failed = 0, remaining = 0 }
        report[#report + 1] = item
        local history = s[target.sent]
        if type(history) ~= "table" then history = {} s[target.sent] = history end
        local attempted = 0
        for _, c in ipairs(list) do
            if not history[c.key] then
                if attempted >= MAX_COVERS_PER_SYNC then
                    item.remaining = item.remaining + 1
                else
                    attempted = attempted + 1
                    local data, ext = self:coverData(c)
                    local code
                    if data and #data > 0 and #data <= MAX_COVER_BYTES and target.token ~= "" then
                        local url = target.base .. "/api/cover/put?t=" .. urlencode(target.token)
                            .. "&title=" .. urlencode(c.title) .. "&author=" .. urlencode(c.authors)
                        code = self:uploadBinary(url, data, COVER_EXT_CT[ext] or "image/jpeg")
                    end
                    if tonumber(code) == 200 then
                        history[c.key] = true
                        item.ok = item.ok + 1
                        any_saved = true
                    else
                        item.failed = item.failed + 1
                        item.remaining = item.remaining + 1
                        item.error = tostring(code or "读取失败或口令未设置")
                    end
                end
            end
        end
    end
    if any_saved then self:saveSettings() end
    self.cover_report = report
    local first = report[1] or { ok = 0, failed = 0 }
    return first.ok, first.failed, report
end

function KRSync:coverSummary(report)
    local lines = {}
    for _, r in ipairs(report or {}) do
        lines[#lines + 1] = string.format("%s封面：已传 %d · 失败 %d · 待传 %d%s",
            r.label, r.ok, r.failed, r.remaining,
            r.error and ("（" .. r.error .. "）") or "")
    end
    return table.concat(lines, "\n")
end

-- 只补封面，不动其它数据。用于第一次装好插件、把已有书的封面一次性补齐。
function KRSync:uploadCoversNow()
    local s = self:loadSettings()
    if #self:targets() == 0 then
        UIManager:show(InfoMessage:new{ text = "请先填写服务器网址和同步口令" })
        self:showConfig()
        return
    end
    if not NetworkMgr:isConnected() then
        UIManager:show(InfoMessage:new{ text = "设备当前没有联网（WiFi 是否打开？）" })
        return
    end
    if self.syncing then
        UIManager:show(InfoMessage:new{ text = "正在同步中，稍等一下再试" })
        return
    end

    self.syncing = true
    UIManager:show(InfoMessage:new{ text = "正在扫描本机书籍封面…" })
    local payload = { v = 1, device = self:deviceName(), model = tostring(Device.model or ""),
                      collected_at = os.time(), books = {}, days = {}, annotations = {}, progress = {} }
    pcall(function() self:collectAnnotations(payload) end)
    local pending = self._pending_covers or {}
    self._pending_covers = nil

    if #pending == 0 then
        self.syncing = false
        UIManager:show(InfoMessage:new{
            text = "没有需要上传的封面。\n（要么本机书籍都没有封面图，要么之前的都传过了）" })
        return
    end

    UIManager:show(InfoMessage:new{ text = string.format("找到 %d 张待传封面，正在上传…", #pending) })
    local worked, err = pcall(function() self:uploadCovers(pending) end)
    self.syncing = false
    UIManager:show(InfoMessage:new{
        text = worked and self:coverSummary(self.cover_report) or "封面上传异常，请重试",
    })
end

function KRSync:sync(verbose)
    if self.syncing then
        if verbose then UIManager:show(InfoMessage:new{ text = "正在同步中，请稍候" }) end
        return
    end
    local targets = self:targets()
    if #targets == 0 then self:showConfig() return end
    if not NetworkMgr:isConnected() then
        self.last_result = "同步失败：设备当前没有联网"
        if verbose then UIManager:show(InfoMessage:new{ text = self.last_result }) end
        return
    end
    self.syncing = true
    local worked = pcall(function()
        if verbose then Notification:notify("正在收集并上传数据…") end
        local payload = self:collect()
        local body = json_encode(payload)
        local success, results = 0, {}
        for _, target in ipairs(targets) do
            local code
            if target.token ~= "" then code = self:upload(body, target.second) end
            if tonumber(code) == 200 then
                success = success + 1
                results[#results + 1] = target.label .. "：已同步"
            else
                results[#results + 1] = target.label .. "：失败（" ..
                    (target.token == "" and "口令未设置" or "HTTP " .. tostring(code)) .. "）"
            end
        end
        local pending = self._pending_covers or {}
        self._pending_covers = nil
        local coverNote = ""
        if #pending > 0 then
            self:uploadCovers(pending)
            coverNote = "\n" .. self:coverSummary(self.cover_report)
        end
        if success > 0 then self.last_sync_at = os.time() end
        local status = success == #targets and "同步成功" or (success > 0 and "部分同步成功" or "同步失败")
        self.last_result = status .. "\n" .. table.concat(results, "\n")
            .. string.format("\n书籍 %d 本 · 划线 %d 条 · %d KB", #payload.books,
                #payload.annotations, math.floor(#body / 1024)) .. coverNote
    end)
    self.syncing = false
    if not worked then self.last_result = "同步异常：请重试，必要时检查书籍扫描目录" end
    if verbose then UIManager:show(InfoMessage:new{ text = self.last_result })
    else Notification:notify(self.last_result) end
    logger.info("KRSync: " .. self.last_result)
end

-- OTA is deliberately a single-file update. Credentials live in settings/krsync.lua.
local OTA_ROOT = "https://raw.githubusercontent.com/Yuki-1panda/krsync/"
local source_path = debug.getinfo(1, "S").source:gsub("^@", "")

local function newer_version(candidate, current)
    local a, b, c = candidate:match("^(%d+)%.(%d+)%.(%d+)$")
    local x, y, z = current:match("^(%d+)%.(%d+)%.(%d+)$")
    if not a or not x then return false end
    a, b, c, x, y, z = tonumber(a), tonumber(b), tonumber(c), tonumber(x), tonumber(y), tonumber(z)
    return a > x or (a == x and (b > y or (b == y and c > z)))
end

function KRSync:otaGet(url, limit)
    local https = require("ssl.https")
    local socketutil = require("socketutil")
    local chunks, count, started = {}, 0, os.time()
    socketutil:set_timeout(10, 30)
    local ok, result, code = pcall(https.request, {
        url = url, method = "GET", redirect = false,
        headers = { ["User-Agent"] = "ReadboxSync/" .. PLUGIN_VERSION },
        sink = function(chunk, err)
            if err then return nil, err end
            if chunk then
                count = count + #chunk
                if count > limit or os.time() - started > 30 then return nil, "下载超限或超时" end
                chunks[#chunks + 1] = chunk
            end
            return 1
        end,
    })
    socketutil:reset_timeout()
    if not ok or not result or tonumber(code) ~= 200 then return nil, "下载失败，请检查 WiFi 和 GitHub 连接" end
    return table.concat(chunks)
end

function KRSync:installPluginUpdate(version, digest, size)
    if self.syncing then return end
    self.syncing = true
    local ok, message = pcall(function()
        local body, err = self:otaGet(OTA_ROOT .. "v" .. version .. "/plugin/krsync.koplugin/main.lua", 512 * 1024)
        if not body then return err end
        if #body ~= size or require("ffi/sha2").sha256(body) ~= digest then return "更新校验失败，未替换插件" end
        if body:match('^local PLUGIN_VERSION = "([%d%.]+)"') ~= version then return "更新版本不匹配" end
        local compiler = loadstring or load
        if not compiler(body, "@krsync-update") then return "更新文件语法错误，未替换插件" end
        local function writeFile(path, data)
            local f = io.open(path, "wb")
            if not f then return false end
            local wrote = f:write(data)
            local closed = f:close()
            return wrote ~= nil and closed ~= nil
        end
        local original = io.open(source_path, "rb")
        if not original then return "无法读取当前插件位置" end
        local old = original:read("*a") original:close()
        local staged = source_path .. ".ota-new"
        if not writeFile(staged, body) then return "写入更新失败，未替换插件" end
        if not writeFile(source_path .. ".bak", old) then return "备份失败，未替换插件" end
        if not os.rename(staged, source_path) then return "替换失败，原插件保留" end
        self.update_installed = true
        return "插件已升级到 " .. version .. "，请重启 KOReader 生效。\n网址和同步口令已保留。"
    end)
    self.syncing = false
    UIManager:show(InfoMessage:new{ text = ok and message or "更新异常，重新检查更新后再试" })
end

function KRSync:checkPluginUpdate()
    if self.syncing then UIManager:show(InfoMessage:new{ text = "正在同步，请稍后检查更新" }) return end
    if self.update_installed then UIManager:show(InfoMessage:new{ text = "更新已安装，请先重启 KOReader" }) return end
    if not NetworkMgr:isConnected() then UIManager:show(InfoMessage:new{ text = "请先连接 WiFi" }) return end
    self.syncing = true
    local ok, message = pcall(function()
        local manifest, err = self:otaGet(OTA_ROOT .. "main/ota.txt", 1024)
        if not manifest then return err end
        local version, digest, bytes = manifest:match("^(%d+%.%d+%.%d+)\n([a-f0-9]+)\n(%d+)\n?$")
        local size = tonumber(bytes)
        if not version or #digest ~= 64 or not size or size < 1000 or size > 512 * 1024 then return "更新信息无效" end
        if not newer_version(version, PLUGIN_VERSION) then return "已是最新版本：" .. PLUGIN_VERSION end
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = "发现新版本 " .. version .. "，下载并安装？\n完成后需重启 KOReader。",
            ok_callback = function() self:installPluginUpdate(version, digest, size) end,
        })
    end)
    self.syncing = false
    if message or not ok then UIManager:show(InfoMessage:new{ text = ok and message or "检查更新异常，请重试" }) end
end

return KRSync
