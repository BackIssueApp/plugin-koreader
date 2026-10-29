--[[--
BackIssue for KOReader.

A BackIssue entry in the Tools menu: browse and download the server's Books
library, and keep reading progress in sync. Positions are kept as KOReader
states them (an xpointer in an EPUB, a page in a PDF), so two KOReader devices
resume at the exact spot; the web reader shares the position by percentage.

A book downloaded here remembers which BackIssue book it is in its sidecar.
Any other copy (fetched over OPDS, copied by hand) is recognised by a
fingerprint of its first and last 64 KiB, which the server computes too.
--]]--

local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
local Api = require("backissue_api")

local PLUGIN_VERSION = "0.1.0"
local PAGE_SIZE = 200          -- books fetched per list page
local PUSH_DEBOUNCE_S = 10     -- push this long after the last page turn
local PUSH_MIN_INTERVAL_S = 25 -- and never more often than this, unless asked
local MISS_RETRY_S = 86400     -- a book the server didn't know: ask again after a day
local FINGERPRINT_WINDOW = 65536

local BackIssue = WidgetContainer:extend{
    name = "backissue",
    is_doc_only = false,
}

-- backissue_defaults.lua is written by the server that handed out this copy
-- of the plugin, with its own address.
local function readDefaults()
    local ok, d = pcall(require, "backissue_defaults")
    if ok and type(d) == "table" then return d end
    return {}
end

local function pct(f)
    return math.floor((tonumber(f) or 0) * 100 + 0.5)
end

-- Same recipe as the server's fingerprint.js: MD5 over the first and the last
-- 64 KiB (a small file hashes its whole content twice).
local function fingerprint(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end") or 0
    local md5 = require("ffi/sha2").md5
    local update = md5()
    f:seek("set", 0)
    local head = f:read(math.min(FINGERPRINT_WINDOW, size))
    if head then update(head) end
    local tail_start = math.max(0, size - FINGERPRINT_WINDOW)
    f:seek("set", tail_start)
    local tail = f:read(size - tail_start)
    if tail then update(tail) end
    f:close()
    return update(), size
end

function BackIssue:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/backissue.lua")
    local defaults = readDefaults()
    if not self.settings:has("server") and type(defaults.server) == "string" and defaults.server ~= "" then
        self.settings:saveSetting("server", defaults.server)
        self.settings:flush()
    end
    self.device_id = G_reader_settings:readSetting("device_id")
    self.last_push = 0
    self.push_task = function() self:pushProgress({ auto = true }) end
    self.ui.menu:registerToMainMenu(self)
end

-- ---- settings ----------------------------------------------------------------

function BackIssue:server() return self.settings:readSetting("server") or "" end
function BackIssue:apiKey() return self.settings:readSetting("api_key") or "" end
function BackIssue:isConfigured() return self:server() ~= "" and self:apiKey() ~= "" end
function BackIssue:autoSync() return self.settings:nilOrTrue("auto_sync") end
function BackIssue:deviceName()
    return self.settings:readSetting("device_name") or Device.model or "KOReader"
end
function BackIssue:downloadDir()
    return self.settings:readSetting("download_dir")
        or G_reader_settings:readSetting("download_dir")
        or G_reader_settings:readSetting("home_dir")
        or Device.home_dir
        or "."
end
function BackIssue:client()
    return Api:new{
        server = self:server(),
        api_key = self:apiKey(),
        user_agent = "BackIssue-KOReader/" .. PLUGIN_VERSION .. " (" .. tostring(Device.model or "device") .. ")",
    }
end

function BackIssue:addToMainMenu(menu_items)
    local configured = function() return self:isConfigured() end
    local reading = function() return self.ui.document ~= nil and self:isConfigured() end
    menu_items.backissue = {
        text = _("BackIssue"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Browse library"),
                enabled_func = configured,
                callback = function() self:browse({}) end,
            },
            {
                text = _("Recently added"),
                enabled_func = configured,
                callback = function() self:browse({ sort = "recent" }) end,
            },
            {
                text = _("Search library"),
                enabled_func = configured,
                callback = function() self:askSearch() end,
                separator = true,
            },
            {
                text = _("Pull progress from server"),
                enabled_func = reading,
                callback = function() self:pullProgress({ interactive = true }) end,
            },
            {
                text = _("Push progress to server"),
                enabled_func = reading,
                callback = function() self:pushProgress({ interactive = true }) end,
            },
            {
                text = _("Automatic sync"),
                help_text = _("Pull the newest position when a book opens; push this device's position as you read, and when the book closes or the device sleeps."),
                checked_func = function() return self:autoSync() end,
                callback = function()
                    self.settings:saveSetting("auto_sync", not self:autoSync())
                    self.settings:flush()
                end,
                separator = true,
            },
            {
                text_func = function()
                    local s = self:server()
                    return s ~= "" and T(_("Server: %1"), BD.url(s)) or _("Server")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editText(_("BackIssue server address"), "server", {
                        hint = "https://backissue.example.com",
                        normalize = function(v)
                            v = v:gsub("/+$", "")
                            if v ~= "" and not v:match("^https?://") then v = "https://" .. v end
                            return v
                        end,
                    }, function() touchmenu_instance:updateItems() end)
                end,
            },
            {
                text_func = function()
                    return self:apiKey() ~= "" and _("API key: set") or _("API key")
                end,
                help_text = _("A personal key from your Profile page in BackIssue."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editText(_("BackIssue API key"), "api_key", { password = true },
                        function() touchmenu_instance:updateItems() end)
                end,
            },
            {
                text_func = function()
                    return T(_("Download folder: %1"), BD.dirpath(self:downloadDir()))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    require("ui/downloadmgr"):new{
                        onConfirm = function(path)
                            self.settings:saveSetting("download_dir", path)
                            self.settings:flush()
                            touchmenu_instance:updateItems()
                        end,
                    }:chooseDir(self:downloadDir())
                end,
            },
            {
                text_func = function() return T(_("This device: %1"), self:deviceName()) end,
                help_text = _("How this device is named when another one picks up its position."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editText(_("Name of this device"), "device_name", { default = self:deviceName() },
                        function() touchmenu_instance:updateItems() end)
                end,
                separator = true,
            },
            {
                text = _("Test connection"),
                enabled_func = configured,
                keep_menu_open = true,
                callback = function() self:testConnection() end,
            },
            {
                text = T(_("About BackIssue plugin (%1)"), PLUGIN_VERSION),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_([[BackIssue for KOReader %1

Browse and download your Books library, and keep reading progress in sync. Two KOReader devices resume at the exact spot; the web reader shares the position by percentage.

Server: %2]]), PLUGIN_VERSION, self:server() ~= "" and self:server() or _("not set")),
                    })
                end,
            },
        },
    }
end

function BackIssue:editText(title, key, opts, after)
    opts = opts or {}
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self.settings:readSetting(key) or opts.default or "",
        input_hint = opts.hint,
        text_type = opts.password and "password" or nil,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local v = util.trim(dialog:getInputText() or "")
                    if opts.normalize then v = opts.normalize(v) end
                    if v == "" then self.settings:delSetting(key) else self.settings:saveSetting(key, v) end
                    self.settings:flush()
                    UIManager:close(dialog)
                    if after then after() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BackIssue:testConnection()
    NetworkMgr:runWhenOnline(function()
        local me, err = self:client():me()
        if me then
            local text = T(_("Connected to %1 as %2.\nBackIssue %3, server plugin %4."),
                BD.url(self:server()), me.user or "?", me.version or "?", me.plugin or "?")
            if me.books == false then text = text .. "\n\n" .. _("This server has no Books library yet.") end
            UIManager:show(InfoMessage:new{ text = text })
        else
            UIManager:show(InfoMessage:new{ text = T(_("Could not reach the server: %1"), err or "?") })
        end
    end)
end

-- ---- browsing and downloading ---------------------------------------------------

function BackIssue:browse(opts)
    NetworkMgr:runWhenOnline(function() self:showBooks(opts or {}) end)
end

function BackIssue:askSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("Search BackIssue library"),
        input_hint = _("title, series or author"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local q = util.trim(dialog:getInputText() or "")
                    UIManager:close(dialog)
                    if q ~= "" then self:browse({ q = q }) end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BackIssue:localPath(b)
    local dir = self:downloadDir()
    local name = b.filename
    if not name or name == "" then name = (b.title or "book") .. "." .. (b.format or "epub") end
    return dir .. "/" .. util.getSafeFilename(name, dir)
end

local function bookLine(b)
    local head = ""
    if b.series and b.series ~= "" then
        head = b.series
        if b.series_index and b.series_index ~= "" then head = head .. " " .. tostring(b.series_index) end
        head = head .. ": "
    end
    local by = ""
    if type(b.authors) == "table" and #b.authors > 0 then by = " — " .. table.concat(b.authors, ", ") end
    return head .. (b.title or "?") .. by
end

function BackIssue:bookItems(state)
    local items = {}
    for _i, b in ipairs(state.books) do
        local tags = {}
        if (tonumber(b.fraction) or 0) > 0 then tags[#tags + 1] = pct(b.fraction) .. "%" end
        if b.format then tags[#tags + 1] = string.upper(b.format) end
        if lfs.attributes(self:localPath(b), "mode") == "file" then tags[#tags + 1] = _("on device") end
        items[#items + 1] = {
            text = bookLine(b),
            mandatory = table.concat(tags, " · "),
            book = b,
            callback = function() self:downloadBook(b) end,
        }
    end
    if state.total > #state.books then
        items[#items + 1] = {
            text = T(_("More… (%1 of %2)"), #state.books, state.total),
            bold = true,
            callback = function() self:loadMore(state) end,
        }
    end
    return items
end

function BackIssue:listTitle(state)
    if state.q then return T(_("BackIssue: “%1”"), state.q) end
    if state.sort == "recent" then return _("BackIssue: recently added") end
    return _("BackIssue library")
end

function BackIssue:showBooks(opts)
    local state = { q = opts.q, sort = opts.sort or "title", books = {}, total = 0 }
    local list, err = self:client():books{ q = state.q, sort = state.sort, limit = PAGE_SIZE, offset = 0 }
    if not list then
        UIManager:show(InfoMessage:new{ text = T(_("Could not list books: %1"), err or "?") })
        return
    end
    state.books = list.books or {}
    state.total = tonumber(list.total) or #state.books
    if #state.books == 0 then
        UIManager:show(InfoMessage:new{ text = state.q and T(_("Nothing matches “%1”."), state.q) or _("The Books library is empty.") })
        return
    end
    self.list_state = state
    if self.menu then UIManager:close(self.menu) end
    self.menu = Menu:new{
        title = self:listTitle(state),
        subtitle = T(_("%1 books"), state.total),
        item_table = self:bookItems(state),
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.search",
        onLeftButtonTap = function() self:askSearch() end,
        onMenuHold = function(_menu, item)
            if item.book then self:showBookInfo(item.book) end
            return true
        end,
        close_callback = function()
            if self.menu then UIManager:close(self.menu) end
            self.menu = nil
        end,
    }
    UIManager:show(self.menu)
end

function BackIssue:loadMore(state)
    local list, err = self:client():books{ q = state.q, sort = state.sort, limit = PAGE_SIZE, offset = #state.books }
    if not list then
        UIManager:show(InfoMessage:new{ text = T(_("Could not list books: %1"), err or "?") })
        return
    end
    for _i, b in ipairs(list.books or {}) do state.books[#state.books + 1] = b end
    state.total = tonumber(list.total) or #state.books
    self:refreshList()
end

-- Rebuild the open list (a download changes the "on device" tags).
function BackIssue:refreshList()
    if self.menu and self.list_state then
        self.menu:switchItemTable(self:listTitle(self.list_state), self:bookItems(self.list_state), -1, nil, T(_("%1 books"), self.list_state.total))
    end
end

function BackIssue:showBookInfo(b)
    local lines = { b.title or "?" }
    if type(b.authors) == "table" and #b.authors > 0 then lines[#lines + 1] = T(_("By %1"), table.concat(b.authors, ", ")) end
    if b.series and b.series ~= "" then
        lines[#lines + 1] = b.series_index and T(_("Series: %1, book %2"), b.series, b.series_index) or T(_("Series: %1"), b.series)
    end
    local about = {}
    if b.format then about[#about + 1] = string.upper(b.format) end
    if tonumber(b.size) then about[#about + 1] = util.getFriendlySize(tonumber(b.size)) end
    if b.library then about[#about + 1] = b.library end
    if #about > 0 then lines[#lines + 1] = table.concat(about, " · ") end
    if (tonumber(b.fraction) or 0) > 0 then lines[#lines + 1] = T(_("Read: %1%"), pct(b.fraction)) end
    if b.remote then lines[#lines + 1] = _("Fetched by the server on first download.") end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

function BackIssue:downloadBook(b)
    local path = self:localPath(b)
    if lfs.attributes(path, "mode") == "file" then
        UIManager:show(ConfirmBox:new{
            text = T(_("%1 is already on this device.\nOpen it?"), b.title or "?"),
            ok_text = _("Open"),
            ok_callback = function() self:openBook(path, b.id) end,
            other_buttons = {{
                { text = _("Download again"), callback = function() self:fetchBook(b, path) end },
            }},
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Download %1 to %2?"), b.title or "?", BD.dirpath(self:downloadDir())),
        ok_text = _("Download"),
        ok_callback = function() self:fetchBook(b, path) end,
    })
end

function BackIssue:fetchBook(b, path)
    local info = InfoMessage:new{ text = T(_("Downloading %1…"), b.title or "?") }
    UIManager:show(info)
    -- Let the message paint before the blocking download starts.
    UIManager:scheduleIn(0.1, function()
        local ok, err = self:client():download(b.download, path)
        UIManager:close(info)
        if not ok then
            UIManager:show(InfoMessage:new{ text = T(_("Download failed: %1"), err or "?") })
            return
        end
        self:remember(path, b.id)
        self:refreshList()
        if self.ui.file_chooser then self.ui.file_chooser:refreshPath() end
        UIManager:show(ConfirmBox:new{
            text = T(_("Downloaded %1.\nRead it now?"), b.title or "?"),
            ok_text = _("Read now"),
            cancel_text = _("Later"),
            ok_callback = function() self:openBook(path, b.id) end,
        })
    end)
end

-- The sidecar remembers which BackIssue book a file is.
function BackIssue:remember(path, issue_id)
    local ds = DocSettings:open(path)
    ds:saveSetting("backissue", { issue_id = issue_id, server = self:server() })
    ds:delSetting("backissue_miss")
    ds:flush()
end

function BackIssue:openBook(path, issue_id)
    if self.menu then
        UIManager:close(self.menu)
        self.menu = nil
    end
    if issue_id then self:remember(path, issue_id) end
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        require("apps/reader/readerui"):showReader(path)
    end
end

-- ---- progress sync ---------------------------------------------------------------

--- Which BackIssue book the open document is: the sidecar's answer, else the
-- server's by fingerprint (remembered either way). nil when it isn't one.
function BackIssue:identify()
    local ds = self.ui.doc_settings
    if not ds or not self.ui.document then return nil end
    local saved = ds:readSetting("backissue")
    if type(saved) == "table" and saved.issue_id and saved.server == self:server() then return saved.issue_id end
    local miss = ds:readSetting("backissue_miss")
    if type(miss) == "table" and miss.server == self:server() and os.time() - (miss.at or 0) < MISS_RETRY_S then return nil end
    local fp, size = fingerprint(self.ui.document.file)
    if not fp then return nil end
    local book, err, code = self:client():lookup(fp, size)
    if book and book.id then
        ds:saveSetting("backissue", { issue_id = book.id, server = self:server() })
        ds:delSetting("backissue_miss")
        return book.id
    end
    if code == 404 then ds:saveSetting("backissue_miss", { server = self:server(), at = os.time() }) end
    if err and code ~= 404 then logger.warn("BackIssue: lookup failed:", err) end
    return nil
end

function BackIssue:currentProgress()
    local doc = self.ui.document
    if not doc then return nil end
    if doc.info.has_pages then
        return {
            kind = "page",
            position = tostring(self.ui.paging:getLastProgress()),
            fraction = tonumber(self.ui.paging:getLastPercent()) or 0,
        }
    end
    return {
        kind = "xpointer",
        position = self.ui.rolling:getLastProgress(),
        fraction = tonumber(self.ui.rolling:getLastPercent()) or 0,
    }
end

function BackIssue:applyProgress(p)
    local doc = self.ui.document
    if p.kind == "page" and doc.info.has_pages and tonumber(p.position) then
        self.ui:handleEvent(Event:new("GotoPage", tonumber(p.position)))
    elseif p.kind == "xpointer" and not doc.info.has_pages and type(p.position) == "string" and p.position ~= "" then
        self.ui:handleEvent(Event:new("GotoXPointer", p.position))
    elseif tonumber(p.fraction) then
        self.ui:handleEvent(Event:new("GotoPercent", tonumber(p.fraction) * 100))
    end
end

local function say(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

--- opts.interactive: asked from the menu (always runs, reports back);
-- opts.auto: a timer or lifecycle push (rate limited, silent).
function BackIssue:pushProgress(opts)
    opts = opts or {}
    if not self.ui.document or not self:isConfigured() then return end
    if not opts.interactive and not self:autoSync() then return end
    if opts.auto and os.time() - self.last_push < PUSH_MIN_INTERVAL_S then return end
    if not NetworkMgr:isOnline() then
        if opts.interactive then NetworkMgr:runWhenOnline(function() self:pushProgress(opts) end) end
        return
    end
    local issue_id = self:identify()
    if not issue_id then
        if opts.interactive then say(_("This book is not in your BackIssue library.")) end
        return
    end
    local p = self:currentProgress()
    if not p then return end
    p.device = self:deviceName()
    p.device_id = self.device_id
    local ok, err = self:client():putProgress(issue_id, p)
    self.last_push = os.time()
    if ok then
        self.last_pushed = p.position
        if opts.interactive then say(T(_("Progress pushed: %1%."), pct(p.fraction)), 2) end
    else
        logger.warn("BackIssue: push failed:", err)
        if opts.interactive then say(T(_("Could not push progress: %1"), err or "?")) end
    end
end

function BackIssue:pullProgress(opts)
    opts = opts or {}
    if not self.ui.document or not self:isConfigured() then return end
    if not NetworkMgr:isOnline() then
        if opts.interactive then NetworkMgr:runWhenOnline(function() self:pullProgress(opts) end) end
        return
    end
    local issue_id = self:identify()
    if not issue_id then
        if opts.interactive then say(_("This book is not in your BackIssue library.")) end
        return
    end
    local res, err = self:client():getProgress(issue_id)
    if not res then
        logger.warn("BackIssue: pull failed:", err)
        if opts.interactive then say(T(_("Could not pull progress: %1"), err or "?")) end
        return
    end
    local remote = res.progress
    if not remote then
        if opts.interactive then say(_("No progress on the server yet.")) end
        return
    end
    -- This device's own last push is nothing new.
    if not opts.interactive and remote.source == "koreader" and remote.device_id == self.device_id then return end
    local cur = self:currentProgress()
    local rf = tonumber(remote.fraction) or 0
    local cf = cur and cur.fraction or 0
    local same = (cur and type(remote.position) == "string" and remote.position == cur.position)
        or math.abs(rf - cf) < 0.002
    if same then
        if opts.interactive then say(_("Already at the latest position."), 2) end
        return
    end
    local who = remote.source == "web" and _("the web reader") or (remote.device or _("another device"))
    local function apply()
        self:applyProgress(remote)
        UIManager:show(Notification:new{ text = T(_("Synced to %1% from %2"), pct(rf), who) })
    end
    -- Further along elsewhere: follow without asking. Behind: ask, since
    -- going back is rarely what the reader wants by accident.
    if rf > cf and not opts.interactive then
        apply()
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("%1 is at %2% (this device is at %3%).\nGo there?"), who, pct(rf), pct(cf)),
        ok_text = _("Go there"),
        cancel_text = _("Stay here"),
        ok_callback = apply,
    })
end

function BackIssue:schedulePush()
    if not self.ui.document or not self:isConfigured() or not self:autoSync() then return end
    UIManager:unschedule(self.push_task)
    UIManager:scheduleIn(PUSH_DEBOUNCE_S, self.push_task)
end

-- ---- events ----------------------------------------------------------------------

function BackIssue:onReaderReady()
    if not self:isConfigured() or not self:autoSync() then return end
    UIManager:scheduleIn(1, function()
        if self.ui and self.ui.document then self:pullProgress({}) end
    end)
end

function BackIssue:onPageUpdate() self:schedulePush() end
function BackIssue:onPosUpdate() self:schedulePush() end

function BackIssue:onCloseDocument()
    UIManager:unschedule(self.push_task)
    self:pushProgress({})
end

function BackIssue:onSuspend()
    UIManager:unschedule(self.push_task)
    self:pushProgress({})
end

function BackIssue:onResume()
    if not self:isConfigured() or not self:autoSync() or not self.ui.document then return end
    UIManager:scheduleIn(2, function()
        if self.ui and self.ui.document and NetworkMgr:isOnline() then self:pullProgress({}) end
    end)
end

function BackIssue:onNetworkConnected()
    if self.ui.document and self:autoSync() then self:schedulePush() end
end

function BackIssue:onCloseWidget()
    UIManager:unschedule(self.push_task)
end

return BackIssue
