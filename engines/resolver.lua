-- engines/resolver.lua — file extension → interpreter VM mapping.
--
-- One RemGlk protocol, selected purely by extension:
--   bocfel — Z-machine  (.z1–.z8, .zblorb, .dat)
--   git    — Glulx      (.ulx, .gblorb, .blb)
--   twine  — Twine HTML (.html, .htm), played by qjs + twine/player.js, which
--            speaks the same JSON (the binary is "qjs", see main.lua)
-- This is a pure module (no KOReader requires) so it is unit-testable headless;
-- main.lua layers the arch/filesystem binary lookup on top.

local Resolver = {}

-- Lowercased extension → VM binary name.
Resolver.VM_BY_EXT = {
    -- Z-machine → bocfel
    z1 = "bocfel", z2 = "bocfel", z3 = "bocfel", z4 = "bocfel",
    z5 = "bocfel", z6 = "bocfel", z7 = "bocfel", z8 = "bocfel",
    zblorb = "bocfel", zlb = "bocfel", dat = "bocfel",
    -- Glulx → git
    ulx = "git", gblorb = "git", glb = "git", blb = "git", blorb = "git",
    -- Twine (any HTML file is offered; the player reports a non-Twine one)
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

return Resolver
