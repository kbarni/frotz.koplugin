-- imagestore.lua — the plugin's illustration policy and viewer.
--
-- RemGlk hands us image *spans* carrying only a Blorb resource number (see
-- engines/remglk.lua); blorb.lua turns that number into bytes. This module sits
-- between them and answers two questions:
--
--   1. Is this image worth a line of transcript?  Games redraw ornaments — an
--      icon before every room name, a divider rule, a border — on every single
--      move, and a placeholder per move would drown the story. classify() keeps
--      the first sighting of a real picture, turns wide-and-flat images into a
--      text rule, and drops small or already-seen ones. Everything still
--      reaches the menu's illustration list, so nothing is truly lost.
--   2. How do we show it?  On demand only: we never hold a decoded image, we
--      decode when the player opens one and hand ownership to the ImageViewer.
--
-- Placeholders carry their own resource number ("[Illustration 3]"), so a tap
-- on a transcript line can recover which image it means with parseLabel() —
-- no bookkeeping that has to survive word-wrap and pagination.
--
-- KOReader modules are required lazily so this file loads under the headless
-- harness; classify()/label()/parseLabel() are pure.

local Blorb = require("blorb")
local ptf   = require("ptfwrap")

local M = {}

-- An image no larger than this in either direction is an ornament (bullet,
-- icon, rule cap), not an illustration.
local SMALL_MAX_PX        = 64
-- Margin-floated images are decorative sidebar art by authorial intent, so they
-- have to be bigger before we treat them as content.
local MARGIN_SMALL_MAX_PX = 128
-- Wide and flat is a divider, not a picture: render it as a text rule.
local RULE_MIN_ASPECT     = 8
local RULE_MAX_HEIGHT_PX  = 20
local RULE_MAX_COLS       = 24

-- Decode target: a fit-preserving box this many screens across, so the viewer
-- can zoom without us holding the full-resolution bitmap of a 4000px scan.
local DECODE_SCREENS      = 2

M.MODES = { "off", "notable", "all" }

--- Coerce a stored/unknown value to a valid mode.
function M.toMode(mode)
    for _, m in ipairs(M.MODES) do
        if m == mode then return m end
    end
    return "notable"
end

-- ── Pure policy ─────────────────────────────────────────────────────────────

--- Decide what an image span becomes in the transcript.
-- @param width,height  pixel size (VM-requested if given, else native); may be nil
-- @param alignment     RemGlk span alignment ("inlineup", "marginleft", …)
-- @param seen_count    how many times this resource has appeared before now
-- @param mode          "off" | "notable" | "all"
-- @return "show" | "rule" | "skip"
function M.classify(width, height, alignment, seen_count, mode)
    if mode == "off" then return "skip" end
    if width and height and width > 0 and height > 0 then
        if width / height >= RULE_MIN_ASPECT and height <= RULE_MAX_HEIGHT_PX then
            return "rule"
        end
        if mode ~= "all" then
            local margin = alignment == "marginleft" or alignment == "marginright"
            local limit  = margin and MARGIN_SMALL_MAX_PX or SMALL_MAX_PX
            if math.max(width, height) < limit then return "skip" end
        end
    end
    if mode ~= "all" and (seen_count or 0) > 0 then return "skip" end
    return "show"
end

local function truncate(text, max_chars)
    if not max_chars then return text end
    local chars = ptf.split_chars(text)
    if #chars <= max_chars then return text end
    local kept = {}
    for i = 1, math.max(1, max_chars - 2) do kept[i] = chars[i] end
    return table.concat(kept) .. "…]"
end

--- The transcript placeholder for one image. The resource number is part of the
--- text on purpose — parseLabel() reads it back out of the rendered line.
function M.label(number, alt, is_cover, max_chars)
    local name = is_cover and "Cover art" or "Illustration"
    if alt and alt ~= "" then
        alt = alt:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
        return truncate(("[%s %d: %s]"):format(name, number, alt), max_chars)
    end
    return ("[%s %d]"):format(name, number)
end

--- Slice one rendered line out of a widget's character array. Offsets come from
--- TextBoxWidget's line list and are clamped, since a stale or out-of-range pair
--- must return nothing rather than raise.
function M.lineText(chars, from, to)
    if type(chars) ~= "table" or type(from) ~= "number" or type(to) ~= "number" then
        return nil
    end
    if from < 1 then from = 1 end
    if to > #chars then to = #chars end
    if from > to then return nil end
    return table.concat(chars, "", from, to)
end

--- Recover the resource number from a rendered transcript line, or nil.
function M.parseLabel(line)
    if not line then return nil end
    return tonumber(line:match("^%s*%[[%a][%a ]* (%d+)[%]:]"))
end

function M.rule(max_chars)
    return ("─"):rep(math.min(max_chars or RULE_MAX_COLS, RULE_MAX_COLS))
end

-- ── The store ───────────────────────────────────────────────────────────────

local ImageStore = {}
ImageStore.__index = ImageStore

--- @param o { game_path = string, max_width = columns, mode = string }
function M.new(o)
    o = o or {}
    local self = setmetatable({
        max_width = o.max_width,
        mode      = M.toMode(o.mode),
        _count    = {},   -- resource → times seen in the story so far
        _kind     = {},   -- resource → "show" | "rule" (last classification)
        _order    = {},   -- resources in order of first appearance
    }, ImageStore)
    self.map = Blorb.openFor(o.game_path)
    return self
end

function ImageStore:isAvailable()
    return self.map ~= nil
end

function ImageStore:setMode(mode)
    self.mode = M.toMode(mode)
end

--- Called for every image span the VM emits (see the engine's image_hook).
--- Returns the replacement text and its Glk style, or nil to drop the image.
function ImageStore:describe(span)
    local number = span and span.image
    if not number or not self.map then return nil end

    local info = self.map:info(number)
    if not info then return nil end

    local seen = self._count[number] or 0
    if seen == 0 then self._order[#self._order + 1] = number end
    self._count[number] = seen + 1

    -- A Rect resource reserves space but holds no pixels: there would be
    -- nothing behind the placeholder, so say nothing.
    if info.format == "rect" then return nil end

    -- The VM's requested size is what the player would have seen; fall back to
    -- the image's own size when the game draws it unscaled.
    local w = (span.width  and span.width  > 0) and span.width  or info.width
    local h = (span.height and span.height > 0) and span.height or info.height

    local class = M.classify(w, h, span.alignment, seen, self.mode)
    self._kind[number] = class

    if class == "rule" then
        return M.rule(self.max_width), "normal"
    elseif class == "show" then
        local is_cover = (self.map.cover == number)
        return M.label(number, info.alt, is_cover, self.max_width), "emphasized"
    end
    return nil
end

--- Illustrations the player could open: the cover, plus every picture the story
--- has actually drawn (dividers and pixel-less placeholders excluded). Unseen
--- pictures are deliberately not listed — the gallery should not spoil art the
--- game has not reached yet.
function ImageStore:list()
    if not self.map then return {} end
    local out, added = {}, {}
    local cover = self.map.cover
    if cover and self.map:has(cover) then
        local info = self.map:info(cover)
        out[#out + 1] = { number = cover, is_cover = true,
                          label = M.label(cover, info and info.alt, true) }
        added[cover] = true
    end
    for _, n in ipairs(self._order) do
        if not added[n] and self._kind[n] ~= "rule" and self:isViewable(n) then
            local info = self.map:info(n)
            out[#out + 1] = { number = n, is_cover = false,
                              label = M.label(n, info and info.alt, false) }
            added[n] = true
        end
    end
    return out
end

--- Whether this resource is something we can put on screen.
function ImageStore:isViewable(number)
    if not (self.map and number and self.map:has(number)) then return false end
    local info = self.map:info(number)
    return info ~= nil and info.format ~= "rect" and info.format ~= "unknown"
end

-- Fit (w,h) inside (max_w,max_h) without upscaling or distorting.
local function fit(w, h, max_w, max_h)
    local scale = math.min(max_w / w, max_h / h, 1)
    return math.max(1, math.floor(w * scale)), math.max(1, math.floor(h * scale))
end

--- Decode one picture to a BlitBuffer the caller then owns. Returns nil, err.
function ImageStore:blitbuffer(number)
    if not self.map then return nil, "no illustrations in this game" end
    local data, err = self.map:data(number)
    if not data then return nil, err or "no image data" end

    local RenderImage = require("ui/renderimage")
    local Screen      = require("device").screen

    -- MuPDF scales to exactly the width/height it is given, so only pass a pair
    -- we computed ourselves from the real dimensions; otherwise decode native.
    local info = self.map:info(number)
    local w, h
    if info and info.width and info.height and info.width > 0 and info.height > 0 then
        w, h = fit(info.width, info.height,
                   Screen:getWidth() * DECODE_SCREENS, Screen:getHeight() * DECODE_SCREENS)
    end

    local bb = RenderImage:renderImageData(data, #data, false, w, h)
    if not bb then return nil, "could not decode image" end
    return bb
end

--- Open one picture full-screen. Returns true, or false plus a reason.
function ImageStore:view(number)
    local bb, err = self:blitbuffer(number)
    if not bb then return false, err end

    local ImageViewer = require("ui/widget/imageviewer")
    local UIManager   = require("ui/uimanager")
    local info = self.map:info(number)
    UIManager:show(ImageViewer:new{
        image            = bb,
        image_disposable = true,
        modal            = true,
        fullscreen       = true,
        with_title_bar   = true,
        title_text       = M.label(number, nil, self.map.cover == number),
        caption          = info and info.alt or nil,
    })
    return true
end

return M
