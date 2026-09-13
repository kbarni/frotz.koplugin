-- netfetch.lua — HTTP(S) GET for the IFDB browser, into memory or into a file.
--
-- Plain LuaSocket/LuaSec with KOReader's socketutil timeouts. Redirects are
-- followed here rather than by LuaSocket, because LuaSocket skips 308 and
-- would write a redirect's own body into the file sink. IF Archive links
-- always redirect (ifarchive.org → a regional mirror), and some old
-- http:// links redirect to https.
--
-- No UI: the browser calls these inside Trapper:dismissableRunInSubprocess, so
-- a slow download can be cancelled without freezing the screen.

local http       = require("socket.http")
local socket     = require("socket")
local socketutil = require("socketutil")
local url        = require("socket.url")

local M = {}

local MAX_REDIRECTS = 5
local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

-- One GET per hop; make_sink() supplies a fresh sink each time so a redirect's
-- body never ends up in the result.
local function fetch(u, make_sink, block_timeout, total_timeout)
    socketutil:set_timeout(block_timeout, total_timeout)
    local code, headers, status
    for _ = 0, MAX_REDIRECTS do
        local sink, err = make_sink()
        if not sink then
            socketutil:reset_timeout()
            return nil, err
        end
        code, headers, status = socket.skip(1, http.request{
            url      = u,
            method   = "GET",
            sink     = sink,
            redirect = false,
            headers  = { ["Accept-Encoding"] = "identity" },
        })
        if REDIRECT[code] and headers and headers.location then
            u = url.absolute(u, headers.location)
        else
            break
        end
    end
    socketutil:reset_timeout()

    if code == 200 then return true end
    if type(code) ~= "number" then
        return nil, tostring(code or status or "network unreachable")
    end
    if REDIRECT[code] then return nil, "too many redirects" end
    return nil, status and status:gsub("^HTTP/[%d.]+%s*", "") or ("HTTP " .. code)
end

--- GET a URL into memory. Returns the body, or nil and an error string.
function M.get(u)
    local chunks
    local ok, err = fetch(u, function()
        chunks = {}
        return socketutil.table_sink(chunks)
    end, socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    if not ok then return nil, err end
    return table.concat(chunks)
end

--- GET a URL into a file. Writes <path>.part and renames it on success, so a
--- failed or killed download never leaves a truncated game under the real
--- name. No total timeout — big story files over slow e-reader Wi-Fi take
--- a while, and the user can cancel — only the per-read one.
-- @return true, or nil and an error string
function M.download(u, path)
    local part = path .. ".part"
    local handle
    local ok, err = fetch(u, function()
        if handle then pcall(handle.close, handle) end
        local h, ioerr = io.open(part, "wb")
        handle = h
        if not h then return nil, ioerr end
        return socketutil.file_sink(h)
    end, socketutil.FILE_BLOCK_TIMEOUT, -1)
    if handle then pcall(handle.close, handle) end
    if not ok then
        os.remove(part)
        return nil, err
    end
    os.remove(path)
    local renamed, rerr = os.rename(part, path)
    if not renamed then
        os.remove(part)
        return nil, rerr
    end
    return true
end

return M
