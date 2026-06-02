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
local Screen          = require("device").screen

-- Locate the plugin directory so we can find bin/dfrotz regardless of
-- where KOReader is installed.
local _plugin_dir = debug.getinfo(1, "S").source:match("@(.+)/[^/]+$") or "."
local DFROTZ_BIN  = _plugin_dir .. "/bin/dfrotz"

local EXTENSIONS = {
    z1=true, z2=true, z3=true, z4=true,
    z5=true, z6=true, z7=true, z8=true,
    zblorb=true, dat=true,
}

local DEFAULT_FONT_SIZE = 20
local MAX_RECENT        = 10

local Frotz = WidgetContainer:extend{
    name        = "frotz",
    is_doc_only = false,
    _settings   = nil,
}

function Frotz:init()
    self.ui.menu:registerToMainMenu(self)
end

-- ── Persistent settings (last directory + last game) ──────────────────────────

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

-- Most-recent-first list of game paths.  Seeds from the old single "last_game"
-- setting on first run, so existing users keep their last game.
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

-- Build the "Recent games" sub-menu, pruning entries whose file no longer
-- exists and flagging those that have an autosave to resume.
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
        filter_func      = function(filename)
            local ext = filename:match("%.([^.]+)$")
            return ext ~= nil and EXTENSIONS[ext:lower()] == true
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

    local font_size = self:_fontSize()

    -- cols is the wrap width dfrotz uses for its output lines.  GameView renders
    -- the transcript in a monospace face ("infont"), so one glyph advance is
    -- constant: cols = usable text width / advance makes dfrotz's wrapping line
    -- up exactly with the rendered width (no double-wrapping, ASCII maps align).
    --
    -- usable must be the TextBoxWidget's inner width, not the ScrollTextWidget's
    -- outer width: ScrollTextWidget reserves scroll_bar_width (6) + text_scroll_span
    -- (12) on the right (see scrolltextwidget.lua).  GameView passes the outer
    -- width as sw - 2*padding.large (its _scroll_w).  Omitting the scroll overhead
    -- overcounts by a fixed ~18px, which at large font sizes is a whole extra
    -- column and overflows the screen.
    local face          = Font:getFace("infont", font_size)
    local advance       = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, "0").x
    local scroll_overhead = Screen:scaleBySize(6) + Screen:scaleBySize(12)
    local usable        = Screen:getWidth() - 2 * Size.padding.large - scroll_overhead
    local cols          = math.max(20, math.floor(usable / advance))
    -- rows is deliberately large: MORE is disabled (-m in session.lua), so the
    -- screen buffer must hold a whole turn's output without scrolling lines off
    -- the top.  The UI paginates this output itself (see gameview.lua).
    local rows = 200

    self:_pushRecent(gamefile)

    -- Per-game save directory holds the numbered slots and the autosave.
    local _dir, fname   = util.splitFilePathName(gamefile)
    local save_dir      = self:_saveDirFor(gamefile)
    util.makePath(save_dir)
    local autosave_path = self:_autosavePathFor(gamefile)

    local function launch(auto_restore)
        local ok, result = pcall(Session.new, Session, DFROTZ_BIN, gamefile, cols, rows)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Failed to start dfrotz:\n") .. tostring(result),
            })
            logger.err("Frotz: session error:", result)
            return
        end

        local game_view = GameView:new{
            session      = result,
            game_title   = fname,
            font_size    = font_size,
            settings     = self._settings,
            save_dir     = save_dir,
            auto_restore = auto_restore,
            on_close     = function()
                self._game_view = nil
            end,
        }
        self._game_view = game_view
        game_view:show()
    end

    -- Offer to pick up from the autosave if one exists (feature #4).
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
