local DataStorage     = require("datastorage")
local InfoMessage     = require("ui/widget/infomessage")
local LuaSettings     = require("luasettings")
local PathChooser     = require("ui/widget/pathchooser")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil         = require("ffi/util")
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

    local last = self._settings:readSetting("last_game")
    if last then
        local _dir, fname = util.splitFilePathName(last)
        table.insert(items, {
            text     = ffiUtil.template(_("Resume: %1"), fname),
            callback = function() self:_startGame(last) end,
        })
    end

    return items
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

function Frotz:_startGame(gamefile)
    local Session  = require("session")
    local GameView = require("gameview")

    -- cols is the wrap width dfrotz uses for its output lines.
    -- rows is deliberately large: MORE is disabled (-m in session.lua), so the
    -- screen buffer must hold a whole turn's output without scrolling lines off
    -- the top.  The UI paginates this output itself (see gameview.lua).
    local cols = 56 --math.max(40, math.floor(Screen:getWidth() / 8))
    local rows = 200

    local ok, result = pcall(Session.new, Session, DFROTZ_BIN, gamefile, cols, rows)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Failed to start dfrotz:\n") .. tostring(result),
        })
        logger.err("Frotz: session error:", result)
        return
    end

    self:_saveSetting("last_game", gamefile)

    local _dir, fname = util.splitFilePathName(gamefile)
    local game_view = GameView:new{
        session    = result,
        game_title = fname,
        on_close   = function()
            self._game_view = nil
        end,
    }
    self._game_view = game_view
    game_view:show()
end

function Frotz:onFlushSettings()
    if self._settings then
        self._settings:flush()
    end
end

return Frotz
