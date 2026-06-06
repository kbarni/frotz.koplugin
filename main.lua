local ConfirmBox      = require("ui/widget/confirmbox")
local DataStorage     = require("datastorage")
local InfoMessage     = require("ui/widget/infomessage")
local LuaSettings     = require("luasettings")
local lfs             = require("libs/libkoreader-lfs")
local PathChooser     = require("ui/widget/pathchooser")
local RenderText      = require("ui/rendertext")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Font            = require("ui/font")
local logger          = require("logger")
local util            = require("util")
local _               = require("gettext")
local T               = require("ffi/util").template
local Screen          = require("device").screen

local Resolver  = require("engines/resolver")
local rapidjson = require("rapidjson")

-- Locate the plugin directory so we can find the interpreter binaries regardless
-- of where KOReader is installed.
local _plugin_dir = debug.getinfo(1, "S").source:match("@(.+)/[^/]+$") or "."

local DEFAULT_FONT_SIZE = 20
local MAX_RECENT        = 10

-- ── Interpreter binary lookup ────────────────────────────────────────────────────
-- Prefer a per-arch binary under binaries/<arch>/, fall back to bin/ (the host
-- spike build used by the emulator). Arch detection is best-effort and finalized
-- with the cross-builds in Phase 5; the file-existence scan is self-correcting
-- when only one arch is actually present.

local function detect_arch()
    local m
    local p = io.popen and io.popen("uname -m 2>/dev/null")
    if p then m = p:read("*l"); p:close() end
    m = m or ""
    if m:match("x86_64") or m:match("amd64") then return "x86_64" end
    if m:match("aarch64") then return "aarch64" end
    if m:match("arm") then return "armhf" end
    return "x86_64"
end

local _arch = detect_arch()

local function binary_for(vm)
    local candidates = {
        _plugin_dir .. "/binaries/" .. _arch .. "/" .. vm,
        _plugin_dir .. "/binaries/armhf/" .. vm,
        _plugin_dir .. "/binaries/armel/" .. vm,
        _plugin_dir .. "/binaries/x86_64/" .. vm,
        _plugin_dir .. "/bin/" .. vm,
    }
    for _, path in ipairs(candidates) do
        if lfs.attributes(path, "mode") then return path end
    end
    return nil
end

local Frotz = WidgetContainer:extend{
    name        = "frotz",
    is_doc_only = false,
    _settings   = nil,
}

function Frotz:init()
    self.ui.menu:registerToMainMenu(self)
end

-- ── Persistent settings (last directory + recent games + font size) ─────────────

function Frotz:_loadSettings()
    if not self._settings then
        self._settings = LuaSettings:open(
            DataStorage:getSettingsDir() .. "/frotz.lua")
    end
end

function Frotz:_saveSetting(key, value)
    self:_loadSettings()
    self._settings:saveSetting(key, value)
    self._settings:flush()
end

-- ── Menu ──────────────────────────────────────────────────────────────────────

function Frotz:addToMainMenu(menu_items)
    menu_items.frotz = {
        text         = _("Interactive Fiction"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            self:_loadSettings()
            return self:_buildMenuItems()
        end,
    }
end

function Frotz:_buildMenuItems()
    local items = {}

    table.insert(items, {
        text     = _("Open game…"),
        callback = function() self:_openFileBrowser() end,
    })

    local recent = self:_buildRecentSubmenu()
    if #recent > 0 then
        table.insert(items, {
            text           = _("Recent games"),
            sub_item_table = recent,
        })
    end

    return items
end

-- ── Recent games library ────────────────────────────────────────────────────────

function Frotz:_recentGames()
    self:_loadSettings()
    local list = self._settings:readSetting("recent_games")
    if not list then
        list = {}
        local last = self._settings:readSetting("last_game")
        if last then table.insert(list, last) end
    end
    return list
end

function Frotz:_pushRecent(gamefile)
    local list = self:_recentGames()
    for i = #list, 1, -1 do
        if list[i] == gamefile then table.remove(list, i) end
    end
    table.insert(list, 1, gamefile)
    while #list > MAX_RECENT do table.remove(list) end
    self:_saveSetting("recent_games", list)
end

function Frotz:_buildRecentSubmenu()
    local list  = self:_recentGames()
    local kept  = {}
    local items = {}
    for _idx, path in ipairs(list) do
        if lfs.attributes(path, "mode") == "file" then
            table.insert(kept, path)
            local _dir, fname = util.splitFilePathName(path)
            table.insert(items, {
                text      = fname,
                mandatory = lfs.attributes(self:_autosavePathFor(path), "mode")
                            and _("saved") or nil,
                callback  = function() self:_startGame(path) end,
            })
        end
    end
    if #kept ~= #list then
        self:_saveSetting("recent_games", kept)
    end
    if #items > 0 then
        table.insert(items, {
            text     = _("Clear recent games"),
            separator = true,
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text        = _("Clear the recent games list?"),
                    ok_text     = _("Clear"),
                    ok_callback = function()
                        self:_saveSetting("recent_games", {})
                    end,
                })
            end,
        })
    end
    return items
end

-- ── Display settings ────────────────────────────────────────────────────────────

function Frotz:_fontSize()
    self:_loadSettings()
    return self._settings:readSetting("font_size") or DEFAULT_FONT_SIZE
end

-- ── File browser ──────────────────────────────────────────────────────────────

function Frotz:_openFileBrowser()
    self:_loadSettings()
    local start_dir = self._settings:readSetting("game_directory")
                      or (DataStorage:getDataDir() .. "/ifgames")
    UIManager:show(PathChooser:new{
        select_directory = false,
        path             = start_dir,
        -- Show both Z-machine and Glulx games (resolved by extension).
        filter_func      = function(filename)
            return Resolver.is_supported(filename)
        end,
        onConfirm = function(file_path)
            local dir = file_path:match("(.*)/")
            if dir and dir ~= "" then
                self:_saveSetting("game_directory", dir)
            end
            self:_startGame(file_path)
        end,
    })
end

-- ── Game startup ──────────────────────────────────────────────────────────────

-- Per-game save directory: DataDir/frotz_saves/<sanitised story name>/.
function Frotz:_saveDirFor(gamefile)
    local _dir, fname = util.splitFilePathName(gamefile)
    local stem        = fname:gsub("%.[^.]+$", "")
    local safe_name   = stem:gsub("[^%w%-_]", "_")
    return DataStorage:getDataDir() .. "/frotz_saves/" .. safe_name
end

function Frotz:_autosavePathFor(gamefile)
    return self:_saveDirFor(gamefile) .. "/autosave.qzl"
end

function Frotz:_startGame(gamefile)
    local Session  = require("session")
    local GameView = require("gameview")
    local RemGlk   = require("engines/remglk")

    -- Pick the interpreter from the extension, then find its binary.
    local vm = Resolver.vm_for(gamefile)
    if not vm then
        UIManager:show(InfoMessage:new{
            text = _("Unsupported game format: ") .. tostring(gamefile),
        })
        return
    end
    local binary = binary_for(vm)
    if not binary then
        UIManager:show(InfoMessage:new{
            text = T(_("Interpreter binary not found: %1 (arch %2)"), vm, _arch),
        })
        return
    end

    local font_size = self:_fontSize()

    -- cols is the monospace column width. GameView renders the transcript in a
    -- fixed-width face ("infont") and word-wraps the story to `cols`, so one glyph
    -- advance is constant and wrapping lines up exactly with the rendered width.
    -- usable is the TextBoxWidget's inner width: ScrollTextWidget reserves
    -- scroll_bar_width (6) + text_scroll_span (12) on the right, and GameView
    -- pads by Size.padding.large on each side.
    local face            = Font:getFace("infont", font_size)
    local advance         = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, "0").x
    local scroll_overhead = Screen:scaleBySize(6) + Screen:scaleBySize(12)
    local usable          = Screen:getWidth() - 2 * Size.padding.large - scroll_overhead
    local cols            = math.max(20, math.floor(usable / advance))
    -- rows is advertised tall so the VM never paginates; the UI owns paging.
    local rows = 200

    self:_pushRecent(gamefile)

    -- Per-game save directory holds the numbered slots and the autosave.
    local _dir, fname   = util.splitFilePathName(gamefile)
    local save_dir      = self:_saveDirFor(gamefile)
    util.makePath(save_dir)
    local autosave_path = self:_autosavePathFor(gamefile)

    local function launch(auto_restore)
        local ok, transport = pcall(Session.new, Session, binary, gamefile)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Failed to start interpreter:\n") .. tostring(transport),
            })
            logger.err("Frotz: session error:", transport)
            return
        end
        local engine = RemGlk:new(transport, rapidjson, cols, rows)

        local game_view = GameView:new{
            engine       = engine,
            game_title   = fname,
            font_size    = font_size,
            cols         = cols,
            settings     = self._settings,
            save_dir     = save_dir,
            auto_restore = auto_restore,
            -- The hosting FileManager/ReaderUI register a "dictionary" module;
            -- passing ui through enables hold-to-look-up in the transcript.
            ui           = self.ui,
            on_close     = function()
                self._game_view = nil
            end,
        }
        self._game_view = game_view
        game_view:show()
    end

    -- Offer to pick up from the autosave if one exists.
    if lfs.attributes(autosave_path, "mode") then
        UIManager:show(ConfirmBox:new{
            text            = _("Resume where you left off?"),
            ok_text         = _("Resume"),
            cancel_text     = _("Start over"),
            ok_callback     = function() launch(true) end,
            cancel_callback = function() launch(false) end,
        })
    else
        launch(false)
    end
end

function Frotz:onFlushSettings()
    if self._settings then
        self._settings:flush()
    end
end

return Frotz
