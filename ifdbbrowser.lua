-- ifdbbrowser.lua — find and download games from IFDB (ifdb.org).
--
-- A full-screen Menu with its own screen stack:
--   home      search, format choice, download folder, browse presets
--   listing   result rows (title — author, ★rating), "More results…"
--   game      a TextViewer on top: details, Download / Play, Cover
-- ifdb.lua does the queries and parsing, netfetch.lua the HTTP, and
-- gamelibrary.lua remembers what was downloaded.
--
-- Every network call runs in Trapper:dismissableRunInSubprocess, so the screen
-- shows what is happening, a tap cancels it, and a slow Kindle Wi-Fi link never
-- freezes the UI. The subprocess hands back raw bytes; JSON is decoded here in
-- the parent, because rapidjson's tables do not survive Trapper's serialiser.

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox   = require("ui/widget/confirmbox")
local DataStorage  = require("datastorage")
local InfoMessage  = require("ui/widget/infomessage")
local InputDialog  = require("ui/widget/inputdialog")
local Menu         = require("ui/widget/menu")
local NetworkMgr   = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local PathChooser  = require("ui/widget/pathchooser")
local TextViewer   = require("ui/widget/textviewer")
local Trapper      = require("ui/trapper")
local UIManager    = require("ui/uimanager")
local lfs          = require("libs/libkoreader-lfs")
local logger       = require("logger")
local rapidjson    = require("rapidjson")
local util         = require("util")
local _            = require("gettext")
local T            = require("ffi/util").template

local GameLibrary = require("gamelibrary")
local Ifdb        = require("ifdb")
local Resolver    = require("engines/resolver")

local FORMAT_LABELS = {
    both  = _("Z-machine + Glulx"),
    zcode = _("Z-machine"),
    glulx = _("Glulx"),
}

local PRESET_LABELS = {
    top     = _("Top rated"),
    popular = _("Most rated"),
    new     = _("Newest releases"),
    short   = _("Short games (under an hour)"),
    random  = _("Surprise me"),
}

local MAX_TAGS_SHOWN = 15

local IfdbBrowser = Menu:extend{
    title               = _("Find games on IFDB"),
    is_popout           = false,
    is_borderless       = true,
    covers_fullscreen   = true,
    title_bar_fm_style  = true,
    title_bar_left_icon = "appbar.search",
    settings            = nil,  -- LuaSettings handle from main.lua
    on_play             = nil,  -- function(path): start a game
}

function IfdbBrowser:init()
    self.library    = GameLibrary.open()
    self.game_cache = {}
    self.item_table = self:_homeItems()
    self.cur_title  = self.title
    Menu.init(self)
end

-- ── settings ─────────────────────────────────────────────────────────────────

function IfdbBrowser:_setting(key, default)
    local v = self.settings and self.settings:readSetting(key)
    if v == nil then return default end
    return v
end

function IfdbBrowser:_saveSetting(key, value)
    if not self.settings then return end
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function IfdbBrowser:_formatChoice()
    local f = self:_setting("ifdb_format", "both")
    return FORMAT_LABELS[f] and f or "both"
end

-- A dedicated setting, not the file browser's game_directory: that one follows
-- the last game opened, which after playing a download is the game's own
-- subfolder — downloads would nest ever deeper.
function IfdbBrowser:_downloadDir()
    return self:_setting("ifdb_download_dir", DataStorage:getDataDir() .. "/ifgames")
end

-- ── screens ──────────────────────────────────────────────────────────────────

function IfdbBrowser:_homeItems()
    local _dir, dir_name = util.splitFilePathName(self:_downloadDir())
    local items = {
        { text = _("Search…"), callback = function() self:_showSearchDialog() end },
        {
            text      = _("Formats"),
            mandatory = FORMAT_LABELS[self:_formatChoice()],
            callback  = function() self:_cycleFormat() end,
        },
        {
            text      = _("Download folder"),
            mandatory = dir_name,
            callback  = function() self:_chooseDownloadDir() end,
        },
    }
    for _i, preset in ipairs(Ifdb.PRESETS) do
        items[#items + 1] = {
            text     = PRESET_LABELS[preset.id],
            callback = function() self:_openPreset(preset) end,
        }
    end
    return items
end

function IfdbBrowser:_pushScreen(title, items, listing)
    self.item_table.title = self.cur_title
    self.item_table.focus = self:getFirstVisibleItemIndex()
    table.insert(self.item_table_stack, self.item_table)
    items.listing   = listing
    self.cur_title  = title
    self:switchItemTable(title, items)
end

-- Back (key, swipe, title-bar close) walks our screen stack before closing.
function IfdbBrowser:onClose()
    if #self.item_table_stack > 0 then
        local parent = table.remove(self.item_table_stack)
        self.cur_title = parent.title
        self:switchItemTable(parent.title, parent, parent.focus)
        return true
    end
    return Menu.onClose(self)
end

function IfdbBrowser:onLeftButtonTap()
    self:_showSearchDialog()
end

function IfdbBrowser:_cycleFormat()
    local choices, cur = Ifdb.FORMAT_CHOICES, self:_formatChoice()
    local next_choice = choices[1]
    for i, c in ipairs(choices) do
        if c == cur then next_choice = choices[i % #choices + 1] end
    end
    self:_saveSetting("ifdb_format", next_choice)
    self:switchItemTable(nil, self:_homeItems(), 2)
end

function IfdbBrowser:_chooseDownloadDir()
    local dir = self:_downloadDir()
    util.makePath(dir)
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file      = false,
        path             = dir,
        onConfirm        = function(path)
            self:_saveSetting("ifdb_download_dir", path)
            self:switchItemTable(nil, self:_homeItems(), 3)
        end,
    })
end

-- ── network ──────────────────────────────────────────────────────────────────

-- Run fn in a Trapper coroutine once the device is online (turning Wi-Fi on
-- first if needed).
function IfdbBrowser:_online(fn)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(fn)
    end)
end

-- GET a URL in a cancellable subprocess. Call inside _online().
-- @return body, or nil and an error string (false when the user cancelled)
function IfdbBrowser:_get(url, message)
    local completed, res = Trapper:dismissableRunInSubprocess(function()
        local body, err = require("netfetch").get(url)
        if body then return "OK\n" .. body end
        return "ERR\n" .. tostring(err)
    end, message, true)
    if not completed then return nil, false end
    if type(res) ~= "string" then return nil, _("no response") end
    if res:sub(1, 3) == "OK\n" then return res:sub(4) end
    return nil, res:sub(5)
end

function IfdbBrowser:_getJson(url, message)
    local body, err = self:_get(url, message)
    if not body then return nil, err end
    local ok, decoded = pcall(rapidjson.decode, body)
    if not ok or type(decoded) ~= "table" then
        logger.warn("IFDB: not JSON from", url, body:sub(1, 200))
        return nil, _("IFDB sent an unexpected reply. The site may be down, or blocking this device.")
    end
    return decoded
end

function IfdbBrowser:_showError(err)
    if err == false then return end -- cancelled: nothing to say
    UIManager:show(InfoMessage:new{
        text = T(_("IFDB request failed:\n%1"), tostring(err)),
    })
end

-- ── result listings ──────────────────────────────────────────────────────────

-- A listing is one result list plus what's needed to fetch more of it.
-- server_filtered: IFDB already restricted it to our formats; otherwise rows
-- from authoring systems we can't play are held back in `hidden`.
local function newListing(title, requests, sortby, server_filtered)
    return {
        title = title, requests = requests, sortby = sortby,
        server_filtered = server_filtered,
        page = 1, rows = {}, hidden = {}, seen = {}, more = false,
    }
end

-- Fetch the listing's next page (every request that still has more). Call
-- inside _online().
function IfdbBrowser:_loadPage(listing)
    local lists, more = {}, false
    for _i, req in ipairs(listing.requests) do
        if req.more ~= false then
            local decoded, err = self:_getJson(
                Ifdb.searchUrl(req.query, listing.sortby, listing.page),
                listing.page == 1 and _("Searching IFDB…") or _("Loading more results…"))
            if not decoded then return nil, err end
            local res, perr = Ifdb.parseSearch(decoded)
            if not res then return nil, perr, true end
            req.more = res.has_more
            more = more or res.has_more
            lists[#lists + 1] = res.games
        end
    end
    local merged = Ifdb.mergeResults(lists, listing.sortby, listing.seen)
    if listing.server_filtered then
        for _i, g in ipairs(merged) do table.insert(listing.rows, g) end
    else
        local kept, hidden = Ifdb.splitBySystem(merged)
        for _i, g in ipairs(kept) do table.insert(listing.rows, g) end
        for _i, g in ipairs(hidden) do table.insert(listing.hidden, g) end
    end
    listing.more = more
    listing.page = listing.page + 1
    return true
end

function IfdbBrowser:_openListing(listing, fallback_requests)
    self:_online(function()
        local ok, err, from_ifdb = self:_loadPage(listing)
        if not ok and from_ifdb and fallback_requests then
            -- IFDB rejected the filtered query: retry unfiltered and narrow
            -- the results by authoring system instead.
            logger.info("IFDB: filtered query failed, retrying unfiltered:", err)
            listing = newListing(listing.title, fallback_requests, "rel", false)
            ok, err = self:_loadPage(listing)
        end
        if not ok then return self:_showError(err) end
        if #listing.rows == 0 and #listing.hidden == 0 then
            UIManager:show(InfoMessage:new{ text = _("No games found.") })
            return
        end
        self:_pushScreen(listing.title, self:_listingItems(listing), listing)
    end)
end

function IfdbBrowser:_listingItems(listing)
    local items = {}
    local function add(g, note)
        local owned = self.library:findByTuid(g.tuid)
        local right = Ifdb.ratingText(g)
        if note then right = note end
        if owned then right = "✓ " .. right end
        items[#items + 1] = {
            text      = g.author and (g.title .. " — " .. g.author) or g.title,
            mandatory = right,
            callback  = function() self:_openGame(g) end,
        }
    end
    for _i, g in ipairs(listing.rows) do add(g) end
    if listing.show_hidden then
        for _i, g in ipairs(listing.hidden) do add(g, g.devsys) end
    elseif #listing.hidden > 0 then
        items[#items + 1] = {
            text     = T(_("Show %1 more (other authoring systems)"), #listing.hidden),
            callback = function()
                listing.show_hidden = true
                self:_refreshListing(listing, #listing.rows + 1)
            end,
        }
    end
    if listing.more then
        items[#items + 1] = {
            text     = _("More results…"),
            callback = function()
                self:_online(function()
                    local first_new = #self.item_table
                    local ok, err = self:_loadPage(listing)
                    if not ok then return self:_showError(err) end
                    self:_refreshListing(listing, first_new)
                end)
            end,
        }
    end
    return items
end

function IfdbBrowser:_refreshListing(listing, focus)
    local items = self:_listingItems(listing)
    items.listing = listing
    self:switchItemTable(nil, items, focus or self:getFirstVisibleItemIndex())
end

function IfdbBrowser:_openPreset(preset)
    local f = self:_formatChoice()
    local title = PRESET_LABELS[preset.id]
    if f ~= "both" then title = title .. " · " .. FORMAT_LABELS[f] end
    self:_openListing(newListing(title, Ifdb.presetQueries(preset, f), preset.sortby, true))
end

function IfdbBrowser:_showSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title       = _("Search IFDB"),
        input       = self.last_query or "",
        input_hint  = _("Title or author"),
        description = _("Filters also work, alone or combined: author:\"Emily Short\"  tag:horror  genre:mystery  rating:4-  playtime:-1h  language:fr"),
        buttons     = {{
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text             = _("Search"),
                is_enter_default = true,
                callback         = function()
                    local text = dialog:getInputText()
                    if not text:match("%S") then return end
                    UIManager:close(dialog)
                    self.last_query = text
                    self:_search(text)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function IfdbBrowser:_search(text)
    local requests, filtered = Ifdb.searchQueries(text, self:_formatChoice())
    local listing = newListing(T(_("Search: %1"), text), requests,
                               filtered and "ratu" or "rel", filtered)
    local fallback = filtered and { { query = text } } or nil
    self:_openListing(listing, fallback)
end

-- ── one game ─────────────────────────────────────────────────────────────────

function IfdbBrowser:_openGame(row)
    local cached = self.game_cache[row.tuid]
    if cached then return self:_showGame(cached) end
    self:_online(function()
        local decoded, err = self:_getJson(Ifdb.viewgameUrl(row.tuid), _("Loading game details…"))
        if not decoded then return self:_showError(err) end
        local game, perr = Ifdb.parseGame(decoded)
        if not game then return self:_showError(perr) end
        game.tuid   = game.tuid or row.tuid
        game.devsys = row.devsys
        self.game_cache[row.tuid] = game
        self:_showGame(game)
    end)
end

local function playtimeText(minutes)
    local n, unit = Ifdb.playtime(minutes)
    if not n then return nil end
    if unit == "minutes" then return T(_("about %1 minutes"), n) end
    return n == 1 and _("about 1 hour") or T(_("about %1 hours"), n)
end

function IfdbBrowser:_describe(game, links)
    local out = {}
    local function line(s) if s and s ~= "" then out[#out + 1] = s end end

    if game.author then line(T(_("by %1"), game.author)) end
    local facts = {}
    for _i, v in ipairs({ game.year, game.genre, game.language }) do
        if v and v ~= "" then facts[#facts + 1] = v end
    end
    line(table.concat(facts, " · "))
    if game.rating and game.ratings > 0 then
        line(T(_("Rating: %1 (%2 ratings)"), string.format("★%.1f", game.rating), game.ratings))
    end
    local pt = playtimeText(game.playtime)
    if pt then line(T(_("Play time: %1"), pt)) end
    if #game.tags > 0 then
        local names = {}
        for i = 1, math.min(MAX_TAGS_SHOWN, #game.tags) do names[i] = game.tags[i].name end
        line(T(_("Tags: %1"), table.concat(names, ", ")))
    end

    if game.description then
        out[#out + 1] = ""
        out[#out + 1] = util.htmlToPlainText(game.description)
    end

    out[#out + 1] = ""
    if #links > 0 then
        local best = links[1]
        line(T(_("Download: %1 (%2)"), best.filename, best.zip and (best.label .. ", zip") or best.label))
        if #links == 2 then
            line(_("1 other download available."))
        elseif #links > 2 then
            line(T(_("%1 other downloads available."), #links - 1))
        end
    else
        line(_("No Z-machine or Glulx download is listed for this game."))
        if game.devsys then line(T(_("Authoring system: %1"), game.devsys)) end
    end
    return table.concat(out, "\n")
end

function IfdbBrowser:_showGame(game)
    local links = Ifdb.playableLinks(game, Resolver)
    local owned_path = self.library:findByTuid(game.tuid)
    local viewer
    local function close() UIManager:close(viewer) end

    local row = {}
    if owned_path then
        row[#row + 1] = { text = _("Play"), callback = function()
            close()
            self:_play(owned_path)
        end }
    elseif #links > 0 then
        row[#row + 1] = { text = _("Download"), callback = function()
            self:_chooseLink(game, links, close)
        end }
    end
    if game.cover_url then
        row[#row + 1] = { text = _("Cover"), callback = function() self:_showCover(game) end }
    end
    row[#row + 1] = { text = _("Close"), callback = close }

    viewer = TextViewer:new{
        title         = game.title,
        text          = self:_describe(game, links),
        text_type     = "book_info",
        buttons_table = { row },
    }
    UIManager:show(viewer)
end

function IfdbBrowser:_showCover(game)
    local function show(bytes)
        local RenderImage = require("ui/renderimage")
        local bb = bytes and RenderImage:renderImageData(bytes, #bytes, false)
        if not bb then
            UIManager:show(InfoMessage:new{ text = _("Could not show the cover image.") })
            return
        end
        local ImageViewer = require("ui/widget/imageviewer")
        UIManager:show(ImageViewer:new{
            image            = bb,
            image_disposable = true,
            modal            = true,
            fullscreen       = true,
            with_title_bar   = true,
            title_text       = game.title,
        })
    end

    local _path, entry = self.library:findByTuid(game.tuid)
    if entry and entry.cover then
        local fh = io.open(GameLibrary.coverPath(entry.cover), "rb")
        if fh then
            local data = fh:read("*a")
            fh:close()
            return show(data)
        end
    end
    self:_online(function()
        local body, err = self:_get(game.cover_url, _("Loading cover…"))
        if not body then return self:_showError(err) end
        show(body)
    end)
end

-- ── downloading ──────────────────────────────────────────────────────────────

function IfdbBrowser:_chooseLink(game, links, done)
    if #links == 1 then return self:_confirmDownload(game, links[1], done) end
    local dialog
    local buttons = {}
    for _i, link in ipairs(links) do
        local text = T("%1 (%2)", link.filename, link.zip and (link.label .. ", zip") or link.label)
        if link.desc then text = text .. " — " .. link.desc end
        buttons[#buttons + 1] = {{
            text     = text,
            align    = "left",
            callback = function()
                UIManager:close(dialog)
                self:_confirmDownload(game, link, done)
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{ title = _("Choose a download"), buttons = buttons }
    UIManager:show(dialog)
end

function IfdbBrowser:_confirmDownload(game, link, done)
    local dir    = self:_downloadDir() .. "/" .. Ifdb.safeName(game.title)
    local target = dir .. "/" .. Ifdb.safeFileName(link.filename)
    local function start()
        self:_online(function() self:_download(game, link, dir, target, done) end)
    end
    if not link.zip and lfs.attributes(target, "mode") then
        UIManager:show(ConfirmBox:new{
            text        = T(_("%1 is already in the download folder. Download it again?"), link.filename),
            ok_text     = _("Download"),
            ok_callback = start,
        })
    else
        start()
    end
end

-- Remove a game folder we created if a failed download left it empty.
local function removeIfEmpty(dir)
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then return end
    end
    lfs.rmdir(dir)
end

-- Call inside _online(). `target` is the story file's final path; for a zip it
-- names the archive's folder and the member decides the file name.
function IfdbBrowser:_download(game, link, dir, target, done)
    util.makePath(dir)
    local cover_file = game.cover_url and game.tuid and (game.tuid .. ".cover")
    local cover_path = cover_file and GameLibrary.coverPath(cover_file)
    local url, cover_url = link.url, game.cover_url

    local completed, res = Trapper:dismissableRunInSubprocess(function()
        local NetFetch = require("netfetch")
        local ok, err = NetFetch.download(url, target)
        if not ok then return "ERR\n" .. tostring(err) end
        if cover_path then NetFetch.download(cover_url, cover_path) end -- best effort
        return "OK\n"
    end, T(_("Downloading %1…"), link.filename), true)

    if not completed then
        -- The subprocess was killed: its .part files are left behind.
        os.remove(target .. ".part")
        if cover_path then os.remove(cover_path .. ".part") end
        removeIfEmpty(dir)
        UIManager:show(Notification:new{ text = _("Download cancelled.") })
        return
    end
    if type(res) ~= "string" or res:sub(1, 3) ~= "OK\n" then
        removeIfEmpty(dir)
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed:\n%1"), type(res) == "string" and res:sub(5) or _("no response")),
        })
        return
    end
    if cover_path and not lfs.attributes(cover_path, "mode") then cover_file = nil end

    if link.zip then
        self:_unzip(game, target, dir, cover_file, done)
    else
        self:_finish(game, target, cover_file, done)
    end
end

function IfdbBrowser:_unzip(game, zip_path, dir, cover_file, done)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        UIManager:show(InfoMessage:new{
            text = T(_("Could not open the zip file:\n%1"), tostring(reader.err)),
        })
        return
    end
    local paths = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then paths[#paths + 1] = entry.path end
    end
    local members = Ifdb.playableMembers(paths, Resolver)

    local function extract(member)
        local base   = member:match("([^/]+)$")
        local target = dir .. "/" .. Ifdb.safeFileName(base)
        local ok     = reader:extractToPath(member, target)
        local err    = reader.err
        reader:close()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not extract %1:\n%2"), base, tostring(err)),
            })
            return
        end
        os.remove(zip_path)
        self:_finish(game, target, cover_file, done)
    end

    if #members == 0 then
        reader:close()
        UIManager:show(InfoMessage:new{
            text = T(_("The zip file has no Z-machine or Glulx story file in it. It was kept at:\n%1"), zip_path),
        })
    elseif #members == 1 then
        extract(members[1])
    else
        local dialog
        local buttons = {}
        for _i, member in ipairs(members) do
            buttons[#buttons + 1] = {{
                text     = member,
                align    = "left",
                callback = function()
                    UIManager:close(dialog)
                    extract(member)
                end,
            }}
        end
        buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function()
            UIManager:close(dialog)
            reader:close()
        end }}
        dialog = ButtonDialog:new{ title = _("Which story file?"), buttons = buttons }
        UIManager:show(dialog)
    end
end

function IfdbBrowser:_finish(game, path, cover_file, done)
    self.library:put(path, {
        source      = "ifdb",
        tuid        = game.tuid,
        ifids       = game.ifids,
        title       = game.title,
        author      = game.author,
        year        = game.year,
        rating      = game.rating,
        ratings     = game.ratings,
        playtime    = game.playtime,
        pageversion = game.pageversion,
        cover       = cover_file,
    })
    -- Let "Open game…" start where the downloads are, unless the player has
    -- already been browsing somewhere.
    if not self:_setting("game_directory") then
        self:_saveSetting("game_directory", self:_downloadDir())
    end
    if done then done() end
    local listing = self.item_table.listing
    if listing then self:_refreshListing(listing) end -- show the ✓

    UIManager:show(ConfirmBox:new{
        text        = T(_("%1 is ready to play."), game.title),
        ok_text     = _("Play now"),
        cancel_text = _("Later"),
        ok_callback = function() self:_play(path) end,
    })
end

function IfdbBrowser:_play(path)
    if self.on_play then self.on_play(path) end
end

return IfdbBrowser
