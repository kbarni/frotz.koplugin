local PathChooser      = require("ui/widget/pathchooser")
local SpinWidget       = require("ui/widget/spinwidget")
local UIManager        = require("ui/uimanager")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local lfs              = require("libs/libkoreader-lfs")
local ffiUtil          = require("ffi/util")
local logger           = require("logger")
local util             = require("util")
local _                = require("gettext")

-- Resolve the plugin directory from this file's path so we can locate the
-- interpreter binaries regardless of install location.
local _plugin_dir = debug.getinfo(1, "S").source:match("@(.+)/[^/]+$") or "."

local GameView = require("gameview")
local Session  = require("session")
local Settings = require("settings")
local Resolver = require("engines/resolver")

-- JSON codec for the engine. KOReader bundles rapidjson (gate confirmed on the
-- emulator 2026-06-06); the headless harness injects its own codec instead.
local rapidjson = require("rapidjson")

-- ── Binary lookup ──────────────────────────────────────────────────────────────
-- Prefer a per-arch binary under binaries/<arch>/, fall back to bin/ (the host
-- spike build used by the emulator). Arch detection is best-effort here and is
-- finalized alongside the cross-builds in Phase 5; the file-existence scan makes
-- it self-correcting when only one arch is actually present.

local function detect_arch()
    local m
    local p = io.popen and io.popen("uname -m 2>/dev/null")
    if p then m = p:read("*l"); p:close() end
    m = m or ""
    if m:match("x86_64") or m:match("amd64") then return "x86_64" end
    if m:match("aarch64") then return "aarch64" end
    if m:match("arm") then return "armhf" end   -- soft/hard refined in Phase 5
    return "x86_64"
end

local _arch = detect_arch()

local function file_exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

-- Return an absolute path to the VM binary, trying the detected arch first, then
-- any other built arch, then the bin/ spike build. Returns nil if none found.
local function binary_for(vm)
    local candidates = {
        _plugin_dir .. "/binaries/" .. _arch .. "/" .. vm,
        _plugin_dir .. "/binaries/armhf/" .. vm,
        _plugin_dir .. "/binaries/armel/" .. vm,
        _plugin_dir .. "/binaries/x86_64/" .. vm,
        _plugin_dir .. "/bin/" .. vm,
    }
    for _, path in ipairs(candidates) do
        if file_exists(path) then return path end
    end
    return nil
end

-- ── Plugin ──────────────────────────────────────────────────────────────────────

local FrotzPlugin = WidgetContainer:extend{
    name        = "frotz",
    is_doc_only = false,
    _settings   = nil,
    _session    = nil,
    _game_view  = nil,
}

function FrotzPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function FrotzPlugin:_loadSettings()
    if not self._settings then
        self._settings = Settings:load()
    end
end

-- ── Menu integration ──────────────────────────────────────────────────────────

function FrotzPlugin:addToMainMenu(menu_items)
    menu_items.frotz = {
        text         = _("Interactive Fiction"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            self:_loadSettings()
            return self:_buildMenuItems()
        end,
    }
end

function FrotzPlugin:_buildMenuItems()
    local items = {}

    table.insert(items, {
        text     = _("Open game…"),
        callback = function() self:_openFileBrowser() end,
    })

    if self._settings.last_game then
        local _dir, fname = util.splitFilePathName(self._settings.last_game)
        table.insert(items, {
            text     = ffiUtil.template(_("Resume: %1"), fname),
            callback = function() self:_startGame(self._settings.last_game) end,
        })
    end

    table.insert(items, {
        text            = _("Settings"),
        separator       = true,
        sub_item_table  = self:_buildSettingsItems(),
    })

    return items
end

function FrotzPlugin:_buildSettingsItems()
    return {
        {
            text_func = function()
                return ffiUtil.template(_("Font size: %1"), self._settings.font_size)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    value         = self._settings.font_size,
                    value_min     = 10,
                    value_max     = 30,
                    default_value = 18,
                    title_text    = _("Font size"),
                    callback      = function(spin)
                        self._settings.font_size = spin.value
                        Settings:save(self._settings)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end,
        },
        {
            text = _("Show keyboard on start"),
            checked_func = function()
                return self._settings.show_keyboard
            end,
            callback = function()
                self._settings.show_keyboard = not self._settings.show_keyboard
                Settings:save(self._settings)
            end,
        },
    }
end

-- ── File browser ──────────────────────────────────────────────────────────────

function FrotzPlugin:_openFileBrowser()
    self:_loadSettings()
    UIManager:show(PathChooser:new{
        select_directory = false,
        path             = self._settings.game_directory,
        -- Show both Z-machine and Glulx games (PathChooser passes each filename).
        filter_func = function(filename)
            return Resolver.is_supported(filename)
        end,
        onConfirm = function(file_path)
            local dir = file_path:match("(.*)/")
            if dir and dir ~= "" then
                self._settings.game_directory = dir
                Settings:save(self._settings)
            end
            self:_startGame(file_path)
        end,
    })
end

-- ── Game startup ──────────────────────────────────────────────────────────────

function FrotzPlugin:_showError(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text })
    logger.err("FrotzPlugin:", text)
end

function FrotzPlugin:_startGame(gamefile)
    self:_loadSettings()

    -- Pick the interpreter from the extension, then find its binary.
    local vm = Resolver.vm_for(gamefile)
    if not vm then
        self:_showError(_("Unsupported game format: ") .. tostring(gamefile))
        return
    end
    local binary = binary_for(vm)
    if not binary then
        self:_showError(ffiUtil.template(
            _("Interpreter binary not found: %1 (arch %2)"), vm, _arch))
        return
    end

    -- Character grid advertised to the VM via the JSON init. We keep the buffer
    -- window tall so the VM never paginates — paging is the UI's job (Phase 3).
    local cols = 80
    local rows = 50

    self._settings.last_game = gamefile
    Settings:save(self._settings)

    -- Spawn the VM subprocess, then wrap it in the RemGlk JSON engine.
    local ok, transport = pcall(Session.new, Session, binary, gamefile)
    if not ok then
        self:_showError(_("Failed to start interpreter:\n") .. tostring(transport))
        return
    end
    local engine = require("engines/remglk"):new(transport, rapidjson, cols, rows)

    self._session = transport
    local _, fname = util.splitFilePathName(gamefile)

    self._game_view = GameView:new{
        engine     = engine,
        settings   = self._settings,
        game_title = fname,
        on_close   = function()
            self._session   = nil
            self._game_view = nil
        end,
    }
    self._game_view:show()
end

-- ── Suspend / resume ──────────────────────────────────────────────────────────

function FrotzPlugin:onSuspend()
    -- The VM keeps running; its state lives in the child process.
end

function FrotzPlugin:onResume()
    -- Nothing needed — the game view is still on screen.
end

function FrotzPlugin:onFlushSettings()
    if self._settings then
        Settings:save(self._settings)
    end
end

return FrotzPlugin
