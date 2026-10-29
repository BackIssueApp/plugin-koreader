--[[--
The graphical side of BackIssue for KOReader: a Home screen with the books
under way and the newest additions, a Library of covers with filters, a book
page, and Authors and Series lists, all sharing a header and a bottom tab
bar. Built from KOReader's own widgets so it looks at home on e-ink.

Sizes are designed for a 600×800 logical screen and go through
Screen:scaleBySize, so other sizes scale. Every screen takes the plugin
instance (`plugin`) for the server client, the download folder and the
open/download actions; this module keeps no state beyond the cover cache.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local DocSettings = require("docsettings")
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
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
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

local function S(n) return Screen:scaleBySize(n) end

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local DARK = Blitbuffer.COLOR_DARK_GRAY            -- secondary text
local GRAY = Blitbuffer.COLOR_GRAY                 -- row rules, disabled controls
local GRAY_D = Blitbuffer.COLOR_GRAY_D or (Blitbuffer.Color8 and Blitbuffer.Color8(0xDD)) or GRAY   -- light rules
local LIGHT = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY                                 -- group headers

local HEADER_H, PAGE_HEADER_H, TAB_H, SIDE = 56, 52, 64, 20
local CACHE_DIR = DataStorage:getDataDir() .. "/cache/backissue"
local cover_miss = {}            -- book id → true when the server has no cover (per session)

local function pct(f) return math.floor((tonumber(f) or 0) * 100 + 0.5) end
local function frac(b) return tonumber(b.fraction) or 0 end
local function underWay(b) return frac(b) > 0 and not b.finished end
-- "72%", or "<1%" for a book only just opened.
local function pctText(b)
    local n = pct(b.fraction)
    if n == 0 and frac(b) > 0 then return "<1%" end
    return n .. "%"
end

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

local function nBooks(n)
    n = tonumber(n) or 0
    if n == 1 then return _("1 book") end
    return T(_("%1 books"), n)
end

-- ---- time words --------------------------------------------------------------------------

-- A server timestamp ("2026-10-29T10:42:00.000Z") as local epoch seconds.
local function parseIso(s)
    local y, m, d, H, M, sec = tostring(s or ""):match("(%d+)%-(%d+)%-(%d+)[T ](%d+):(%d+):(%d+)")
    if not y then return nil end
    local t = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = tonumber(H), min = tonumber(M), sec = tonumber(sec) }
    local utc = os.date("!*t")
    utc.isdst = os.date("*t").isdst
    return t + (os.time() - os.time(utc))
end

local function dayStart(t)
    local d = os.date("*t", t)
    return os.time{ year = d.year, month = d.month, day = d.day, hour = 12 }
end

-- "today", "yesterday", "3 days ago", "last week", "2 weeks ago"...
local function agoText(t)
    if not t then return nil end
    local days = math.floor((dayStart(os.time()) - dayStart(t)) / 86400 + 0.5)
    if days <= 0 then return _("today")
    elseif days == 1 then return _("yesterday")
    elseif days < 7 then return T(_("%1 days ago"), days)
    elseif days < 14 then return _("last week")
    elseif days < 60 then return T(_("%1 weeks ago"), math.floor(days / 7))
    elseif days < 365 then return T(_("%1 months ago"), math.floor(days / 30))
    end
    return os.date("%Y", t)
end

-- "10:42" today, "29 Oct" earlier.
local function clockText(t)
    if not t then return nil end
    if dayStart(t) == dayStart(os.time()) then return os.date("%H:%M", t) end
    return os.date("%d %b", t)
end

-- ---- small building blocks -------------------------------------------------------------

local function label(str, size, o)
    o = o or {}
    return TextWidget:new{
        text = str or "", face = Font:getFace(o.face or "cfont", size), bold = o.bold, fgcolor = o.color or BLACK,
        padding = 0, max_width = o.max_width, truncate_with_ellipsis = true,
    }
end
local function hspan(n) return HorizontalSpan:new{ width = n } end
local function vspan(n) return VerticalSpan:new{ width = n } end
local function rule(w, h, color) return LineWidget:new{ dimen = Geom:new{ w = w, h = h }, background = color or BLACK } end
local function nothing() return VerticalSpan:new{ width = 0 } end

-- A box of exact size with its child centred vertically and placed left,
-- centre or right.
local function fixed(w, h, child, align)
    local dimen = Geom:new{ w = w, h = h }
    if align == "center" then return CenterContainer:new{ dimen = dimen, child }
    elseif align == "right" then return RightContainer:new{ dimen = dimen, child } end
    return LeftContainer:new{ dimen = dimen, child }
end

-- A bordered (or filled) box of exact outer size with its child centred.
local function box(w, h, child, o)
    o = o or {}
    local bs = o.border or 0
    return FrameContainer:new{
        bordersize = bs, padding = 0, margin = 0, radius = o.radius, color = o.border_color or BLACK, background = o.bg or WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = w - 2 * bs, h = h - 2 * bs }, child },
    }
end

-- The height of one line of text in a face, measured once.
local line_h = {}
local function lineHeight(size, face_name)
    local k = (face_name or "cfont") .. size
    if not line_h[k] then
        local probe = TextWidget:new{ text = "Ag", face = Font:getFace(face_name or "cfont", size), padding = 0 }
        line_h[k] = probe:getSize().h
        probe:free()
    end
    return line_h[k]
end

-- The height of n lines of a text box in a face, measured once.
local box_h = {}
local function boxLines(n, size, face_name)
    local k = (face_name or "cfont") .. size
    if not box_h[k] then
        local probe = TextBoxWidget:new{ text = "Ag", face = Font:getFace(face_name or "cfont", size), width = S(100) }
        box_h[k] = probe:getSize().h
        probe:free()
    end
    return box_h[k] * n
end

-- Something to tap (and hold). It handles the raw gesture itself: the
-- usual ges_events route turns a match into a named event and propagates
-- that to children first, so a tap on a row would fire a button nested in
-- it.
local Touch = InputContainer:extend{ on_tap = nil, on_hold = nil }

function Touch:onGesture(ev)
    if not self.dimen or not ev.pos or not self.dimen:contains(ev.pos) then return false end
    if ev.ges == "tap" and self.on_tap then
        safe(self.on_tap)()
        return true
    elseif ev.ges == "hold" and self.on_hold then
        safe(self.on_hold)()
        return true
    end
    return false
end

local function touch(child, on_tap, on_hold)
    return Touch:new{ child, on_tap = on_tap, on_hold = on_hold }
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
-- With `fetch` false only the cache is consulted (offline).
function UI.coverPath(plugin, b, fetch)
    if not b or not b.id or cover_miss[b.id] then return nil end
    lfs.mkdir(DataStorage:getDataDir() .. "/cache")
    lfs.mkdir(CACHE_DIR)
    local path = CACHE_DIR .. "/" .. tostring(b.id) .. ".png"
    if lfs.attributes(path, "mode") == "file" then return path end
    local kept = CACHE_DIR .. "/" .. tostring(b.id) .. ".jpg"
    if lfs.attributes(kept, "mode") == "file" then return kept end
    if fetch == false then return nil end
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
        os.rename(raw, kept)
        return kept
    end
    cover_miss[b.id] = true
    if err and not tostring(err):match("^404") then logger.dbg("BackIssue: no cover for", b.id, err) end
    return nil
end

--- A cover box of the given outer size: the image fitted in it behind a 1px
-- border, or the title on a plain card when the server has none.
function UI.coverWidget(plugin, b, w, h, fetch)
    local path = UI.coverPath(plugin, b, fetch)
    local bs = S(1)
    if path then
        return box(w, h, ImageWidget:new{ file = path, width = w - 2 * bs, height = h - 2 * bs, scale_factor = 0, file_do_cache = false }, { border = bs })
    end
    local pad = S(6)
    return box(w, h, TextBoxWidget:new{
        text = b.title or "?",
        face = Font:getFace("cfont", math.max(10, math.min(16, math.floor(w / S(9))))),
        width = w - 2 * bs - 2 * pad,
        alignment = "center",
        height = h - 2 * bs - 2 * pad,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    }, { border = bs, bg = LIGHT })
end

-- "72%", "✓ Read" or "On device" in the corner of a cover; nil when the book
-- is untouched and not here.
local function statusChipText(plugin, b)
    if b.finished then return "✓ " .. _("Read") end
    if frac(b) > 0 then return pctText(b) end
    if plugin:isOnDevice(b) then return _("On device") end
    return nil
end

-- A cover with its status chip at the bottom-left corner.
local function coverWithChip(plugin, b, w, h, fetch)
    local cover = UI.coverWidget(plugin, b, w, h, fetch)
    local text = statusChipText(plugin, b)
    if not text then return cover end
    local t = label(text, 12, { bold = true })
    local chip_h = lineHeight(12) + 2 * S(1) + 2 * S(1)
    local chip = box(t:getSize().w + 2 * S(6) + 2 * S(1), chip_h, t, { border = S(1) })
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        cover,
        VerticalGroup:new{ align = "left", vspan(h - chip_h), chip },
    }
end

-- ---- the screen shell: header, body, tab bar ------------------------------------------------

local TABS = {
    { id = "home", label = _("Home") },
    { id = "library", label = _("Library") },
    { id = "series", label = _("Series") },
    { id = "authors", label = _("Authors") },
    { id = "search", label = _("Search") },
}
local function tabLabel(id)
    for _i, t in ipairs(TABS) do if t.id == id then return t.label end end
    return _("Home")
end

-- A screen-filling frame: header, body and the tab bar. A root screen owns
-- its tab; a page (`is_page`) stacks over the root with the same tab active
-- and a back chevron instead of the close button.
local TabScreen = InputContainer:extend{
    plugin = nil, tab = "home", title = "", count = nil, is_page = false,
}

function TabScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.key_events = { Close = { { Device.input.group.Back } } }
    self.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } } }
    self.header_h = S(self.is_page and PAGE_HEADER_H or HEADER_H)
    self.tab_h = S(TAB_H)
    self.body_h = self.dimen.h - self.header_h - self.tab_h
    if self.setup then self:setup() end
    self:update()
end

-- Widgets at the right end of the header, in order.
function TabScreen:headerRight() return {} end

function TabScreen:header()
    local w = self.dimen.w
    local right = HorizontalGroup:new{ align = "center" }
    for _i, wdg in ipairs(self:headerRight()) do right[#right + 1] = wdg end
    right[#right + 1] = hspan(S(8))
    local left = HorizontalGroup:new{ align = "center" }
    local room = w - right:getSize().w - S(SIDE)
    if self.is_page then
        -- ‹ plus the title (or, with none, the tab we came from).
        local back = touch(fixed(S(48), S(48), label("‹", 26), "center"), function() self:onClose() end)
        left[#left + 1] = hspan(S(8))
        left[#left + 1] = back
        room = room - S(56) + S(SIDE)
        if self.title and self.title ~= "" then
            left[#left + 1] = label(self.title, 20, { face = "tfont", bold = true, max_width = room - S(80) })
        else
            left[#left + 1] = label(tabLabel(self.tab), 16, { max_width = room })
        end
    else
        left[#left + 1] = hspan(S(SIDE))
        left[#left + 1] = label(self.title, 24, { face = "tfont", bold = true, max_width = room - S(80) })
    end
    if self.count and self.count ~= "" then
        left[#left + 1] = hspan(S(4))
        left[#left + 1] = label(self.count, 15, { color = DARK, max_width = math.max(S(40), w - left:getSize().w - right:getSize().w - S(4)) })
        left:resetLayout()   -- the group caches its size on first measure
    end
    local spacer = math.max(0, w - left:getSize().w - right:getSize().w)
    return fixed(w, self.header_h, HorizontalGroup:new{ align = "center", left, hspan(spacer), right }, "left")
end

function TabScreen:tabbar()
    local w = self.dimen.w
    local col_w = math.floor(w / #TABS)
    local row = HorizontalGroup:new{ align = "top" }
    for i, t in ipairs(TABS) do
        local active = t.id == self.tab
        local cw = i == #TABS and (w - col_w * (#TABS - 1)) or col_w
        local bar_h = active and S(5) or S(2)
        local cell = VerticalGroup:new{
            align = "center",
            rule(cw, bar_h, BLACK),
            fixed(cw, self.tab_h - bar_h, label(t.label, 15, { bold = active, max_width = cw - S(8) }), "center"),
        }
        row[#row + 1] = touch(cell, function() self:switchTab(t.id) end)
    end
    return row
end

function TabScreen:body() return VerticalGroup:new{} end

function TabScreen:update()
    local body = self:body()
    local gap = math.max(0, self.body_h - body:getSize().h)
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = WHITE,
        VerticalGroup:new{ align = "left", self:header(), body, vspan(gap), self:tabbar() },
    }
end

function TabScreen:refresh(kind)
    self:update()
    UIManager:setDirty(self, kind or "ui")
end

-- Painting happens in KOReader's loop, outside any guard: a widget that
-- fails to draw would end KOReader. Log it and close the screen instead.
function TabScreen:paintTo(bb, x, y)
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

-- Back: a page closes; a tab root other than Home goes Home; Home closes.
function TabScreen:onClose()
    local p = self.plugin
    if self.is_page then
        if p.page == self then p.page = nil end
        UIManager:close(self)
    elseif self.tab ~= "home" then
        UI.openTab(p, "home")
    else
        if p.screen == self then p.screen = nil end
        UIManager:close(self)
    end
    return true
end

function TabScreen:switchTab(id)
    if id == "search" then
        self.plugin:askSearch()
        return
    end
    if id == self.tab and not self.is_page then return end
    if id == self.tab and self.is_page and self.plugin.screen then
        -- Back to the root of this tab.
        self:onClose()
        return
    end
    UI.openTab(self.plugin, id)
end

function TabScreen:onSwipe(_a, ges)
    if ges.direction == "west" then safe(function() self:onNextPage() end)() return true
    elseif ges.direction == "east" then safe(function() self:onPrevPage() end)() return true end
    return false
end
function TabScreen:onNextPage() return false end
function TabScreen:onPrevPage() return false end

function TabScreen:onCloseWidget()
    if self._replacing then return end
    UIManager:setDirty(nil, "ui")
end

-- Page turns in a paged screen: a full refresh now and then clears ghosting.
function TabScreen:turned()
    self.turns = (self.turns or 0) + 1
    self:refresh(self.turns % 6 == 0 and "full" or "ui")
end

-- Show `screen` in place of whatever BackIssue screens are open: a page
-- stacks on the current root, a root replaces root and page.
local function present(plugin, screen)
    local old_page, old_root = plugin.page, plugin.screen
    if screen.is_page then
        if old_page then old_page._replacing = true end
        plugin.page = screen
        UIManager:show(screen)
        if old_page then UIManager:close(old_page) end
        return
    end
    if old_page then old_page._replacing = true end
    if old_root then old_root._replacing = true end
    plugin.page, plugin.screen = nil, screen
    plugin.tabs_seen = plugin.tabs_seen or {}
    local first = not plugin.tabs_seen[screen.tab]
    plugin.tabs_seen[screen.tab] = true
    UIManager:show(screen, first and "full" or "ui")
    if old_page then UIManager:close(old_page) end
    if old_root then UIManager:close(old_root) end
end

-- "Loading…", then build off the event loop so the message paints first.
local function loading(text, build)
    local info = InfoMessage:new{ text = text or _("Loading…") }
    UIManager:show(info)
    UIManager:scheduleIn(0.05, safe(function()
        local ok, err = xpcall(build, debug.traceback)
        UIManager:close(info)
        if not ok then error(err, 0) end
    end))
end

-- ---- Home ----------------------------------------------------------------------------------

local Home = TabScreen:extend{ tab = "home", now_books = nil, now_total = 0, recent_books = nil, offline = false }

function Home:setup() self.title = _("Home") end

function Home:headerRight()
    local p = self.plugin
    local text
    if self.offline then text = _("Offline")
    elseif p.syncing then text = _("Syncing…")
    elseif p.sync_failed then text = _("Not synced")
    elseif p.last_sync_at then text = T(_("Synced %1"), clockText(p.last_sync_at))
    else text = _("Sync") end
    local inner = HorizontalGroup:new{ align = "center", label("⟳", 17), hspan(S(8)), label(text, 14) }
    local pill = box(inner:getSize().w + 2 * S(12) + 2 * S(1), S(40), inner, { border = S(1) })
    local close = fixed(S(48), S(48), label("✕", 22), "center")
    return {
        touch(pill, function()
            if self.offline then UI.showHome(p, { connect = true })
            elseif not p.syncing then p:syncAll() end
        end),
        hspan(S(6)),
        touch(close, function() self:onClose() end),
    }
end

-- "READING NOW ........ 6 books ›"
function Home:sectionRow(title, right_text, on_right)
    local w = self.dimen.w
    local t = label(string.upper(title), 15, { bold = true })
    local r = label(right_text, 14)
    local r_w = r:getSize().w + S(SIDE) + S(12)
    local right = touch(fixed(r_w, S(44), HorizontalGroup:new{ r, hspan(S(SIDE)) }, "right"), on_right)
    return fixed(w, S(44), HorizontalGroup:new{
        align = "center", hspan(S(SIDE)), t, hspan(math.max(0, w - S(SIDE) - t:getSize().w - r_w)), right,
    }, "left")
end

function Home:emptyLine(text)
    return fixed(self.dimen.w, S(44), HorizontalGroup:new{ hspan(S(SIDE)), label(text, 14, { color = DARK, max_width = self.dimen.w - 2 * S(SIDE) }) }, "left")
end

-- One book under way: cover, title, author, progress, and its own button.
function Home:nowRow(b)
    local p, w = self.plugin, self.dimen.w
    local cover_w, cover_h = S(64), S(96)
    local btn_w, btn_h = S(84), S(46)
    local text_w = w - 2 * S(SIDE) - cover_w - 2 * S(16) - btn_w
    local col = VerticalGroup:new{ align = "left" }
    col[#col + 1] = label(b.title or "?", 17, { bold = true, max_width = text_w })
    col[#col + 1] = vspan(S(4))
    col[#col + 1] = label(byline(b), 14, { color = DARK, max_width = text_w })
    col[#col + 1] = vspan(S(6))
    local caption = pctText(b)
    local when = agoText(parseIso(b.last_read_at))
    if when then caption = caption .. " · " .. when end
    local cap = label(caption, 13, { max_width = text_w })
    local bar_w = math.min(S(170), text_w - cap:getSize().w - S(8))
    local bar = ProgressWidget:new{
        width = math.max(S(40), bar_w), height = S(6), percentage = frac(b),
        margin_h = 0, margin_v = 0, radius = 0, bordersize = S(1), bordercolor = BLACK, fillcolor = BLACK, bgcolor = WHITE,
    }
    col[#col + 1] = HorizontalGroup:new{ align = "center", bar, hspan(S(8)), cap }
    local on_device = p:isOnDevice(b)
    local btn = box(btn_w, btn_h, label(on_device and _("Read") or _("Get"), 16, { bold = true }), { border = S(2) })
    local button = touch(btn, function()
        if on_device then p:openBook(p:localPath(b), b.id)
        else p:fetchBook(b, p:localPath(b), nil, "open") end
    end)
    local content = HorizontalGroup:new{
        align = "center",
        hspan(S(SIDE)), UI.coverWidget(p, b, cover_w, cover_h, not self.offline), hspan(S(16)),
        fixed(text_w, cover_h, col, "left"), hspan(S(16)), button, hspan(S(SIDE)),
    }
    local row = VerticalGroup:new{ align = "left", vspan(S(12)), content, vspan(S(12)), rule(w, S(1), GRAY) }
    return touch(row, function() UI.showBook(p, b, self.tab) end, function() p:downloadBook(b) end)
end

function Home:recentStrip(books)
    local w = self.dimen.w
    local cols = 4
    local gap = S(12)
    local col_w = math.floor((w - 2 * S(SIDE) - (cols - 1) * gap) / cols)
    local cover_h = S(150)
    local row = HorizontalGroup:new{ align = "top" }
    row[#row + 1] = hspan(S(SIDE))
    for i = 1, math.min(cols, #books) do
        local b = books[i]
        local tile = VerticalGroup:new{
            align = "left",
            UI.coverWidget(self.plugin, b, col_w, cover_h),
            vspan(S(5)),
            label(b.title or "?", 13, { bold = true, max_width = col_w }),
        }
        row[#row + 1] = touch(tile, function() UI.showBook(self.plugin, b, self.tab) end, function() self.plugin:downloadBook(b) end)
        if i < cols then row[#row + 1] = hspan(gap) end
    end
    return row
end

function Home:body()
    local p, w = self.plugin, self.dimen.w
    local g = VerticalGroup:new{ align = "left" }
    local row_h = S(96) + 2 * S(12) + S(1)
    local now = self.now_books or {}
    g[#g + 1] = self:sectionRow(_("Reading now"), nBooks(self.now_total) .. " ›",
        function() UI.openTab(p, "library", { sort = "progress" }) end)
    g[#g + 1] = rule(w, S(2), BLACK)
    local max_rows = 3
    if self.offline then max_rows = math.max(1, math.floor((self.body_h - S(44) - S(2)) / row_h)) end
    if #now == 0 then
        g[#g + 1] = self:emptyLine(self.offline and _("No book from the library is on this device.") or _("Nothing under way. Open a book and read a little."))
    else
        for i = 1, math.min(max_rows, #now) do g[#g + 1] = self:nowRow(now[i]) end
    end
    if self.offline then return g end
    local recent = self.recent_books or {}
    g[#g + 1] = vspan(S(8))
    g[#g + 1] = self:sectionRow(_("Recently added"), _("See all") .. " ›", function() UI.openTab(p, "library", { sort = "recent" }) end)
    if #recent == 0 then
        g[#g + 1] = self:emptyLine(_("The Books library is empty."))
    else
        g[#g + 1] = self:recentStrip(recent)
    end
    return g
end

-- Books under way that are on this device, from KOReader's history, for an
-- offline Home.
local function offlineBooks(plugin)
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok then return {} end
    local out = {}
    for _i, h in ipairs(ReadHistory.hist or {}) do
        if #out >= 12 then break end
        local path = h.file
        if path and lfs.attributes(path, "mode") == "file" and DocSettings:hasSidecarFile(path) then
            local ds = DocSettings:open(path)
            local saved = ds:readSetting("backissue")
            local f = tonumber(ds:readSetting("percent_finished")) or 0
            local summary = ds:readSetting("summary")
            local done = type(summary) == "table" and summary.status == "complete"
            if type(saved) == "table" and saved.issue_id and f > 0 and not done then
                local props = ds:readSetting("doc_props") or {}
                out[#out + 1] = {
                    id = saved.issue_id, title = props.title or path:match("([^/]+)%.[^.]+$") or path,
                    authors = props.authors and { (tostring(props.authors):gsub("\n", ", ")) } or {},
                    fraction = f, finished = false, local_path = path,
                    last_read_at = h.time and os.date("!%Y-%m-%dT%H:%M:%S", h.time) or nil,
                }
            end
        end
    end
    return out
end

--- Home: the books under way, the newest additions, and the sync pill.
-- opts.connect asks for a connection first (from the Offline pill).
function UI.showHome(plugin, opts)
    opts = opts or {}
    local NetworkMgr = require("ui/network/manager")
    if opts.connect then
        NetworkMgr:runWhenOnline(function() UI.showHome(plugin) end)
        return
    end
    loading(nil, function()
        local now, recent, total, offline = {}, {}, 0, false
        if NetworkMgr:isOnline() then
            local api = plugin:client()
            local cont, err = api:books{ sort = "progress", limit = 3, offset = 0 }
            if cont then
                now, total = cont.books or {}, tonumber(cont.total) or 0
                local r = api:books{ sort = "recent", limit = 4, offset = 0 }
                recent = r and r.books or {}
            else
                logger.warn("BackIssue: home offline:", err)
                offline = true
            end
        else
            offline = true
        end
        if offline then now = offlineBooks(plugin) total = #now end
        present(plugin, Home:new{ plugin = plugin, now_books = now, now_total = total, recent_books = recent, offline = offline })
    end)
end

-- ---- Library ------------------------------------------------------------------------------

local SORTS = {
    { id = "recent", label = _("Newest") },
    { id = "title", label = _("Title") },
    { id = "author", label = _("Author") },
    { id = "read", label = _("Recently read") },
    { id = "progress", label = _("Under way") },
}
local function sortLabel(id)
    for _i, s in ipairs(SORTS) do if s.id == id then return s.label end end
    return SORTS[1].label
end

-- state = { books, total, sort, filter (all|on_device|unread|finished), q,
-- author, series, series_title, counts, page }
local Library = TabScreen:extend{ tab = "library", state = nil }

function Library:setup()
    local st = self.state
    self.title = self.is_page and (st.author or st.series_title or "") or _("Library")
    self.count = nBooks(st.total)
    local w = self.dimen.w
    self.gap_h, self.gap_v = S(18), S(16)
    self.cols = math.max(3, math.floor((w - 2 * S(SIDE) + self.gap_h) / (S(176) + self.gap_h)))
    self.tile_w = math.floor((w - 2 * S(SIDE) - (self.cols - 1) * self.gap_h) / self.cols)
    self.cover_h = math.floor(self.tile_w * 212 / 176)
    self.tile_h = self.cover_h + S(5) + lineHeight(14) + S(2) + lineHeight(12)
    self.chips_h = self.is_page and 0 or (S(44) + S(8))
    self.pager_h = S(52)
    local avail = self.body_h - self.chips_h - S(1) - S(12) - self.pager_h
    self.rows = math.max(1, math.floor((avail + self.gap_v) / (self.tile_h + self.gap_v)))
    self.page = st.page or 1
end

function Library:headerRight()
    if self.is_page then return {} end
    local t = HorizontalGroup:new{ align = "center", label(sortLabel(self.state.sort), 14), hspan(S(4)), label("▾", 14) }
    local ctl = touch(fixed(t:getSize().w + 2 * S(12), S(44), t, "center"), function() self:askSort() end)
    return { ctl }
end

function Library:askSort()
    local dialog
    local rows = {}
    for _i, s in ipairs(SORTS) do
        rows[#rows + 1] = {{
            text = s.id == self.state.sort and ("✓ " .. s.label) or s.label,
            callback = function()
                UIManager:close(dialog)
                if s.id ~= self.state.sort then self:reload({ sort = s.id }) end
            end,
        }}
    end
    dialog = ButtonDialog:new{ buttons = rows }
    UIManager:show(dialog)
end

-- Rebuild the list with changed parameters (filter, sort, query).
function Library:reload(changes)
    local st = self.state
    local opts = { sort = st.sort, filter = st.filter, q = st.q }
    for k, v in pairs(changes) do opts[k] = v end
    if changes.clear_q then opts.q = nil end
    UI.openTab(self.plugin, "library", opts)
end

function Library:chip(text, active, on_tap)
    local t = label(text, 14, { bold = active, color = active and WHITE or BLACK })
    local c = box(t:getSize().w + 2 * S(14), S(36), t, { border = S(1), radius = S(18), bg = active and BLACK or WHITE })
    return touch(fixed(c:getSize().w, S(44), c, "center"), on_tap)
end

function Library:chips()
    local st, p = self.state, self.plugin
    local counts = st.counts or {}
    local row = HorizontalGroup:new{ align = "center" }
    row[#row + 1] = hspan(S(SIDE))
    local function add(chip) row[#row + 1] = chip row[#row + 1] = hspan(S(8)) end
    if st.q then
        add(self:chip("“" .. st.q .. "” ✕", true, function() self:reload({ clear_q = true, filter = "all" }) end))
    end
    local function withCount(text, n) return n and (text .. " " .. tostring(n)) or text end
    local f = st.q and "" or (st.filter or "all")
    add(self:chip(_("All"), f == "all", function() self:reload({ filter = "all", clear_q = true }) end))
    add(self:chip(withCount(_("On device"), p.on_device_count), f == "on_device", function() self:reload({ filter = "on_device", clear_q = true }) end))
    add(self:chip(withCount(_("Unread"), counts.unread), f == "unread", function() self:reload({ filter = "unread", clear_q = true }) end))
    add(self:chip(withCount(_("Finished"), counts.finished), f == "finished", function() self:reload({ filter = "finished", clear_q = true }) end))
    return row
end

function Library:perPage() return self.rows * self.cols end

function Library:pageCount()
    return math.max(1, math.ceil((self.state.total or #self.state.books) / self:perPage()))
end

function Library:tile(b)
    local p = self.plugin
    local t = VerticalGroup:new{
        align = "left",
        coverWithChip(p, b, self.tile_w, self.cover_h),
        vspan(S(5)),
        label(b.title or "?", 14, { bold = true, max_width = self.tile_w }),
        vspan(S(2)),
        label(byline(b), 12, { color = DARK, max_width = self.tile_w }),
    }
    return touch(t, function() UI.showBook(p, b, self.tab) end, function() p:downloadBook(b) end)
end

function Library:pager()
    local pages = self:pageCount()
    local function arrow(text, enabled, fn)
        local color = enabled and BLACK or GRAY
        local a = box(S(72), S(44), label(text, 22, { color = color }), { border = S(1), border_color = color })
        return touch(a, enabled and fn or function() end)
    end
    local row = HorizontalGroup:new{
        align = "center",
        arrow("‹", self.page > 1, function() self:onPrevPage() end),
        hspan(S(4)),
        fixed(S(120), S(44), label(T("%1 / %2", self.page, pages), 15), "center"),
        hspan(S(4)),
        arrow("›", self.page < pages, function() self:onNextPage() end),
    }
    return fixed(self.dimen.w, self.pager_h, row, "center")
end

function Library:body()
    local st, w = self.state, self.dimen.w
    local g = VerticalGroup:new{ align = "left" }
    if not self.is_page then
        g[#g + 1] = self:chips()
        g[#g + 1] = vspan(S(8))
    end
    g[#g + 1] = rule(w, S(1), GRAY)
    g[#g + 1] = vspan(S(12))
    local per = self:perPage()
    local first = (self.page - 1) * per + 1
    local books = st.books
    local grid_h = 0
    if #books == 0 then
        local text = _("The Books library is empty.")
        if st.q then text = T(_("Nothing matches “%1”."), st.q)
        elseif st.sort == "progress" then text = _("No book under way. Open one and read a little.")
        elseif st.filter == "on_device" then text = _("No library book is on this device yet.")
        elseif st.filter == "finished" then text = _("No finished book yet.")
        elseif st.filter == "unread" then text = _("Every book has been opened.") end
        g[#g + 1] = fixed(w, S(44), HorizontalGroup:new{ hspan(S(SIDE)), label(text, 14, { color = DARK, max_width = w - 2 * S(SIDE) }) }, "left")
        grid_h = S(44)
    end
    for r = 0, self.rows - 1 do
        local from = first + r * self.cols
        if from > #books then break end
        local row = HorizontalGroup:new{ align = "top" }
        row[#row + 1] = hspan(S(SIDE))
        for c = 0, self.cols - 1 do
            local b = books[from + c]
            if not b then break end
            row[#row + 1] = self:tile(b)
            if c < self.cols - 1 then row[#row + 1] = hspan(self.gap_h) end
        end
        if r > 0 then g[#g + 1] = vspan(self.gap_v) grid_h = grid_h + self.gap_v end
        g[#g + 1] = row
        grid_h = grid_h + self.tile_h
    end
    local used = self.chips_h + S(1) + S(12) + grid_h
    g[#g + 1] = vspan(math.max(0, self.body_h - used - self.pager_h))
    g[#g + 1] = self:pager()
    return g
end

function Library:onNextPage()
    if self.page >= self:pageCount() then return true end
    local per = self:perPage()
    local need = (self.page + 1) * per
    if need > #self.state.books and #self.state.books < (self.state.total or 0) then
        local ok = self.plugin:loadMoreInto(self.state)
        if not ok then return true end
    end
    self.page = self.page + 1
    self.state.page = self.page
    self:turned()
    return true
end

function Library:onPrevPage()
    if self.page <= 1 then return true end
    self.page = self.page - 1
    self.state.page = self.page
    self:turned()
    return true
end

--- The cover grid. opts: sort, filter (all|on_device|unread|finished), q,
-- author, series, series_title. An author's or series' books stack as a
-- page over the current tab; everything else is the Library tab.
function UI.showLibrary(plugin, opts)
    opts = opts or {}
    local as_page = (opts.author or opts.series) and true or false
    loading(_("Loading covers…"), function()
        local st = {
            q = opts.q, sort = opts.sort or (as_page and "title" or "recent"), filter = opts.filter or "all",
            author = opts.author, series = opts.series, series_title = opts.series_title,
            books = {}, total = 0, page = 1,
        }
        st.on_device = st.filter == "on_device"
        st.finished = st.filter == "finished"
        st.unread = st.filter == "unread"
        if not plugin:loadMoreInto(st) then return end
        if st.on_device then plugin.on_device_count = st.total end
        if not as_page then st.counts = plugin:client():counts() or {} end
        local tab = as_page and (plugin.screen and plugin.screen.tab or "library") or "library"
        present(plugin, Library:new{ plugin = plugin, state = st, tab = tab, is_page = as_page })
    end)
end

-- ---- the book page --------------------------------------------------------------------------

local BookPage = TabScreen:extend{ is_page = true, book = nil }

function BookPage:setup() self.title = "" end

function BookPage:syncedText()
    local p, b = self.plugin, self.book
    local path = p:localPath(b)
    if not DocSettings:hasSidecarFile(path) then return _("not synced yet") end
    local at = tonumber(DocSettings:open(path):readSetting("backissue_synced_at"))
    if at then return T(_("synced %1"), clockText(at)) end
    return _("not synced yet")
end

function BookPage:statStrip()
    local p, b, w = self.plugin, self.book, self.dimen.w
    local cells = {}
    if b.finished then cells[1] = { _("Done"), _("finished") }
    elseif frac(b) > 0 then cells[1] = { pctText(b), _("read") }
    else cells[1] = { _("New"), _("unread") } end
    cells[2] = { b.format and string.upper(b.format) or "—", tonumber(b.size) and util.getFriendlySize(tonumber(b.size)) or (b.remote and _("on request") or "") }
    if p:isOnDevice(b) then cells[3] = { _("On device"), self:syncedText() }
    else cells[3] = { _("On server"), _("not downloaded") } end
    local outer_w = w - 2 * S(SIDE)
    local inner_w = outer_w - 2 * S(1)
    local cell_w = math.floor((inner_w - 2 * S(1)) / 3)
    local cell_h = S(8) + lineHeight(18) + S(2) + lineHeight(12) + S(8)
    local row = HorizontalGroup:new{ align = "center" }
    for i, c in ipairs(cells) do
        local cw = i == 3 and (inner_w - 2 * S(1) - 2 * cell_w) or cell_w
        row[#row + 1] = fixed(cw, cell_h, VerticalGroup:new{
            align = "center",
            label(c[1], 18, { bold = true, max_width = cw - S(8) }),
            vspan(S(2)),
            label(c[2], 12, { color = DARK, max_width = cw - S(8) }),
        }, "center")
        if i < 3 then row[#row + 1] = rule(S(1), cell_h, BLACK) end
    end
    return box(outer_w, cell_h + 2 * S(1), row, { border = S(1) })
end

function BookPage:actions()
    local p, b, w = self.plugin, self.book, self.dimen.w
    local avail = w - 2 * S(SIDE)
    local gap = S(10)
    local primary_w = math.floor((avail - gap) * 2 / 3)
    local secondary_w = avail - gap - primary_w
    local h = S(52)
    local on_device = p:isOnDevice(b)
    local text = not on_device and _("Download") or (underWay(b) and _("Resume") or _("Read"))
    local primary = touch(box(primary_w, h, label(text, 18, { bold = true, color = WHITE }), { bg = BLACK }), function()
        if on_device then p:openBook(p:localPath(b), b.id)
        else p:fetchBook(b, p:localPath(b), function() self.changed = true self:refresh() end, "quiet") end
    end)
    local secondary = touch(box(secondary_w, h, label(b.finished and _("Mark unread") or _("Mark finished"), 15, { bold = true }), { border = S(1) }), function()
        p:setFinished(b, not b.finished, function() self.changed = true self:refresh() end)
    end)
    return HorizontalGroup:new{ align = "center", hspan(S(SIDE)), primary, hspan(gap), secondary }
end

function BookPage:byline()
    local p, b, w = self.plugin, self.book, self.dimen.w
    local by = byline(b)
    local max_w = w - 2 * S(40)
    if not b.series or b.series == "" then
        return by ~= "" and label(by, 16, { max_width = max_w }) or nothing()
    end
    local series = b.series
    if b.series_index and b.series_index ~= "" then series = series .. " " .. tostring(b.series_index) end
    local a = by ~= "" and label(by .. " · ", 16) or nothing()
    local s = label(series, 16, { max_width = math.max(S(60), max_w - a:getSize().w) })
    local link = touch(VerticalGroup:new{ align = "left", s, vspan(S(2)), rule(s:getSize().w, S(1), BLACK) },
        function() if b.series_id then UI.showLibrary(p, { series = b.series_id, series_title = b.series }) end end)
    return HorizontalGroup:new{ align = "top", a, link }
end

function BookPage:body()
    local b, w = self.book, self.dimen.w
    local g = VerticalGroup:new{ align = "center" }
    g[#g + 1] = vspan(S(4))
    g[#g + 1] = UI.coverWidget(self.plugin, b, S(160), S(240))
    g[#g + 1] = vspan(S(14))
    local title_lines = 2
    g[#g + 1] = TextBoxWidget:new{
        text = b.title or "?", face = Font:getFace("tfont", 24), bold = true, width = w - 2 * S(40), alignment = "center",
        height = boxLines(title_lines, 24, "tfont"), height_adjust = true, height_overflow_show_ellipsis = true,
    }
    g[#g + 1] = vspan(S(4))
    g[#g + 1] = self:byline()
    g[#g + 1] = vspan(S(16))
    g[#g + 1] = self:statStrip()
    g[#g + 1] = vspan(S(12))
    g[#g + 1] = self:actions()
    local used = g:getSize().h + S(16)
    local desc = type(b.description) == "string" and b.description:gsub("<[^>]+>", ""):gsub("%s+", " ") or ""
    local desc_h = self.body_h - used - S(8)
    if desc ~= "" and desc_h > S(40) then
        g[#g + 1] = vspan(S(16))
        g[#g + 1] = ScrollTextWidget:new{ text = desc, face = Font:getFace("cfont", 15), width = w - 2 * S(SIDE), height = desc_h, dialog = self }
        g:resetLayout()
    end
    return g
end

function BookPage:onCloseWidget()
    local p = self.plugin
    if self.changed then
        if self.under and self.under.refresh then safe(function() self.under:refresh() end)() end
        if p.screen and p.screen.refresh then safe(function() p.screen:refresh() end)() end
    end
    TabScreen.onCloseWidget(self)
end

function BookPage:onClose()
    self.plugin.page = self.under
    UIManager:close(self)
    return true
end

--- The book page, over the current tab (`tab`, default the open root's).
-- A book page over another page (an author's list) keeps that page under it.
function UI.showBook(plugin, b, tab)
    tab = tab or (plugin.screen and plugin.screen.tab) or "home"
    loading(nil, function()
        local page = BookPage:new{ plugin = plugin, book = b, tab = tab, under = plugin.page }
        plugin.page = page
        UIManager:show(page)
    end)
end

-- ---- Authors ------------------------------------------------------------------------------

-- "Ursula K. Le Guin" → "Le Guin, Ursula K."; the sort key is the surname.
local PARTICLES = { van = true, von = true, de = true, der = true, den = true, le = true, la = true, du = true, del = true, da = true, di = true, st = true, ["st."] = true, mac = true }
local function sortName(name)
    name = util.trim(name or "")
    if name:find(",", 1, true) then return name, name end
    local parts = {}
    for w in name:gmatch("%S+") do parts[#parts + 1] = w end
    if #parts < 2 then return name, name end
    local i = #parts
    while i > 2 and PARTICLES[parts[i - 1]:lower()] do i = i - 1 end
    local surname = table.concat(parts, " ", i)
    local rest = table.concat(parts, " ", 1, i - 1)
    return surname .. ", " .. rest, surname
end

local function groupLetter(key)
    local c = (key or ""):sub(1, 1):upper()
    if c:match("%a") then return c end
    return "#"
end

local Authors = TabScreen:extend{ tab = "authors", authors = nil }

function Authors:setup()
    self.title = _("Authors")
    self.count = tostring(#self.authors)
    self.page = 1
    self.rail_w = S(36)
    self.list_w = self.dimen.w - self.rail_w
    -- Flatten into letter headers and rows, then cut into pages by height.
    local entries = {}
    for _i, a in ipairs(self.authors) do
        local shown, surname = sortName(a.name)
        entries[#entries + 1] = { a = a, shown = shown, key = (surname .. " " .. shown):lower(), letter = groupLetter(surname) }
    end
    table.sort(entries, function(x, y) return x.key < y.key end)
    self.head_h, self.row_h = S(30), S(56) + S(1)
    self.pages, self.letter_page, self.has_letter = {}, {}, {}
    local page, used, last = {}, 0, nil
    local function flush() if #page > 0 then self.pages[#self.pages + 1] = page page, used = {}, 0 end end
    for _i, e in ipairs(entries) do
        local need = self.row_h + (e.letter ~= last and self.head_h or 0)
        if used + need > self.body_h - S(1) and #page > 0 then flush() last = nil end
        if e.letter ~= last then
            page[#page + 1] = { head = e.letter }
            used = used + self.head_h
            if not self.letter_page[e.letter] then self.letter_page[e.letter] = #self.pages + 1 end
            self.has_letter[e.letter] = true
            last = e.letter
        end
        page[#page + 1] = e
        used = used + self.row_h
    end
    flush()
    if #self.pages == 0 then self.pages[1] = {} end
end

local function authorMeta(a)
    local parts = { nBooks(a.books) }
    if (tonumber(a.finished) or 0) > 0 then parts[#parts + 1] = T(_("%1 read"), a.finished)
    elseif (tonumber(a.reading) or 0) > 0 then parts[#parts + 1] = _("reading") end
    return table.concat(parts, " · ")
end

function Authors:row(e)
    local p, w = self.plugin, self.list_w
    local meta = label(authorMeta(e.a), 13, { color = DARK })
    local chev = label("›", 20)
    local name_w = w - S(SIDE) - S(12) - 2 * S(10) - meta:getSize().w - chev:getSize().w
    local content = HorizontalGroup:new{
        align = "center", hspan(S(SIDE)), fixed(name_w, S(56), label(e.shown, 17, { max_width = name_w }), "left"),
        hspan(S(10)), meta, hspan(S(10)), chev, hspan(S(12)),
    }
    local row = VerticalGroup:new{ align = "left", fixed(w, S(56), content, "left"), rule(w, S(1), GRAY_D) }
    return touch(row, function() UI.showLibrary(p, { author = e.a.name }) end)
end

function Authors:head(letter)
    return box(self.list_w, self.head_h, HorizontalGroup:new{ hspan(S(SIDE)), fixed(self.list_w - S(SIDE), self.head_h, label(letter, 14, { bold = true }), "left") }, { bg = LIGHT })
end

function Authors:rail()
    local letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local lh = lineHeight(12)
    local pad = S(6)
    local gap = math.max(0, (self.body_h - 2 * pad - 26 * lh) / 25)
    local col = VerticalGroup:new{ align = "center" }
    col[#col + 1] = vspan(pad)
    for i = 1, 26 do
        local ch = letters:sub(i, i)
        local has = self.has_letter[ch]
        col[#col + 1] = touch(fixed(self.rail_w - S(1), lh, label(ch, 12, { bold = true, color = has and BLACK or GRAY }), "center"),
            has and function() self.page = self.letter_page[ch] self:turned() end or nil)
        if i < 26 then col[#col + 1] = vspan(math.floor(gap * i) - math.floor(gap * (i - 1))) end
    end
    return HorizontalGroup:new{ align = "top", rule(S(1), self.body_h, GRAY), col }
end

function Authors:body()
    local items = self.pages[self.page] or {}
    local list = VerticalGroup:new{ align = "left" }
    list[#list + 1] = rule(self.list_w, S(1), GRAY)
    if #self.authors == 0 then
        list[#list + 1] = fixed(self.list_w, S(44), HorizontalGroup:new{ hspan(S(SIDE)), label(_("The Books library is empty."), 14, { color = DARK }) }, "left")
    end
    for _i, it in ipairs(items) do
        if it.head then list[#list + 1] = self:head(it.head)
        else list[#list + 1] = self:row(it) end
    end
    local used = list:getSize().h
    list[#list + 1] = vspan(math.max(0, self.body_h - used))
    list:resetLayout()
    return HorizontalGroup:new{ align = "top", list, self:rail() }
end

function Authors:onNextPage()
    if self.page < #self.pages then self.page = self.page + 1 self:turned() end
    return true
end
function Authors:onPrevPage()
    if self.page > 1 then self.page = self.page - 1 self:turned() end
    return true
end

--- The Authors tab.
function UI.showAuthors(plugin)
    loading(nil, function()
        local r, err = plugin:client():authors()
        if not r then
            UIManager:show(InfoMessage:new{ text = T(_("Could not list authors: %1"), err or "?") })
            return
        end
        present(plugin, Authors:new{ plugin = plugin, authors = r.authors or {} })
    end)
end

-- ---- Series -------------------------------------------------------------------------------

local SeriesScreen = TabScreen:extend{ tab = "series", series = nil }

function SeriesScreen:setup()
    self.title = _("Series")
    self.count = tostring(#self.series)
    self.page = 1
    self.row_h = S(86) + S(1)
    self.foot_h = S(44)
    self.per = math.max(1, math.floor((self.body_h - S(1) - self.foot_h) / self.row_h))
end

function SeriesScreen:pageCount() return math.max(1, math.ceil(#self.series / self.per)) end

-- Two offset covers: a blank one behind, the first book's in front.
function SeriesScreen:stack(s)
    local cw, ch = S(46), S(64)
    local back = HorizontalGroup:new{ hspan(S(8)), box(cw, ch, nothing(), { border = S(1), bg = GRAY_D }) }
    local front = VerticalGroup:new{ align = "left", vspan(S(6)), UI.coverWidget(self.plugin, { id = s.first_id, cover = s.cover, title = s.title }, cw, ch) }
    return OverlapGroup:new{ dimen = Geom:new{ w = cw + S(8), h = ch + S(6) }, back, front }
end

function SeriesScreen:row(s)
    local p, w = self.plugin, self.dimen.w
    local name_w = w - S(SIDE) - S(16) - (S(46) + S(8)) - S(16) - S(22) - S(16)
    local squares = HorizontalGroup:new{ align = "center" }
    local statuses = tostring(s.statuses or "")
    local shown = math.max(0, math.min(#statuses, math.floor((name_w - S(120)) / S(17)), 24))
    for i = 1, shown do
        local c = statuses:sub(i, i)
        local fill = c == "f" and BLACK or (c == "r" and DARK or WHITE)
        squares[#squares + 1] = box(S(14), S(14), nothing(), { border = S(1), bg = fill })
        if i < shown then squares[#squares + 1] = hspan(S(3)) end
    end
    if shown < #statuses then squares[#squares + 1] = label("…", 13, { color = DARK }) end
    local parts = { nBooks(s.books) }
    if (tonumber(s.finished) or 0) > 0 then parts[#parts + 1] = T(_("%1 finished"), s.finished)
    elseif (tonumber(s.reading) or 0) > 0 then parts[#parts + 1] = T(_("%1 under way"), s.reading) end
    local meta = label(table.concat(parts, " · "), 13, { color = DARK, max_width = math.max(S(60), name_w - squares:getSize().w - S(10)) })
    local col = VerticalGroup:new{
        align = "left",
        label(s.title or "?", 17, { bold = true, max_width = name_w }),
        vspan(S(6)),
        HorizontalGroup:new{ align = "center", squares, hspan(shown > 0 and S(10) or 0), meta },
    }
    local content = HorizontalGroup:new{
        align = "center", hspan(S(SIDE)), self:stack(s), hspan(S(16)), fixed(name_w, S(86), col, "left"), hspan(S(16)), label("›", 22), hspan(S(16)),
    }
    local row = VerticalGroup:new{ align = "left", fixed(w, S(86), content, "left"), rule(w, S(1), GRAY) }
    return touch(row, function() UI.showLibrary(p, { series = s.id, series_title = s.title }) end)
end

function SeriesScreen:body()
    local w = self.dimen.w
    local g = VerticalGroup:new{ align = "left" }
    g[#g + 1] = rule(w, S(1), GRAY)
    if #self.series == 0 then
        g[#g + 1] = fixed(w, S(44), HorizontalGroup:new{ hspan(S(SIDE)), label(_("No series in the Books library yet."), 14, { color = DARK }) }, "left")
    end
    local first = (self.page - 1) * self.per + 1
    for i = first, math.min(#self.series, first + self.per - 1) do g[#g + 1] = self:row(self.series[i]) end
    local pages = self:pageCount()
    if pages > 1 then
        local used = g:getSize().h
        g[#g + 1] = vspan(math.max(0, self.body_h - used - self.foot_h))
        g[#g + 1] = fixed(w, self.foot_h, label(T("%1 / %2", self.page, pages), 13, { color = DARK }), "center")
        g:resetLayout()
    end
    return g
end

function SeriesScreen:onNextPage()
    if self.page < self:pageCount() then self.page = self.page + 1 self:turned() end
    return true
end
function SeriesScreen:onPrevPage()
    if self.page > 1 then self.page = self.page - 1 self:turned() end
    return true
end

--- The Series tab.
function UI.showSeries(plugin)
    loading(_("Loading covers…"), function()
        local r, err = plugin:client():series()
        if not r then
            UIManager:show(InfoMessage:new{ text = T(_("Could not list series: %1"), err or "?") })
            return
        end
        present(plugin, SeriesScreen:new{ plugin = plugin, series = r.series or {} })
    end)
end

-- ---- tabs ---------------------------------------------------------------------------------

--- Open a tab root: home | library | series | authors. Library takes the
-- showLibrary opts.
function UI.openTab(plugin, id, opts)
    local NetworkMgr = require("ui/network/manager")
    if id == "home" then UI.showHome(plugin) return end
    NetworkMgr:runWhenOnline(function()
        if id == "library" then UI.showLibrary(plugin, opts)
        elseif id == "authors" then UI.showAuthors(plugin)
        elseif id == "series" then UI.showSeries(plugin) end
    end)
end

--- Rebuild whatever BackIssue screens are open (a download or a status
-- change moved a chip).
function UI.refreshAll(plugin)
    if plugin.screen and plugin.screen.refresh then safe(function() plugin.screen:refresh() end)() end
    if plugin.page and plugin.page.refresh then safe(function() plugin.page:refresh() end)() end
end

--- Close every BackIssue screen (a book is about to open).
function UI.closeAll(plugin)
    local open = {}
    local s = plugin.page
    while s do open[#open + 1] = s s = s.under end
    if plugin.screen then open[#open + 1] = plugin.screen end
    for _i, w in ipairs(open) do
        w._replacing = true
        UIManager:close(w)
    end
    plugin.page, plugin.screen = nil, nil
    UIManager:setDirty(nil, "ui")
end

return UI
