local checks = 0
local function check(v, text) assert(v, text) checks = checks + 1 end
local calls = {}
local originalCollect = KRSync.collect
local originalOtaGet = KRSync.otaGet
local originalAnnotations = KRSync.collectAnnotations
local lfs = package.loaded["libs/libkoreader-lfs"]
local oldAttributes = lfs.attributes
lfs.attributes = function(p, req)
    local a = oldAttributes(p, req)
    if type(a) == "table" then a.size = 300 end
    return a
end
KRSync:collectAnnotations({ books={}, progress={}, annotations={} })
check(#KRSync._pending_covers > 0 and KRSync._pending_covers[1].ext == "png", "collector preserves PNG extension")
lfs.attributes = oldAttributes
local function setup(primary, secondary)
    KRSync.settings = { server_url = primary and "https://primary.example" or "", token = "one",
        server_url2 = secondary and "https://secondary.example" or "", token2 = "two",
        cover_sent = {}, cover_sent2 = {}, upload_covers = true }
    calls = {}
    KRSync._pending_covers = {}
    KRSync.update_installed = false
    KRSync.collect = function(self) return { books = {}, annotations = {} } end
    KRSync.upload = function(self, body, second)
        calls[#calls + 1] = second and "secondary" or "primary"
        return 200
    end
    KRSync.saveSettings = function() end
end
setup(false, true)
KRSync:sync(true)
check(#calls == 1 and calls[1] == "secondary", "secondary-only sync")
setup(true, true)
KRSync.upload = function(self, body, second)
    calls[#calls + 1] = second and "secondary" or "primary"
    return second and 200 or 503
end
KRSync:sync(false)
check(#calls == 2 and calls[2] == "secondary", "primary failure must not stop secondary")
check(KRSync.last_result:find("部分同步成功",1,true), "partial failure shown: " .. KRSync.last_result)
check(__cap.notified:find("失败",1,true), "automatic sync failure notification")
setup(true, true)
KRSync.collect = function() error("bad collect") end
KRSync:sync(true)
check(KRSync.syncing == false, "lock released after exception")
setup(true, true)
local originalOpen = io.open
io.open = function(path, mode) return { read = function() return "PNG_BYTES" end, close = function() return true end } end
local covers = {{ key="book", path="cover.png", ext="png", title="测试", authors="作者" }}
KRSync.settings.cover_sent.book = true
KRSync.uploadBinary = function(self, url, data, ct)
    calls[#calls + 1] = url
    check(ct == "image/png" and data == "PNG_BYTES", "PNG bytes and MIME preserved")
    return 200
end
KRSync:uploadCovers(covers)
check(#calls == 1 and calls[1]:find("secondary.example",1,true), "skip already sent primary")
check(KRSync.settings.cover_sent2.book, "secondary cover history saved")
calls = {} KRSync:uploadCovers(covers)
check(#calls == 0, "no duplicate covers after both sent")
setup(true,false)
KRSync.settings.cover_sent.book = true
KRSync:uploadCovers(covers)
check(#calls == 0, "single destination does not require secondary history")
setup(true,false)
KRSync.uploadBinary = function() return 500 end
KRSync:uploadCovers(covers)
check(not KRSync.settings.cover_sent.book, "failed cover remains pending")
check(KRSync.cover_report[1].failed == 1, "cover failure report")
setup(true,true)
local many = {}
for i=1,15 do many[i]={key=tostring(i),path="x",ext="png",title="T",authors="A"} end
KRSync.uploadBinary = function() calls[#calls+1]=true return 200 end
KRSync:uploadCovers(many)
check(#calls==24 and KRSync.cover_report[1].remaining==3 and KRSync.cover_report[2].remaining==3, "12 cover limit per destination")
io.open = originalOpen

-- OTA: simulated filesystem; no plugin on disk is overwritten.
setup(true,false)
local vfs = {}
local pluginPath = "PLUGIN_PATH"
vfs[pluginPath] = "OLD_PLUGIN"
io.open = function(path, mode)
    if mode == "rb" then
        if not vfs[path] then return nil end
        return {read=function() return vfs[path] end, close=function() return true end}
    end
    return {write=function(_,body) vfs[path]=body return true end, close=function() return true end}
end
local oldRename = os.rename
os.rename = function(a,b) vfs[b]=vfs[a] vfs[a]=nil return true end
package.loaded["ffi/sha2"].sha256 = function(body) return body == "CORRUPT" and string.rep("b",64) or string.rep("a",64) end
local updateBody = 'local PLUGIN_VERSION = "1.2.0"\nreturn {}\n' .. string.rep(" ",1100)
local updateRequests = {}
KRSync.otaGet = function(self,url)
    updateRequests[#updateRequests+1]=url
    if url:find("ota.txt",1,true) then return "1.2.0\n"..string.rep("a",64).."\n"..#updateBody.."\n" end
    return updateBody
end
local confirm
package.loaded["ui/widget/confirmbox"] = {new=function(_,t) confirm=t return t end}
KRSync:checkPluginUpdate()
check(confirm and confirm.ok_callback and not KRSync.syncing, "OTA offers confirmation and releases lock")
check(vfs[pluginPath]=="OLD_PLUGIN", "check update does not install")
confirm.ok_callback()
check(vfs[pluginPath] == updateBody and vfs[pluginPath..".bak"]=="OLD_PLUGIN", "OTA install with backup")
check(updateRequests[2]:find("/v1.2.0/plugin/krsync.koplugin/main.lua",1,true), "version-pinned URL")
check(KRSync.settings.token=="one" and KRSync.settings.token2=="two", "OTA preserves sync settings")
KRSync.update_installed=false vfs[pluginPath]="OLD_PLUGIN"
KRSync.otaGet=function() return "CORRUPT" end
KRSync:installPluginUpdate("1.2.0",string.rep("a",64),7)
check(vfs[pluginPath]=="OLD_PLUGIN" and not KRSync.syncing, "bad digest does not replace plugin")
KRSync.otaGet=function() return 'local PLUGIN_VERSION = "1.2.0"\nthis is bad lua' end
local bad = KRSync:otaGet()
KRSync:installPluginUpdate("1.2.0",string.rep("a",64),#bad)
check(vfs[pluginPath]=="OLD_PLUGIN", "invalid Lua does not replace plugin")
KRSync.otaGet=function() return "invalid manifest" end
confirm=nil KRSync:checkPluginUpdate()
check(confirm == nil and not KRSync.syncing, "invalid manifest rejected")
KRSync.otaGet=function() return "1.0.0\n"..string.rep("a",64).."\n2000\n" end
confirm=nil KRSync:checkPluginUpdate()
check(confirm == nil, "OTA will not downgrade")
package.loaded["socketutil"] = {set_timeout=function() end, reset_timeout=function() end}
package.loaded["ssl.https"].request = function(t) t.sink("123456") return 1,200 end
local downloaded = originalOtaGet(KRSync,"https://example.com",10)
check(downloaded == "123456", "OTA download reads complete response")
package.loaded["ssl.https"].request = function(t)
    local ok,err=t.sink("123456")
    if not ok then return nil,err end
    return 1,200
end
downloaded = originalOtaGet(KRSync,"https://example.com",3)
check(downloaded == nil, "OTA download rejects oversized response")
package.loaded["ssl.https"].request = function() return 1,404 end
check(originalOtaGet(KRSync,"https://example.com",10)==nil, "OTA rejects HTTP errors")
local freed = false
package.loaded["apps/filemanager/filemanagerbookinfo"] = {getCoverImage=function(_,doc,file)
    check(file == "sample.epub", "embedded cover reads document path")
    return {getWidth=function() return 300 end, getHeight=function() return 450 end,
        writeToFile=function(_,file,format) vfs[file]="JPEG_BYTES" return true end,
        free=function() freed=true end}
end}
local data,ext=KRSync:coverData({document="sample.epub"})
check(data=="JPEG_BYTES" and ext=="jpg" and freed, "embedded cover encoded and buffer freed")
io.open = originalOpen os.rename = oldRename
__checks = tostring(checks)
