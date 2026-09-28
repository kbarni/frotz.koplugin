-- simpleui_integration.lua — everything the Frotz plugin puts on Simple UI.
--
-- Simple UI (simpleui.koplugin) replaces KOReader's file manager with a launch
-- screen, and lets other plugins add themselves to it in two independent ways.
-- We use both, and they are the whole of this file:
--
--   • a homescreen **module** — the games you played last, one tappable row
--     each (the interactive-fiction counterpart of Simple UI's Recent Books),
--     registered with modules/moduleregistry;
--   • a **quick action** — "Interactive Fiction" on the bottom bar or in a
--     Quick Actions row, opening the Recent games picker, registered with
--     features/sui_quickactions.
--
-- Simple UI keeps those in two separate registries and one does not imply the
-- other, but everything else about them is shared (the same recent games, the
-- same live-instance lookup), so they live together here. register(plugin) does
-- both and is a no-op when Simple UI is absent or older than either registry.
--
-- Only KOReader widgets are used for the rows, and our one setting ("Games
-- shown") lives in the Frotz plugin's own LuaSettings rather than Simple UI's
-- per-screen store, so this file has no build-time dependency on Simple UI
-- internals and survives its refactors.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local lfs             = require("libs/libkoreader-lfs")
local _               = require("gettext")
local Screen          = Device.screen

local _plugin_dir = debug.getinfo(1, "S").source:match("@(.+)/[^/]+$") or "."

-- Row geometry at 100% scale. Simple UI passes ctx.landscape_factor (a scale
-- multiplier) which we honour so the rows match neighbouring modules.
local _BASE_ROW_H = Screen:scaleBySize(34)  -- one game's row, in pixels
-- Font sizes are *points*, not pixels: Font:getFace() runs the size through
-- Screen:scaleBySize() itself, so scaling here too made the titles render at
-- roughly DPI-squared — visibly oversized on high-DPI devices (Kindle) while
-- looking right in the emulator. 16 sits just under Simple UI's own body text
-- (SUIStyle.FS_BODY = 18), which suits a compact list of rows.
local _BASE_FS    = 16                      -- title font size

-- Width-independent vertical metrics, shared by build() and getHeight() so the
-- height Simple UI reserves matches the widget actually rendered. A
-- FrameContainer's height is content_h + 2*(bordersize + padding) (margin = 0).
local function _dims(ctx)
    local scale  = ctx and ctx.landscape_factor or 1
    local row_h  = math.max(Screen:scaleBySize(24), math.floor(_BASE_ROW_H * scale))
    local fs     = math.max(10, math.floor(_BASE_FS * scale))
    local pad    = Size.padding.default
    local border = Size.border.thin
    local line   = Size.line.thin
    return row_h, fs, pad, border, line
end

-- Both descriptors are registered once per FileManager/ReaderUI init and
-- capture that instance. A row or an action can be tapped much later, from the
-- other one, so resolve the plugin instance of whichever UI is live now and
-- keep the captured one only as a fallback.
local function _live(fallback)
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    if fm and fm.frotz then return fm.frotz end
    local RUI = package.loaded["apps/reader/readerui"]
    local rui = RUI and RUI.instance
    if rui and rui.frotz then return rui.frotz end
    return fallback
end

-- ── Homescreen module ─────────────────────────────────────────────────────────

-- The rows to draw: one per recent game, plus a final "More…" row when the
-- list is longer than what fits the user's chosen count, or a single invitation
-- row when nothing has been played yet. build() and getHeight() both call this,
-- so they can never disagree about how many rows there are.
--   { label = …, right = …|nil, run = function() … end }
-- Uncached on purpose: it stats each game file and reads the game library once
-- per call (twice per render, for getHeight and build). That is a few small
-- reads, and it keeps the list honest right after a game is played or deleted —
-- a cache would have to be invalidated from outside this file.
local function _rows(plugin)
    local p = _live(plugin)
    if not p then return {} end
    local entries = p:_recentEntries()
    local rows = {}

    if #entries == 0 then
        return { {
            label = _("Open a game…"),
            run   = function() p:_openFileBrowser() end,
        } }
    end

    local shown = math.min(p:_simpleuiRowCount(), #entries)
    for i = 1, shown do
        local e = entries[i]
        rows[#rows + 1] = {
            label = e.title,
            right = e.saved and _("saved") or nil,
            run   = function() p:_startGame(e.path) end,
        }
    end
    if #entries > shown then
        rows[#rows + 1] = {
            label = _("More games…"),
            run   = function() p:_openRecentPicker(true) end,
        }
    end
    return rows
end

-- One row: title on the left, an optional marker on the right, the whole strip
-- tappable. OverlapGroup rather than a HorizontalGroup because the two texts are
-- anchored to opposite edges with a variable gap between them.
local function _rowWidget(inner_w, row_h, fs, row)
    local right, right_w = nil, 0
    if row.right then
        right = TextWidget:new{
            text = row.right,
            face = Font:getFace("cfont", math.max(9, fs - 4)),
        }
        right_w = right:getSize().w + Size.span.horizontal_default
    end

    local title = TextWidget:new{
        text      = row.label,
        face      = Font:getFace("cfont", fs),
        max_width = math.max(0, inner_w - right_w),
    }

    local row_dimen = Geom:new{ w = inner_w, h = row_h }
    local overlap = OverlapGroup:new{
        dimen = row_dimen:copy(),
        LeftContainer:new{ dimen = row_dimen:copy(), title },
    }
    if right then
        table.insert(overlap, RightContainer:new{ dimen = row_dimen:copy(), right })
    end

    local container = InputContainer:new{
        dimen = row_dimen:copy(),
        overlap,
    }
    container.ges_events = {
        TapFrotzGame = {
            GestureRange:new{
                ges   = "tap",
                -- InputContainer:paintTo keeps dimen.x/y current, so this is the
                -- row's real position on screen once the homescreen is drawn.
                range = function() return container.dimen end,
            },
        },
    }
    function container:onTapFrotzGame()
        row.run()
        return true
    end
    return container
end

-- The module descriptor, bound to `plugin` (the Frotz WidgetContainer). It
-- speaks Simple UI's module contract (see the header of
-- simpleui.koplugin/modules/moduleregistry.lua):
--
--   M.id, M.name                     identity (shown in the Arrange list)
--   M.label                          section header above the rows
--   M.enabled_key, M.default_on      on/off toggle, persisted per screen
--   M.build(w, ctx)   -> widget|nil  the rendered rows
--   M.getHeight(ctx)  -> number      their height, width-independent
--   M.getMenuItems(ctx_menu)         its settings sub-menu ("Games shown")
local function _makeModule(plugin)
    local M = {}
    M.id          = "frotz_recent"
    M.name        = _("Interactive Fiction")
    M.label       = _("Interactive Fiction")   -- section header above the rows
    M.enabled_key = "frotz_recent_enabled"
    M.default_on  = true

    function M.build(w, ctx)
        local row_h, fs, pad, border, line_h = _dims(ctx)
        local rows = _rows(plugin)
        if #rows == 0 then return nil end

        local inner_w = w - 2 * (pad + border)
        local group   = VerticalGroup:new{ align = "left" }
        for i, row in ipairs(rows) do
            if i > 1 then
                table.insert(group, LineWidget:new{
                    background = Blitbuffer.COLOR_GRAY,
                    dimen      = Geom:new{ w = inner_w, h = line_h },
                })
            end
            table.insert(group, _rowWidget(inner_w, row_h, fs, row))
        end

        return FrameContainer:new{
            width      = w,
            margin     = 0,
            bordersize = border,
            radius     = Size.radius.button,
            padding    = pad,
            background = Blitbuffer.COLOR_WHITE,
            group,
        }
    end

    function M.getHeight(ctx)
        local row_h, _fs, pad, border, line_h = _dims(ctx)
        local n = #_rows(plugin)
        if n == 0 then return 0 end
        return n * row_h + (n - 1) * line_h + 2 * (pad + border)
    end

    -- Settings sub-menu: how many games the list shows. ctx_menu carries the
    -- screen prefix, a refresh() that redraws the homescreen, and the
    -- translation function Simple UI wants used for its own menus.
    function M.getMenuItems(ctx_menu)
        local refresh = ctx_menu and ctx_menu.refresh or function() end
        local _lc     = (ctx_menu and ctx_menu._) or _
        local items   = {}
        for _idx, n in ipairs({ 1, 3, 5, 8 }) do
            table.insert(items, {
                text_func = function()
                    return string.format(_lc("%d games"), n)
                end,
                checked_func = function()
                    local p = _live(plugin)
                    return p ~= nil and p:_simpleuiRowCount() == n
                end,
                radio          = true,
                keep_menu_open = true,
                callback = function()
                    local p = _live(plugin)
                    if p then p:_setSimpleuiRowCount(n) end
                    refresh()
                end,
            })
        end
        return {
            {
                text           = _lc("Games shown"),
                sub_item_table = items,
            },
        }
    end

    return M
end

-- ── Quick action ──────────────────────────────────────────────────────────────

-- Simple UI takes icons as absolute paths to an SVG/PNG. Ours ships with the
-- plugin; fall back to Simple UI's generic plugin icon if it ever goes missing,
-- because a nil icon would leave the bar with an empty slot.
local function _icon()
    local own = _plugin_dir .. "/icons/frotz.svg"
    if lfs.attributes(own, "mode") == "file" then return own end
    local ok, Config = pcall(require, "infra/sui_config")
    if ok and Config and Config.ICON then return Config.ICON.plugin end
    return nil
end

-- The action descriptor, bound to `plugin`. It speaks Simple UI's action
-- contract (see the header of simpleui.koplugin/features/sui_quickactions.lua):
--
--   id                 unique, stable string
--   label / icon       what the picker and the bar show (user-overridable)
--   is_in_place        true  → Simple UI keeps its screen open and just runs us
--   is_async_in_place  true  → our UI outlives execute(), so Simple UI must not
--                              do its window-stack sink/restore dance around it
--   execute(ctx)       do the thing
local function _makeQuickAction(plugin)
    return {
        id                = "frotz_play",
        label             = _("Interactive Fiction"),
        icon              = _icon(),
        -- The picker and the game view are plain KOReader widgets shown on top
        -- of whatever Simple UI has open, and they stay up after execute()
        -- returns: in-place, asynchronously.
        is_in_place       = true,
        is_async_in_place = true,
        execute = function(_ctx)
            local p = _live(plugin)
            if p and p._openRecentPicker then
                p:_openRecentPicker(true)   -- true: no recent game → file browser
            end
        end,
    }
end

-- ── Registration ──────────────────────────────────────────────────────────────

-- Put both on Simple UI, if it is installed. KOReader's PluginLoader puts every
-- plugin root on package.path, so these requires resolve to Simple UI's files
-- when it is there, and fail harmlessly when it is not. Safe to re-run: both
-- registries key on the descriptor's id, so each FileManager/Reader init just
-- refreshes them with the current Frotz instance.
--
-- Called from Frotz:init(), i.e. while the FileManager is building its plugins
-- and before Simple UI's own init: that matters, because Simple UI drops
-- configured bar slots whose action id is not registered yet.
local function register(plugin)
    local ok_reg, Registry = pcall(require, "modules/moduleregistry")
    if ok_reg and type(Registry) == "table" and Registry.register then
        pcall(function() Registry.register(_makeModule(plugin)) end)
    end

    local ok_qa, QA = pcall(require, "features/sui_quickactions")
    if ok_qa and type(QA) == "table" and QA.register then
        pcall(function() QA.register(_makeQuickAction(plugin)) end)
    end
end

return {
    register       = register,
    -- register() is what the plugin calls; the two factories are exposed for
    -- off-device tests with stubbed widgets.
    makeModule      = _makeModule,
    makeQuickAction = _makeQuickAction,
}
