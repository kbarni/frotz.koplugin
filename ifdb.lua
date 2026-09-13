-- ifdb.lua — the Interactive Fiction Database (ifdb.org), as data.
--
-- IFDB serves JSON on two public endpoints:
--   search?json&searchfor=<query>&sortby=<order>&pg=<page>   → {"games":[…]}
--   viewgame?json&id=<tuid>                                  → one full record
-- This module builds those URLs and queries and turns the replies into plain
-- tables the browser can show: deduplicated result rows, a game record, and
-- the download links we can actually play, best first.
--
-- Pure Lua (no KOReader requires) so the headless harness can run it against
-- recorded replies in notes/harness/fixtures/ifdb/. Decoding is the caller's
-- job (rapidjson on device, json_min in the harness); we take decoded tables
-- and never trust a field's type, because rapidjson turns JSON null into a
-- sentinel rather than nil.
--
-- Two IFDB quirks shape the query code (see notes/ifdb_downloader_plan.md §2.3):
--   * the `format:` filter wants wildcards — `format:*z-code*` / `format:*glulx*`
--     — to match blorb downloads as well as bare story files;
--   * free text combined with `format:` makes IFDB return {"error":…}, so only
--     filters-only queries get the format filter. Free-text results are
--     narrowed on our side by authoring system instead (isLikelySupported).

local M = {}

M.BASE      = "https://ifdb.org"
M.PAGE_SIZE = 100  -- IFDB's fixed page size; a full page means "maybe more"

-- Format choice → the IFDB filter that selects it.
M.FORMAT_FILTERS = {
    zcode = "format:*z-code*",
    glulx = "format:*glulx*",
}
M.FORMAT_CHOICES = { "both", "zcode", "glulx" }

-- Browse lists. IFDB returns nothing for an empty query, so each preset carries
-- at least the format filter (added by presetQueries).
M.PRESETS = {
    { id = "top",     filters = "#ratings:10-",              sortby = "ratu" },
    { id = "popular", filters = "",                          sortby = "rcu"  },
    { id = "new",     filters = "",                          sortby = "new"  },
    { id = "short",   filters = "playtime:-1h #ratings:3-",  sortby = "ratu" },
    { id = "random",  filters = "",                          sortby = "rand" },
}

-- Download-link formats that are a story file for one of our VMs, and the
-- extension we name the file with when the URL has none we recognise.
M.LINK_FORMATS = {
    ["zcode"]       = { ext = "z5",     vm = "bocfel", label = "Z-machine" },
    ["blorb/zcode"] = { ext = "zblorb", vm = "bocfel", label = "Z-machine, blorb" },
    ["glulx"]       = { ext = "ulx",    vm = "git",    label = "Glulx" },
    ["blorb/glulx"] = { ext = "gblorb", vm = "git",    label = "Glulx, blorb" },
}

-- Authoring systems that never produce Z-code or Glulx. Matched as whole words
-- against the lowercased `devsys`, so "ink" does not hit "Inform".
local UNSUPPORTED_SYSTEMS = {
    "tads", "adrift", "hugo", "alan", "twine", "quest", "choicescript", "ink",
    "inklewriter", "ren'py", "renpy", "adventuron", "texture", "squiffy",
    "undum", "raconteur", "ramus", "agt", "ags", "unity", "rpg maker",
}

-- ── small helpers ────────────────────────────────────────────────────────────

local function str(v)
    return type(v) == "string" and v or nil
end

local function num(v)
    if type(v) == "number" then return v end
    if type(v) == "string" then return tonumber(v) end
    return nil
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Percent-encode a query-string value (RFC 3986 unreserved characters kept).
function M.urlEncode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

--- Percent-decode (for filenames taken from URLs).
function M.urlDecode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- ── URLs and queries ─────────────────────────────────────────────────────────

function M.searchUrl(query, sortby, page)
    local u = M.BASE .. "/search?json&searchfor=" .. M.urlEncode(query)
    if sortby and sortby ~= "" then u = u .. "&sortby=" .. M.urlEncode(sortby) end
    if page and page > 1 then u = u .. "&pg=" .. page end
    return u
end

function M.viewgameUrl(tuid)
    return M.BASE .. "/viewgame?json&id=" .. M.urlEncode(tuid)
end

--- Split a query into terms, keeping double-quoted phrases (also `key:"a b"`)
--- together.
function M.tokenize(query)
    local terms, i, n = {}, 1, #query
    while i <= n do
        local s = query:find("%S", i)
        if not s then break end
        local j, in_quote = s, false
        while j <= n do
            local c = query:sub(j, j)
            if c == '"' then
                in_quote = not in_quote
            elseif not in_quote and c:match("%s") then
                break
            end
            j = j + 1
        end
        terms[#terms + 1] = query:sub(s, j - 1)
        i = j
    end
    return terms
end

--- True when every term is a `key:value` filter (optionally +/- prefixed), so
--- IFDB accepts a `format:` filter alongside it.
function M.isFiltersOnly(query)
    local terms = M.tokenize(query or "")
    if #terms == 0 then return false end
    for _, t in ipairs(terms) do
        if not t:match("^[+%-]?#?[%a]+:") then return false end
    end
    return true
end

--- Format choice → list of format keys to query.
local function formatsFor(choice)
    if choice == "zcode" or choice == "glulx" then return { choice } end
    return { "zcode", "glulx" }
end

--- The IFDB requests behind one user search. Returns a list of
--- { query = <searchfor>, format = <key or nil> } and whether the results are
--- already format-filtered by the server.
function M.searchQueries(text, format_choice)
    text = trim(text or "")
    if M.isFiltersOnly(text) then
        local out = {}
        for _, f in ipairs(formatsFor(format_choice)) do
            out[#out + 1] = { query = text .. " " .. M.FORMAT_FILTERS[f], format = f }
        end
        return out, true
    end
    return { { query = text .. " downloadable:yes" } }, false
end

--- The IFDB requests behind a browse preset.
function M.presetQueries(preset, format_choice)
    local out = {}
    for _, f in ipairs(formatsFor(format_choice)) do
        local q = M.FORMAT_FILTERS[f]
        if preset.filters ~= "" then q = q .. " " .. preset.filters end
        out[#out + 1] = { query = q, format = f }
    end
    return out
end

-- ── search results ───────────────────────────────────────────────────────────

--- Pull the message out of IFDB's {"error":"<p>…</p>"} reply.
local function errorText(decoded)
    local e = str(decoded.error)
    if not e then return nil end
    e = trim(M.stripHtml(e))
    return e ~= "" and e or "IFDB reported an error"
end

--- Normalise one search reply.
-- @return { games = {row…}, raw_count = n, has_more = bool } or nil, err
function M.parseSearch(decoded)
    if type(decoded) ~= "table" then return nil, "not an IFDB reply" end
    local err = errorText(decoded)
    if err then return nil, err end
    local list = decoded.games
    if type(list) ~= "table" then return nil, "not an IFDB reply" end

    local games, seen, raw = {}, {}, 0
    for _, g in ipairs(list) do
        raw = raw + 1
        local tuid = type(g) == "table" and str(g.tuid)
        if tuid and not seen[tuid] then
            seen[tuid] = true
            local pub = type(g.published) == "table" and g.published or {}
            games[#games + 1] = {
                tuid      = tuid,
                title     = str(g.title) or "?",
                author    = str(g.author),
                devsys    = str(g.devsys),
                published = str(pub.machine),
                year      = str(pub.machine) and pub.machine:match("^(%d%d%d%d)"),
                rating    = num(g.averageRating),
                stars     = num(g.starRating),
                star_sort = num(g.starSort),
                ratings   = num(g.numRatings) or 0,
                cover_url = str(g.coverArtLink),
            }
        end
    end
    return { games = games, raw_count = raw, has_more = raw >= M.PAGE_SIZE }
end

-- Sort keys for merging the Z-code and Glulx lists of a "both formats" view.
local MERGE_KEYS = {
    ratu = function(g) return g.star_sort or g.rating or 0 end,
    rcu  = function(g) return g.ratings or 0 end,
    new  = function(g) return g.published or "" end,
}

--- Merge several result lists into one, dropping games already listed.
--- Sorted orders are merged by their key; others (relevance, random) are
--- interleaved so neither format crowds out the other.
-- @param lists  list of row lists (from parseSearch)
-- @param seen   optional tuid set carried across pages; updated in place
function M.mergeResults(lists, sortby, seen)
    seen = seen or {}
    local out = {}
    local key = MERGE_KEYS[sortby]
    if key then
        local all, order = {}, {}
        for li, list in ipairs(lists) do
            for gi, g in ipairs(list) do
                all[#all + 1] = g
                order[g] = li * 100000 + gi
            end
        end
        table.sort(all, function(a, b)
            local ka, kb = key(a), key(b)
            if ka ~= kb then return ka > kb end
            return order[a] < order[b]
        end)
        for _, g in ipairs(all) do
            if not seen[g.tuid] then seen[g.tuid] = true; out[#out + 1] = g end
        end
    else
        local i, more = 1, true
        while more do
            more = false
            for _, list in ipairs(lists) do
                local g = list[i]
                if g then
                    more = true
                    if not seen[g.tuid] then seen[g.tuid] = true; out[#out + 1] = g end
                end
            end
            i = i + 1
        end
    end
    return out, seen
end

local function isUnsupportedSystem(name)
    local d = " " .. name:lower():gsub("[^%w']+", " ") .. " "
    for _, sys in ipairs(UNSUPPORTED_SYSTEMS) do
        if d:find(" " .. sys .. " ", 1, true) then return true end
    end
    return false
end

--- Whether a game's authoring system can produce Z-code or Glulx. Unknown or
--- custom systems count as yes: the detail screen gives the real answer. A
--- game listed under several systems ("TADS 2, Inform 6") is kept if any of
--- them might be ours.
function M.isLikelySupported(devsys)
    if not devsys or devsys == "" then return true end
    for part in devsys:gmatch("[^,/;]+") do
        if part:match("%S") and not isUnsupportedSystem(part) then return true end
    end
    return false
end

--- Split rows into those shown by default and those hidden by system.
function M.splitBySystem(games)
    local kept, hidden = {}, {}
    for _, g in ipairs(games) do
        if M.isLikelySupported(g.devsys) then kept[#kept + 1] = g
        else hidden[#hidden + 1] = g end
    end
    return kept, hidden
end

-- ── one game ─────────────────────────────────────────────────────────────────

--- Convert IFDB's description HTML to plain text. Fallback for the harness;
--- the UI prefers KOReader's util.htmlToPlainText.
function M.stripHtml(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("%s*<%s*[bB][rR]%s*/?>%s*", "\n")
    s = s:gsub("%s*</?%s*[pP]%s*/?>%s*", "\n\n")
    s = s:gsub("<[^>]*>", "")
    local entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }
    s = s:gsub("&(#?%w+);", function(e)
        if entities[e] then return entities[e] end
        local code = e:match("^#(%d+)$")
        if code then
            code = tonumber(code)
            if code < 0x80 then return string.char(code) end
            if code < 0x800 then
                return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
            end
            if code < 0x10000 then
                return string.char(0xE0 + math.floor(code / 0x1000),
                                   0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
            end
        end
        return "&" .. e .. ";"
    end)
    s = s:gsub("\n\n\n+", "\n\n")
    return trim(s)
end

--- The file name at the end of a URL (query and fragment dropped, decoded).
function M.urlFileName(url)
    local path = url:gsub("[?#].*$", ""):match("^%a[%w+.-]*://[^/]*(/.*)$") or ""
    local name = path:match("([^/]+)$")
    return name and M.urlDecode(name) or nil
end

local function extOf(name)
    local ext = name and name:match("%.([^.]+)$")
    return ext and ext:lower() or nil
end

--- Normalise a viewgame reply into a game record.
-- @return record or nil, err
function M.parseGame(decoded)
    if type(decoded) ~= "table" then return nil, "not an IFDB reply" end
    local err = errorText(decoded)
    if err then return nil, err end
    local bib = type(decoded.bibliographic) == "table" and decoded.bibliographic
    local db  = type(decoded.ifdb) == "table" and decoded.ifdb
    if not (bib and db) then return nil, "not an IFDB game record" end
    local ident = type(decoded.identification) == "table" and decoded.identification or {}

    local ifids = {}
    if type(ident.ifids) == "table" then
        for _, id in ipairs(ident.ifids) do
            if str(id) then ifids[#ifids + 1] = id end
        end
    end

    -- Tags, most widely used first: "puzzle" before one-off tags like "bottle".
    local tags = {}
    if type(db.tags) == "table" then
        for i, t in ipairs(db.tags) do
            if type(t) == "table" and str(t.name) then
                tags[#tags + 1] = { name = t.name, games = num(t.gamecnt) or 0, i = i }
            end
        end
        table.sort(tags, function(a, b)
            if a.games ~= b.games then return a.games > b.games end
            return a.i < b.i
        end)
    end

    local links = {}
    local downloads = type(db.downloads) == "table" and db.downloads
    if downloads and type(downloads.links) == "table" then
        for _, l in ipairs(downloads.links) do
            if type(l) == "table" and str(l.url) then
                links[#links + 1] = {
                    url     = l.url,
                    title   = str(l.title),
                    desc    = str(l.desc),
                    format  = str(l.format),
                    is_game = l.isGame == true,
                }
            end
        end
    end

    local cover = type(db.coverart) == "table" and str(db.coverart.url)
    local published = str(bib.firstpublished)
    return {
        tuid        = str(db.tuid),
        title       = str(bib.title) or "?",
        author      = str(bib.author),
        language    = str(bib.language),
        published   = published,
        year        = published and published:match("(%d%d%d%d)"),
        genre       = str(bib.genre),
        description = str(bib.description),
        ifids       = ifids,
        format      = str(ident.format),
        rating      = num(db.averageRating),
        stars       = num(db.starRating),
        ratings     = num(db.ratingCountTot) or 0,
        playtime    = num(db.playTimeInMinutes),
        cover_url   = cover or nil,
        pageversion = num(db.pageversion),
        link        = str(db.link),
        tags        = tags,
        links       = links,
    }
end

-- ── downloads ────────────────────────────────────────────────────────────────

--- The game's download links we can play, best first. Each entry is the link
--- plus: zip (bool), vm, label (format description), filename (what to save
--- it as — for a zip, the archive's own name).
-- @param resolver  engines/resolver.lua (injected to keep this module pure)
function M.playableLinks(game, resolver)
    local out = {}
    for i, l in ipairs(game.links or {}) do
        local name   = M.urlFileName(l.url)
        local ext    = extOf(name)
        local known  = l.format and M.LINK_FORMATS[l.format]
        local by_ext = name and resolver.vm_for(name)
        local zip    = ext == "zip"
        -- A URL with no file name is a web page (e.g. an iplayif.com player
        -- wrapping the story), even when IFDB tags it zcode.
        local keep   = l.is_game and name and (by_ext or known)
        if keep then
            local label = known and known.label
                          or (by_ext == "git" and "Glulx" or "Z-machine")
            local filename = name
            if not zip and known and by_ext ~= known.vm then
                -- No usable extension (download.php?id=12), or one that picks
                -- the wrong VM (a Z-code blorb named .blorb would go to git):
                -- name the file from the declared format.
                filename = (name and name:gsub("%.[^.]*$", "") or "game") .. "." .. known.ext
                by_ext = known.vm
            end
            local score = 0
            if l.format and l.format:find("^blorb/") or ext == "zblorb" or ext == "gblorb" then
                score = score + 8
            end
            if not zip then score = score + 4 end
            if l.url:match("^https:") then score = score + 2 end
            if l.url:match("^%a+://[%w.]*ifarchive%.org/") then score = score + 1 end
            out[#out + 1] = {
                url = l.url, title = l.title, desc = l.desc, format = l.format,
                zip = zip, vm = by_ext or known.vm, label = label,
                filename = filename, score = score, order = i,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.order < b.order
    end)
    return out
end

--- Members of a zip worth extracting: story files we can play, skipping
--- macOS resource forks. Takes a list of member paths.
function M.playableMembers(paths, resolver)
    local out = {}
    for _, p in ipairs(paths) do
        local base = p:match("([^/]+)$")
        if base and not p:find("__MACOSX/", 1, true) and not base:match("^%._")
           and resolver.is_supported(base) then
            out[#out + 1] = p
        end
    end
    return out
end

--- A folder or file name that is safe on FAT (Kindle/Kobo user storage):
--- reserved characters replaced, trimmed, capped at 80 bytes on a UTF-8
--- boundary.
function M.safeName(s)
    s = tostring(s or ""):gsub('[%c/\\:%*%?"<>|]', "_")
    s = trim(s):gsub("%.+$", "")
    if #s > 80 then
        local cut = 80
        while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do
            cut = cut - 1
        end
        s = trim(s:sub(1, cut))
    end
    return s ~= "" and s or "game"
end

--- Play time as (count, unit): 9, "hours" / 45, "minutes"; nil when unknown.
function M.playtime(minutes)
    if not minutes or minutes <= 0 then return nil end
    if minutes < 60 then return math.floor(minutes + 0.5), "minutes" end
    return math.max(1, math.floor(minutes / 60 + 0.5)), "hours"
end

--- safeName for a file: the stem is cleaned and capped, the extension kept.
function M.safeFileName(name)
    local stem, ext = tostring(name or ""):match("^(.*)%.(%w+)$")
    if not stem or stem == "" then return M.safeName(name) end
    return M.safeName(stem) .. "." .. ext
end

--- "★4.5 (532)" for a row or record; "" when unrated.
function M.ratingText(g)
    if not g.rating or (g.ratings or 0) == 0 then return "" end
    return string.format("★%.1f (%d)", g.rating, g.ratings)
end

return M
