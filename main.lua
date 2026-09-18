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
local logger          = require("logger")
local util            = require("util")
local _               = require("gettext")
local T               = require("ffi/util").template
local Screen          = require("device").screen

local Resolver  = require("engines/resolver")
local GameLibrary = require("gamelibrary")
local monoface  = require("monoface")
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

-- Device ABI, not binary ABI: our VMs are statically linked, but a hard-float
-- (armhf) binary still won't run on a soft-float (armel) userspace, and
-- `uname -m` reports armv7l for both — it cannot tell them apart. The glibc
-- dynamic loader path *does* encode the float ABI, so probe for it. The files
-- are a proxy for the device, mutually exclusive on real hardware, and the
-- check is a dependency-free file stat (no subprocess).
local function file_exists(p)
    return lfs.attributes(p, "mode") ~= nil
end

local function detect_arch()
    if file_exists("/lib/ld-linux-armhf.so.3")    then return "armhf"  end -- Kobo, Kindle-hf
    if file_exists("/lib/ld-linux.so.3")          then return "armel"  end -- Kindle PW2 (soft-float)
    if file_exists("/lib64/ld-linux-x86-64.so.2") then return "x86_64" end
    if file_exists("/lib/ld-linux-aarch64.so.1")  then return "aarch64" end
    return "x86_64" -- emulator / desktop default
end

local _arch = detect_arch()

local function binary_for(vm)
    -- detect_arch() now reliably distinguishes armel/armhf/x86_64, so the binary
    -- lives at exactly one path. No arch-guessing fallbacks needed.
    -- Twine stories run on QuickJS (qjs) with the plugin's own player script.
    local exe = (vm == "twine") and "qjs" or vm
    local path = _plugin_dir .. "/binaries/" .. _arch .. "/" .. exe
    if lfs.attributes(path, "mode") then return path end
    return nil
end

local Frotz = WidgetContainer:extend{
    name        = "frotz",
    is_doc_only = false,
    _settings   = nil,
}

function Frotz:init()
    self.ui.menu:registerToMainMenu(self)
    self:_registerSimpleUIModule()
end

-- ── Simple UI integration ───────────────────────────────────────────────────────
-- If the Simple UI plugin (simpleui.koplugin) is installed, register a launcher
-- module on its homescreen. The module is a single tappable row that opens our
-- Recent games picker — quick access to resume playing. No-op when Simple UI is
-- absent, and safe to re-run: Registry.register() dedups by module id, so each
-- FileManager/Reader init just refreshes the descriptor with the current Frotz
-- instance (its captured `self` drives the tap).
function Frotz:_registerSimpleUIModule()
    -- Simple UI's registry lives at "modules/moduleregistry"; KOReader's
    -- PluginLoader puts every plugin root on package.path, so this require
    -- resolves to Simple UI's file when it is installed and enabled.
    local ok_reg, Registry = pcall(require, "modules/moduleregistry")
    if not (ok_reg and type(Registry) == "table" and Registry.register) then return end
    local ok_mod, mod = pcall(require, "simpleui_module")
    if not (ok_mod and type(mod) == "table" and mod.make) then return end
    pcall(function() Registry.register(mod.make(self)) end)
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

    table.insert(items, {
        text     = _("Find games on IFDB…"),
        callback = function() self:_openIfdbBrowser() end,
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
    local library = GameLibrary.open()
    for _idx, path in ipairs(list) do
        if lfs.attributes(path, "mode") == "file" then
            table.insert(kept, path)
            local _dir, fname = util.splitFilePathName(path)
            -- A known title (from IFDB, or one a Twine story reported) reads
            -- better than a file name like "index.html".
            local entry = library:get(path)
            table.insert(items, {
                text      = (entry and entry.title) or fname,
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

-- Standalone "Recent games" picker, used by the Simple UI launcher module (and
-- usable from anywhere). Shows the recent games in a full-screen Menu; tapping
-- one closes the picker and starts it. This mirrors _buildRecentSubmenu(), but
-- as a self-contained window that closes itself on selection (the main menu
-- closes automatically; a standalone Menu must be told to).
function Frotz:_openRecentPicker()
    self:_loadSettings()
    local list    = self:_recentGames()
    local library = GameLibrary.open()
    local kept    = {}
    local items   = {}
    local menu    -- forward reference so callbacks can close it
    for _idx, path in ipairs(list) do
        if lfs.attributes(path, "mode") == "file" then
            table.insert(kept, path)
            local _dir, fname = util.splitFilePathName(path)
            local entry = library:get(path)
            table.insert(items, {
                text      = (entry and entry.title) or fname,
                mandatory = lfs.attributes(self:_autosavePathFor(path), "mode")
                            and _("saved") or nil,
                -- Menu:onMenuSelect runs this callback, then close_callback,
                -- so the picker closes itself; we only start the game here.
                callback  = function()
                    self:_startGame(path)
                end,
            })
        end
    end
    if #kept ~= #list then
        self:_saveSetting("recent_games", kept)
    end

    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No recent games yet.\nOpen a game from the Tools menu ▸ Interactive Fiction."),
        })
        return
    end

    local Menu = require("ui/widget/menu")
    menu = Menu:new{
        title               = _("Recent games"),
        item_table          = items,
        is_popout           = false,
        is_borderless       = true,
        covers_fullscreen   = true,
        title_bar_fm_style  = true,
    }
    menu.close_callback = function() UIManager:close(menu) end
    UIManager:show(menu)
end

-- ── Display settings ────────────────────────────────────────────────────────────

function Frotz:_fontSize()
    self:_loadSettings()
    return self._settings:readSetting("font_size") or DEFAULT_FONT_SIZE
end

-- ── File browser ──────────────────────────────────────────────────────────────

-- An .html file is a game only if it holds a Twine story, and finding out reads
-- the file, so answers are remembered by path, size and modification time.
-- true / false, or nil when the file can't be examined.
local _twine_checked = {}
local function is_twine_story(path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end
    local known = _twine_checked[path]
    if known and known.size == attr.size and known.mtime == attr.modification then
        return known.ok
    end
    local ok = Resolver.is_twine_file(path)
    if ok == nil then return nil end
    _twine_checked[path] = { size = attr.size, mtime = attr.modification, ok = ok }
    return ok
end

function Frotz:_openFileBrowser()
    self:_loadSettings()
    local start_dir = self._settings:readSetting("game_directory")
                      or (DataStorage:getDataDir() .. "/ifgames")
    UIManager:show(PathChooser:new{
        select_directory = false,
        path             = start_dir,
        -- Show Z-machine, Glulx and Twine games (resolved by extension).
        -- KOReader's FileChooser reads this as `file_filter` (not `filter_func`),
        -- and only honours it when `show_unsupported` is false.
        show_unsupported = false,
        file_filter      = function(filename)
            return Resolver.is_supported(filename)
        end,
        -- file_filter gets only the name; an .html file must also hold a Twine
        -- story, which takes the full path that FileChooser:show_file has. Set
        -- here rather than after new(): the first listing happens in init.
        show_file        = function(chooser, filename, fullpath)
            if not PathChooser.show_file(chooser, filename, fullpath) then return false end
            if fullpath and Resolver.vm_for(filename) == "twine" then
                return is_twine_story(fullpath) == true
            end
            return true
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

-- ── IFDB browser ──────────────────────────────────────────────────────────────

function Frotz:_openIfdbBrowser()
    self:_loadSettings()
    local IfdbBrowser = require("ifdbbrowser")
    UIManager:show(IfdbBrowser:new{
        settings = self._settings,
        on_play  = function(path) self:_startGame(path) end,
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

-- Glk VMs write their own save format; the Twine player writes JSON.
local function save_ext_for(gamefile)
    return Resolver.vm_for(gamefile) == "twine" and ".json" or ".qzl"
end

function Frotz:_autosavePathFor(gamefile)
    return self:_saveDirFor(gamefile) .. "/autosave" .. save_ext_for(gamefile)
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
    -- An HTML page that isn't a Twine story (a walkthrough, a web page) can
    -- still arrive here, e.g. from Recent games: say so instead of starting.
    if vm == "twine" and is_twine_story(gamefile) == false then
        UIManager:show(InfoMessage:new{
            text = T(_("This HTML file is not a Twine story:\n%1"), gamefile),
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
    -- fixed-width typewriter face (Courier Prime) and word-wraps the story to
    -- `cols`, so one glyph advance is constant and wrapping lines up exactly with
    -- the rendered width. We measure the *same* face GameView renders with (see
    -- monoface.lua), or its bundled-mono fallback if the font is missing.
    -- usable is the TextBoxWidget's inner width: ScrollTextWidget reserves
    -- scroll_bar_width (6) + text_scroll_span (12) on the right, and GameView
    -- pads by Size.padding.large on each side.
    local face            = monoface.getFace(font_size)
    local advance         = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, "0").x
    local scroll_overhead = Screen:scaleBySize(6) + Screen:scaleBySize(12)
    local usable          = Screen:getWidth() - 2 * Size.padding.large - scroll_overhead
    local cols            = math.max(20, math.floor(usable / advance))
    -- rows is advertised tall so the VM never paginates; the UI owns paging.
    local rows = 200

    self:_pushRecent(gamefile)

    -- Per-game save directory holds the numbered slots and the autosave.
    local _dir, fname   = util.splitFilePathName(gamefile)
    local library       = GameLibrary.open()
    local known         = library:get(gamefile)
    local known_title   = known and known.title
    local save_dir      = self:_saveDirFor(gamefile)
    util.makePath(save_dir)
    local autosave_path = self:_autosavePathFor(gamefile)

    -- bocfel re-plays the whole transcript ("[Starting history playback]") on a
    -- verb restore unless -H is given; git (Glulx) has no such replay and rejects
    -- the flag, so only pass it to bocfel. qjs takes the Twine player script
    -- first, then the story file.
    local is_twine = vm == "twine"
    local extra_args = nil
    if vm == "bocfel" then
        extra_args = { "-H" }
    elseif is_twine then
        local player = _plugin_dir .. "/twine/player.js"
        if not lfs.attributes(player, "mode") then
            UIManager:show(InfoMessage:new{
                text = T(_("Twine player not found: %1"), player),
            })
            return
        end
        -- data: images are decoded into the game's save folder, not /tmp
        -- (a small RAM disk on e-readers).
        extra_args = { player, "--images=" .. save_dir .. "/images" }
    end

    local function launch(auto_restore)
        local ok, transport = pcall(Session.new, Session, binary, gamefile, extra_args)
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
            game_title   = known_title or fname,
            -- An IFDB title stays; otherwise a story's own title (Twine)
            -- replaces the file name and is remembered for the recent list.
            keep_title   = known ~= nil and known.source == "ifdb" and known_title ~= nil,
            on_title     = function(story_title)
                library:put(gamefile, { title = story_title })
            end,
            game_path    = gamefile,
            font_size    = font_size,
            cols         = cols,
            settings     = self._settings,
            save_dir     = save_dir,
            auto_restore = auto_restore,
            link_mode    = is_twine,
            state_saves  = is_twine,
            save_ext     = save_ext_for(gamefile),
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
