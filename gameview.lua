local Blitbuffer       = require("ffi/blitbuffer")
local Button           = require("ui/widget/button")
local ButtonDialog     = require("ui/widget/buttondialog")
local ConfirmBox       = require("ui/widget/confirmbox")
local Device           = require("device")
local Font             = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local InfoMessage      = require("ui/widget/infomessage")
local InputContainer   = require("ui/widget/container/inputcontainer")
local InputText        = require("ui/widget/inputtext")
local LineWidget       = require("ui/widget/linewidget")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size             = require("ui/size")
local SpinWidget       = require("ui/widget/spinwidget")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local time             = require("ui/time")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local lfs              = require("libs/libkoreader-lfs")
local logger           = require("logger")
local _                = require("gettext")
local T                = require("ffi/util").template
local Screen           = Device.screen

-- Save slots shown in the Save/Restore pickers.  "autosave" is the slot written
-- on close and offered at launch (feature #4); the rest are manual slots (#3).
local SAVE_SLOTS = {
    { name = "autosave", label = _("Autosave") },
    { name = "slot1",    label = _("Slot 1")   },
    { name = "slot2",    label = _("Slot 2")   },
    { name = "slot3",    label = _("Slot 3")   },
    { name = "slot4",    label = _("Slot 4")   },
    { name = "slot5",    label = _("Slot 5")   },
}

local MIN_FONT_SIZE   = 14
local MAX_FONT_SIZE   = 32

local POLL_INTERVAL_S = 0.05   -- 50 ms between output checks
local SETTLE_TIME_S   = 0.15   -- 150 ms quiet → dfrotz is waiting for input
local POLL_TIMEOUT_S  = 15.0   -- give up after 15 s

-- Shown as the last line of a page while more buffered output is waiting.
-- TAP_HINT_PATTERN must stay in sync with TAP_HINT (it is a Lua pattern with
-- the brackets escaped) and is used to strip the hint before the next page.
local TAP_HINT         = "[Tap to continue…]"
local TAP_HINT_PATTERN = "\n*%[Tap to continue…%]%s*$"

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
    on_close   = nil,
    font_size  = 20,    -- transcript font size; overridden by the caller
    settings   = nil,   -- LuaSettings, so the font-size menu can persist changes
    save_dir   = nil,   -- per-game directory for save slots + autosave
    auto_restore = false, -- restore the autosave once the intro settles
}

-- ── Initialisation ─────────────────────────────────────────────────────────────

function GameView:init()
    self.transcript       = ""
    self._polling         = false
    self._awaiting_more   = false      -- a page of buffered output awaits a tap
    self._had_content     = false
    self._last_activity   = 0
    self._poll_start      = 0
    self._turn_buf        = ""         -- raw output accumulated for the current turn
    self._pending_lines   = {}         -- turn lines not yet revealed (pagination)
    self._tap_overlay     = nil
    self._keyboard_height = 0
    self._keyboard_visible = true   -- on-screen keyboard is shown on startup
    self._sw              = Screen:getWidth()
    self._sh              = Screen:getHeight()
    -- Monospace face so dfrotz's column wrapping (the -w value) lines up exactly
    -- with the rendered width; see main.lua _startGame for the cols derivation.
    self._face            = Font:getFace("infont", self.font_size)
    self._autosave_path   = self.save_dir and (self.save_dir .. "/autosave.qzl") or nil
    -- Restore the autosave on the first settled turn (the intro), see _finishTurn.
    self._auto_restore_pending = self.auto_restore and self._autosave_path ~= nil
    self:_build()
end

-- Call this instead of UIManager:show(self) so polling starts at the right time.
function GameView:show()
    UIManager:show(self)
    if self.session then
        self:_startPolling()
    end
    UIManager:scheduleIn(0.15, function()
        if self._input_widget then
            self._input_widget:onShowKeyboard()
        end
    end)
    UIManager:scheduleIn(0.45, function()
        self:_syncKeyboardHeight()
    end)
end

-- ── Event routing ──────────────────────────────────────────────────────────────

-- Guard against events arriving after UIManager:close(self) has been called.
-- Also intercepts KeyPress events while a page of output is waiting to be
-- revealed, so any hardware key (e.g. page-turn buttons) advances the page.
function GameView:handleEvent(event)
    for i = #UIManager._window_stack, 1, -1 do
        if UIManager._window_stack[i].widget == self then
            if self._awaiting_more and event.name == "KeyPress" then
                if self._tap_overlay then
                    UIManager:close(self._tap_overlay)
                    self._tap_overlay = nil
                end
                self:_advancePage()
                return true
            end
            return FrameContainer.handleEvent(self, event)
        end
    end
    return false
end

-- ── Widget construction ────────────────────────────────────────────────────────

function GameView:_build()
    local sw = self._sw
    local sh = self._sh

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

    self._scroll_margin = Size.padding.large

    -- InputText reports self.width as the INNER text width.  The rendered widget
    -- is wider by 2*(bordersize + margin + padding) due to _frame_textwidget.
    -- Subtract that overhead so [InputText | Send] sums exactly to screen width.
    local it_pad   = Size.padding.large
    local it_extra = 2 * (Size.border.inputtext + Size.margin.default + it_pad)
    local btn_w    = math.floor(sw * 0.14)
    local itext_w  = sw - btn_w - it_extra
    -- One line of text.  InputText uses this value as the inner TextBoxWidget
    -- height, where lines_per_page = floor(height / line_height_px) and
    -- line_height_px = round(1.3 * face.size).  It adds its own padding/border
    -- around this, so we must NOT add it_pad here — doing so divides into the
    -- line height twice and the field renders two lines tall.
    local itext_h  = math.ceil(self._face.size * 1.3)

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

    -- When the on-screen keyboard has been toggled off (e.g. an external
    -- keyboard is in use), tapping the input field must not pop it back up.
    -- Every show path funnels through onShowKeyboard, so gate it on our
    -- visibility flag.  Explicit shows (startup, toggle-on) set the flag true
    -- first, so they still work.  The field keeps focus either way, so hardware
    -- key input continues to reach it.
    do
        local gameview  = self
        local orig_show = self._input_widget.onShowKeyboard
        self._input_widget.onShowKeyboard = function(iw, ...)
            if not gameview._keyboard_visible then
                return true
            end
            return orig_show(iw, ...)
        end
    end

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

    self._sep_h = Screen:scaleBySize(1)
    self._sep   = LineWidget:new{
        dimen = Geom:new{ w = sw, h = self._sep_h },
    }

    self._scroll_w = sw - 2 * self._scroll_margin
    self._scroll_h = sh - self._title_h - self._sep_h
                     - self._input_bar_h - self._keyboard_height
    if self._scroll_h < 80 then self._scroll_h = 80 end

    self._scroll = self:_buildScrollWidget()

    self._vgroup = VerticalGroup:new{
        align = "center",
        self._title_bar,  -- [1]
        self._scroll,     -- [2]  ← replaced on each update
        self._sep,        -- [3]
        self._input_bar,  -- [4]
    }

    local used = self._title_h + self._scroll_h + self._sep_h + self._input_bar_h
    local gap  = sh - self._keyboard_height - used
    if gap > 0 then
        table.insert(self._vgroup, VerticalSpan:new{ width = sw, height = gap })
    end

    self[1]    = self._vgroup
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
end

-- ── Keyboard height management ─────────────────────────────────────────────────

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
        self:_refreshDisplay()
    end
end

function GameView:onKeyboardHeightChanged()
    UIManager:scheduleIn(0.1, function() self:_syncKeyboardHeight() end)
    return true
end

function GameView:onKeyboardClosed()
    self._keyboard_height  = 0
    self._keyboard_visible = false
    self._scroll_h = self._sh - self._title_h - self._sep_h - self._input_bar_h
    if self._scroll_h < 80 then self._scroll_h = 80 end
    self:_refreshDisplay()
    return true
end

-- Show or hide the on-screen keyboard.  Useful when an external (USB/Bluetooth)
-- keyboard is attached and the soft keyboard is just wasting screen space.
function GameView:_toggleKeyboard()
    if self._keyboard_visible then
        self._input_widget:onCloseKeyboard()
        self._keyboard_visible = false
        self._keyboard_height  = 0
        self._scroll_h = self._sh - self._title_h - self._sep_h - self._input_bar_h
        if self._scroll_h < 80 then self._scroll_h = 80 end
        self:_refreshDisplay()
        -- A full repaint clears the e-ink ghost the keyboard leaves behind.
        UIManager:setDirty(self, "full")
    else
        self._keyboard_visible = true
        self._input_widget:onShowKeyboard()
        -- Let the keyboard lay out, then shrink the transcript to fit above it.
        UIManager:scheduleIn(0.3, function() self:_syncKeyboardHeight() end)
    end
end

-- InputText calls parent:onSwitchFocus(field) on tap/hold/focus *before* it
-- would otherwise pop up its own keyboard (see inputtext.lua onTapTextBox).
-- Implementing this hook is what actually keeps the soft keyboard down once the
-- player has toggled it off: we re-focus the field (so external-keyboard typing
-- still works) but only show the keyboard when it is meant to be visible.
function GameView:onSwitchFocus(inputfield)
    inputfield.focused = true
    if self._keyboard_visible then
        inputfield:onShowKeyboard()
    end
    return true
end

-- ── Transcript helpers ─────────────────────────────────────────────────────────

function GameView:_buildScrollWidget()
    local text = self.transcript
    text = text:gsub("\r", "")
    text = text:gsub("\n>[ \t]*$", "")
    return ScrollTextWidget:new{
        text          = text,
        face          = self._face,
        width         = self._scroll_w,
        height        = self._scroll_h,
        scroll_by_pan = true,
        dialog        = self,
    }
end

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
    if self._polling then return end
    if self._awaiting_more then
        self:_advancePage()
        return
    end

    local cmd = self._input_widget:getText() or ""
    cmd = cmd:match("^%s*(.-)%s*$") or ""

    if self.transcript ~= "" then
        self.transcript = self.transcript .. "\n"
    end
    self.transcript = self.transcript .. "> " .. cmd .. "\n"
    self._input_widget:setText("")

    if self.session then
        self.session:send_input(cmd)
        self:_startPolling()
    end
    self:_refreshDisplay()
end

-- ── Output polling ─────────────────────────────────────────────────────────────

function GameView:_startPolling()
    if self._polling then return end
    self._polling       = true
    self._poll_start    = time.now()
    self._last_activity = time.now()
    self._had_content   = false
    self._turn_buf      = ""
    UIManager:scheduleIn(POLL_INTERVAL_S, function() self:_pollStep() end)
end

function GameView:_pollStep()
    if not self._polling then return end

    -- Accumulate the whole turn's output; we don't display it until the turn
    -- settles, so we can split it into pages.  (dfrotz runs with MORE disabled,
    -- so a turn arrives as one continuous stream ending in the "> " prompt.)
    local chunk = self.session:read_output_nonblocking()
    if chunk then
        self._turn_buf      = self._turn_buf .. chunk
        self._last_activity = time.now()
        self._had_content   = true
    end

    local now     = time.now()
    local settled = self._had_content and (now - self._last_activity) >= time.s(SETTLE_TIME_S)
    local timeout = (now - self._poll_start) >= time.s(POLL_TIMEOUT_S)

    if settled or timeout then
        self._polling = false
        if not self.session:is_alive() then
            self:_finishTurn()   -- still show whatever output we received
            self:_onGameEnded()
            return
        end
        self:_finishTurn()
    else
        UIManager:scheduleIn(POLL_INTERVAL_S, function() self:_pollStep() end)
    end
end

-- ── Pagination ─────────────────────────────────────────────────────────────────

-- A turn has finished arriving.  Strip the trailing "> " input prompt, split the
-- output into physical lines (dfrotz already wrapped them to the -w width) and
-- reveal the first page.  Remaining lines are paginated on tap / key press.
function GameView:_finishTurn()
    -- Feature #4: the first settled turn is the intro.  If we are resuming,
    -- discard it and restore the autosave instead, replacing _turn_buf with the
    -- restored location text so it paginates normally below.  (The poller is
    -- stopped here, so the synchronous restore won't race the async reader.)
    if self._auto_restore_pending then
        self._auto_restore_pending = false
        local ok, text = false, nil
        if self.session then
            ok, text = self.session:restore_game(self._autosave_path)
        end
        if ok then
            self:_pushLine(_("[Resumed from autosave]"))
            self._turn_buf = text or ""
        else
            self:_pushLine(_("[Could not resume; starting fresh]"))
            -- _turn_buf still holds the intro, so the fresh game shows instead.
        end
    end

    local buf = self._turn_buf
    self._turn_buf = ""
    buf = buf:gsub("\r", "")
    buf = buf:gsub("\n?>[ \t]*$", "")   -- drop the trailing input prompt
    buf = buf:gsub("%s+$", "")          -- and any trailing blank space

    self._pending_lines = {}
    if buf ~= "" then
        for line in (buf .. "\n"):gmatch("(.-)\n") do
            table.insert(self._pending_lines, line)
        end
    end
    self:_revealNextPage()
end

-- How many text lines fit in the transcript area.  Shrinks when the on-screen
-- keyboard is visible (self._scroll_h is smaller) and grows when it is hidden,
-- which is exactly the page size the player asked for.
function GameView:_linesPerPage()
    local line_h
    local tw = self._scroll and self._scroll.text_widget
    if tw and tw.line_height_px and tw.line_height_px > 0 then
        line_h = tw.line_height_px
    else
        line_h = math.ceil(self._face.size * 1.3)   -- fallback estimate
    end
    -- One line of slack so the top line of a page is never pushed off-screen
    -- by a small line-height under-estimate.
    local n = math.floor(self._scroll_h / line_h) - 1
    if n < 1 then n = 1 end
    return n
end

-- Reveal up to one screenful of buffered output, then either wait for a tap
-- (more pending) or return control to the player (buffer drained).
function GameView:_revealNextPage()
    -- Drop the "tap to continue" hint left by the previous page, if any.
    self.transcript = self.transcript:gsub(TAP_HINT_PATTERN, "")

    local n = self:_linesPerPage()
    local revealed = {}
    while #revealed < n and #self._pending_lines > 0 do
        table.insert(revealed, table.remove(self._pending_lines, 1))
    end
    if #revealed > 0 then
        if self.transcript ~= "" then
            self.transcript = self.transcript .. "\n"
        end
        self.transcript = self.transcript .. table.concat(revealed, "\n")
    end

    if #self._pending_lines > 0 then
        self._awaiting_more = true
        -- Append the hint as the last visible line.  _linesPerPage() reserves
        -- one line of slack so this never pushes page content off-screen.
        self.transcript = self.transcript .. "\n" .. TAP_HINT
        self:_refreshDisplay()
        self:_showTapOverlay()
    else
        self._awaiting_more = false
        self:_refreshDisplay()
    end
end

-- Tap / key-press handler while a page is pending.  Pagination is entirely
-- local now (dfrotz has MORE disabled), so nothing is sent to the subprocess.
function GameView:_advancePage()
    self._awaiting_more = false
    self:_revealNextPage()
end

-- ── Tap-to-continue overlay ───────────────────────────────────────────────────

-- Show an invisible InputContainer over the scroll area that intercepts one tap.
-- GameView extends FrameContainer (no gesture machinery); registerTouchZones on
-- a thin InputContainer overlay is the correct KOReader pattern.
-- modal = true is required so UIManager places this above the VirtualKeyboard
-- (which is also modal); without it the overlay is inserted below the keyboard
-- and never becomes top_widget, so it never receives gesture events.
function GameView:_showTapOverlay()
    local gameview = self
    local sh = self._sh
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
                gameview:_advancePage()
                return true
            end,
        },
    })
    self._tap_overlay = overlay
    UIManager:show(overlay)
end

-- ── In-game menu ───────────────────────────────────────────────────────────────

function GameView:showMenu()
    local menu
    -- Single-column layout: each entry is its own one-button row.
    local buttons = {
        {{
            text     = _("Scroll to bottom"),
            callback = function()
                UIManager:close(menu)
                self._scroll:scrollToBottom()
                UIManager:setDirty(self, "ui")
            end,
        }},
        {{
            text     = self._keyboard_visible and _("Hide on-screen keyboard")
                                              or  _("Show on-screen keyboard"),
            callback = function()
                UIManager:close(menu)
                self:_toggleKeyboard()
            end,
        }},
    }
    if self.session and self.save_dir then
        table.insert(buttons, {{
            text     = _("Save game"),
            callback = function()
                UIManager:close(menu)
                self:_showSaveSlots("save")
            end,
        }})
        table.insert(buttons, {{
            text     = _("Restore game"),
            callback = function()
                UIManager:close(menu)
                self:_showSaveSlots("restore")
            end,
        }})
    end
    table.insert(buttons, {{
        text     = _("Font size"),
        callback = function()
            UIManager:close(menu)
            self:_showFontSizeDialog()
        end,
    }})
    table.insert(buttons, {{
        text     = _("Close game"),
        callback = function()
            UIManager:close(menu)
            self:onClose()
        end,
    }})
    menu = ButtonDialog:new{
        modal  = true,
        shrink_unneeded_width = true,
        anchor = function()
            return self._title_bar.left_button.image.dimen
        end,
        buttons = buttons,
    }
    UIManager:show(menu)
end

-- Font size persists to settings and applies on the next game launch: changing
-- it requires re-spawning dfrotz with a new -w (column) value, which would lose
-- the current game, so we don't restart the live process here.
function GameView:_showFontSizeDialog()
    -- modal = true is essential: the on-screen keyboard is itself a modal, so a
    -- non-modal dialog would be placed *below* it in the window stack (hidden
    -- behind the OSK, taps stolen).  As a modal, the dialog sits above the
    -- keyboard, so we can leave the keyboard up and need no hide/restore dance.
    UIManager:show(SpinWidget:new{
        modal       = true,
        title_text  = _("Font size"),
        info_text   = _("Size of the game text. Changes take effect after restarting Frotz."),
        value       = self.font_size,
        value_min   = MIN_FONT_SIZE,
        value_max   = MAX_FONT_SIZE,
        value_step  = 1,
        ok_text     = _("Set"),
        callback    = function(spin)
            if self.settings then
                self.settings:saveSetting("font_size", spin.value)
                self.settings:flush()
            end
            UIManager:show(InfoMessage:new{
                text = _("Changes will take effect after restarting Frotz."),
            })
        end,
    })
end

-- ── Save / restore slots ────────────────────────────────────────────────────────

function GameView:_slotPath(name)
    return self.save_dir .. "/" .. name .. ".qzl"
end

-- Returns a "YYYY-MM-DD HH:MM" timestamp for an occupied slot, or nil if empty.
function GameView:_slotStatus(name)
    local mtime = lfs.attributes(self:_slotPath(name), "modification")
    return mtime and os.date("%Y-%m-%d %H:%M", mtime) or nil
end

-- Append one line to the transcript without refreshing the display.
function GameView:_pushLine(text)
    if self.transcript ~= "" then
        self.transcript = self.transcript .. "\n"
    end
    self.transcript = self.transcript .. text
end

-- Append a one-line system message (e.g. "[Saved to Slot 1]") and show it.
function GameView:_appendSystem(text)
    self:_pushLine(text)
    self:_refreshDisplay()
end

-- Slot picker for both Save and Restore.  modal = true so it sits above the OSK
-- (which is itself a modal); empty slots are disabled in restore mode.
function GameView:_showSaveSlots(mode)
    if not (self.session and self.save_dir) then return end
    -- Save/restore drives dfrotz's stdin synchronously; don't start it while a
    -- turn is still streaming output (the poller owns the stream until it settles).
    if self._polling or self._awaiting_more then
        UIManager:show(InfoMessage:new{
            text = _("Please wait for the game to finish responding."),
        })
        return
    end
    local picker
    local buttons = {}
    for _i, slot in ipairs(SAVE_SLOTS) do
        local status   = self:_slotStatus(slot.name)
        local occupied = status ~= nil
        table.insert(buttons, {{
            text     = slot.label .. "    " .. (status or _("(empty)")),
            enabled  = not (mode == "restore" and not occupied),
            callback = function()
                UIManager:close(picker)
                if mode == "save" then
                    self:_saveToSlot(slot, occupied)
                else
                    self:_restoreFromSlot(slot)
                end
            end,
        }})
    end
    picker = ButtonDialog:new{
        modal       = true,
        title       = mode == "save" and _("Save game") or _("Restore game"),
        title_align = "center",
        buttons     = buttons,
    }
    UIManager:show(picker)
end

-- Confirm before clobbering an occupied manual slot (autosave is fair game).
function GameView:_saveToSlot(slot, occupied)
    if occupied and slot.name ~= "autosave" then
        UIManager:show(ConfirmBox:new{
            modal       = true,
            text        = T(_("Overwrite %1?"), slot.label),
            ok_text     = _("Overwrite"),
            ok_callback = function() self:_doSave(slot) end,
        })
    else
        self:_doSave(slot)
    end
end

function GameView:_doSave(slot)
    if not self.session then return end
    local ok = self.session:save_game(self:_slotPath(slot.name))
    self:_appendSystem(ok and T(_("[Saved to %1]"), slot.label)
                          or  T(_("[Save to %1 failed]"), slot.label))
end

function GameView:_restoreFromSlot(slot)
    if not self.session then return end
    local ok, text = self.session:restore_game(self:_slotPath(slot.name))
    if not ok then
        self:_appendSystem(T(_("[Restore of %1 failed]"), slot.label))
        return
    end
    -- Show the marker, then paginate whatever location text dfrotz printed.
    self:_pushLine(T(_("[Restored %1]"), slot.label))
    self._turn_buf = text or ""
    self:_finishTurn()
end

-- ── Game-ended handler ─────────────────────────────────────────────────────────

function GameView:_onGameEnded()
    UIManager:show(ConfirmBox:new{
        text        = _("The game has ended. Close the game view?"),
        ok_text     = _("Close"),
        ok_callback = function() self:onClose() end,
    })
end

-- ── Close ──────────────────────────────────────────────────────────────────────

function GameView:onClose()
    self._polling = false
    if self._tap_overlay then
        UIManager:close(self._tap_overlay)
        self._tap_overlay = nil
    end
    if self.session then
        -- Feature #4: autosave before quitting, so the next launch can resume.
        -- Only if the game is still running (a finished game can't be saved).
        if self._autosave_path and self.session:is_alive() then
            self.session:save_game(self._autosave_path)
        end
        self.session:terminate()
        self.session = nil
    end
    if self._input_widget then
        self._input_widget:onCloseKeyboard()
    end
    if self.on_close then
        self.on_close()
    end
    UIManager:close(self, "full")
end

return GameView
