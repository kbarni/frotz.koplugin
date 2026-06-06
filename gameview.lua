--[[
    gameview.lua — full-screen game UI, driven by the RemGlk JSON engine.

      ┌─────────────────────────────────┐
      │ ☰  zork.z5                    X │  ← TitleBar
      │ West of House      Score:0 Mv:0 │  ← status line (grid window)
      ├─────────────────────────────────┤
      │  [scrollable transcript]        │  ← buffer window, story runs
      ├─────────────────────────────────┤
      │ [⌨] [type here…]         [Send] │  ← input bar (line / char)
      └─────────────────────────────────┘

    Phase 2 scope: launch the engine, render the first screen and every turn,
    accept line and char input, show the status line. The rendering is plain
    text — Phase 3 layers the style→render mapping, a fixed-cell grid status
    widget, and our own [Tap to continue…] paging; Phase 4 adds save/restore.

    GameView extends FrameContainer (matches the pattern used by interactive
    full-screen plugins) so TitleBar buttons receive gesture events.
--]]

local Blitbuffer       = require("ffi/blitbuffer")
local Button           = require("ui/widget/button")
local ButtonDialog     = require("ui/widget/buttondialog")
local ConfirmBox       = require("ui/widget/confirmbox")
local Font             = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local InputText        = require("ui/widget/inputtext")
local LineWidget       = require("ui/widget/linewidget")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextWidget       = require("ui/widget/textwidget")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local Size             = require("ui/size")
local Screen           = require("device").screen
local _                = require("gettext")

local POLL_INTERVAL_S = 0.05    -- 50 ms between polls
local POLL_TIMEOUT_S  = 30.0    -- give up waiting for a turn after 30 s

local GameView = FrameContainer:extend{
    bordersize        = 0,
    padding           = 0,
    background        = Blitbuffer.COLOR_WHITE,
    covers_fullscreen = true,
    is_always_active  = true,

    -- Set via :new{...}
    engine     = nil,
    settings   = nil,
    game_title = "",
    on_close   = nil,
}

-- ── Initialisation ────────────────────────────────────────────────────────────

function GameView:init()
    self.transcript        = ""
    self._status           = ""
    self.history           = require("history"):new(self.settings.history_size)
    self._polling          = false
    self._poll_start       = 0
    self._input_kind       = "line"   -- "line" | "char" | nil (turn in flight)
    self._input_window     = nil
    self._keyboard_visible = self.settings.show_keyboard
    self._keyboard_height  = 0

    self:_build()
end

-- ── Event handling ────────────────────────────────────────────────────────────

function GameView:handleEvent(event)
    local on_stack = false
    for i = #UIManager._window_stack, 1, -1 do
        if UIManager._window_stack[i].widget == self then
            on_stack = true
            break
        end
    end
    if not on_stack then return false end
    return FrameContainer.handleEvent(self, event)
end

-- ── Widget construction ───────────────────────────────────────────────────────

function GameView:_build()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self._sw, self._sh = sw, sh

    -- Title bar
    self._title_bar = TitleBar:new{
        fullscreen             = true,
        title                  = self.game_title,
        width                  = sw,
        with_bottom_line       = true,
        left_icon              = "appbar.menu",
        left_icon_tap_callback = function() self:_showMenu() end,
        close_callback         = function() self:_confirmQuit() end,
        show_parent            = self,
    }
    self._title_h = self._title_bar:getSize().h

    -- Status line (grid window). Rebuilt each turn in _refreshDisplay.
    self._status_w = self:_buildStatus()
    self._status_h = self._status_w:getSize().h

    -- Input bar
    local face    = Font:getFace("x_smallinfofont", self.settings.font_size)
    local btn_w   = math.floor(sw * 0.14)
    local padding = Screen:scaleBySize(4)
    local it_extra = 2 * (Size.border.inputtext + Size.margin.default + padding)
    local itext_w = sw - 2 * btn_w - it_extra
    local itext_h = math.ceil(face.size * 1.6) + 2 * padding

    self._input_text = InputText:new{
        text           = "",
        face           = face,
        width          = itext_w,
        height         = itext_h,
        scroll         = false,
        focused        = false,
        parent         = self,
        padding        = padding,
        enter_callback = function() self:_onSubmit() end,
    }

    local osk_btn = Button:new{
        text = "⌨", width = btn_w, show_parent = self,
        callback = function() self:_toggleKeyboard() end,
    }
    local send_btn = Button:new{
        text = _("Send"), width = btn_w, show_parent = self,
        callback = function() self:_onSubmit() end,
    }

    self._input_bar = HorizontalGroup:new{
        align = "center", osk_btn, self._input_text, send_btn,
    }
    self._input_bar_h = self._input_bar:getSize().h

    -- Separator
    self._sep_h = Screen:scaleBySize(1)
    self._sep = LineWidget:new{ dimen = Geom:new{ w = sw, h = self._sep_h } }

    -- Transcript (fills remaining height)
    self._tw_width  = sw
    self:_recomputeTranscriptHeight()
    self._transcript_w = self:_buildTranscript()

    self._vgroup = VerticalGroup:new{
        align = "left",
        self._title_bar,    -- [1]
        self._status_w,     -- [2]
        self._transcript_w, -- [3]
        self._sep,          -- [4]
        self._input_bar,    -- [5]
    }
    self:_fillGap()

    self[1]    = self._vgroup
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
end

function GameView:_recomputeTranscriptHeight()
    self._tw_height = self._sh - self._title_h - self._status_h
                      - self._sep_h - self._input_bar_h - self._keyboard_height
end

-- VerticalGroup ignores height; pad the leftover with a VerticalSpan.
function GameView:_fillGap()
    -- Drop a previous trailing span if present.
    if self._vgroup[6] then self._vgroup[6] = nil end
    local used = self._title_h + self._status_h + self._tw_height
                 + self._sep_h + self._input_bar_h
    local gap = self._sh - used
    if gap > 0 then
        self._vgroup[6] = VerticalSpan:new{ width = self._sw, height = gap }
    end
end

function GameView:_buildStatus()
    return TextWidget:new{
        text                   = self._status or "",
        face                   = Font:getFace("infont", self.settings.font_size),
        max_width              = self._sw,
        truncate_with_ellipsis = true,
    }
end

function GameView:_buildTranscript()
    return ScrollTextWidget:new{
        text          = self.transcript,
        face          = Font:getFace("infont", self.settings.font_size),
        width         = self._tw_width,
        height        = self._tw_height,
        scroll_by_pan = true,
        dialog        = self,  -- updateScrollBar needs self.movable
    }
end

-- ── Showing / lifecycle ─────────────────────────────────────────────────────────

function GameView:show()
    UIManager:show(self)
    UIManager:setDirty(self, "full")
    self:_startPolling()   -- read the opening screen
    if self._keyboard_visible then
        UIManager:scheduleIn(0.15, function()
            if self._input_text and self._input_text.onShowKeyboard then
                self._input_text:onShowKeyboard()
            end
        end)
        UIManager:scheduleIn(0.45, function() self:_syncKeyboardHeight() end)
    end
end

-- ── Keyboard height management ──────────────────────────────────────────────────

function GameView:_syncKeyboardHeight()
    local h = 0
    if self._input_text and self._input_text.keyboard then
        local dimen = self._input_text.keyboard.dimen
        h = dimen and dimen.h or 0
    end
    self:_setKeyboardHeight(h)
end

function GameView:_setKeyboardHeight(h)
    if h == self._keyboard_height then return end
    self._keyboard_height = h
    self:_recomputeTranscriptHeight()
    self:_refreshDisplay()
end

function GameView:onKeyboardHeightChanged()
    UIManager:scheduleIn(0.1, function() self:_syncKeyboardHeight() end)
    return true
end

function GameView:onKeyboardClosed()
    self:_setKeyboardHeight(0)
    return true
end

-- ── Player input ────────────────────────────────────────────────────────────────

function GameView:_onSubmit()
    if self._polling then return end
    local text = self._input_text:getText() or ""

    if self._input_kind == "char" then
        -- Single-key input (menus / "press a key"). Use the typed first char if
        -- any, else Return. Phase 3 adds a proper single-key affordance.
        local key = (text ~= "" and text:sub(1, 1)) or "return"
        self._input_text:setText("")
        self.engine:send_char(self._input_window, key)
        self:_startPolling()
        return
    end

    local command = text:match("^%s*(.-)%s*$") or ""
    if command == "" then return end
    self.history:push(command)
    self.history:resetCursor()
    self._input_text:setText("")
    -- The VM echoes the command back as an "input"-styled story run, so we do
    -- not append "> command" ourselves.
    self.engine:send_line(self._input_window, command)
    self:_startPolling()
end

-- ── Turn polling ──────────────────────────────────────────────────────────────

function GameView:_startPolling()
    if self._polling then return end
    self._polling    = true
    self._input_kind = nil    -- turn in flight; input disabled until it returns
    self._poll_start = os.clock()
    UIManager:scheduleIn(POLL_INTERVAL_S, function() self:_pollStep() end)
end

function GameView:_pollStep()
    if not self._polling then return end

    local update = self.engine:poll()
    if update then
        self._polling = false
        self:_applyUpdate(update)
        return
    end

    if (os.clock() - self._poll_start) >= POLL_TIMEOUT_S then
        self._polling = false
        if not self.engine:is_alive() then self:_onGameEnded() end
        return
    end
    UIManager:scheduleIn(POLL_INTERVAL_S, function() self:_pollStep() end)
end

-- Apply a normalized Update from the engine to the UI.
function GameView:_applyUpdate(u)
    if u.error then
        self.transcript = self.transcript .. "\n[" .. tostring(u.error) .. "]\n"
        self:_refreshDisplay()
        self:_onGameEnded()
        return
    end

    if u.cleared then self.transcript = "" end

    if u.story and #u.story > 0 then
        local parts = {}
        for _, run in ipairs(u.story) do parts[#parts + 1] = run.text end
        self.transcript = self.transcript .. table.concat(parts)
    end

    if u.status then self._status = u.status end
    self:_refreshDisplay()

    if u.exited then self:_onGameEnded(); return end

    if u.fileref then
        -- Phase 4 will present a save/restore slot UI. For now, cancel the
        -- prompt with an empty filename and keep playing.
        self.engine:send_fileref("")
        self:_startPolling()
        return
    end

    if u.input then
        self._input_kind   = u.input.kind
        self._input_window = u.input.window
    elseif not self.engine:is_alive() then
        self:_onGameEnded()
    end
end

-- ── Display update ──────────────────────────────────────────────────────────────

function GameView:_refreshDisplay()
    -- Status line
    local new_status = self:_buildStatus()
    self._vgroup[2] = new_status
    self._status_w  = new_status

    -- Transcript (scrolled to bottom)
    local new_tw = self:_buildTranscript()
    new_tw:scrollToBottom()
    self._vgroup[3]    = new_tw
    self._transcript_w = new_tw

    self:_fillGap()
    self._vgroup:resetLayout()
    UIManager:setDirty(self, "partial")
end

-- ── Keyboard toggle ─────────────────────────────────────────────────────────────

function GameView:_toggleKeyboard()
    self._keyboard_visible = not self._keyboard_visible
    if self._keyboard_visible then
        if self._input_text.onShowKeyboard then
            self._input_text:onShowKeyboard()
        end
        UIManager:scheduleIn(0.3, function() self:_syncKeyboardHeight() end)
    else
        if self._input_text.onCloseKeyboard then
            self._input_text:onCloseKeyboard()
        elseif self._input_text.keyboard then
            self._input_text.keyboard:hideKeyboard()
        end
        self:_setKeyboardHeight(0)
    end
end

-- ── In-game menu ────────────────────────────────────────────────────────────────

function GameView:_showMenu()
    local menu
    menu = ButtonDialog:new{
        buttons = {
            {{
                text     = _("Scroll to bottom"),
                callback = function()
                    UIManager:close(menu)
                    self:_refreshDisplay()
                end,
            }},
            {{
                text     = _("Quit game"),
                callback = function()
                    UIManager:close(menu)
                    self:_confirmQuit()
                end,
            }},
        },
    }
    UIManager:show(menu)
end

-- ── Quit / close ────────────────────────────────────────────────────────────────

function GameView:_confirmQuit()
    UIManager:show(ConfirmBox:new{
        text        = _("The progress since the last save will be lost. Close the game?"),
        ok_text     = _("Close"),
        ok_callback = function() self:_close() end,
    })
end

function GameView:_onGameEnded()
    UIManager:show(ConfirmBox:new{
        text        = _("The game has ended. Close the game view?"),
        ok_text     = _("Close"),
        ok_callback = function() self:_close() end,
    })
end

function GameView:_close()
    self._polling = false
    self.engine:terminate()
    if self._input_text then
        self._input_text:onCloseKeyboard()
    end
    UIManager:close(self, "full")
    if self.on_close then self.on_close() end
end

return GameView
