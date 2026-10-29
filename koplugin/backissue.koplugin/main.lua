--[[--
BackIssue for KOReader.

A BackIssue entry in the Tools menu: browse and download the server's Books
library, and keep reading in sync with it:

  • positions, as KOReader states them (an xpointer in an EPUB, a page in a
    PDF), so two KOReader devices resume at the exact spot; the web reader
    shares the position by percentage;
  • reading status (finished, abandoned);
  • highlights and notes, both ways with the web and the apps;
  • page-reading statistics, so the server knows how long you read.

A book downloaded here remembers which BackIssue book it is in its sidecar.
Any other copy (fetched over OPDS, copied by hand) is recognised by a
fingerprint of its first and last 64 KiB, which the server computes too.
"Sync all books" sweeps the reading history so books read before the plugin
was installed are synced as well.
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
local UI = require("backissue_ui")

local PLUGIN_VERSION = "0.1.0"
local PAGE_SIZE = 200          -- books fetched per list page
local PUSH_DEBOUNCE_S = 10     -- push this long after the last page turn
local PUSH_MIN_INTERVAL_S = 25 -- and never more often than this, unless asked
local MISS_RETRY_S = 86400     -- a book the server didn't know: ask again after a day
local FINGERPRINT_WINDOW = 65536
local SWEEP_MAX_BOOKS = 200    -- how far back in the reading history a sweep goes
local EVENTS_BATCH = 2000      -- page events per upload
local STATS_DB = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local KO_COLORS = { red = true, orange = true, yellow = true, green = true, olive = true, cyan = true, blue = true, purple = true, gray = true }

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

local function say(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
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
function BackIssue:syncHighlightsOn() return self.settings:nilOrTrue("sync_highlights") end
function BackIssue:syncStatsOn() return self.settings:nilOrTrue("sync_stats") end
function BackIssue:deviceName()
    return self.settings:readSetting("device_name") or Device.model or "KOReader"
end
function BackIssue:deviceInfo()
    return { device = self:deviceName(), device_id = self.device_id }
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
        plugin_version = PLUGIN_VERSION,
        device_id = self.device_id,
        device_name = self:deviceName(),
        model = Device.model,
    }
end

function BackIssue:addToMainMenu(menu_items)
    local configured = function() return self:isConfigured() end
    local reading = function() return self.ui.document ~= nil and self:isConfigured() end
    local function toggle(key, getter)
        return function()
            self.settings:saveSetting(key, not getter())
            self.settings:flush()
        end
    end
    menu_items.backissue = {
        text = _("BackIssue"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Dashboard"),
                enabled_func = configured,
                callback = function() self:showDashboard() end,
            },
            {
                text = _("Browse library"),
                enabled_func = configured,
                callback = function() self:browse({}) end,
            },
            {
                text = _("Continue reading"),
                enabled_func = configured,
                callback = function() self:browse({ sort = "progress" }) end,
            },
            {
                text = _("Recently added"),
                enabled_func = configured,
                callback = function() self:browse({ sort = "recent" }) end,
            },
            {
                text = _("Authors"),
                enabled_func = configured,
                callback = function() self:browseAuthors() end,
            },
            {
                text = _("Series"),
                enabled_func = configured,
                callback = function() self:browseSeries() end,
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
                text = _("Sync highlights of this book"),
                enabled_func = reading,
                callback = function() self:syncHighlightsNow({ interactive = true }) end,
            },
            {
                text = _("Sync all books"),
                help_text = _("Walk the reading history: every book the server knows gets its position, status, highlights and reading time uploaded, including books read before this plugin was installed."),
                enabled_func = configured,
                callback = function() self:syncAll() end,
                separator = true,
            },
            {
                text = _("Automatic sync"),
                help_text = _("Pull the newest position when a book opens; push this device's position as you read, and when the book closes or the device sleeps."),
                checked_func = function() return self:autoSync() end,
                callback = toggle("auto_sync", function() return self:autoSync() end),
            },
            {
                text = _("Sync highlights and notes"),
                help_text = _("Highlights made here appear in BackIssue; a note changed or a mark deleted there follows here. Highlights from another KOReader device land at their exact spot."),
                checked_func = function() return self:syncHighlightsOn() end,
                callback = toggle("sync_highlights", function() return self:syncHighlightsOn() end),
            },
            {
                text = _("Sync reading statistics"),
                help_text = _("Upload KOReader's page-reading statistics so BackIssue can show how long you read."),
                checked_func = function() return self:syncStatsOn() end,
                callback = toggle("sync_stats", function() return self:syncStatsOn() end),
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
                text = _("Check for plugin update"),
                enabled_func = configured,
                keep_menu_open = true,
                callback = function() self:checkUpdate() end,
            },
            {
                text = T(_("About BackIssue plugin (%1)"), PLUGIN_VERSION),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_([[BackIssue for KOReader %1

Browse and download your Books library, and keep reading in sync: positions (exact between KOReader devices, by percentage with the web reader), finished status, highlights and notes, and reading time.

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
            if type(me.plugin) == "string" and me.plugin ~= PLUGIN_VERSION then
                text = text .. "\n\n" .. T(_("This device runs plugin %1; the server offers %2. See “Check for plugin update”."), PLUGIN_VERSION, me.plugin)
            end
            UIManager:show(InfoMessage:new{ text = text })
        else
            UIManager:show(InfoMessage:new{ text = T(_("Could not reach the server: %1"), err or "?") })
        end
    end)
end

-- ---- plugin update ---------------------------------------------------------------

-- Where this plugin lives: the loader records it; failing that, this file's
-- own path says.
function BackIssue:pluginDir()
    if type(self.path) == "string" and self.path ~= "" then return self.path end
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    return src:match("^(.*)/[^/]+$") or "."
end

-- Fetch the server's copy of the plugin and unpack it over this one; a
-- restart loads it.
function BackIssue:checkUpdate()
    NetworkMgr:runWhenOnline(function()
        local me, err = self:client():me()
        if not me then
            say(T(_("Could not reach the server: %1"), err or "?"))
            return
        end
        local offered = type(me.plugin) == "string" and me.plugin or "?"
        if offered == PLUGIN_VERSION then
            say(T(_("The plugin is up to date (%1)."), PLUGIN_VERSION))
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("The server offers plugin %1; this device runs %2.\nInstall it now? KOReader needs a restart afterwards."), offered, PLUGIN_VERSION),
            ok_text = _("Install"),
            ok_callback = function() self:installUpdate(offered) end,
        })
    end)
end

function BackIssue:installUpdate(version)
    local dir = self:pluginDir()
    local tmp = DataStorage:getDataDir() .. "/cache/backissue-plugin.zip"
    lfs.mkdir(DataStorage:getDataDir() .. "/cache")
    local info = InfoMessage:new{ text = _("Downloading the plugin…") }
    UIManager:show(info)
    UIManager:scheduleIn(0.1, function()
        local ok, err = self:client():download("/api/koreader/plugin.zip", tmp)
        UIManager:close(info)
        if not ok then
            say(T(_("Download failed: %1"), err or "?"))
            return
        end
        local Archiver = require("ffi/archiver")
        local reader = Archiver.Reader:new()
        if not reader:open(tmp) then
            os.remove(tmp)
            say(T(_("Could not open the downloaded plugin: %1"), tostring(reader.err)))
            return
        end
        local n, failed = 0, nil
        for entry in reader:iterate() do
            if entry.mode == "file" then
                local name = entry.path:match("([^/]+)$")
                -- Only the plugin's own files, into its own folder.
                if name and name:match("%.lua$") then
                    if reader:extractToPath(entry.path, dir .. "/" .. name) then n = n + 1 else failed = name end
                end
            end
        end
        reader:close()
        os.remove(tmp)
        if failed or n == 0 then
            say(T(_("The update could not be written (%1). The old plugin is still in place."), failed or "no files"))
            return
        end
        local text = T(_("Plugin %1 installed (%2 files). Restart KOReader to use it."), version, n)
        if Device.canRestart and Device:canRestart() then
            UIManager:show(ConfirmBox:new{
                text = text,
                ok_text = _("Restart now"),
                cancel_text = _("Later"),
                ok_callback = function() UIManager:restartKOReader() end,
            })
        else
            say(text)
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
        if b.finished then tags[#tags + 1] = _("finished")
        elseif (tonumber(b.fraction) or 0) > 0 then tags[#tags + 1] = pct(b.fraction) .. "%" end
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
    if state.author then return state.author end
    if state.series_title then return state.series_title end
    if state.on_device then return _("On this device") end
    if state.finished then return _("Finished") end
    if state.sort == "recent" then return _("Recently added") end
    if state.sort == "progress" then return _("Continue reading") end
    return _("BackIssue library")
end

-- One list widget at a time; a tap acts on the item and keeps the list open
-- (Menu's own onMenuSelect would run close_callback after every choice).
function BackIssue:showMenu(spec)
    if self.menu then UIManager:close(self.menu) end
    self.menu = Menu:new{
        title = spec.title,
        subtitle = spec.subtitle,
        item_table = spec.items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.search",
        onLeftButtonTap = function() self:askSearch() end,
        onMenuSelect = function(_menu, item)
            if item.callback then item.callback() end
            return true
        end,
        onMenuHold = function(_menu, item)
            if item.book then self:showBookInfo(item.book) end
            return true
        end,
        close_callback = function()
            self.menu = nil
            self.list_state = nil
        end,
    }
    UIManager:show(self.menu)
end

function BackIssue:isOnDevice(b)
    return lfs.attributes(self:localPath(b), "mode") == "file"
end

function BackIssue:showDashboard()
    NetworkMgr:runWhenOnline(function() UI.showDashboard(self) end)
end

-- One page of a list from the server, appended to the state. Returns true,
-- or nil and a message.
function BackIssue:loadMoreInto(state)
    local list, err = self:client():books{
        q = state.q, sort = state.sort, author = state.author, series = state.series, finished = state.finished and "1" or nil,
        limit = PAGE_SIZE, offset = state.fetched or 0,
    }
    if not list then
        say(T(_("Could not list books: %1"), err or "?"))
        return nil, err
    end
    state.fetched = (state.fetched or 0) + #(list.books or {})
    if state.on_device then
        -- The server can't know what is on this device: walk the whole list.
        for _i, b in ipairs(list.books or {}) do
            if self:isOnDevice(b) then state.books[#state.books + 1] = b end
        end
        if state.fetched < (tonumber(list.total) or 0) and state.fetched < 2000 then return self:loadMoreInto(state) end
        state.total = #state.books
    else
        for _i, b in ipairs(list.books or {}) do state.books[#state.books + 1] = b end
        state.total = tonumber(list.total) or #state.books
    end
    return true
end

function BackIssue:showBooks(opts)
    local state = {
        q = opts.q, sort = opts.sort or "title", author = opts.author, series = opts.series, series_title = opts.series_title,
        finished = opts.finished, on_device = opts.on_device, books = {}, total = 0,
    }
    if not self:loadMoreInto(state) then return end
    if #state.books == 0 then
        local text = _("The Books library is empty.")
        if state.q then text = T(_("Nothing matches “%1”."), state.q)
        elseif state.sort == "progress" then text = _("No book under way. Open one and read a little.")
        elseif state.on_device then text = _("No library book is on this device yet.")
        elseif state.finished then text = _("No finished book yet.") end
        say(text)
        return
    end
    self.list_state = state
    state.title = self:listTitle(state)
    state.subtitle = T(_("%1 books"), state.total)
    UI.showGrid(self, state)
end

function BackIssue:loadMore(state)
    if self:loadMoreInto(state) then self:refreshList() end
end

-- Rebuild the open list (a download changes the "on device" tags).
function BackIssue:refreshList()
    if self.grid then self.grid:refresh() end
    if self.menu and self.list_state then
        self.menu:switchItemTable(self:listTitle(self.list_state), self:bookItems(self.list_state), -1, nil, T(_("%1 books"), self.list_state.total))
    end
end

-- Finished or not, on the server; the book's own record follows.
function BackIssue:setFinished(b, finished, after)
    NetworkMgr:runWhenOnline(function()
        local p = { fraction = finished and 1 or (tonumber(b.fraction) or 0), status = finished and "complete" or "reading" }
        if not finished and p.fraction >= 0.98 then p.fraction = 0 end
        p.device = self:deviceName()
        p.device_id = self.device_id
        local ok, err = self:client():putProgress(b.id, p)
        if not ok then
            say(T(_("Could not update the book: %1"), err or "?"))
            return
        end
        b.finished = finished
        b.fraction = p.fraction
        UIManager:show(Notification:new{ text = finished and _("Marked finished") or _("Marked unread") })
        if after then after() end
    end)
end

function BackIssue:browseAuthors()
    NetworkMgr:runWhenOnline(function()
        local r, err = self:client():authors()
        if not r then
            say(T(_("Could not list authors: %1"), err or "?"))
            return
        end
        local items = {}
        for _i, a in ipairs(r.authors or {}) do
            items[#items + 1] = {
                text = a.name,
                mandatory = tostring(a.books or ""),
                callback = function() self:showBooks({ author = a.name }) end,
            }
        end
        if #items == 0 then
            say(_("The Books library is empty."))
            return
        end
        self.list_state = nil
        self:showMenu{ title = _("BackIssue: authors"), subtitle = T(_("%1 authors"), #items), items = items }
    end)
end

function BackIssue:browseSeries()
    NetworkMgr:runWhenOnline(function()
        local r, err = self:client():series()
        if not r then
            say(T(_("Could not list series: %1"), err or "?"))
            return
        end
        local items = {}
        for _i, s in ipairs(r.series or {}) do
            local by = type(s.authors) == "table" and #s.authors > 0 and (" — " .. table.concat(s.authors, ", ")) or ""
            items[#items + 1] = {
                text = (s.title or "?") .. by,
                mandatory = tostring(s.books or ""),
                callback = function() self:showBooks({ series = s.id, series_title = s.title }) end,
            }
        end
        if #items == 0 then
            say(_("No series in the Books library yet."))
            return
        end
        self.list_state = nil
        self:showMenu{ title = _("BackIssue: series"), subtitle = T(_("%1 series"), #items), items = items }
    end)
end

function BackIssue:showBookInfo(b)
    UI.showBook(self, b, self.grid or self.dashboard)
end

function BackIssue:showBookInfoText(b)
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
    if b.finished then lines[#lines + 1] = _("Finished.")
    elseif (tonumber(b.fraction) or 0) > 0 then lines[#lines + 1] = T(_("Read: %1%"), pct(b.fraction)) end
    if b.remote then lines[#lines + 1] = _("Fetched by the server on first download.") end
    if type(b.description) == "string" and b.description ~= "" then
        local d = b.description:gsub("<[^>]+>", ""):gsub("%s+", " ")
        if #d > 700 then d = d:sub(1, 700) .. "…" end
        lines[#lines + 1] = ""
        lines[#lines + 1] = d
    end
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

function BackIssue:fetchBook(b, path, after)
    local info = InfoMessage:new{ text = T(_("Downloading %1…"), b.title or "?") }
    UIManager:show(info)
    -- Let the message paint before the blocking download starts.
    UIManager:scheduleIn(0.1, function()
        local ok, err = self:client():download(b.download, path)
        UIManager:close(info)
        if not ok then
            say(T(_("Download failed: %1"), err or "?"))
            return
        end
        self:remember(path, b.id)
        self:refreshList()
        if after then after() end
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

-- ---- which book is this -----------------------------------------------------------

--- Which BackIssue book a file is: the sidecar's answer, else the server's
-- by fingerprint (remembered either way). nil when it isn't one. `ds` is the
-- file's DocSettings; `flush` writes a new answer to disk at once (for a
-- file that isn't open, whose sidecar nobody else will flush).
function BackIssue:identifyFile(path, ds, flush)
    if not ds or not path then return nil end
    local saved = ds:readSetting("backissue")
    if type(saved) == "table" and saved.issue_id and saved.server == self:server() then return saved.issue_id end
    local miss = ds:readSetting("backissue_miss")
    if type(miss) == "table" and miss.server == self:server() and os.time() - (miss.at or 0) < MISS_RETRY_S then return nil end
    local fp, size = fingerprint(path)
    if not fp then return nil end
    local book, err, code = self:client():lookup(fp, size)
    if book and book.id then
        ds:saveSetting("backissue", { issue_id = book.id, server = self:server() })
        ds:delSetting("backissue_miss")
        if flush then ds:flush() end
        return book.id
    end
    if code == 404 then
        ds:saveSetting("backissue_miss", { server = self:server(), at = os.time() })
        if flush then ds:flush() end
    end
    if err and code ~= 404 then logger.warn("BackIssue: lookup failed:", err) end
    return nil
end

function BackIssue:identify()
    if not self.ui.document then return nil end
    return self:identifyFile(self.ui.document.file, self.ui.doc_settings, false)
end

-- ---- progress sync ---------------------------------------------------------------

local function statusOf(ds)
    local summary = ds and ds:readSetting("summary")
    local s = type(summary) == "table" and summary.status or nil
    if s == "complete" or s == "abandoned" or s == "reading" then return s end
    return nil
end

function BackIssue:currentProgress()
    local doc = self.ui.document
    if not doc then return nil end
    local p
    if doc.info.has_pages then
        p = {
            kind = "page",
            position = tostring(self.ui.paging:getLastProgress()),
            fraction = tonumber(self.ui.paging:getLastPercent()) or 0,
        }
    else
        p = {
            kind = "xpointer",
            position = self.ui.rolling:getLastProgress(),
            fraction = tonumber(self.ui.rolling:getLastPercent()) or 0,
        }
    end
    p.status = statusOf(self.ui.doc_settings)
    return p
end

-- The position a closed book's sidecar holds, or nil when it was never read.
local function sidecarProgress(ds)
    local fraction = tonumber(ds:readSetting("percent_finished"))
    local xp = ds:readSetting("last_xpointer")
    local page = ds:readSetting("last_page")
    if not fraction and not xp and not page then return nil end
    local p = { fraction = fraction or 0, status = statusOf(ds) }
    if type(xp) == "string" and xp ~= "" then
        p.kind, p.position = "xpointer", xp
    elseif tonumber(page) then
        p.kind, p.position = "page", tostring(page)
    end
    return p
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

-- The server says the book is finished and this device doesn't: mark it.
function BackIssue:applyFinished(remote)
    if not remote.finished or not self.ui.doc_settings then return false end
    local summary = self.ui.doc_settings:readSetting("summary", {})
    if summary.status == "complete" then return false end
    summary.status = "complete"
    summary.modified = os.date("%Y-%m-%d")
    self.ui.doc_settings:saveSetting("summary", summary)
    return true
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
    if self:applyFinished(remote) then
        UIManager:show(Notification:new{ text = _("Marked finished, as on the server.") })
    end
    if remote.file_changed_at and not self.ui.doc_settings:readSetting("backissue_file_changed_told") then
        self.ui.doc_settings:saveSetting("backissue_file_changed_told", remote.file_changed_at)
        UIManager:show(Notification:new{ text = _("The server's copy of this book changed since this device last synced.") })
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

-- ---- highlights ------------------------------------------------------------------

-- A stable name for an annotation: its creation stamp plus where it starts.
local function posString(p)
    if type(p) == "table" then return Api.encode({ page = p.page, x = p.x, y = p.y }) end
    if p == nil then return nil end
    return tostring(p)
end
local function posValue(s, kind)
    if kind == "page" and type(s) == "string" and s:sub(1, 1) == "{" then
        local t = Api.decode(s)
        if type(t) == "table" then return t end
    end
    return s
end
local function hlKey(a)
    return (a.datetime or "") .. "|" .. (posString(a.pos0) or tostring(a.page or ""))
end
local function isHighlight(a)
    return type(a) == "table" and a.drawer ~= nil and (a.pos0 ~= nil or a.page ~= nil)
end

-- How far into the book an annotation sits, 0..1.
function BackIssue:highlightFraction(a, ctx)
    if ctx.live then
        local doc = self.ui.document
        local ok, f = pcall(function()
            if doc.info.has_pages then
                local page = type(a.pos0) == "table" and a.pos0.page or tonumber(a.page)
                local n = doc:getPageCount()
                return (page and n and n > 0) and (page / n) or 0
            end
            local y = doc:getPosFromXPointer(a.pos0 or a.page)
            local h = doc.info.doc_height
            return (y and h and h > 0) and (y / h) or 0
        end)
        if ok and tonumber(f) then return math.min(1, math.max(0, f)) end
        return 0
    end
    local pages = tonumber(ctx.ds:readSetting("doc_pages"))
    if a.pageno and pages and pages > 0 then return math.min(1, math.max(0, a.pageno / pages)) end
    return 0
end

-- The annotations list and how to change it: the reader's module for the
-- open book, the sidecar table for a closed one.
function BackIssue:annotationsOf(ctx)
    if ctx.live then return self.ui.annotation.annotations end
    local list = ctx.ds:readSetting("annotations")
    if type(list) ~= "table" then
        list = {}
        ctx.ds:saveSetting("annotations", list)
    end
    return list
end

function BackIssue:addRemoteHighlight(ctx, h)
    -- Only into the open book, and only an EPUB: a PDF highlight also needs
    -- the drawn boxes the selection computed, which the server doesn't carry.
    if not ctx.live or self.ui.document.info.has_pages or h.kind ~= "xpointer" then return false end
    if type(h.pos0) ~= "string" or h.pos0 == "" then return false end
    local item = {
        page = h.pos0,
        pos0 = h.pos0,
        pos1 = h.pos1 or h.pos0,
        text = h.text or "",
        note = h.note,
        chapter = h.chapter,
        datetime = h.created_at or os.date("%Y-%m-%d %H:%M:%S"),
        drawer = h.drawer or self.ui.view.highlight.saved_drawer or "lighten",
        color = KO_COLORS[h.color or ""] and h.color or self.ui.view.highlight.saved_color,
    }
    local ok, index = pcall(function() return self.ui.annotation:addItem(item) end)
    if not ok then
        logger.warn("BackIssue: could not place a highlight:", index)
        return false
    end
    self.ui:handleEvent(Event:new("AnnotationsModified", { item, nb_highlights_added = 1, index_modified = index }))
    return true
end

function BackIssue:removeLocalHighlight(ctx, a)
    local list = self:annotationsOf(ctx)
    local index
    if ctx.live then
        index = self.ui.annotation:getItemIndex(a)
        if index then self.ui.bookmark:removeItemByIndex(index) end
        return index ~= nil
    end
    for i, x in ipairs(list) do
        if x == a then index = i break end
    end
    if index then table.remove(list, index) end
    return index ~= nil
end

function BackIssue:updateLocalHighlight(ctx, a, h)
    a.note = h.note
    if KO_COLORS[h.color or ""] then a.color = h.color end
    if ctx.live then
        self.ui:handleEvent(Event:new("AnnotationsModified", { a }))
    else
        a.datetime_updated = os.date("%Y-%m-%d %H:%M:%S")
    end
end

--- Three-way merge of a book's highlights with the server. ctx: { live =
-- true } for the open book, or { ds = DocSettings, path = file } for a closed
-- one. Returns counts { pushed, added, updated, removed } or nil, err.
function BackIssue:mergeHighlights(issue_id, ctx)
    local api = self:client()
    local remote, err = api:getHighlights(issue_id)
    if not remote then return nil, err end
    local ds = ctx.live and self.ui.doc_settings or ctx.ds
    local kind = (ctx.live and self.ui.document.info.has_pages) and "page" or (ctx.live and "xpointer" or nil)
    local base = ds:readSetting("backissue_hl")
    if type(base) ~= "table" then base = {} end
    local counts = { pushed = 0, added = 0, updated = 0, removed = 0 }
    local changed_local = false

    local local_by_key = {}
    for _i, a in ipairs(self:annotationsOf(ctx)) do
        if isHighlight(a) then local_by_key[hlKey(a)] = a end
    end
    -- Gone here since the last sync: tell the server.
    local deleted = {}
    local deleted_set = {}
    for key in pairs(base) do
        if not local_by_key[key] then
            deleted[#deleted + 1] = key
            deleted_set[key] = true
        end
    end
    -- Gone on the server (the web, an app, another device): drop here.
    for _i, key in ipairs(remote.deleted or {}) do
        local a = local_by_key[key]
        if a and self:removeLocalHighlight(ctx, a) then
            local_by_key[key] = nil
            counts.removed = counts.removed + 1
            changed_local = true
        end
    end
    local remote_by_key = {}
    for _i, h in ipairs(remote.items or {}) do
        if type(h) == "table" and h.key then
            remote_by_key[h.key] = h
            local a = local_by_key[h.key]
            if not a then
                if not deleted_set[h.key] and self:addRemoteHighlight(ctx, h) then
                    counts.added = counts.added + 1
                    changed_local = true
                    for _j, x in ipairs(self:annotationsOf(ctx)) do
                        if isHighlight(x) and hlKey(x) == h.key then local_by_key[h.key] = x break end
                    end
                end
            else
                local b = base[h.key]
                local remote_changed = (b == nil) or (b.srv ~= h.updated_at)
                local local_changed = (b == nil) or ((a.datetime_updated or "") ~= (b.loc or ""))
                local differs = (a.note or nil) ~= (h.note or nil) or ((a.color or "") ~= (h.color or "") and KO_COLORS[h.color or ""])
                if differs and remote_changed and not local_changed then
                    self:updateLocalHighlight(ctx, a, h)
                    counts.updated = counts.updated + 1
                    changed_local = true
                end
            end
        end
    end
    -- Everything here, to the server; `changed` marks what this device edited.
    local items = {}
    local keys = {}
    for key, a in pairs(local_by_key) do
        local b = base[key]
        local h = remote_by_key[key]
        local differs = h and ((a.note or nil) ~= (h.note or nil) or (a.color or "") ~= (h.color or "")) or false
        items[#items + 1] = {
            key = key,
            kind = kind or (type(a.pos0) == "table" and "page" or "xpointer"),
            pos0 = posString(a.pos0) or posString(a.page),
            pos1 = posString(a.pos1),
            page = tonumber(a.pageno) or (type(a.page) == "number" and a.page or nil),
            chapter = a.chapter,
            text = a.text,
            note = a.note,
            color = a.color,
            drawer = a.drawer,
            fraction = self:highlightFraction(a, ctx),
            created_at = a.datetime,
            changed = (h ~= nil) and differs and ((b == nil) or (a.datetime_updated or "") ~= (b.loc or "")),
        }
        keys[#keys + 1] = key
    end
    local res
    res, err = api:putHighlights(issue_id, items, deleted, self:deviceInfo())
    if not res then return nil, err end
    counts.pushed = #items
    -- Remember what the server holds for each local mark, so the next merge
    -- knows which side moved.
    local srv = {}
    for _i, h in ipairs(res.items or {}) do if h.key then srv[h.key] = h.updated_at end end
    local newbase = {}
    for key, a in pairs(local_by_key) do
        newbase[key] = { srv = srv[key] or "", loc = a.datetime_updated or "" }
    end
    ds:saveSetting("backissue_hl", newbase)
    if not ctx.live then
        ds:saveSetting("annotations", self:annotationsOf(ctx))
        ds:flush()
    elseif changed_local then
        UIManager:setDirty(self.ui, "ui")
    end
    return counts
end

function BackIssue:syncHighlightsNow(opts)
    opts = opts or {}
    if not self.ui.document or not self:isConfigured() then return end
    if not opts.interactive and not self:syncHighlightsOn() then return end
    if not NetworkMgr:isOnline() then
        if opts.interactive then NetworkMgr:runWhenOnline(function() self:syncHighlightsNow(opts) end) end
        return
    end
    local issue_id = self:identify()
    if not issue_id then
        if opts.interactive then say(_("This book is not in your BackIssue library.")) end
        return
    end
    local counts, err = self:mergeHighlights(issue_id, { live = true })
    if not counts then
        logger.warn("BackIssue: highlight sync failed:", err)
        if opts.interactive then say(T(_("Could not sync highlights: %1"), err or "?")) end
        return
    end
    if opts.interactive then
        say(T(_("Highlights synced: %1 here, %2 added from the server, %3 updated, %4 removed."), counts.pushed, counts.added, counts.updated, counts.removed), 3)
    elseif counts.added + counts.updated + counts.removed > 0 then
        UIManager:show(Notification:new{ text = T(_("Highlights synced: %1 added, %2 updated, %3 removed"), counts.added, counts.updated, counts.removed) })
    end
end

-- ---- reading statistics -----------------------------------------------------------

-- KOReader's statistics plugin keys its book rows by a partial MD5 of the
-- file, which the sidecar also records.
local function statsMd5(path, ds)
    local m = ds and ds:readSetting("partial_md5_checksum")
    if type(m) == "string" and m ~= "" then return m end
    local ok, v = pcall(util.partialMD5, path)
    if ok then return v end
    return nil
end

--- Upload this book's page events newer than what the server has from this
-- device. Returns how many went up, or nil, err.
function BackIssue:pushEventsFor(path, ds, issue_id)
    if lfs.attributes(STATS_DB, "mode") ~= "file" then return 0 end
    local md5 = statsMd5(path, ds)
    if not md5 then return 0 end
    local api = self:client()
    local since, err = api:eventsCursor(issue_id)
    if since == nil then return nil, err end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return 0 end
    local okc, conn = pcall(SQ3.open, STATS_DB, "ro")
    if not okc then return 0 end
    local events = {}
    local okq, qerr = pcall(function()
        local books = conn:exec(string.format("SELECT id FROM book WHERE md5 = '%s';", md5:gsub("'", "''")))
        if not books or not books[1] or #books[1] == 0 then return end
        local ids = {}
        for i = 1, #books[1] do ids[#ids + 1] = tostring(tonumber(books[1][i])) end
        local rows = conn:exec(string.format(
            "SELECT start_time, duration, page, total_pages FROM page_stat_data WHERE id_book IN (%s) AND start_time > %d ORDER BY start_time LIMIT %d;",
            table.concat(ids, ","), since, EVENTS_BATCH))
        if not rows or not rows[1] then return end
        for i = 1, #rows[1] do
            events[#events + 1] = {
                start_time = tonumber(rows[1][i]), duration = tonumber(rows[2][i]),
                page = tonumber(rows[3][i]), pages = tonumber(rows[4][i]),
            }
        end
    end)
    pcall(function() conn:close() end)
    if not okq then
        logger.warn("BackIssue: statistics read failed:", qerr)
        return 0
    end
    if #events == 0 then return 0 end
    local res
    res, err = api:putEvents(issue_id, events)
    if not res then return nil, err end
    return tonumber(res.added) or #events
end

-- After a book closes, the statistics plugin writes its last page events;
-- give it a moment, then upload.
function BackIssue:pushEventsLater(path, issue_id)
    if not self:syncStatsOn() or not issue_id then return end
    UIManager:scheduleIn(3, function()
        if not NetworkMgr:isOnline() then return end
        local ds = DocSettings:open(path)
        local n, err = self:pushEventsFor(path, ds, issue_id)
        if n == nil then logger.warn("BackIssue: statistics upload failed:", err) end
    end)
end

-- ---- sync all ----------------------------------------------------------------------

--- Walk the reading history and sync every book the server knows: position
-- (unless the server's is newer), status, highlights, reading time.
function BackIssue:syncAll()
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Syncing all books…") }
        UIManager:show(info)
        UIManager:scheduleIn(0.1, function()
            local ok, result = xpcall(function() return self:sweep() end, debug.traceback)
            UIManager:close(info)
            if not ok then
                logger.err("BackIssue: sync all failed:", result)
                say(T(_("Sync all failed: %1"), tostring(result):match("^[^\n]*") or "?"))
                return
            end
            local r = result
            local lines = { T(_("Synced %1 books."), r.synced) }
            if r.positions + r.skipped > 0 then lines[#lines + 1] = T(_("Positions sent: %1 (%2 already newer on the server)."), r.positions, r.skipped) end
            if r.highlights > 0 then lines[#lines + 1] = T(_("Highlights: %1 uploaded, %2 brought here."), r.highlights, r.hl_in) end
            if r.events > 0 then lines[#lines + 1] = T(_("Reading events uploaded: %1."), r.events) end
            if r.unknown > 0 then lines[#lines + 1] = T(_("Not in the library: %1."), r.unknown) end
            if r.failed > 0 then lines[#lines + 1] = T(_("Failed: %1 (see the log)."), r.failed) end
            UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
        end)
    end)
end

function BackIssue:sweep()
    local ReadHistory = require("readhistory")
    local r = { synced = 0, positions = 0, skipped = 0, highlights = 0, hl_in = 0, events = 0, unknown = 0, failed = 0 }
    local api = self:client()
    local open_file = self.ui.document and self.ui.document.file or nil
    local seen = {}
    local n = 0
    for _i, entry in ipairs(ReadHistory.hist or {}) do
        if n >= SWEEP_MAX_BOOKS then break end
        local path = entry.file
        if path and not seen[path] and lfs.attributes(path, "mode") == "file" then
            seen[path] = true
            n = n + 1
            local live = (path == open_file)
            local ds = live and self.ui.doc_settings or DocSettings:open(path)
            local issue_id = self:identifyFile(path, ds, not live)
            if not issue_id then
                r.unknown = r.unknown + 1
            else
                local okb, berr = pcall(function()
                    -- Position and status. The open book's is live; a closed
                    -- book's comes from its sidecar, stamped with its last
                    -- access so the server keeps anything newer.
                    local p = live and self:currentProgress() or sidecarProgress(ds)
                    if p then
                        p.device = self:deviceName()
                        p.device_id = self.device_id
                        if not live then p.at = tonumber(entry.time) end
                        local res, err = api:putProgress(issue_id, p)
                        if not res then error(err) end
                        if res.progress and res.progress.skipped then r.skipped = r.skipped + 1 else r.positions = r.positions + 1 end
                    end
                    if self:syncHighlightsOn() then
                        local c, err = self:mergeHighlights(issue_id, live and { live = true } or { ds = ds, path = path })
                        if not c then error(err) end
                        r.highlights = r.highlights + c.pushed
                        r.hl_in = r.hl_in + c.added + c.updated
                    end
                    if self:syncStatsOn() then
                        local e, err = self:pushEventsFor(path, ds, issue_id)
                        if e == nil then error(err) end
                        r.events = r.events + e
                    end
                end)
                if okb then r.synced = r.synced + 1 else
                    r.failed = r.failed + 1
                    logger.warn("BackIssue: sync failed for", path, berr)
                end
            end
        end
    end
    pcall(function() api:synced() end)
    return r
end

-- ---- events ----------------------------------------------------------------------

function BackIssue:onReaderReady()
    if not self:isConfigured() or not self:autoSync() then return end
    UIManager:scheduleIn(1, function()
        if self.ui and self.ui.document then
            self:pullProgress({})
            if self:syncHighlightsOn() and NetworkMgr:isOnline() then self:syncHighlightsNow({}) end
        end
    end)
end

function BackIssue:onPageUpdate() self:schedulePush() end
function BackIssue:onPosUpdate() self:schedulePush() end

function BackIssue:onCloseDocument()
    UIManager:unschedule(self.push_task)
    local path = self.ui.document and self.ui.document.file
    local issue_id = self.ui.document and self:isConfigured() and self:autoSync() and NetworkMgr:isOnline() and self:identify() or nil
    self:pushProgress({})
    if issue_id and self:syncHighlightsOn() then self:syncHighlightsNow({}) end
    if issue_id and path then self:pushEventsLater(path, issue_id) end
end

function BackIssue:onSuspend()
    UIManager:unschedule(self.push_task)
    self:pushProgress({})
    if self:syncHighlightsOn() and NetworkMgr:isOnline() then self:syncHighlightsNow({}) end
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

-- A fault in the plugin must not take KOReader down with it: every entry
-- point runs under xpcall, and an error is shown, logged and appended to
-- backissue_crash.log in KOReader's data folder for reporting.
local CRASH_LOG = DataStorage:getDataDir() .. "/backissue_crash.log"
local function guard(fn)
    return function(...)
        local r = { xpcall(fn, debug.traceback, ...) }
        if r[1] then return unpack(r, 2) end
        local err = tostring(r[2])
        logger.err("BackIssue:", err)
        local f = io.open(CRASH_LOG, "a")
        if f then
            f:write(os.date("%Y-%m-%d %H:%M:%S"), " plugin ", PLUGIN_VERSION, "\n", err, "\n\n")
            f:close()
        end
        UIManager:show(InfoMessage:new{
            text = T(_("BackIssue ran into an error: %1\n\nDetails were written to %2"), err:match("^[^\n]*") or "?", CRASH_LOG),
        })
    end
end
for _i, name in ipairs({
    "showBooks", "loadMore", "refreshList", "askSearch", "showBookInfo", "downloadBook", "browseAuthors", "browseSeries",
    "openBook", "testConnection", "editText", "pushProgress", "pullProgress", "syncHighlightsNow", "syncAll",
    "checkUpdate", "installUpdate", "pushEventsLater", "showDashboard", "setFinished", "fetchBook",
    "onReaderReady", "onCloseDocument", "onSuspend", "onResume", "onNetworkConnected",
}) do
    BackIssue[name] = guard(BackIssue[name])
end

return BackIssue
