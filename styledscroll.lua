-- styledscroll.lua — a ScrollTextWidget that renders real bold / italic /
-- bolditalic inline, drawn from the four Courier Prime variants.
--
-- Why a subclass: KOReader's stock TextBoxWidget shapes the whole buffer with a
-- single face (XText takes one face) and only supports synthetic bold. We want
-- the genuine bold/italic cuts. The trick that makes this cheap: all four
-- Courier Prime variants are monospace with *identical* metrics, so XText's
-- glyph positions (shaped against the regular face) are valid for every variant.
-- So we let stock TextBoxWidget shape/lay out/word-wrap/scroll/word-lookup the
-- clean text as usual, and only override the glyph BLIT: for chars inside a
-- styled span we fetch the glyph from the matching variant face *by charcode*
-- (a fresh cmap lookup, since glyph IDs differ between the variant TTFs) and
-- place it at XText's computed position.
--
-- Style markers come from ptfwrap.lua (PTF_HEADER + bold/italic span markers).
-- We strip them before stock init so the stock (bold-only) PTF path is bypassed
-- and XText shapes clean text; we keep a per-char style + codepoint map aligned
-- with XText's text_index (1-based char position in the cleaned text).

local Blitbuffer    = require("ffi/blitbuffer")
local RenderText    = require("ui/rendertext")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local util          = require("util")
local Screen        = require("device").screen

local ptf = require("ptfwrap")

-- Decode a single UTF-8 character string to its Unicode codepoint.
local function utf8_codepoint(c)
    local b = c:byte(1)
    if not b then return 0xFFFD end
    if b < 0x80 then return b end
    local n, cp
    if     b >= 0xF0 then n, cp = 3, b % 0x08
    elseif b >= 0xE0 then n, cp = 2, b % 0x10
    elseif b >= 0xC0 then n, cp = 1, b % 0x20
    else return 0xFFFD end
    for k = 2, n + 1 do
        local cb = c:byte(k)
        if not cb then return 0xFFFD end
        cp = cp * 0x40 + (cb % 0x40)
    end
    return cp
end

-- ── StyledTextBox: TextBoxWidget with bold/italic span rendering ────────────

local StyledTextBox = TextBoxWidget:extend{
    -- { b = boldface, i = italicface, bi = bolditalicface }; set by StyledScroll.
    styled_faces = nil,
}

-- Parse our style markers out of self.text, building:
--   self._ptf_style[idx] = "b" | "i" | "bi"   (only for styled chars)
--   self._ptf_code[idx]  = codepoint          (only for styled chars)
-- keyed by 1-based char position in the cleaned text, and replace self.text with
-- the marker-free string. Mirrors stock TextBoxWidget's PTF stripping so idx
-- lines up with XText's xglyph.text_index.
function StyledTextBox:_parseStyleMarkers()
    local chars = util.splitToChars(self.text)
    table.remove(chars, 1)  -- drop PTF_HEADER

    local style, code = {}, {}
    local is_b, is_i = false, false
    local out, idx = {}, 0
    for _, ch in ipairs(chars) do
        if ch == ptf.PTF_BOLD_START then
            is_b = true
        elseif ch == ptf.PTF_BOLD_END then
            is_b = false
        elseif ch == ptf.PTF_ITALIC_START then
            is_i = true
        elseif ch == ptf.PTF_ITALIC_END then
            is_i = false
        else
            idx = idx + 1
            out[idx] = ch
            if is_b or is_i then
                style[idx] = is_b and (is_i and "bi" or "b") or "i"
                code[idx]  = utf8_codepoint(ch)
            end
        end
    end
    self.text = table.concat(out)
    self._ptf_style = style
    self._ptf_code  = code
    -- Keep the marker-free characters: `out[i]` lines up with XText's
    -- text_index (and with the charlist stock TextBoxWidget builds when XText
    -- is off), so a caller holding a line's offset/end_offset can slice the
    -- rendered text back out without touching XText internals — self.charlist
    -- is the XText userdata itself under use_xtext, not a table.
    self._ptf_chars = out
end

function StyledTextBox:init()
    if type(self.text) == "string"
            and self.text:sub(1, #ptf.PTF_HEADER) == ptf.PTF_HEADER then
        self:_parseStyleMarkers()
    end
    TextBoxWidget.init(self)
end

-- Returns the variant face for a style code, or the regular face (self.face)
-- if the variant isn't available.
function StyledTextBox:_styledFace(s)
    local f = self.styled_faces and self.styled_faces[s]
    return f or self.face
end

-- Override the glyph blit to draw styled chars from the variant faces. Adapted
-- from TextBoxWidget:_renderText (XText branch only); falls back to the stock
-- method when there's no styling to apply or XText is disabled.
function StyledTextBox:_renderText(start_row_idx, end_row_idx)
    if not (self._ptf_style and self.use_xtext) then
        return TextBoxWidget._renderText(self, start_row_idx, end_row_idx)
    end

    if start_row_idx < 1 then start_row_idx = 1 end
    if end_row_idx > #self.vertical_string_list then end_row_idx = #self.vertical_string_list end
    local row_count = end_row_idx == 0 and 1 or end_row_idx - start_row_idx + 1
    local h = self.height or self.line_height_px * row_count
    h = h + self.line_glyph_extra_height
    if self._bb then self._bb:free() end
    local bbtype = nil
    local color_fg = not Blitbuffer.isColor8(self.fgcolor)
    local color_bg = not Blitbuffer.isColor8(self.bgcolor)
    if (self.line_num_to_image and self.line_num_to_image[start_row_idx]) or color_fg or color_bg then
        bbtype = Screen:isColorEnabled() and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8
    end
    self._bb = Blitbuffer.new(self.width, h, bbtype)
    if not color_bg then
        self._bb:fill(self.bgcolor)
    else
        self._bb:paintRectRGB32(0, 0, self._bb:getWidth(), self._bb:getHeight(), self.bgcolor)
    end

    local y = self.line_glyph_baseline
    for i = start_row_idx, end_row_idx do
        local line = self.vertical_string_list[i]
        if self.line_with_ellipsis and i == self.line_with_ellipsis and not line.ellipsis_added then
            local ellipsis_width = RenderText:getEllipsisWidth(self.face)
            line.width = line.width + ellipsis_width
            if line.width > line.targeted_width then
                line = self._xtext:makeLine(line.offset, line.targeted_width - ellipsis_width, false, self._tabstop_width)
                self.vertical_string_list[i] = line
            end
            if line.end_offset and line.end_offset < #self._xtext then
                line.end_offset = line.end_offset + 1
                line.idx_to_substitute_with_ellipsis = line.end_offset
            end
            line.ellipsis_added = true
        end
        self:_shapeLine(line)
        if line.xglyphs then
            for _, xglyph in ipairs(line.xglyphs) do
                if not xglyph.no_drawing then
                    local s = self._ptf_style[xglyph.text_index]
                    local glyph
                    if s then
                        -- Styled run: draw from the variant face by charcode.
                        -- Positions stay valid because metrics are identical.
                        glyph = RenderText:getGlyph(self:_styledFace(s), self._ptf_code[xglyph.text_index], false)
                    else
                        local face = self.face.getFallbackFont(xglyph.font_num)
                        glyph = RenderText:getGlyphByIndex(face, xglyph.glyph, self.bold, false)
                    end
                    if glyph and glyph.bb then
                        local color = self.fgcolor
                        if self._alt_color_for_rtl then
                            color = xglyph.is_rtl and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
                        end
                        if not color_fg then
                            self._bb:colorblitFrom(glyph.bb,
                                        xglyph.x0 + glyph.l + xglyph.x_offset,
                                        y - glyph.t - xglyph.y_offset,
                                        0, 0, glyph.bb:getWidth(), glyph.bb:getHeight(), color)
                        else
                            self._bb:colorblitFromRGB32(glyph.bb,
                                        xglyph.x0 + glyph.l + xglyph.x_offset,
                                        y - glyph.t - xglyph.y_offset,
                                        0, 0, glyph.bb:getWidth(), glyph.bb:getHeight(), color)
                        end
                    end
                end
            end
        end
        y = y + self.line_height_px
    end
    self:_renderImage(start_row_idx)
    if self.highlight_rects then
        for _, rect in ipairs(self.highlight_rects) do
            self._bb:darkenRect(rect.x, rect.y, rect.w, rect.h, self.highlight_lighten_factor)
        end
    end
end

-- ── StyledScroll: ScrollTextWidget that builds a StyledTextBox ──────────────

local StyledScroll = ScrollTextWidget:extend{
    styled_faces = nil,
}

-- ScrollTextWidget:init() hardcodes `TextBoxWidget:new{...}` for its inner
-- widget. Rather than copy its whole init (scrollbar + gestures, version-
-- sensitive), we temporarily intercept TextBoxWidget construction so the inner
-- widget is a StyledTextBox carrying our face set. The swap is restored
-- immediately and only affects this one init call.
function StyledScroll:init()
    local faces = self.styled_faces
    -- Capture the resolved constructor (likely inherited from Widget) and build
    -- a StyledTextBox with it directly. We can't call StyledTextBox:new() from
    -- the override, because StyledTextBox inherits `new` from TextBoxWidget and
    -- would resolve right back to this override → infinite recursion.
    local orig_new = TextBoxWidget.new
    local had_own = rawget(TextBoxWidget, "new")
    rawset(TextBoxWidget, "new", function(_cls, o)
        o = o or {}
        o.styled_faces = faces
        return orig_new(StyledTextBox, o)
    end)
    local ok, err = pcall(ScrollTextWidget.init, self)
    if had_own ~= nil then
        rawset(TextBoxWidget, "new", had_own)
    else
        rawset(TextBoxWidget, "new", nil)
    end
    if not ok then error(err) end
end

StyledScroll.StyledTextBox = StyledTextBox
return StyledScroll
