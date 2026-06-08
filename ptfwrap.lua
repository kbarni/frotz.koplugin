-- ptfwrap.lua — styled story runs → monospace, word-wrapped text with KOReader
-- "Poor Text Formatting" (PTF) bold markers. Pure Lua (no KOReader deps) so it is
-- unit-testable headless.
--
-- KOReader's TextBoxWidget renders a single face, but supports inline *bold* via
-- three private markers when the text starts with PTF_HEADER:
--   PTF_HEADER (U+FFF1) at index 1 enables PTF parsing,
--   PTF_BOLD_START (U+FFF2) / PTF_BOLD_END (U+FFF3) bracket bold spans.
-- The widget strips these and renders the bracketed chars bold (synthetic bold
-- under xtext). There is no inline italic/face switch, so on our all-monospace
-- transcript the Glk style map (plan §4a) collapses to:
--   header / subheader / alert / emphasized → bold
--   preformatted                            → already monospace (normal)
--   everything else                         → normal
-- (blockquote indent / inline color are deferred.)
--
-- We insert bold markers, word-wrap to a column count (markers are zero-width and
-- never counted), and RE-BALANCE bold per physical line: each output line opens
-- and closes its own bold span. That keeps a bold run from leaking across a wrap
-- or — crucially — across a pagination page boundary (the UI reveals lines a page
-- at a time, so an unclosed span would bold the rest of the transcript).

local M = {}

M.PTF_HEADER      = "\239\191\177"  -- U+FFF1
M.PTF_BOLD_START  = "\239\191\178"  -- U+FFF2
M.PTF_BOLD_END    = "\239\191\179"  -- U+FFF3

-- Glk styles that map to bold on a monospace e-ink transcript.
M.BOLD_STYLES = {
    header = true, subheader = true, alert = true, emphasized = true,
}

-- Split a UTF-8 string into a list of characters (each multibyte char as one
-- element). Pure pattern-based; good enough for the regular text RemGlk emits.
local function split_chars(s)
    local t = {}
    -- One ASCII byte, or a UTF-8 lead byte followed by its continuation bytes.
    -- (Range starts at \1: Lua 5.1's pattern parser mishandles an embedded \0,
    -- and RemGlk story text never contains null bytes.)
    for c in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
        t[#t + 1] = c
    end
    return t
end
M.split_chars = split_chars

-- Flatten an engine Update's story runs into a marked string: bold styles get
-- PTF bold markers, the VM's echoed command ("input" style) is dropped (the UI
-- echoes it itself). Returns a plain string with inline U+FFF2/U+FFF3 markers.
function M.runs_to_marked(story)
    if not story then return "" end
    local out = {}
    for _, run in ipairs(story) do
        if run.style ~= "input" and run.text then
            if M.BOLD_STYLES[run.style] then
                out[#out + 1] = M.PTF_BOLD_START
                out[#out + 1] = run.text
                out[#out + 1] = M.PTF_BOLD_END
            else
                out[#out + 1] = run.text
            end
        end
    end
    return table.concat(out)
end

-- Word-wrap `marked` (a string with inline bold markers) to `cols` monospace
-- columns, preserving paragraph breaks ("\n") and balancing bold per line.
-- Returns a string of wrapped lines joined by "\n", each line self-contained
-- w.r.t. its bold markers.
function M.wrap(marked, cols)
    cols = cols or 64
    marked = marked:gsub("\r", "")

    -- Decode to tokens {ch, bold}, stripping the markers and tracking bold state.
    local toks, bold = {}, false
    for _, c in ipairs(split_chars(marked)) do
        if c == M.PTF_BOLD_START then
            bold = true
        elseif c == M.PTF_BOLD_END then
            bold = false
        else
            toks[#toks + 1] = { ch = c, b = bold }
        end
    end

    -- Greedy word-wrap over tokens; column count = number of (visible) chars.
    local lines = {}            -- each line is a list of tokens
    local line, line_len = {}, 0
    local word, word_len = {}, 0

    local function emit_line()
        lines[#lines + 1] = line
        line, line_len = {}, 0
    end
    local function take_word()
        if word_len == 0 then return end
        if line_len > 0 and line_len + 1 + word_len > cols then
            emit_line()
        end
        if line_len > 0 then
            line[#line + 1] = { ch = " ", b = false }
            line_len = line_len + 1
        end
        for _, t in ipairs(word) do line[#line + 1] = t end
        line_len = line_len + word_len
        word, word_len = {}, 0
    end

    for _, t in ipairs(toks) do
        if t.ch == "\n" then
            take_word()
            emit_line()
        elseif t.ch == " " or t.ch == "\t" then
            take_word()
        else
            word[#word + 1] = t
            word_len = word_len + 1
            -- Hard-break a word longer than the whole line width.
            if word_len >= cols then
                if line_len > 0 then emit_line() end
                for _, wt in ipairs(word) do line[#line + 1] = wt end
                line_len = word_len
                word, word_len = {}, 0
                emit_line()
            end
        end
    end
    take_word()
    if line_len > 0 then emit_line() end

    -- Render each line, opening/closing bold within the line only.
    local rendered = {}
    for _, ln in ipairs(lines) do
        local parts, cur = {}, false
        for _, t in ipairs(ln) do
            if t.b and not cur then
                parts[#parts + 1] = M.PTF_BOLD_START; cur = true
            elseif (not t.b) and cur then
                parts[#parts + 1] = M.PTF_BOLD_END; cur = false
            end
            parts[#parts + 1] = t.ch
        end
        if cur then parts[#parts + 1] = M.PTF_BOLD_END end
        rendered[#rendered + 1] = table.concat(parts)
    end
    return table.concat(rendered, "\n")
end

return M
