-- simpleui_module.lua — a Simple UI homescreen module for the Frotz plugin.
--
-- Simple UI (simpleui.koplugin) builds its launch screen from "modules"
-- registered in modules/moduleregistry.lua. Third-party plugins add their own
-- via Registry.register(<module table>). This file is that module: a single
-- tappable launcher row whose tap opens the Frotz "Recent games" picker — a
-- quick way to resume playing without going through the Tools menu.
--
-- It is a *factory*: require() it and call make(plugin) to get a descriptor
-- bound to the live Frotz plugin instance (its methods do the actual work).
-- The descriptor speaks Simple UI's module contract (see the header of
-- simpleui.koplugin/modules/moduleregistry.lua):
--
--   M.id, M.name                     identity (shown in the Arrange list)
--   M.enabled_key, M.default_on      on/off toggle, persisted per screen
--   M.build(w, ctx)   -> widget|nil  the rendered row
--   M.getHeight(ctx)  -> number      its height, width-independent
--
-- Only KOReader widgets are used here, so the module has no build-time
-- dependency on Simple UI internals and survives its refactors.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local _               = require("gettext")
local Screen          = Device.screen

-- Row geometry at 100% scale. Simple UI passes ctx.landscape_factor (a scale
-- multiplier) which we honour so the row matches neighbouring modules.
local _BASE_INNER_H = Screen:scaleBySize(40)  -- content band height
local _BASE_FS      = Screen:scaleBySize(20)  -- label font size

-- Width-independent vertical metrics, shared by build() and getHeight() so the
-- height Simple UI reserves matches the widget actually rendered. A
-- FrameContainer's height is content_h + 2*(bordersize + padding) (margin = 0).
local function _dims(ctx)
    local scale   = ctx and ctx.landscape_factor or 1
    local inner_h = math.max(Screen:scaleBySize(28), math.floor(_BASE_INNER_H * scale))
    local fs      = math.max(12, math.floor(_BASE_FS * scale))
    local pad     = Size.padding.default
    local border  = Size.border.thin
    return inner_h, fs, pad, border
end

-- make(plugin) -> Simple UI module descriptor bound to `plugin` (the Frotz
-- WidgetContainer instance). Its tap handler calls plugin:_openRecentPicker().
local function make(plugin)
    local M = {}
    M.id         = "frotz_recent"
    M.name       = _("Interactive Fiction")
    M.label      = nil            -- no section header; the row is self-describing
    M.enabled_key = "frotz_recent_enabled"
    M.default_on = true

    function M.build(w, ctx)
        local inner_h, fs, pad, border = _dims(ctx)

        local label = TextWidget:new{
            text = "▶  " .. M.name,
            face = Font:getFace("cfont", fs),
            bold = true,
        }

        local frame = FrameContainer:new{
            width      = w,
            margin     = 0,
            bordersize = border,
            radius     = Size.radius.button,
            padding    = pad,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = w - 2 * (pad + border), h = inner_h },
                label,
            },
        }

        local container = InputContainer:new{
            dimen = Geom:new{ w = w, h = frame:getSize().h },
            frame,
        }
        container.ges_events = {
            TapFrotzRecent = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return container.dimen end,
                },
            },
        }
        function container:onTapFrotzRecent()
            if plugin and plugin._openRecentPicker then
                plugin:_openRecentPicker()
            end
            return true
        end
        return container
    end

    function M.getHeight(ctx)
        local inner_h, _fs, pad, border = _dims(ctx)
        return inner_h + 2 * (pad + border)
    end

    return M
end

return { make = make }
