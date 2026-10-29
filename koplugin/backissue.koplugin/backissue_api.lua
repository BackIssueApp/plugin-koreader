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

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function query(params)
    local parts = {}
    for k, v in pairs(params or {}) do
        if v ~= nil and v ~= "" then parts[#parts + 1] = urlencode(k) .. "=" .. urlencode(v) end
    end
    table.sort(parts)
    return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

function Api:headers(extra)
    local h = {
        ["X-Api-Key"] = self.api_key,
        ["Accept"] = "application/json",
        ["User-Agent"] = self.user_agent,
        ["Accept-Encoding"] = "identity",
    }
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
    if text ~= "" then
        local dok, d = pcall(JSON.decode, text)
        if dok then decoded = withoutNulls(d) end
    end
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
-- size, library, remote, filename, fraction, download } } }
function Api:books(params)
    return self:request("GET", "/api/koreader/books" .. query(params))
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
-- source = "koreader" | "web", updated_at }, or nil when never opened.
function Api:getProgress(id)
    local r, err, code = self:request("GET", "/api/koreader/progress/" .. tostring(id))
    if not r then return nil, err, code end
    return { progress = type(r.progress) == "table" and r.progress or nil }, nil, code
end

function Api:putProgress(id, p)
    return self:request("PUT", "/api/koreader/progress/" .. tostring(id), {
        fraction = p.fraction, position = p.position, kind = p.kind,
        device = p.device, device_id = p.device_id,
    })
end

return Api
