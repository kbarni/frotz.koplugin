-- monoface.lua — builds the typewriter faces (Courier Prime) used for the
-- transcript, status bar, and input line.
--
-- KOReader's Font:getFace() can only load fonts from directories it scans
-- (koreader/fonts + the external font dir); it won't take an arbitrary path,
-- so a plugin-bundled font has to be wrapped by hand. We build each FreeType
-- face ourselves but borrow a "donor" face (the bundled mono "infont") for two
-- things: the DPI-scaled pixel size, and KOReader's standard glyph-fallback
-- chain (Noto / CJK / symbols / box-drawing) for the few characters Courier
-- Prime lacks. The shape of each returned table mirrors ui/font.lua's face_obj.
--
-- getFaceSet() returns all four variants (regular / bold / italic / bolditalic).
-- They share identical monospace metrics, which is what lets styledscroll.lua
-- keep xtext's glyph positions (shaped against the regular face) while drawing
-- styled runs from a variant face. See styledscroll.lua and ptfwrap.lua.

local Font     = require("ui/font")
local Freetype = require("ffi/freetype")

-- Directory of THIS file, so the bundled fonts resolve regardless of cwd
-- (same trick as main.lua's binary lookup).
local _dir = debug.getinfo(1, "S").source:match("@(.+)/[^/]+$") or "."

local FONT_FILES = {
    regular    = _dir .. "/fonts/CourierPrime-Regular.ttf",
    bold       = _dir .. "/fonts/CourierPrime-Bold.ttf",
    italic     = _dir .. "/fonts/CourierPrime-Italic.ttf",
    bolditalic = _dir .. "/fonts/CourierPrime-BoldItalic.ttf",
}

-- Synthesized-bold strength: the same factor KOReader uses in
-- ui/font.lua (_completeFaceProperties). Only relevant to the regular face's
-- fallback synthesized bold; the real bold variants don't use it.
local BOLD_STRENGTH_FACTOR = 3/8

local M = {}

-- Build one FontFaceObj-compatible table from a font file at pixel size `px`,
-- borrowing `donor`'s fallback chain. Returns nil if the file can't be loaded.
local function build_face(path, px, orig_size, donor, hashkey)
    local ok, ftsize = pcall(Freetype.newFaceSize, path, px)
    if not ok then
        return nil
    end
    local face = {
        orig_font    = hashkey,
        realname     = path:match("[^/]+$"),
        size         = px,
        orig_size    = orig_size,
        ftsize       = ftsize,
        hash         = hashkey .. "/" .. px,
        is_real_bold = false,
        -- Enable kerning + ligatures, matching getFace's defaults.
        hb_features  = { "+kern", "+liga" },
    }
    face.embolden_half_strength = ftsize:getEmboldenHalfStrength(BOLD_STRENGTH_FACTOR)
    -- Glyph source for XText: our font for the primary glyphs (num 0), and
    -- KOReader's standard fallback chain (via the donor) for everything else.
    face.getFallbackFont = function(num)
        if not num or num == 0 then return face end
        return donor.getFallbackFont(num)
    end
    return face
end

-- Returns the regular Courier Prime face at `size` (DPI-scaled internally),
-- or the bundled mono ("infont") if the font file is missing.
function M.getFace(size)
    local donor = Font:getFace("infont", size)
    return build_face(FONT_FILES.regular, donor.size, donor.orig_size, donor,
                      "frotz_courierprime_regular") or donor
end

-- Returns { regular, bold, italic, bolditalic } at `size`. Any variant whose
-- file is missing falls back to the regular face (so styling degrades to plain
-- rather than failing).
function M.getFaceSet(size)
    local donor = Font:getFace("infont", size)
    local px, orig = donor.size, donor.orig_size
    local regular = build_face(FONT_FILES.regular, px, orig, donor,
                               "frotz_courierprime_regular") or donor
    local set = { regular = regular }
    set.bold       = build_face(FONT_FILES.bold,       px, orig, donor, "frotz_courierprime_bold")       or regular
    set.italic     = build_face(FONT_FILES.italic,     px, orig, donor, "frotz_courierprime_italic")     or regular
    set.bolditalic = build_face(FONT_FILES.bolditalic, px, orig, donor, "frotz_courierprime_bolditalic") or regular
    return set
end

return M
