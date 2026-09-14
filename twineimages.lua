-- twineimages.lua — a Twine story's pictures, behind the same interface as a
-- Blorb map (blorb.lua: has / info / data / cover), so imagestore.lua's policy,
-- placeholders, gallery and viewer work for Twine unchanged.
--
-- A Twine story has no Blorb. Its player (twine/images.js) resolves every image
-- to an absolute file path — a file beside the story, or a data: image it
-- decoded into a cache folder — or to a remote URL, numbers it, and puts both on
-- each image span. We learn pictures from those spans (register), read only
-- file headers for format and size, and read the bytes when one is opened.
--
-- Pure Lua (no KOReader requires), headless-testable.

local Blorb = require("blorb")

local M = {}

-- As in blorb.lua: refuse to read a huge file into a Lua string.
local MAX_BYTES  = 16 * 1024 * 1024
-- Enough for a JPEG frame header past its EXIF block.
local HEAD_BYTES = 64 * 1024

local function le16(s, i)
    local a, b = s:byte(i, i + 1)
    if not b then return nil end
    return a + b * 256
end

local function le24(s, i)
    local a, b, c = s:byte(i, i + 2)
    if not c then return nil end
    return a + b * 256 + c * 65536
end

--- Format and pixel size from the first bytes of an image file:
--- "png" | "jpeg" | "gif" | "webp" | "svg" | "unknown", width, height.
function M.sniff(head)
    if type(head) ~= "string" or #head < 4 then return "unknown" end
    if head:sub(1, 8) == "\137PNG\r\n\26\n" then
        return "png", Blorb.png_dims(head)
    end
    if head:byte(1) == 0xFF and head:byte(2) == 0xD8 then
        return "jpeg", Blorb.jpeg_dims(head)
    end
    if head:sub(1, 4) == "GIF8" then
        return "gif", le16(head, 7), le16(head, 9)
    end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
        local chunk = head:sub(13, 16)
        if chunk == "VP8 " and #head >= 30 then
            return "webp", le16(head, 27) % 16384, le16(head, 29) % 16384
        elseif chunk == "VP8L" and #head >= 25 then
            local b0, b1, b2, b3 = head:byte(22, 25)
            return "webp", 1 + b0 + (b1 % 64) * 256,
                           1 + math.floor(b1 / 64) + b2 * 4 + (b3 % 16) * 1024
        elseif chunk == "VP8X" and #head >= 30 then
            return "webp", 1 + le24(head, 25), 1 + le24(head, 28)
        end
        return "webp"
    end
    if head:sub(1, 512):lower():find("<svg", 1, true) then return "svg" end
    return "unknown"
end

local Map = {}
Map.__index = Map

function M.new()
    return setmetatable({ _pict = {} }, Map)
end

--- Learn a picture from an image span { image = N, url = ..., alttext = ... }.
function Map:register(span)
    local n = type(span) == "table" and span.image
    if type(n) ~= "number" or type(span.url) ~= "string" then return end
    local rec = self._pict[n]
    if not rec or rec.url ~= span.url then
        rec = { number = n, url = span.url }
        self._pict[n] = rec
    end
    -- The first alt text wins: the same file used again as a link's picture
    -- carries the link's label, which would be a poor caption.
    if not rec.alt and type(span.alttext) == "string" and span.alttext ~= "" then
        rec.alt = span.alttext
    end
end

-- Fill in format / size / length for one picture. Cached.
local function probe(rec)
    if rec.format then return rec end
    if rec.url:match("^%a[%w+.-]*://") then
        rec.format = "remote"
        return rec
    end
    local fh = io.open(rec.url, "rb")
    if not fh then
        rec.format = "missing"
        return rec
    end
    local head = fh:read(HEAD_BYTES)
    rec.length = fh:seek("end")
    fh:close()
    rec.format, rec.width, rec.height = M.sniff(head)
    return rec
end

function Map:has(number)
    return self._pict[number] ~= nil
end

--- { number, format, width, height, alt, url }; format is also "missing" (no
--- such file) or "remote" (a web address) — neither can be shown.
function Map:info(number)
    local rec = self._pict[number]
    if not rec then return nil end
    probe(rec)
    return {
        number = number,
        format = rec.format,
        width  = rec.width,
        height = rec.height,
        alt    = rec.alt,
        url    = rec.url,
    }
end

function Map:data(number)
    local rec = self._pict[number]
    if not rec then return nil, "unknown image" end
    probe(rec)
    if rec.format == "remote" then return nil, "the picture is on the web: " .. rec.url end
    if rec.format == "missing" then return nil, "file not found: " .. rec.url end
    if (rec.length or 0) > MAX_BYTES then return nil, "image too large" end
    local fh = io.open(rec.url, "rb")
    if not fh then return nil, "cannot open " .. rec.url end
    local bytes = fh:read("*a")
    fh:close()
    if not bytes or bytes == "" then return nil, "empty file" end
    return bytes
end

--- Whether any picture met so far can be opened (gates the Illustrations menu).
function Map:available()
    for _, rec in pairs(self._pict) do
        local f = probe(rec).format
        if f ~= "remote" and f ~= "missing" and f ~= "unknown" then return true end
    end
    return false
end

return M
