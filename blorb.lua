-- blorb.lua — a minimal Blorb (IFF) resource reader.
--
-- RemGlk never sends pixels: an illustration arrives as
-- {"special":"image","image":N,...} and it is up to us to find resource N in
-- the game's Blorb container. A .zblorb / .gblorb IS the Blorb; a bare .z5 or
-- .ulx may have a sidecar .blb / .blorb next to it (see M.openFor).
--
-- Blorb is IFF: a FORM of type IFRS holding
--   RIdx  the resource index: count, then count × (usage, number, origin)
--   Fspc  the frontispiece (cover art) picture number
--   RDes  resource descriptions (alt text), Blorb 2.0
-- plus the resource chunks themselves, each addressed by its file offset. The
-- chunk's own type is the image format: "PNG ", "JPEG", or "Rect" (a
-- placeholder that carries only a size, no pixels).
--
-- Pure Lua (no KOReader deps) so it is unit-testable headless; nothing here
-- decodes pixels, it only locates bytes and reads image headers for dimensions.

local M = {}

-- A resource larger than this is refused rather than read into a Lua string:
-- these run on e-readers with little RAM, and no IF illustration is this big.
local MAX_RESOURCE_BYTES = 16 * 1024 * 1024
-- How far into a JPEG we look for the frame header (past any EXIF blob).
local JPEG_SCAN_BYTES    = 64 * 1024
-- Guards against a corrupt RDes count sending us on a long read.
local MAX_RDES_BYTES     = 1024 * 1024

local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end
M.be32 = be32

local function be16(s, i)
    local a, b = s:byte(i, i + 1)
    if not b then return nil end
    return a * 256 + b
end

local function read_at(fh, pos, n)
    if n <= 0 then return "" end
    if not fh:seek("set", pos) then return nil end
    local s = fh:read(n)
    if not s or #s < n then return nil end
    return s
end

-- ── Image header parsing (dimensions only) ──────────────────────────────────

local PNG_SIG = "\137PNG\r\n\26\n"

-- PNG: signature (8) + IHDR length (4) + "IHDR" (4) + width (4) + height (4).
local function png_dims(head)
    if #head < 24 or head:sub(1, 8) ~= PNG_SIG or head:sub(13, 16) ~= "IHDR" then
        return nil
    end
    return be32(head, 17), be32(head, 21)
end

-- JPEG: walk the marker segments to the first SOFn frame header, which carries
-- height then width as 16-bit fields. DHT (C4), JPG (C8) and DAC (CC) share the
-- C0-CF range but are not frame headers.
local function jpeg_dims(buf)
    if #buf < 4 or buf:byte(1) ~= 0xFF or buf:byte(2) ~= 0xD8 then return nil end
    local i = 3
    while i + 3 <= #buf do
        local marker = buf:byte(i + 1)
        if buf:byte(i) ~= 0xFF then return nil end
        if marker == 0xFF then           -- fill byte, skip it
            i = i + 1
        elseif marker >= 0xD0 and marker <= 0xD9 then   -- standalone markers
            i = i + 2
        else
            local seg_len = be16(buf, i + 2)
            if not seg_len or seg_len < 2 then return nil end
            local is_sof = marker >= 0xC0 and marker <= 0xCF
                           and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC
            if is_sof then
                if i + 8 > #buf then return nil end
                return be16(buf, i + 7), be16(buf, i + 5)   -- width, height
            end
            i = i + 2 + seg_len
        end
    end
    return nil
end

-- ── The map ─────────────────────────────────────────────────────────────────

local Map = {}
Map.__index = Map

local FORMATS = { ["PNG "] = "png", ["JPEG"] = "jpeg", ["Rect"] = "rect", ["GIF "] = "gif" }

local function parse_ridx(map, data)
    local count = be32(data, 1)
    if not count then return end
    for n = 0, count - 1 do
        local base = 5 + n * 12
        if base + 11 > #data then break end
        local usage = data:sub(base, base + 3)
        local number = be32(data, base + 4)
        local origin = be32(data, base + 8)
        if usage == "Pict" and number and origin then
            if not map._pict[number] then
                map._pict[number] = { number = number, origin = origin }
                map._order[#map._order + 1] = number
            end
        end
    end
end

-- RDes: count, then count × (usage, number, text length, UTF-8 text).
local function parse_rdes(map, data)
    local count = be32(data, 1)
    if not count then return end
    local pos = 5
    for _ = 1, count do
        if pos + 11 > #data then break end
        local usage  = data:sub(pos, pos + 3)
        local number = be32(data, pos + 4)
        local len    = be32(data, pos + 8)
        pos = pos + 12
        if not len or pos + len - 1 > #data then break end
        if usage == "Pict" and number then
            map._alt[number] = data:sub(pos, pos + len - 1)
        end
        pos = pos + len
    end
end

-- Walk the top-level chunks of the IFRS form.
local function parse(fh, path)
    local header = read_at(fh, 0, 12)
    if not header then return nil, "too short" end
    if header:sub(1, 4) ~= "FORM" or header:sub(9, 12) ~= "IFRS" then
        return nil, "not a blorb"
    end
    local form_len = be32(header, 5) or 0
    local file_end = fh:seek("end")
    local limit = math.min(8 + form_len, file_end)

    local map = setmetatable({
        path    = path,
        cover   = nil,
        _pict   = {},   -- number → { number, origin, [format, offset, length, width, height] }
        _order  = {},   -- picture numbers in index order
        _alt    = {},   -- number → alt text
        _probed = {},   -- number → true once the resource header has been read
    }, Map)

    local pos = 12
    while pos + 8 <= limit do
        local chdr = read_at(fh, pos, 8)
        if not chdr then break end
        local ctype, clen = chdr:sub(1, 4), be32(chdr, 5)
        if not clen or clen < 0 then break end
        if ctype == "RIdx" and clen <= MAX_RDES_BYTES then
            local data = read_at(fh, pos + 8, clen)
            if data then parse_ridx(map, data) end
        elseif ctype == "RDes" and clen <= MAX_RDES_BYTES then
            local data = read_at(fh, pos + 8, clen)
            if data then parse_rdes(map, data) end
        elseif ctype == "Fspc" and clen >= 4 then
            local data = read_at(fh, pos + 8, 4)
            if data then map.cover = be32(data, 1) end
        end
        pos = pos + 8 + clen + (clen % 2)   -- IFF chunks are padded to even length
    end

    table.sort(map._order)
    if #map._order == 0 then return nil, "no pictures" end
    return map
end

-- Fill in format / data extent / dimensions for one picture, reading only its
-- chunk header and (for PNG/JPEG) the first bytes of the image. Cached.
local function probe(map, number)
    local rec = map._pict[number]
    if not rec or map._probed[number] then return rec end
    map._probed[number] = true

    local fh = io.open(map.path, "rb")
    if not fh then return rec end
    local chdr = read_at(fh, rec.origin, 8)
    if chdr then
        local ctype, clen = chdr:sub(1, 4), be32(chdr, 5)
        rec.chunktype = ctype
        rec.format    = FORMATS[ctype] or "unknown"
        rec.offset    = rec.origin + 8
        rec.length    = clen or 0
        if rec.format == "rect" then
            local d = read_at(fh, rec.offset, 8)
            if d then rec.width, rec.height = be32(d, 1), be32(d, 5) end
        elseif rec.format == "png" then
            local head = read_at(fh, rec.offset, math.min(rec.length, 24))
            if head then rec.width, rec.height = png_dims(head) end
        elseif rec.format == "jpeg" then
            local buf = read_at(fh, rec.offset, math.min(rec.length, JPEG_SCAN_BYTES))
            if buf then rec.width, rec.height = jpeg_dims(buf) end
        end
    end
    fh:close()
    return rec
end

--- Picture resource numbers present in the file, ascending.
function Map:pictures()
    local out = {}
    for i, n in ipairs(self._order) do out[i] = n end
    return out
end

function Map:has(number)
    return self._pict[number] ~= nil
end

--- Metadata for one picture: { number, format, offset, length, width, height, alt }.
--- width/height may be nil when the format is unrecognised.
function Map:info(number)
    local rec = probe(self, number)
    if not rec then return nil end
    return {
        number = rec.number,
        format = rec.format,
        offset = rec.offset,
        length = rec.length,
        width  = rec.width,
        height = rec.height,
        alt    = self._alt[number],
    }
end

--- The raw image bytes (PNG/JPEG), or nil for a placeholder / oversized resource.
function Map:data(number)
    local rec = probe(self, number)
    if not rec or not rec.offset then return nil, "unknown resource" end
    if rec.format == "rect" then return nil, "placeholder resource" end
    if rec.length <= 0 then return nil, "empty resource" end
    if rec.length > MAX_RESOURCE_BYTES then return nil, "resource too large" end
    local fh = io.open(self.path, "rb")
    if not fh then return nil, "cannot open " .. tostring(self.path) end
    local bytes = read_at(fh, rec.offset, rec.length)
    fh:close()
    if not bytes then return nil, "short read" end
    return bytes
end

-- ── Opening ─────────────────────────────────────────────────────────────────

--- Open `path` as a Blorb. Returns the map, or nil plus a reason.
function M.open(path)
    if not path then return nil, "no path" end
    local fh = io.open(path, "rb")
    if not fh then return nil, "cannot open" end
    local ok, map, err = pcall(parse, fh, path)
    fh:close()
    if not ok then return nil, tostring(map) end
    return map, err
end

--- Open the Blorb belonging to a game file: the game file itself when it is one
--- (.zblorb/.gblorb), else a sidecar next to it. Returns nil when there is none.
function M.openFor(game_path)
    if not game_path then return nil, "no path" end
    local map, err = M.open(game_path)
    if map then return map end

    local stem = game_path:match("^(.*)%.[^.]*$") or game_path
    for _, cand in ipairs({ stem .. ".blb", stem .. ".blorb", game_path .. ".blb" }) do
        local m = M.open(cand)
        if m then return m end
    end
    return nil, err
end

return M
