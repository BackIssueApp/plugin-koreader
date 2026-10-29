--[[--
The graphical side of BackIssue for KOReader: a dashboard with cover rows, a
cover grid for every book list, and a book page with cover, metadata and
description. Built from KOReader's own widgets so it looks at home on e-ink.

Every screen takes the plugin instance (`plugin`) for the server client, the
download folder and the open/download actions, so this module holds no
state of its own beyond the cover cache.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local UI = {}

local COVER_RATIO = 1.5          -- cover height / width
local CACHE_DIR = DataStorage:getDataDir() .. "/cache/backissue"
local cover_miss = {}            -- book id → true when the server has no cover (per session)

local function pct(f) return math.floor((tonumber(f) or 0) * 100 + 0.5) end

-- Scheduled work runs outside the plugin's guard: wrap it the same way, so a
-- fault is shown and logged instead of ending KOReader.
local CRASH_LOG = DataStorage:getDataDir() .. "/backissue_crash.log"
local function safe(fn)
    return function(...)
        local ok, err = xpcall(fn, debug.traceback, ...)
        if ok then return end
        err = tostring(err)
        logger.err("BackIssue UI:", err)
        local f = io.open(CRASH_LOG, "a")
        if f then f:write(os.date("%Y-%m-%d %H:%M:%S"), " ui\n", err, "\n\n") f:close() end
        UIManager:show(InfoMessage:new{ text = T(_("BackIssue ran into an error: %1\n\nDetails were written to %2"), err:match("^[^\n]*") or "?", CRASH_LOG) })
    end
end
UI.safe = safe

local function byline(b)
    if type(b.authors) == "table" and #b.authors > 0 then return table.concat(b.authors, ", ") end
    return ""
end

-- ---- covers -------------------------------------------------------------------------

-- Covers come at their native size, often larger than KOReader's image cache
-- allows. Each is scaled once to a screen-sized PNG and kept; the original
-- goes.
local function thumbWidth() return math.floor(Screen:getWidth() * 0.4) end

local function makeThumb(src, dst)
    local RenderImage = require("ui/renderimage")
    local bb = RenderImage:renderImageFile(src, false)
    if not bb then return false end
    local w, h = bb:getWidth(), bb:getHeight()
    local tw = thumbWidth()
    if w > tw then
        local th = math.floor(h * tw / w)
        local scaled = RenderImage:scaleBlitBuffer(bb, tw, th)
        if scaled ~= bb then bb:free() end
        bb = scaled
    end
    local ok = pcall(function() bb:writePNG(dst) end)
    bb:free()
    return ok and lfs.attributes(dst, "mode") == "file"
end

--- The cover file for a book, fetched once and kept; nil when there is none.
function UI.coverPath(plugin, b)
    if not b or not b.id or cover_miss[b.id] then return nil end
    lfs.mkdir(DataStorage:getDataDir() .. "/cache")
    lfs.mkdir(CACHE_DIR)
    local path = CACHE_DIR .. "/" .. tostring(b.id) .. ".png"
    if lfs.attributes(path, "mode") == "file" then return path end
    local raw = CACHE_DIR .. "/" .. tostring(b.id) .. ".raw.jpg"
    local ok, err = plugin:client():download(b.cover or ("/api/ebooks/issue/" .. tostring(b.id) .. "/cover"), raw)
    if ok then
        local okc, made = pcall(makeThumb, raw, path)
        if okc and made then
            os.remove(raw)
            return path
        end
        logger.warn("BackIssue: could not scale cover", b.id, okc and "" or made)
        -- Keep the original as a last resort; it is drawn uncached.
        os.rename(raw, CACHE_DIR .. "/" .. tostring(b.id) .. ".jpg")
        return CACHE_DIR .. "/" .. tostring(b.id) .. ".jpg"
    end
    cover_miss[b.id] = true
    if err and not tostring(err):match("^404") then logger.dbg("BackIssue: no cover for", b.id, err) end
    return nil
end

--- A cover box of the given size: the image fitted in it, or the title on a
-- plain card when the server has none.
function UI.coverWidget(plugin, b, w, h, fetch)
    local path = fetch ~= false and UI.coverPath(plugin, b) or nil
    if path then
        return FrameContainer:new{
            bordersize = Size.border.thin,
            padding = 0,
            margin = 0,
            color = Blitbuffer.COLOR_GRAY,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
                ImageWidget:new{ file = path, width = w, height = h, scale_factor = 0, file_do_cache = false },
            },
        }
    end
    return FrameContainer:new{
        bordersize = Size.border.thin,
        padding = Size.padding.small,
        margin = 0,
        color = Blitbuffer.COLOR_GRAY,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * Size.padding.small, h = h - 2 * Size.padding.small },
            TextBoxWidget:new{
                text = b.title or "?",
                face = Font:getFace("cfont", 16),
                width = w - 4 * Size.padding.small,
                alignment = "center",
                height = h - 4 * Size.padding.small,
            },
        },
    }
end

-- ---- a tile --------------------------------------------------------------------------

local Tile = InputContainer:extend{
    plugin = nil, book = nil, width = nil, cover_h = nil, on_tap = nil, on_hold = nil, fetch = true,
}

function Tile:init()
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
    local b = self.book
    local tags = {}
    if b.finished then tags[#tags + 1] = _("finished")
    elseif (tonumber(b.fraction) or 0) > 0 then tags[#tags + 1] = pct(b.fraction) .. "%" end
    if self.plugin:isOnDevice(b) then tags[#tags + 1] = _("on device") end
    local text_w = self.width - 2 * Size.padding.small
    local items = VerticalGroup:new{ align = "center" }
    items[#items + 1] = UI.coverWidget(self.plugin, b, self.width - 2 * Size.padding.small, self.cover_h, self.fetch)
    items[#items + 1] = VerticalSpan:new{ width = Size.padding.small }
    local progress = tonumber(b.fraction) or 0
    if progress > 0 and not b.finished then
        items[#items + 1] = ProgressWidget:new{ width = text_w, height = Screen:scaleBySize(4), percentage = progress, margin_h = 0, margin_v = 0, radius = 0 }
        items[#items + 1] = VerticalSpan:new{ width = Size.padding.small }
    end
    items[#items + 1] = TextBoxWidget:new{
        text = b.title or "?",
        face = Font:getFace("cfont", 15),
        width = text_w,
        alignment = "center",
        height = UI.titleLines(2),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    }
    local sub = byline(b)
    if #tags > 0 then sub = (sub ~= "" and (sub .. " · ") or "") .. table.concat(tags, " · ") end
    items[#items + 1] = TextWidget:new{
        text = sub,
        face = Font:getFace("cfont", 12),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = text_w,
        truncate_with_ellipsis = true,
    }
    self[1] = FrameContainer:new{
        width = self.width,
        bordersize = 0,
        padding = Size.padding.small,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        items,
    }
end

function Tile:onTapSelect()
    if self.on_tap then safe(self.on_tap)(self.book) end
    return true
end

function Tile:onHoldSelect()
    if self.on_hold then safe(self.on_hold)(self.book) end
    return true
end

-- The height of n lines of tile title text, measured once.
local title_line_h
function UI.titleLines(n)
    if not title_line_h then
        local probe = TextBoxWidget:new{ text = "Ag", face = Font:getFace("cfont", 15), width = Screen:scaleBySize(100) }
        title_line_h = probe:getSize().h
        probe:free()
    end
    return title_line_h * n
end

-- How many tiles fit across, and how big each is, for this screen.
local function tileMetrics(cols)
    local w = Screen:getWidth()
    cols = cols or math.max(2, math.min(6, math.floor(w / Screen:scaleBySize(150))))
    local tile_w = math.floor((w - 2 * Size.padding.default) / cols)
    local cover_w = tile_w - 2 * Size.padding.small
    local cover_h = math.floor(cover_w * COVER_RATIO)
    local tile_h = cover_h + UI.titleLines(2) + Screen:scaleBySize(4) + Screen:scaleBySize(18) + 5 * Size.padding.small
    return cols, tile_w, cover_h, tile_h
end

local function tileRow(plugin, books, from, cols, tile_w, cover_h, on_tap, on_hold, fetch)
    local row = HorizontalGroup:new{ align = "top" }
    for i = from, math.min(#books, from + cols - 1) do
        row[#row + 1] = Tile:new{ plugin = plugin, book = books[i], width = tile_w, cover_h = cover_h, on_tap = on_tap, on_hold = on_hold, fetch = fetch }
    end
    return row
end

-- A screen-filling frame with a title bar and a Back/close handler.
local Screenful = InputContainer:extend{ title = "", subtitle = nil, on_search = nil }

function Screenful:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.key_events = { Close = { { Device.input.group.Back } } }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.title_bar = TitleBar:new{
        title = self.title,
        subtitle = self.subtitle,
        fullscreen = true,
        with_bottom_line = true,
        left_icon = self.on_search and "appbar.search" or nil,
        left_icon_tap_callback = self.on_search,
        close_callback = safe(function() self:onClose() end),
        show_parent = self,
    }
    self:update()
end

function Screenful:body() return VerticalGroup:new{} end

function Screenful:update()
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left", self.title_bar, self:body() },
    }
end

function Screenful:refresh()
    self:update()
    UIManager:setDirty(self, "ui")
end

-- Painting happens in KOReader's loop, outside any guard: a widget that
-- fails to draw would end KOReader. Log it and close the screen instead.
function Screenful:paintTo(bb, x, y)
    local ok, err = xpcall(function() InputContainer.paintTo(self, bb, x, y) end, debug.traceback)
    if ok then return end
    err = tostring(err)
    logger.err("BackIssue UI paint:", err)
    local f = io.open(CRASH_LOG, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S"), " paint\n", err, "\n\n") f:close() end
    if not self._paint_failed then
        self._paint_failed = true
        UIManager:nextTick(function()
            UIManager:close(self)
            UIManager:show(InfoMessage:new{ text = T(_("BackIssue could not draw this screen: %1\n\nDetails were written to %2"), err:match("^[^\n]*") or "?", CRASH_LOG) })
        end)
    end
end

function Screenful:onClose()
    UIManager:close(self)
    return true
end

function Screenful:onSwipe(_, ges)
    if ges.direction == "west" then safe(function() self:onNextPage() end)() return true
    elseif ges.direction == "east" then safe(function() self:onPrevPage() end)() return true end
    return false
end
function Screenful:onNextPage() return false end
function Screenful:onPrevPage() return false end
function Screenful:onCloseWidget()
    UIManager:setDirty(nil, "ui")
end

-- ---- the cover grid ---------------------------------------------------------------------

local Grid = Screenful:extend{ plugin = nil, state = nil, page = 1 }

function Grid:init()
    self.cols, self.tile_w, self.cover_h, self.tile_h = tileMetrics()
    Screenful.init(self)
end

function Grid:perPage()
    local avail = self.dimen.h - self.title_bar:getHeight() - Screen:scaleBySize(44) - 2 * Size.padding.default
    local rows = math.max(1, math.floor(avail / self.tile_h))
    return rows * self.cols, rows
end

function Grid:pageCount()
    local per = self:perPage()
    return math.max(1, math.ceil((self.state.total or #self.state.books) / per))
end

function Grid:body()
    local per, rows = self:perPage()
    local books = self.state.books
    local first = (self.page - 1) * per + 1
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = VerticalSpan:new{ width = Size.padding.default }
    local on_tap = function(b) UI.showBook(self.plugin, b, self) end
    local on_hold = function(b) self.plugin:downloadBook(b) end
    for r = 0, rows - 1 do
        local from = first + r * self.cols
        if from > #books then break end
        group[#group + 1] = LeftContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = self.tile_h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = Size.padding.default }, tileRow(self.plugin, books, from, self.cols, self.tile_w, self.cover_h, on_tap, on_hold) },
        }
    end
    -- Footer: page controls.
    local footer_h = Screen:scaleBySize(44)
    local used = self.title_bar:getHeight() + Size.padding.default
    for i = 2, #group do used = used + group[i]:getSize().h end
    local gap = self.dimen.h - used - footer_h
    if gap > 0 then group[#group + 1] = VerticalSpan:new{ width = gap } end
    local pages = self:pageCount()
    local footer = HorizontalGroup:new{
        align = "center",
        Button:new{ text = "◁", callback = safe(function() self:onPrevPage() end), bordersize = 0, width = Screen:scaleBySize(60), show_parent = self },
        TextWidget:new{ text = T(_("Page %1 of %2"), self.page, pages), face = Font:getFace("cfont", 16) },
        Button:new{ text = "▷", callback = safe(function() self:onNextPage() end), bordersize = 0, width = Screen:scaleBySize(60), show_parent = self },
    }
    group[#group + 1] = CenterContainer:new{ dimen = Geom:new{ w = self.dimen.w, h = footer_h }, footer }
    return group
end

function Grid:onNextPage()
    if self.page >= self:pageCount() then return true end
    local per = self:perPage()
    local need = (self.page + 1) * per
    if need > #self.state.books and #self.state.books < (self.state.total or 0) then
        local ok = self.plugin:loadMoreInto(self.state)
        if not ok then return true end
    end
    self.page = self.page + 1
    self:refresh()
    return true
end

function Grid:onPrevPage()
    if self.page <= 1 then return true end
    self.page = self.page - 1
    self:refresh()
    return true
end

--- Show a cover grid over a list state ({ books, total, title, subtitle }).
function UI.showGrid(plugin, state)
    local info = InfoMessage:new{ text = _("Loading covers…") }
    UIManager:show(info)
    UIManager:scheduleIn(0.05, safe(function()
        local grid = Grid:new{
            plugin = plugin, state = state,
            title = state.title or _("BackIssue library"),
            subtitle = state.subtitle,
            on_search = function() plugin:askSearch() end,
        }
        UIManager:close(info)
        UIManager:show(grid)
        plugin.grid = grid
    end))
end

-- ---- the dashboard --------------------------------------------------------------------------

local Dashboard = Screenful:extend{ plugin = nil, continue_books = nil, recent_books = nil }

function Dashboard:init()
    self.cols, self.tile_w, self.cover_h, self.tile_h = tileMetrics()
    Screenful.init(self)
end

function Dashboard:section(label, books, empty, more)
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = LeftContainer:new{
        dimen = Geom:new{ w = self.dimen.w, h = Screen:scaleBySize(30) },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = Size.padding.default },
            TextWidget:new{ text = label, face = Font:getFace("tfont", 18), bold = true },
            HorizontalSpan:new{ width = Size.padding.default },
            Button:new{ text = _("See all"), callback = more, bordersize = 0, text_font_size = 14, show_parent = self },
        },
    }
    if #books == 0 then
        group[#group + 1] = LeftContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = Screen:scaleBySize(30) },
            HorizontalGroup:new{ HorizontalSpan:new{ width = Size.padding.default }, TextWidget:new{ text = empty, face = Font:getFace("cfont", 14), fgcolor = Blitbuffer.COLOR_DARK_GRAY } },
        }
    else
        group[#group + 1] = LeftContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = self.tile_h },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = Size.padding.default },
                tileRow(self.plugin, books, 1, self.cols, self.tile_w, self.cover_h,
                    function(b) UI.showBook(self.plugin, b, self) end,
                    function(b) self.plugin:downloadBook(b) end),
            },
        }
    end
    return group
end

function Dashboard:body()
    local p = self.plugin
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = VerticalSpan:new{ width = Size.padding.default }
    group[#group + 1] = self:section(_("Continue reading"), self.continue_books, _("Nothing under way. Open a book and read a little."),
        function() p:browse({ sort = "progress" }) end)
    group[#group + 1] = VerticalSpan:new{ width = Size.padding.large }
    group[#group + 1] = self:section(_("Recently added"), self.recent_books, _("The Books library is empty."),
        function() p:browse({ sort = "recent" }) end)
    group[#group + 1] = VerticalSpan:new{ width = Size.padding.large }
    group[#group + 1] = LineWidget:new{ dimen = Geom:new{ w = self.dimen.w, h = Size.line.thin }, background = Blitbuffer.COLOR_GRAY }
    group[#group + 1] = VerticalSpan:new{ width = Size.padding.default }
    local buttons = ButtonTable:new{
        width = self.dimen.w - 2 * Size.padding.default,
        buttons = {
            {
                { text = _("All books"), callback = safe(function() p:browse({}) end) },
                { text = _("Authors"), callback = safe(function() p:browseAuthors() end) },
                { text = _("Series"), callback = safe(function() p:browseSeries() end) },
            },
            {
                { text = _("On this device"), callback = safe(function() p:browse({ on_device = true }) end) },
                { text = _("Finished"), callback = safe(function() p:browse({ finished = true }) end) },
                { text = _("Sync all books"), callback = safe(function() p:syncAll() end) },
            },
        },
        zero_sep = true,
        show_parent = self,
    }
    group[#group + 1] = CenterContainer:new{ dimen = Geom:new{ w = self.dimen.w, h = buttons:getSize().h }, buttons }
    return group
end

--- The dashboard: continue reading, recently added, and the browse buttons.
function UI.showDashboard(plugin)
    local info = InfoMessage:new{ text = _("Loading…") }
    UIManager:show(info)
    UIManager:scheduleIn(0.05, safe(function()
        local cols = tileMetrics()
        local api = plugin:client()
        local cont, err = api:books{ sort = "progress", limit = cols, offset = 0 }
        if not cont then
            UIManager:close(info)
            UIManager:show(InfoMessage:new{ text = T(_("Could not reach the server: %1"), err or "?") })
            return
        end
        local recent = api:books{ sort = "recent", limit = cols, offset = 0 } or { books = {} }
        local me = api:me()
        local dash = Dashboard:new{
            plugin = plugin,
            continue_books = cont.books or {},
            recent_books = recent.books or {},
            title = _("BackIssue"),
            subtitle = me and me.user and T(_("%1 · %2 books"), me.user, (recent.total or cont.total or 0)) or nil,
            on_search = function() plugin:askSearch() end,
        }
        UIManager:close(info)
        UIManager:show(dash)
        plugin.dashboard = dash
    end))
end

-- ---- the book page --------------------------------------------------------------------------

local BookPage = Screenful:extend{ plugin = nil, book = nil }

function BookPage:body()
    local p, b = self.plugin, self.book
    local w = self.dimen.w
    local cover_w = math.floor(w * 0.36)
    local cover_h = math.floor(cover_w * COVER_RATIO)
    local text_w = w - cover_w - 3 * Size.padding.large
    local meta = VerticalGroup:new{ align = "left" }
    local function line(text, face, color)
        if not text or text == "" then return end
        meta[#meta + 1] = TextBoxWidget:new{ text = text, face = face or Font:getFace("cfont", 16), width = text_w, fgcolor = color }
        meta[#meta + 1] = VerticalSpan:new{ width = Size.padding.small }
    end
    line(b.title or "?", Font:getFace("tfont", 20))
    line(byline(b), Font:getFace("cfont", 16))
    if b.series and b.series ~= "" then
        line(b.series_index and T(_("Series: %1, book %2"), b.series, b.series_index) or T(_("Series: %1"), b.series), Font:getFace("cfont", 14), Blitbuffer.COLOR_DARK_GRAY)
    end
    local about = {}
    if b.format then about[#about + 1] = string.upper(b.format) end
    if tonumber(b.size) then about[#about + 1] = util.getFriendlySize(tonumber(b.size)) end
    if b.library then about[#about + 1] = b.library end
    line(table.concat(about, " · "), Font:getFace("cfont", 14), Blitbuffer.COLOR_DARK_GRAY)
    local state = {}
    if b.finished then state[#state + 1] = _("Finished")
    elseif (tonumber(b.fraction) or 0) > 0 then state[#state + 1] = T(_("Read: %1%"), pct(b.fraction)) end
    if p:isOnDevice(b) then state[#state + 1] = _("On this device") end
    if b.remote then state[#state + 1] = _("Fetched by the server on first download") end
    line(table.concat(state, " · "), Font:getFace("cfont", 14))
    if (tonumber(b.fraction) or 0) > 0 and not b.finished then
        meta[#meta + 1] = ProgressWidget:new{ width = text_w, height = Screen:scaleBySize(6), percentage = tonumber(b.fraction), margin_h = 0, margin_v = 0, radius = 0 }
    end

    local top = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = Size.padding.large },
        UI.coverWidget(p, b, cover_w, cover_h),
        HorizontalSpan:new{ width = Size.padding.large },
        meta,
    }
    local on_device = p:isOnDevice(b)
    local buttons = ButtonTable:new{
        width = w - 2 * Size.padding.large,
        buttons = {
            {
                { text = on_device and _("Read") or _("Download"), callback = safe(function()
                    if on_device then p:openBook(p:localPath(b), b.id) else p:fetchBook(b, p:localPath(b), function() self:refresh() end) end
                end) },
                { text = b.finished and _("Mark unread") or _("Mark finished"), callback = safe(function() p:setFinished(b, not b.finished, function() self:refresh() end) end) },
                { text = _("Close"), callback = safe(function() self:onClose() end) },
            },
        },
        zero_sep = true,
        show_parent = self,
    }
    local desc = type(b.description) == "string" and b.description:gsub("<[^>]+>", ""):gsub("%s+", " ") or ""
    local used = self.title_bar:getHeight() + Size.padding.default + math.max(cover_h, meta:getSize().h) + Size.padding.large + buttons:getSize().h + Size.padding.large
    local desc_h = self.dimen.h - used - Size.padding.large
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = VerticalSpan:new{ width = Size.padding.default }
    group[#group + 1] = top
    group[#group + 1] = VerticalSpan:new{ width = Size.padding.large }
    if desc ~= "" and desc_h > Screen:scaleBySize(40) then
        group[#group + 1] = LeftContainer:new{
            dimen = Geom:new{ w = w, h = desc_h },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = Size.padding.large },
                ScrollTextWidget:new{ text = desc, face = Font:getFace("cfont", 16), width = w - 2 * Size.padding.large - Size.padding.default, height = desc_h, dialog = self },
            },
        }
    else
        group[#group + 1] = VerticalSpan:new{ width = math.max(0, desc_h) }
    end
    group[#group + 1] = VerticalSpan:new{ width = Size.padding.large }
    group[#group + 1] = CenterContainer:new{ dimen = Geom:new{ w = w, h = buttons:getSize().h }, buttons }
    return group
end

--- The book page. `parent` is the screen to refresh when the book changes
-- (downloaded, marked finished).
function UI.showBook(plugin, b, parent)
    local page = BookPage:new{ plugin = plugin, book = b, title = b.title or "?", subtitle = byline(b) }
    page.onCloseWidget = function()
        if parent and parent.refresh then parent:refresh() else UIManager:setDirty(nil, "ui") end
    end
    UIManager:show(page)
end

return UI
