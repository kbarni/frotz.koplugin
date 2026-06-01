local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Frotz = WidgetContainer:extend{
    name = "frotz",
    is_doc_only = false,
}

function Frotz:init()
    self.ui.menu:registerToMainMenu(self)
end

function Frotz:addToMainMenu(menu_items)
    menu_items.frotz = {
        text = _("Interactive Fiction"),
        sorting_hint = "tools",
        callback = function()
            self:openGameView()
        end,
    }
end

function Frotz:openGameView()
    local GameView = require("gameview")
    local game_view = GameView:new{
        game_title = _("Interactive Fiction"),
        on_close = function()
            self._game_view = nil
        end,
    }
    self._game_view = game_view
    UIManager:show(game_view)
end

return Frotz
