-- engines/resolver.lua — file extension → interpreter VM mapping.
--
-- One RemGlk protocol, selected purely by extension:
--   bocfel — Z-machine  (.z1–.z8, .zblorb, .dat)
--   git    — Glulx      (.ulx, .gblorb, .blb)
--   twine  — Twine HTML (.html, .htm), played by qjs + twine/player.js, which
--            speaks the same JSON (the binary is "qjs", see main.lua). The
--            extension is not enough here: is_twine_file checks the content.
-- This is a pure module (no KOReader requires) so it is unit-testable headless;
-- main.lua layers the arch/filesystem binary lookup on top.

local Resolver = {}

-- is_twine_file reads this much at a time, keeping OVERLAP bytes of the previous
-- chunk so a marker split between two reads is still found. The story data sits
-- after the format's runtime (seen up to ~250 KB in), so there is no safe prefix
-- length: the whole file is scanned, up to MAX_SCAN.
local CHUNK    = 64 * 1024
local OVERLAP  = 512
local MAX_SCAN = 16 * 1024 * 1024

-- Lowercased extension → VM binary name.
Resolver.VM_BY_EXT = {
    -- Z-machine → bocfel
    z1 = "bocfel", z2 = "bocfel", z3 = "bocfel", z4 = "bocfel",
    z5 = "bocfel", z6 = "bocfel", z7 = "bocfel", z8 = "bocfel",
    zblorb = "bocfel", zlb = "bocfel", dat = "bocfel",
    -- Glulx → git
    ulx = "git", gblorb = "git", glb = "git", blb = "git", blorb = "git",
    -- Twine (only an HTML file holding a story is a game: is_twine_file)
    html = "twine", htm = "twine",
}

-- The lowercased extension of a filename/path, or nil.
function Resolver.ext_of(filename)
    if type(filename) ~= "string" then return nil end
    local ext = filename:match("%.([^.\\/]+)$")
    return ext and ext:lower() or nil
end

-- The VM binary name for a file, or nil if the extension is not supported.
function Resolver.vm_for(filename)
    local ext = Resolver.ext_of(filename)
    return ext and Resolver.VM_BY_EXT[ext] or nil
end

-- Whether this file is a game we can open.
function Resolver.is_supported(filename)
    return Resolver.vm_for(filename) ~= nil
end

--- Whether HTML text holds a Twine story, by the markers the player extracts
--- (twine/extract.js): Twine 2's <tw-storydata>, or Twine 1's story area, a
--- <div id="storeArea"> ("store-area" when SugarCube 2 compiled it).
function Resolver.has_twine_marker(text)
    if type(text) ~= "string" then return false end
    if text:find("<tw-storydata", 1, true) then return true end
    local lower = text:lower()
    local from = 1
    while true do
        local s, e = lower:find("id%s*=%s*[\"']?store%-?area", from)
        if not s then return false end
        -- …as an attribute of a <div> tag.
        if lower:sub(math.max(1, s - 512), s - 1):match("<(%w+)[^<>]*$") == "div" then
            return true
        end
        from = e + 1
    end
end

--- Whether the file at `path` is a Twine story: true / false, or nil plus a
--- reason when it can't be read. Stops reading at the first marker.
function Resolver.is_twine_file(path)
    local fh = type(path) == "string" and io.open(path, "rb")
    if not fh then return nil, "cannot open" end
    local tail, read = "", 0
    while read < MAX_SCAN do
        local chunk = fh:read(CHUNK)
        if not chunk then break end
        read = read + #chunk
        if Resolver.has_twine_marker(tail .. chunk) then
            fh:close()
            return true
        end
        tail = chunk:sub(-OVERLAP)
    end
    fh:close()
    return false
end

return Resolver
