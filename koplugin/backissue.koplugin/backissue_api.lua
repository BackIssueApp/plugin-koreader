--[[--
The BackIssue server, as the plugin talks to it: a few JSON calls under
/api/koreader and the book download. Every call is synchronous, like the rest
of KOReader's network code; callers wrap them in NetworkMgr:runWhenOnline.
--]]--

local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local logger = require("logger")

-- rapidjson ships with KOReader; the pure-Lua json is the fallback on builds
-- without it. Both expose encode/decode.
local json_ok, JSON = pcall(require, "rapidjson")
if not json_ok then JSON = require("json") end

-- rapidjson decodes a JSON null as a sentinel userdata, not as nil, so a
-- book with no series would carry a value that passes `~= ""` and then
-- fails to concatenate. Drop the sentinels so callers only ever see nil.
local NULL = json_ok and JSON.null or nil
local function withoutNulls(v)
    if NULL ~= nil and v == NULL then return nil end
    if type(v) == "table" then
        for k, x in pairs(v) do
            if NULL ~= nil and x == NULL then
                v[k] = nil
            elseif type(x) == "table" then
                withoutNulls(x)
            end
        end
    end
    return v
end

local Api = {}
Api.__index = Api

function Api.encode(v) return JSON.encode(v) end

-- An empty Lua table encodes as a JSON object; mark lists so they come out
-- as arrays (rapidjson honours __jsontype; the fallback encoder guesses).
local function asArray(t)
    t = t or {}
    if json_ok then setmetatable(t, { __jsontype = "array" }) end
    return t
end
function Api.decode(s)
    local ok, v = pcall(JSON.decode, s)
    if ok then return withoutNulls(v) end
    return nil
end

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

--- o: server, api_key, user_agent, plugin_version, device_id, device_name, model.
function Api:new(o)
    o = o or {}
    setmetatable(o, self)
    o.server = tostring(o.server or ""):gsub("/+$", "")
    o.api_key = o.api_key or ""
    o.user_agent = o.user_agent or "BackIssue-KOReader"
    return o
end

-- LuaSocket's http handles plain URLs; LuaSec's https the secure ones.
local function requester(u)
    if u:match("^https://") then
        local ok, https = pcall(require, "ssl.https")
        if ok then return https end
    end
    return require("socket.http")
end

local function query(params)
    local parts = {}
    for k, v in pairs(params or {}) do
        if v ~= nil and v ~= "" then parts[#parts + 1] = urlencode(k) .. "=" .. urlencode(v) end
    end
    table.sort(parts)
    return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

-- Every call names the device, so the server's Devices list stays current
-- without a call of its own.
function Api:headers(extra)
    local h = {
        ["X-Api-Key"] = self.api_key,
        ["Accept"] = "application/json",
        ["User-Agent"] = self.user_agent,
        ["Accept-Encoding"] = "identity",
    }
    if self.device_id then h["X-Device-Id"] = tostring(self.device_id) end
    if self.device_name then h["X-Device-Name"] = urlencode(self.device_name) end
    if self.model then h["X-Device-Model"] = urlencode(self.model) end
    if self.plugin_version then h["X-Plugin-Version"] = tostring(self.plugin_version) end
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
end

local function describe(code, status, decoded)
    if code == 401 or code == 403 then return "the server refused the API key (" .. tostring(code) .. ")" end
    if type(decoded) == "table" and type(decoded.error) == "string" then return decoded.error end
    return status or tostring(code)
end

--- A JSON call. Returns the decoded body, or nil and a message (and the HTTP
-- code when there was one).
function Api:request(method, path, body)
    if self.server == "" then return nil, "no server address" end
    if self.api_key == "" then return nil, "no API key" end
    local u = self.server .. path
    local chunks = {}
    local req = { url = u, method = method, headers = self:headers(), sink = ltn12.sink.table(chunks) }
    if body ~= nil then
        local s = JSON.encode(body)
        req.headers["Content-Type"] = "application/json"
        req.headers["Content-Length"] = tostring(#s)
        req.source = ltn12.source.string(s)
    end
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, _, status = requester(u).request(req)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("BackIssue: request failed", method, u, code)
        return nil, tostring(code)
    end
    local text = table.concat(chunks)
    local decoded
    if text ~= "" then decoded = Api.decode(text) end
    if type(code) ~= "number" or code < 200 or code >= 300 then
        logger.warn("BackIssue: HTTP", code, method, u)
        return nil, describe(code, status, decoded), code
    end
    return decoded or {}, nil, code
end

--- A file, streamed to local_path. Returns true, or nil and a message; a
-- failed download leaves nothing behind.
function Api:download(path, local_path)
    if self.server == "" then return nil, "no server address" end
    local u = self.server .. path
    local f = io.open(local_path, "wb")
    if not f then return nil, "cannot write " .. local_path end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, code, _, status = requester(u).request{
        url = u,
        method = "GET",
        headers = self:headers({ ["Accept"] = "*/*" }),
        sink = ltn12.sink.file(f), -- closes the handle when the stream ends
    }
    socketutil:reset_timeout()
    if not ok or code ~= 200 then
        pcall(function() f:close() end)
        os.remove(local_path)
        logger.warn("BackIssue: download failed", u, code, status)
        if not ok then return nil, tostring(code) end
        return nil, describe(code, status)
    end
    return true
end

-- ---- the calls -------------------------------------------------------------

function Api:me()
    return self:request("GET", "/api/koreader/me")
end

--- { total, books = { { id, title, authors, series, series_index, format,
-- size, library, remote, filename, fraction, finished, last_read_at,
-- description, download, cover } } }. params: q, sort
-- (title|recent|progress|read|author), author, series, finished ("1"),
-- unread ("1"), offset, limit.
function Api:books(params)
    return self:request("GET", "/api/koreader/books" .. query(params))
end

--- { authors = { { name, books, finished, reading } } }
function Api:authors()
    return self:request("GET", "/api/koreader/authors")
end

--- { series = { { id, title, authors, books, finished, reading, statuses, first_id, cover } } }
-- `statuses` has one letter per book in reading order: f finished, r under
-- way, u untouched.
function Api:series()
    return self:request("GET", "/api/koreader/series")
end

--- { books, finished, reading, unread }: how many books, and this user's
-- standing in them.
function Api:counts()
    return self:request("GET", "/api/koreader/counts")
end

function Api:book(id)
    local r, err, code = self:request("GET", "/api/koreader/books/" .. tostring(id))
    return r and r.book, err, code
end

function Api:lookup(fp, size)
    local r, err, code = self:request("GET", "/api/koreader/lookup" .. query({ fp = fp, size = size }))
    return r and r.book, err, code
end

--- The newest position: { fraction, position, kind, device, device_id,
-- source = "koreader" | "web", status, finished, updated_at,
-- file_changed_at }, or nil when never opened.
function Api:getProgress(id)
    local r, err, code = self:request("GET", "/api/koreader/progress/" .. tostring(id))
    if not r then return nil, err, code end
    return { progress = type(r.progress) == "table" and r.progress or nil }, nil, code
end

--- p: fraction, position, kind, status, at (unix seconds of the device's
-- last access, for a sweep). The answer's progress.skipped says the server
-- already had something newer.
function Api:putProgress(id, p)
    return self:request("PUT", "/api/koreader/progress/" .. tostring(id), {
        fraction = p.fraction, position = p.position, kind = p.kind,
        device = p.device, device_id = p.device_id, status = p.status, at = p.at,
    })
end

--- { items = { { key, kind, pos0, pos1, page, chapter, text, note, color,
-- drawer, fraction, device, created_at, updated_at } }, deleted = { key } }
function Api:getHighlights(id)
    return self:request("GET", "/api/koreader/highlights/" .. tostring(id))
end

--- items: the device's full list after merging; deleted: keys it removed.
-- Answers like getHighlights.
function Api:putHighlights(id, items, deleted, device)
    return self:request("PUT", "/api/koreader/highlights/" .. tostring(id), {
        items = asArray(items), deleted = asArray(deleted), device = device.device, device_id = device.device_id,
    })
end

--- The newest page event this device already sent for a book (unix seconds).
function Api:eventsCursor(id)
    local r, err, code = self:request("GET", "/api/koreader/events/" .. tostring(id) .. "/cursor")
    if not r then return nil, err, code end
    return tonumber(r.since) or 0
end

--- events: { { start_time, duration, page, pages } }. Answers { added }.
function Api:putEvents(id, events)
    return self:request("PUT", "/api/koreader/events/" .. tostring(id), { events = asArray(events) })
end

--- A "sync all" sweep finished.
function Api:synced()
    return self:request("POST", "/api/koreader/synced", {})
end

return Api
