local Blitbuffer       = require("ffi/blitbuffer")
local Button           = require("ui/widget/button")
local ButtonDialog     = require("ui/widget/buttondialog")
local Device           = require("device")
local Font             = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local InputContainer   = require("ui/widget/container/inputcontainer")
local InputText        = require("ui/widget/inputtext")
local LineWidget       = require("ui/widget/linewidget")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size             = require("ui/size")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local _                = require("gettext")
local Screen           = Device.screen

-- GameView extends FrameContainer (not InputContainer/WidgetContainer).
-- FrameContainer.paintTo records its own dimen.x/y on every repaint, which
-- child InputContainers (Button, TitleBar IconButton) read for gesture
-- hit-testing.  A plain WidgetContainer does not do this, so button taps
-- would land at wrong coordinates and never fire.
--
-- is_always_active = true lets this widget receive events even when the
-- VirtualKeyboard sits above it in the UIManager window stack.  Without it,
-- UIManager only dispatches to the topmost widget (the keyboard) and all
-- buttons in the game view stop responding.
local GameView = FrameContainer:extend{
    bordersize        = 0,
    padding           = 0,
    background        = Blitbuffer.COLOR_WHITE,
    covers_fullscreen = true,
    is_always_active  = true,

    game_title = "Interactive Fiction",
    session    = nil,
    settings   = nil,
    on_close   = nil,
}

-- ── Initialisation ─────────────────────────────────────────────────────────────

function GameView:init()
    self.transcript       = ""
    self._polling         = false
    self._keyboard_height = 0
    self._waiting_for_tap = false
    self._sim_index       = 0
    self._sw              = Screen:getWidth()
    self._sh              = Screen:getHeight()
    self._face            = Font:getFace("x_smallinfofont")
    self:_build()
end

-- ── Event routing ──────────────────────────────────────────────────────────────

-- Guard against events arriving after UIManager:close(self) has been called
-- (the widget may briefly remain referenced while the close is being processed).
-- When we are on the stack, delegate to FrameContainer so its propagateEvent
-- reaches all child widgets.
function GameView:handleEvent(event)
    for i = #UIManager._window_stack, 1, -1 do
        if UIManager._window_stack[i].widget == self then
            return FrameContainer.handleEvent(self, event)
        end
    end
    return false
end

-- ── Widget construction ────────────────────────────────────────────────────────

function GameView:_build()
    local sw = self._sw
    local sh = self._sh

    -- Title bar
    self._title_bar = TitleBar:new{
        width                  = sw,
        with_bottom_line       = true,
        title                  = self.game_title,
        left_icon              = "appbar.menu",
        left_icon_tap_callback = function() self:showMenu() end,
        close_callback         = function() self:onClose() end,
        show_parent            = self,
    }
    self._title_h = self._title_bar:getHeight()

    -- Horizontal margin applied to the transcript area (reading content).
    -- Title bar, separator, and input bar span the full screen width by design.
    self._scroll_margin = Size.padding.large  -- left + right margin for reading area

    -- Input bar ───────────────────────────────────────────────────────────────
    -- InputText reports self.width as the INNER text width.  The widget itself
    -- is rendered wider by 2*(bordersize + margin + padding) due to the internal
    -- _frame_textwidget FrameContainer.  We subtract that overhead so the
    -- HorizontalGroup [InputText | Send] sums exactly to screen width.
    local it_pad    = Size.padding.large      -- comfortable touch padding
    local it_extra  = 2 * (Size.border.inputtext + Size.margin.default + it_pad)
    local btn_w     = math.floor(sw * 0.14)
    local itext_w   = sw - btn_w - it_extra
    local itext_h   = math.ceil(self._face.size * 1.6) + 2 * it_pad

    self._input_widget = InputText:new{
        text           = "",
        hint           = _("Enter command…"),
        face           = self._face,
        width          = itext_w,
        height         = itext_h,
        scroll         = false,
        focused        = false,
        parent         = self,
        padding        = it_pad,
        enter_callback = function() self:onSubmit() end,
    }

    local send_btn = Button:new{
        text        = "↩",
        width       = btn_w,
        show_parent = self,
        callback    = function() self:onSubmit() end,
    }

    self._input_bar = HorizontalGroup:new{
        align = "center",
        self._input_widget,
        send_btn,
    }
    self._input_bar_h = self._input_bar:getSize().h

    -- Separator line
    self._sep_h = Screen:scaleBySize(1)
    self._sep   = LineWidget:new{
        dimen = Geom:new{ w = sw, h = self._sep_h },
    }

    -- Transcript: fills the space above the input bar, below the title bar.
    -- Keyboard height starts at 0; _syncKeyboardHeight() corrects it once
    -- the VirtualKeyboard is fully initialised.
    -- Width is narrowed by the horizontal margin so the reading area has
    -- visible breathing room on both sides.
    self._scroll_w = sw - 2 * self._scroll_margin
    self._scroll_h = sh - self._title_h - self._sep_h
                     - self._input_bar_h - self._keyboard_height
    if self._scroll_h < 80 then self._scroll_h = 80 end

    self._scroll = self:_buildScrollWidget()

    -- Assemble
    -- align = "center" so the narrower scroll widget is centred on screen
    -- while full-width elements (title bar, separator, input bar) remain edge-to-edge.
    self._vgroup = VerticalGroup:new{
        align = "center",
        self._title_bar,  -- [1]
        self._scroll,     -- [2]  ← replaced on each update
        self._sep,        -- [3]
        self._input_bar,  -- [4]
    }

    -- Fill any leftover pixels (VerticalGroup ignores a 'height' field)
    local used = self._title_h + self._scroll_h + self._sep_h + self._input_bar_h
    local gap  = sh - self._keyboard_height - used
    if gap > 0 then
        table.insert(self._vgroup, VerticalSpan:new{ width = sw, height = gap })
    end

    self[1]    = self._vgroup
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    -- Show the keyboard after the widget has been added to the UIManager stack,
    -- then read the actual keyboard height so we can resize the transcript.
    UIManager:scheduleIn(0.15, function()
        if self._input_widget then
            self._input_widget:onShowKeyboard()
        end
    end)
    UIManager:scheduleIn(0.45, function()
        self:_syncKeyboardHeight()
    end)
end

-- ── Keyboard height management ─────────────────────────────────────────────────

-- Read the VirtualKeyboard's actual height and shrink the transcript to match.
-- Must be called after a brief delay so the keyboard widget is fully laid out.
function GameView:_syncKeyboardHeight()
    local h = 0
    if self._input_widget and self._input_widget.keyboard then
        local d = self._input_widget.keyboard.dimen
        h = (d and d.h) or 0
    end
    if h ~= self._keyboard_height then
        self._keyboard_height = h
        self._scroll_h = self._sh - self._title_h - self._sep_h
                         - self._input_bar_h - self._keyboard_height
        if self._scroll_h < 80 then self._scroll_h = 80 end
        self:_refreshDisplay()  -- rebuilds scroll widget with new height
    end
end

-- Called by VirtualKeyboard when its layout language changes height.
function GameView:onKeyboardHeightChanged()
    UIManager:scheduleIn(0.1, function() self:_syncKeyboardHeight() end)
    return true
end

-- Called by VirtualKeyboard on DPad devices when the keyboard is dismissed.
function GameView:onKeyboardClosed()
    self._keyboard_height = 0
    self._scroll_h = self._sh - self._title_h - self._sep_h - self._input_bar_h
    if self._scroll_h < 80 then self._scroll_h = 80 end
    self:_refreshDisplay()
    return true
end

-- ── Transcript helpers ─────────────────────────────────────────────────────────

function GameView:_buildScrollWidget()
    return ScrollTextWidget:new{
        text          = self.transcript,
        face          = self._face,
        width         = self._scroll_w,
        height        = self._scroll_h,
        scroll_by_pan = true,
        dialog        = self,
    }
end

-- Replace the transcript widget in the layout with a fresh one and repaint.
function GameView:_refreshDisplay()
    local new_scroll = self:_buildScrollWidget()
    new_scroll:scrollToBottom()
    if self._vgroup[2] and self._vgroup[2].free then
        self._vgroup[2]:free()
    end
    self._vgroup[2] = new_scroll
    self._scroll    = new_scroll
    self._vgroup:resetLayout()
    UIManager:setDirty(self, "ui")
end

-- ── Player input ───────────────────────────────────────────────────────────────

function GameView:onSubmit()
    local cmd = self._input_widget:getText() or ""
    cmd = cmd:match("^%s*(.-)%s*$") or ""
    if cmd == "" then return end

    if self.transcript ~= "" then
        self.transcript = self.transcript .. "\n"
    end
    self.transcript = self.transcript .. "> " .. cmd
    self._input_widget:setText("")

    if self.session then
        self.session:send_input(cmd)
    else
        self:_simulateResponse()
    end
    self:_refreshDisplay()
end

local _SIM_RESPONSES = {
    "West of House\nYou are standing in an open field west of a white house,\nwith a boarded front door.\nThere is a small mailbox here.",
    "The mailbox is open. Inside the mailbox is a leaflet.",
    "Taken.",
    "Dropped. The leaflet flutters to the ground.",
}

local _SIM_CONTINUATIONS = {
    "A path leads north. You can hear wind in the trees to the east.",
    "You can see the sun beginning to set over the white house.",
    "You are carrying: a leaflet.",
    "The leaflet lies at your feet.",
}

function GameView:_simulateResponse()
    self._sim_index = self._sim_index + 1
    local r = _SIM_RESPONSES[((self._sim_index - 1) % #_SIM_RESPONSES) + 1]
    self.transcript = self.transcript .. "\n" .. r .. "\n\n[Tap to continue]"
    self._waiting_for_tap = true
    self:_showTapOverlay()
end

-- Show an invisible InputContainer over the scroll area that intercepts one tap.
-- GameView extends FrameContainer (no gesture machinery); registerTouchZones on
-- a thin InputContainer overlay is the correct KOReader pattern.
function GameView:_showTapOverlay()
    local gameview = self
    local sh = self._sh
    -- modal = true so UIManager places this above the VirtualKeyboard (which is
    -- also modal); without it the overlay is inserted below the keyboard and
    -- never becomes top_widget, so it never receives gesture events.
    local overlay = InputContainer:new{
        modal = true,
        dimen = Geom:new{ x = 0, y = 0, w = self._sw, h = sh },
    }
    overlay:registerTouchZones({
        {
            id = "frotz_tap_continue",
            ges = "tap",
            screen_zone = {
                ratio_x = 0,
                ratio_y = self._title_h / sh,
                ratio_w = 1,
                ratio_h = (sh - self._title_h - self._keyboard_height) / sh,
            },
            handler = function()
                UIManager:close(overlay)
                gameview._tap_overlay = nil
                gameview:_onTapContinue()
                return true
            end,
        },
    })
    self._tap_overlay = overlay
    UIManager:show(overlay)
end

function GameView:_onTapContinue()
    self.transcript = self.transcript:gsub("\n*%[Tap to continue%]\n*$", "")
    local c = _SIM_CONTINUATIONS[((self._sim_index - 1) % #_SIM_CONTINUATIONS) + 1]
    self.transcript = self.transcript .. "\n" .. c
    self._waiting_for_tap = false
    self:_refreshDisplay()
end

-- Append game output text to the transcript (called by session poller).
function GameView:appendOutput(text)
    if self.transcript ~= "" then
        self.transcript = self.transcript .. "\n"
    end
    self.transcript = self.transcript .. text
    self:_refreshDisplay()
end

-- ── In-game menu ───────────────────────────────────────────────────────────────

function GameView:showMenu()
    local menu
    menu = ButtonDialog:new{
        modal = true,
        shrink_unneeded_width = true,
        anchor = function()
            return self._title_bar.left_button.image.dimen
        end,
        buttons = {
            {{
                text     = _("Scroll to bottom"),
                callback = function()
                    UIManager:close(menu)
                    self._scroll:scrollToBottom()
                    UIManager:setDirty(self, "ui")
                end,
            }},
            {{
                text     = _("Close game"),
                callback = function()
                    UIManager:close(menu)
                    self:onClose()
                end,
            }},
        },
    }
    UIManager:show(menu)
end

-- ── Close ──────────────────────────────────────────────────────────────────────

function GameView:onClose()
    self._polling = false
    if self._tap_overlay then
        UIManager:close(self._tap_overlay)
        self._tap_overlay = nil
    end
    -- Hide the keyboard before removing ourselves from the stack.
    -- UIManager:close(self) does not automatically close the keyboard window.
    if self._input_widget then
        self._input_widget:onCloseKeyboard()
    end
    if self.on_close then
        self.on_close()
    end
    -- "full" triggers a full-screen repaint so the underlying KOReader UI
    -- redraws correctly after the game view is gone.
    UIManager:close(self, "full")
end

return GameView
