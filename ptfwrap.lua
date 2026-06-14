-- ptfwrap.lua — styled story runs → monospace, word-wrapped text with inline
-- style markers (bold + italic). Pure Lua (no KOReader deps) so it is
-- unit-testable headless.
--
-- KOReader's stock TextBoxWidget only renders a single face and supports inline
-- *bold* via two private markers (synthetic bold). We need real bold AND italic
-- from the four Courier Prime variants, so the transcript is drawn by our
-- styledscroll.lua subclass instead, which understands a second marker pair for
-- italic. The markers live in the U+FFFx private area (never present in game
-- text); they are zero-width and balanced per physical line.
--
-- Glk style → look (on our monospace e-ink transcript):
--   header / subheader / alert → bold
--   emphasized                 → italic   (IF/typographic convention)
--   preformatted               → already monospace (normal)
--   everything else            → normal
-- (blockquote indent / inline color are deferred.)
--
-- We insert markers, word-wrap to a column count (markers are zero-width and
-- never counted), and RE-BALANCE each style per physical line: every output
-- line opens and closes its own bold/italic spans. That keeps a span from
-- leaking across a wrap or — crucially — across a pagination page boundary (the
-- UI reveals lines a page at a time, so an unclosed span would style the rest of
-- the transcript).

local M = {}

M.PTF_HEADER        = "\239\191\177"  -- U+FFF1  marks styled content
M.PTF_BOLD_START    = "\239\191\178"  -- U+FFF2
M.PTF_BOLD_END      = "\239\191\179"  -- U+FFF3
M.PTF_ITALIC_START  = "\239\191\180"  -- U+FFF4
M.PTF_ITALIC_END    = "\239\191\181"  -- U+FFF5

-- Glk styles that map to bold / italic on the monospace e-ink transcript.
M.BOLD_STYLES   = { header = true, subheader = true, alert = true }
M.ITALIC_STYLES = { emphasized = true }

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
-- bold markers, italic styles get italic markers, the VM's echoed command
-- ("input" style) is dropped (the UI echoes it itself). Returns a plain string
-- with inline U+FFF2..U+FFF5 markers.
function M.runs_to_marked(story)
    if not story then return "" end
    local out = {}
    for _, run in ipairs(story) do
        if run.style ~= "input" and run.text then
            if M.BOLD_STYLES[run.style] then
                out[#out + 1] = M.PTF_BOLD_START
                out[#out + 1] = run.text
                out[#out + 1] = M.PTF_BOLD_END
            elseif M.ITALIC_STYLES[run.style] then
                out[#out + 1] = M.PTF_ITALIC_START
                out[#out + 1] = run.text
                out[#out + 1] = M.PTF_ITALIC_END
            else
                out[#out + 1] = run.text
            end
        end
    end
    return table.concat(out)
end

-- Word-wrap `marked` (a string with inline bold/italic markers) to `cols`
-- monospace columns, preserving paragraph breaks ("\n") and balancing each
-- style per line. Returns a string of wrapped lines joined by "\n", each line
-- self-contained w.r.t. its style markers.
function M.wrap(marked, cols)
    cols = cols or 64
    marked = marked:gsub("\r", "")

    -- Decode to tokens {ch, b, i}, stripping markers and tracking style state.
    local toks, bold, ital = {}, false, false
    for _, c in ipairs(split_chars(marked)) do
        if c == M.PTF_BOLD_START then
            bold = true
        elseif c == M.PTF_BOLD_END then
            bold = false
        elseif c == M.PTF_ITALIC_START then
            ital = true
        elseif c == M.PTF_ITALIC_END then
            ital = false
        else
            toks[#toks + 1] = { ch = c, b = bold, i = ital }
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
            line[#line + 1] = { ch = " ", b = false, i = false }
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

    -- Render each line, opening/closing each style within the line only. Bold
    -- and italic are independent spans (a char can be both → bolditalic).
    local rendered = {}
    for _, ln in ipairs(lines) do
        local parts, cb, ci = {}, false, false
        for _, t in ipairs(ln) do
            if t.b and not cb then
                parts[#parts + 1] = M.PTF_BOLD_START; cb = true
            elseif (not t.b) and cb then
                parts[#parts + 1] = M.PTF_BOLD_END; cb = false
            end
            if t.i and not ci then
                parts[#parts + 1] = M.PTF_ITALIC_START; ci = true
            elseif (not t.i) and ci then
                parts[#parts + 1] = M.PTF_ITALIC_END; ci = false
            end
            parts[#parts + 1] = t.ch
        end
        if cb then parts[#parts + 1] = M.PTF_BOLD_END end
        if ci then parts[#parts + 1] = M.PTF_ITALIC_END end
        rendered[#rendered + 1] = table.concat(parts)
    end
    return table.concat(rendered, "\n")
end

return M
