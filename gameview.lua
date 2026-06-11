local Blitbuffer       = require("ffi/blitbuffer")
local Button           = require("ui/widget/button")
local ButtonDialog     = require("ui/widget/buttondialog")
local ConfirmBox       = require("ui/widget/confirmbox")
local Device           = require("device")
local Font             = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local GestureRange     = require("ui/gesturerange")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local InfoMessage      = require("ui/widget/infomessage")
local InputContainer   = require("ui/widget/container/inputcontainer")
local InputText        = require("ui/widget/inputtext")
local LeftContainer    = require("ui/widget/container/leftcontainer")
local LineWidget       = require("ui/widget/linewidget")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size             = require("ui/size")
local TextWidget       = require("ui/widget/textwidget")
local SpinWidget       = require("ui/widget/spinwidget")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local ffiUtil          = require("ffi/util")
local time             = require("ui/time")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local lfs              = require("libs/libkoreader-lfs")
local logger           = require("logger")
local _                = require("gettext")
local T                = require("ffi/util").template
local Screen           = Device.screen

local ptf              = require("ptfwrap")

-- Save slots shown in the Save/Restore pickers.  "autosave" is the slot written
-- on close and offered at launch; the rest are manual slots.  The save files are
-- the interpreter's own format (Quetzal for Z-machine, Glulx save for Glulx),
-- selected through the RemGlk fileref protocol — see _engineSave/_engineRestore.
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

-- A grid window taller than this many rows is not a status bar: it's an epigraph
-- quote-box, a boxed menu, or a map. Z-machine games draw these by temporarily
-- expanding the upper window to most of the screen, then collapse it back to the
-- 1-2 line status bar on a keypress. Render tall grids as the main (scrollable)
-- content instead of pinning a huge region over a squished transcript.
local STATUS_MAX_ROWS = 5

local POLL_INTERVAL_S = 0.05   -- 50 ms between engine polls
local POLL_TIMEOUT_S  = 30.0   -- give up waiting for a turn after 30 s

-- Save/restore drive the engine synchronously (blocking the UI thread), so the
-- per-step ceiling and guard-loop bound are kept small: a healthy save/restore
-- round-trips in well under a second, and these also run on close.
local SAVE_WAIT_S     = 3.0
local SAVE_WAIT_GUARD = 4

-- Shown as the last line of a page while more buffered output is waiting.
-- TAP_HINT_PATTERN must stay in sync with TAP_HINT (a Lua pattern with the
-- brackets escaped) and is used to strip the hint before the next page.
local TAP_HINT         = "[Tap to continue…]"
local TAP_HINT_PATTERN = "\n*%[Tap to continue…%]%s*$"

-- GameView extends FrameContainer (not InputContainer/WidgetContainer).
-- FrameContainer.paintTo records its own dimen.x/y on every repaint, which child
-- InputContainers (Button, TitleBar IconButton) read for gesture hit-testing.
-- is_always_active = true lets this widget receive events even when the
-- VirtualKeyboard (modal) sits above it in the UIManager window stack.
local GameView = FrameContainer:extend{
    bordersize        = 0,
    padding           = 0,
    background        = Blitbuffer.COLOR_WHITE,
    covers_fullscreen = true,
    is_always_active  = true,

    game_title = "Interactive Fiction",
    engine     = nil,   -- the RemGlk JSON engine (replaces the old dfrotz session)
    on_close   = nil,
    font_size  = 20,    -- transcript font size; overridden by the caller
    cols       = 64,    -- monospace columns; story is word-wrapped to this width
    settings   = nil,   -- LuaSettings, so the font-size menu can persist changes
    save_dir   = nil,   -- per-game directory for save slots + autosave
    auto_restore = false, -- restore the autosave once the intro settles
    ui         = nil,   -- hosting FileManager/ReaderUI, for dictionary lookup
}

-- ── Initialisation ─────────────────────────────────────────────────────────────

function GameView:init()
    self.transcript       = ""
    self._status_lines    = {}         -- grid window lines (monospace), carried forward
    self._fs_text         = nil        -- when set, the scroll region shows a tall
                                       -- grid (epigraph/menu/map), not the transcript
    self._polling         = false
    self._awaiting_more   = false      -- a page of buffered output awaits a tap
    self._poll_start      = 0
    self._turn_buf        = ""         -- this turn's story text, pre-wrapped
    self._pending_lines   = {}         -- turn lines not yet revealed (pagination)
    self._input_kind      = nil        -- "line" | "char" | nil (turn in flight)
    self._input_window    = nil        -- window id the VM is waiting on
    self._tap_overlay     = nil
    self._keyboard_height = 0
    self._keyboard_visible = true   -- on-screen keyboard is shown on startup
    self._sw              = Screen:getWidth()
    self._sh              = Screen:getHeight()
    -- Monospace face so our word-wrap to `cols` lines up exactly with the
    -- rendered width (see main.lua for the cols derivation).
    self._face            = Font:getFace("infont", self.font_size)
    self._autosave_path   = self.save_dir and (self.save_dir .. "/autosave.qzl") or nil
    -- Restore the autosave on the first settled turn (the intro), see _finishTurn.
    self._auto_restore_pending = self.auto_restore and self._autosave_path ~= nil
    self:_build()
end

-- Call this instead of UIManager:show(self) so polling starts at the right time.
function GameView:show()
    self:_installDictModalHook()
    UIManager:show(self)
    if self.engine then
        self:_startPolling()   -- read the opening screen
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

-- Guard against events arriving after UIManager:close(self).  Also intercepts
-- KeyPress while a page is waiting, so any hardware key advances the page.
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

    -- The grid status (location / score / moves) is rendered below the title in a
    -- dedicated monospace widget (see _buildStatusWidget), not in the title bar,
    -- so its character columns line up like a real interpreter status line.
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
    -- is wider by 2*(bordersize + margin + padding); subtract that overhead so
    -- [InputText | Send] sums exactly to screen width.
    local it_pad   = Size.padding.large
    local it_extra = 2 * (Size.border.inputtext + Size.margin.default + it_pad)
    local btn_w    = math.floor(sw * 0.14)
    local itext_w  = sw - btn_w - it_extra
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

    -- Keep the soft keyboard down once the player toggles it off (external
    -- keyboard case): gate onShowKeyboard on our visibility flag.
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

    self:_layout()
end

-- Height available for the scrolling transcript, given the current title,
-- status grid, separators, input bar and (visible) keyboard.
function GameView:_computeScrollH()
    local status_h     = self._status_h or 0
    local header_sep_h = status_h > 0 and self._sep_h or 0
    local h = self._sh - self._title_h - status_h - header_sep_h
              - self._sep_h - self._input_bar_h - self._keyboard_height
    if h < 80 then h = 80 end
    return h
end

-- Build (or rebuild) the status-bar widget from self._status_lines: one
-- monospace TextWidget per grid line, left-aligned at the transcript's left
-- margin so columns line up. Returns the widget (or nil when there is no status)
-- and sets self._status_h / self._status_count. The grid line text is already
-- padded to the full character width by RemGlk, so spaces preserve alignment.
function GameView:_buildStatusWidget()
    local lines = self._status_lines or {}
    self._status_count = #lines
    if #lines == 0 then
        self._status_h = 0
        return nil
    end
    -- Give the status line all the width to the right of the left margin (the
    -- transcript reserves extra room on the right for its scrollbar; the status bar
    -- has no scrollbar, so it doesn't need that reservation). This keeps a
    -- full-width `cols`-character status line — whose score/moves are
    -- right-justified at the far edge — from being clipped by rounding.
    local status_max_w = self._sw - self._scroll_margin
    local inner = VerticalGroup:new{ align = "left" }
    for _, ltext in ipairs(lines) do
        table.insert(inner, TextWidget:new{
            text                   = (ltext ~= "" and ltext) or " ",
            face                   = self._face,
            max_width              = status_max_w,
            truncate_with_ellipsis = false,
        })
    end
    local h = inner:getSize().h
    self._status_h = h
    return LeftContainer:new{
        dimen = Geom:new{ w = self._sw, h = h },
        HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = self._scroll_margin },
            inner,
        },
    }
end

-- Assemble the full vertical layout: title, optional status grid + separator,
-- transcript, separator, input bar, and a filler span. Called on first build and
-- whenever the status grid's line count changes (which changes its height).
function GameView:_layout()
    local sw, sh = self._sw, self._sh

    local status_w = self:_buildStatusWidget()
    self._scroll_h = self:_computeScrollH()
    self._scroll   = self:_buildScrollWidget()

    local vg = VerticalGroup:new{ align = "center" }
    table.insert(vg, self._title_bar)
    if status_w then
        table.insert(vg, status_w)
        table.insert(vg, LineWidget:new{ dimen = Geom:new{ w = sw, h = self._sep_h } })
        self._status_idx = 2
        self._scroll_idx = 4
    else
        self._status_idx = nil
        self._scroll_idx = 2
    end
    table.insert(vg, self._scroll)
    table.insert(vg, self._sep)
    table.insert(vg, self._input_bar)

    local status_h     = self._status_h or 0
    local header_sep_h = status_h > 0 and self._sep_h or 0
    local used = self._title_h + status_h + header_sep_h + self._scroll_h
                 + self._sep_h + self._input_bar_h
    local gap  = sh - self._keyboard_height - used
    if gap > 0 then
        table.insert(vg, VerticalSpan:new{ width = sw, height = gap })
    end

    self._vgroup = vg
    self[1]      = vg
    self.dimen   = Geom:new{ x = 0, y = 0, w = sw, h = sh }
end

-- Refresh the status grid after a turn. If the line count is unchanged the widget
-- height is the same, so we swap it in place; if it changed we re-run the full
-- layout (which re-derives the transcript height).
function GameView:_applyStatus()
    local new_count = #(self._status_lines or {})
    if new_count == (self._status_count or 0) then
        if new_count == 0 then return end
        local w = self:_buildStatusWidget()
        local old = self._vgroup[self._status_idx]
        if old and old.free then old:free() end
        self._vgroup[self._status_idx] = w
        self._vgroup:resetLayout()
    else
        self:_layout()
    end
    UIManager:setDirty(self, "ui")
end

-- Full grid as text with every row 0..max preserved (blank where the VM left it),
-- so an epigraph's vertical + horizontal (space) centering is reproduced. Only
-- dirty rows are sent, so each is placed at its `line` index and the gaps padded;
-- pad out to the window's full height (`gh`) too.
function GameView:_gridFullText(grids, gh)
    local rows, maxrow = {}, (gh or 0) - 1
    for _, g in ipairs(grids) do
        for _, l in ipairs(g.lines or {}) do
            local idx = l.line or 0
            rows[idx] = l.text or ""
            if idx > maxrow then maxrow = idx end
        end
    end
    local out = {}
    for i = 0, maxrow do out[#out + 1] = rows[i] or "" end
    return table.concat(out, "\n")
end

-- Status-bar lines: stack non-empty grids (a game may open several, some empty),
-- then trim wholly-blank outer rows (a status bar needs no centering). Alignment-
-- padding spaces within a row are kept so columns line up.
function GameView:_gridStatusLines(grids)
    local lines = {}
    for _, g in ipairs(grids) do
        local glines, has_content = {}, false
        for _, l in ipairs(g.lines or {}) do
            local text = l.text or ""
            glines[#glines + 1] = text
            if text:find("%S") then has_content = true end
        end
        if has_content then
            for _, text in ipairs(glines) do lines[#lines + 1] = text end
        end
    end
    while #lines > 0 and not lines[1]:find("%S")     do table.remove(lines, 1) end
    while #lines > 0 and not lines[#lines]:find("%S") do table.remove(lines)    end
    return lines
end

-- Set the status bar / fullscreen-grid region from an update's grid windows.
-- Window geometry is authoritative: the carried-forward grid heights tell a status
-- bar from an epigraph/menu, and reveal a grid collapsing to height 0 on a turn
-- that ships only a geometry change with no grid content (Photopia clears its
-- epigraph this way). The tallest grid decides the mode:
--   height 0          → no status bar, no fullscreen (clear both)
--   height ≤ MAX_ROWS → status bar
--   height > MAX_ROWS → fullscreen epigraph/menu/map (rows preserved, centered)
function GameView:_setStatusFromUpdate(u)
    local gh, have_geom = 0, false
    for _, w in ipairs(u.windows or {}) do
        if w.type == "grid" then
            have_geom = true
            if (w.gridheight or 0) > gh then gh = w.gridheight end
        end
    end
    local was_fs = self._fs_text ~= nil

    if have_geom and gh == 0 then
        -- Grid fully collapsed: drop both the status bar and any fullscreen grid.
        self._fs_text      = nil
        self._status_lines = {}
    elseif u.grids and #u.grids > 0 then
        local fullscreen
        if have_geom then
            fullscreen = gh > STATUS_MAX_ROWS
        else
            -- No geometry yet (shouldn't happen after the first update): fall back
            -- to counting non-blank content rows.
            local n = 0
            for _, g in ipairs(u.grids) do
                for _, l in ipairs(g.lines or {}) do
                    if (l.text or ""):find("%S") then n = n + 1 end
                end
            end
            fullscreen = n > STATUS_MAX_ROWS
        end
        if fullscreen then
            self._fs_text      = self:_gridFullText(u.grids, gh)
            self._status_lines = {}
        else
            self._fs_text      = nil
            self._status_lines = self:_gridStatusLines(u.grids)
        end
    else
        -- A grid is present (gh>0) but no content this turn: carry forward whatever
        -- is already shown.
        return
    end

    if self._fs_text or ((self._fs_text ~= nil) ~= was_fs) then
        -- A tall grid this turn, or a transition in/out of fullscreen-grid mode:
        -- the scroll region's content and the presence of the status bar both
        -- change, so rebuild the whole layout (which honors _fs_text).
        self:_layout()
        UIManager:setDirty(self, "ui")
    else
        self:_applyStatus()
    end
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
        self._scroll_h = self:_computeScrollH()
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
    self._scroll_h = self:_computeScrollH()
    self:_refreshDisplay()
    return true
end

function GameView:_toggleKeyboard()
    if self._keyboard_visible then
        self._input_widget:onCloseKeyboard()
        self._keyboard_visible = false
        self._keyboard_height  = 0
        self._scroll_h = self:_computeScrollH()
        self:_refreshDisplay()
        UIManager:setDirty(self, "full")
    else
        self._keyboard_visible = true
        self._input_widget:onShowKeyboard()
        UIManager:scheduleIn(0.3, function() self:_syncKeyboardHeight() end)
    end
end

function GameView:onSwitchFocus(inputfield)
    inputfield.focused = true
    if self._keyboard_visible then
        inputfield:onShowKeyboard()
    end
    return true
end

-- ── Transcript helpers ─────────────────────────────────────────────────────────

function GameView:_buildScrollWidget()
    local text
    if self._fs_text then
        -- Tall grid: render its rows verbatim (monospace columns already line up;
        -- no PTF/word-wrap — the lines are at the VM's grid width, which is `cols`).
        text = self._fs_text
    else
        text = self.transcript
        text = text:gsub("\r", "")
        text = text:gsub("\n>[ \t]*$", "")
        -- Enable TextBoxWidget's PTF parsing so the inline bold markers in the
        -- transcript render (the header must be the very first character).
        text = ptf.PTF_HEADER .. text
    end
    local stw = ScrollTextWidget:new{
        text          = text,
        face          = self._face,
        width         = self._scroll_w,
        height        = self._scroll_h,
        scroll_by_pan = true,
        dialog        = self,
    }
    self:_enableWordLookup(stw)
    return stw
end

-- Wire "hold on a word" in the transcript to a dictionary lookup.  We register
-- the HoldStart/Pan/Release trio on the inner TextBoxWidget (paint-accurate
-- dimen) so the gesture lands here; a fresh ScrollTextWidget is built on every
-- refresh, hence we (re)attach here.
function GameView:_enableWordLookup(stw)
    if not (self.ui and self.ui.dictionary) then return end
    if not Device:isTouchDevice() then return end
    local tw = stw.text_widget
    local range = function() return tw.dimen end
    local hold_pan_rate = G_reader_settings:readSetting("hold_pan_rate")
                          or (Screen.low_pan_rate and 5.0 or 30.0)
    tw.ges_events = tw.ges_events or {}
    tw.ges_events.HoldStartText = {
        GestureRange:new{ ges = "hold", range = range },
    }
    tw.ges_events.HoldPanText = {
        GestureRange:new{ ges = "hold_pan", range = range, rate = hold_pan_rate },
    }
    tw.ges_events.HoldReleaseText = {
        GestureRange:new{ ges = "hold_release", range = range },
        args = function(text) self:_lookupWord(text) end,
    }
end

function GameView:_lookupWord(word)
    if not word or word == "" then return end
    if not (self.ui and self.ui.dictionary) then return end
    self.ui.dictionary:onLookupWord(word, false)
end

-- For the game view's lifetime, wrap UIManager:show to mark any DictQuickLookup
-- as modal so it lifts above the on-screen keyboard (otherwise the keyboard
-- steals its taps).  Restored in onClose.
function GameView:_installDictModalHook()
    if self._orig_uimgr_show then return end
    if not (self.ui and self.ui.dictionary) then return end
    local DictQuickLookup = require("ui/widget/dictquicklookup")
    local orig = UIManager.show
    self._orig_uimgr_show = orig
    UIManager.show = function(uimgr, widget, ...)
        if widget and getmetatable(widget) == DictQuickLookup then
            widget.modal = true
        end
        return orig(uimgr, widget, ...)
    end
end

function GameView:_removeDictModalHook()
    if self._orig_uimgr_show then
        UIManager.show = self._orig_uimgr_show
        self._orig_uimgr_show = nil
    end
end

function GameView:_refreshDisplay()
    local new_scroll = self:_buildScrollWidget()
    if not self._fs_text then
        new_scroll:scrollToBottom()   -- a tall grid reads from the top, not the tail
    end
    local idx = self._scroll_idx
    if self._vgroup[idx] and self._vgroup[idx].free then
        self._vgroup[idx]:free()
    end
    self._vgroup[idx] = new_scroll
    self._scroll      = new_scroll
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
    if not self.engine then return end

    local raw = self._input_widget:getText() or ""

    -- char input (menus / "press a key"): send one key. Use the typed first
    -- char if any, else Return. (Glulx games request char from turn 1.)
    if self._input_kind == "char" then
        local key = (raw ~= "" and raw:sub(1, 1)) or "return"
        self._input_widget:setText("")
        self.engine:send_char(self._input_window, key)
        self:_startPolling()
        self:_refreshDisplay()
        return
    end

    -- line input: echo the command immediately for responsiveness. The VM also
    -- echoes it as an "input"-styled run, which _storyToBuf drops to avoid a dup.
    local cmd = raw:match("^%s*(.-)%s*$") or ""
    if self.transcript ~= "" then
        self.transcript = self.transcript .. "\n"
    end
    self.transcript = self.transcript .. "> " .. cmd .. "\n"
    self._input_widget:setText("")
    self.engine:send_line(self._input_window, cmd)
    self:_startPolling()
    self:_refreshDisplay()
end

-- ── Turn polling ───────────────────────────────────────────────────────────────

function GameView:_startPolling()
    if self._polling then return end
    self._polling    = true
    self._input_kind = nil   -- input disabled until the turn returns
    self._poll_start = time.now()
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

    if (time.now() - self._poll_start) >= time.s(POLL_TIMEOUT_S) then
        self._polling = false
        if not self.engine:is_alive() then self:_onGameEnded() end
        return
    end
    UIManager:scheduleIn(POLL_INTERVAL_S, function() self:_pollStep() end)
end

-- Apply one normalized Update (a complete turn) from the engine.
function GameView:_applyUpdate(u)
    if u.error then
        self:_pushLine("[" .. tostring(u.error) .. "]")
        self:_refreshDisplay()
        self:_onGameEnded()
        return
    end

    if u.cleared then
        self.transcript     = ""
        self._pending_lines = {}
    end

    self:_setStatusFromUpdate(u)

    -- A game-initiated fileref we did not ask for (rare). Cancel and continue;
    -- player-driven save/restore goes through the synchronous slot helpers.
    if u.fileref then
        self.engine:send_fileref("")
        self:_startPolling()
        return
    end

    self._turn_buf = self:_storyToBuf(u)

    if u.input then
        self._input_kind   = u.input.kind
        self._input_window = u.input.window
    else
        self._input_kind = nil
    end

    self:_finishTurn()

    if u.exited then self:_onGameEnded() end
end

-- ── Story → display text ─────────────────────────────────────────────────────────

-- Flatten an Update's story runs into wrapped, PTF-bold-marked text. ptfwrap maps
-- the Glk styles (header/subheader/alert/emphasized → bold) onto the monospace
-- transcript, drops the VM's echoed command, and word-wraps to `cols` (markers
-- are zero-width and balanced per line). The line-based paginator below then
-- counts physical screen lines correctly. See ptfwrap.lua.
function GameView:_storyToBuf(u)
    return ptf.wrap(ptf.runs_to_marked(u.story), self.cols)
end

-- ── Pagination ─────────────────────────────────────────────────────────────────

-- A turn finished. On the first (intro) turn, optionally restore the autosave and
-- show its location text instead. Then split the (already wrapped) story into
-- physical lines and reveal the first page; the rest paginates on tap / key.
function GameView:_finishTurn()
    -- Autorestore goes through the game's "restore" verb, which works only at a
    -- line prompt (at a char prompt the VM hangs), so we defer until the first
    -- one — that covers Glulx games that open on a char intro. We attempt once:
    -- if the game's first line prompt is its command prompt (Zork and most
    -- games), it restores cleanly; if it is instead a pre-game yes/no question
    -- (Photopia's "Would you like instructions?") "restore" is an invalid answer
    -- and we can't tell the two apart, nor retry (the question just repeats). So
    -- on failure we stop and point the player at manual resume rather than loop.
    if self._auto_restore_pending and self._input_kind == "line" then
        self._auto_restore_pending = false
        local ok, text = self:_engineRestore(self._autosave_path)
        if ok then
            self:_pushLine(_("[Resumed from autosave]"))
            self._turn_buf = text or ""
        else
            self:_pushLine(_("[Couldn't auto-resume here. Once you reach the game's command prompt, use the menu → Restore → Autosave.]"))
        end
    end

    local buf = self._turn_buf
    self._turn_buf = ""
    buf = buf:gsub("\r", "")
    buf = buf:gsub("\n?>[ \t]*$", "")   -- drop a trailing game prompt char
    buf = buf:gsub("%s+$", "")

    self._pending_lines = {}
    if buf ~= "" then
        for line in (buf .. "\n"):gmatch("(.-)\n") do
            table.insert(self._pending_lines, line)
        end
    end
    self:_revealNextPage()
end

function GameView:_linesPerPage()
    local line_h
    local tw = self._scroll and self._scroll.text_widget
    if tw and tw.line_height_px and tw.line_height_px > 0 then
        line_h = tw.line_height_px
    else
        line_h = math.ceil(self._face.size * 1.3)
    end
    local n = math.floor(self._scroll_h / line_h) - 1
    if n < 1 then n = 1 end
    return n
end

function GameView:_revealNextPage()
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
        self.transcript = self.transcript .. "\n" .. TAP_HINT
        self:_refreshDisplay()
        self:_showTapOverlay()
    else
        self._awaiting_more = false
        self:_refreshDisplay()
    end
end

-- Pagination is entirely local (the VM never paginates), so advancing a page
-- sends nothing to the interpreter.
function GameView:_advancePage()
    self._awaiting_more = false
    self:_revealNextPage()
end

-- ── Tap-to-continue overlay ───────────────────────────────────────────────────

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
    if self.engine and self.save_dir then
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

-- Font size persists to settings and applies on the next launch: changing it
-- re-derives `cols` and re-inits the engine metrics, so we don't restart the
-- live process here.
function GameView:_showFontSizeDialog()
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

function GameView:_slotStatus(name)
    local mtime = lfs.attributes(self:_slotPath(name), "modification")
    return mtime and os.date("%Y-%m-%d %H:%M", mtime) or nil
end

function GameView:_pushLine(text)
    if self.transcript ~= "" then
        self.transcript = self.transcript .. "\n"
    end
    self.transcript = self.transcript .. text
end

function GameView:_appendSystem(text)
    self:_pushLine(text)
    self:_refreshDisplay()
end

function GameView:_showSaveSlots(mode)
    if not (self.engine and self.save_dir) then return end
    -- Save/restore drives the engine synchronously; don't start while a turn is
    -- still streaming or a page is pending (those own the poll loop / display).
    if self._polling or self._awaiting_more then
        UIManager:show(InfoMessage:new{
            text = _("Please wait for the game to finish responding."),
        })
        return
    end
    -- Save/restore go through the game's verbs, which only work at a command
    -- (line) prompt — not while the game waits for a single key. We deliberately
    -- do NOT try to block a pre-game yes/no question (e.g. Photopia's "Would you
    -- like instructions?"): such a question is protocol-identical to the real
    -- command prompt (same line input, same collapsed 0-height status grid), so
    -- any heuristic would also block normal play. We let the attempt proceed; at
    -- a genuine command prompt it works, elsewhere it fails gracefully.
    if self._input_kind ~= "line" then
        UIManager:show(InfoMessage:new{
            text = _("Save and restore are only available at a command prompt."),
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
    if not self.engine then return end
    local ok = self:_engineSave(self:_slotPath(slot.name))
    self:_appendSystem(ok and T(_("[Saved to %1]"), slot.label)
                          or  T(_("[Save to %1 failed]"), slot.label))
end

function GameView:_restoreFromSlot(slot)
    if not self.engine then return end
    local ok, text = self:_engineRestore(self:_slotPath(slot.name))
    if not ok then
        self:_appendSystem(T(_("[Restore of %1 failed]"), slot.label))
        return
    end
    self:_pushLine(T(_("[Restored %1]"), slot.label))
    self._turn_buf = text or ""
    self:_finishTurn()
end

-- ── Synchronous engine save/restore via the RemGlk fileref protocol ──────────────
--
-- The game's "save"/"restore" verb makes the interpreter request a fileref; we
-- answer it with the slot path and read the confirming update. These run only
-- when the async poller is idle (the slot picker / autosave-on-close), so the
-- short blocking wait below cannot race the turn loop.

-- Block until the next complete Update, or timeout. Returns the Update or nil.
function GameView:_waitUpdate(timeout_s)
    local waited = 0
    local step   = 20000   -- 20 ms
    while waited < timeout_s * 1e6 do
        local u = self.engine:poll()
        if u then return u end
        ffiUtil.usleep(step)
        waited = waited + step
    end
    return nil
end

-- Refresh the cached input window/gen + status from a settled update.
function GameView:_resyncInput(u)
    if not u then return end
    self:_setStatusFromUpdate(u)
    if u.input then
        self._input_kind   = u.input.kind
        self._input_window = u.input.window
    end
end

function GameView:_engineSave(path)
    if not self.engine then return false end
    -- The "save" verb requires a line prompt; sending it at a char prompt hangs
    -- the VM. Refuse rather than desync (caller treats false as "save failed").
    if self._input_kind ~= "line" then return false end
    self.engine:send_line(self._input_window, "save")
    -- These waits block the UI thread, so keep the ceilings tight: a healthy save
    -- returns the fileref prompt in well under a second. The guard loop only spins
    -- on the rare update that carries neither prompt nor input; bound it low so a
    -- misbehaving game can't freeze KOReader (this path also runs on close).
    local u = self:_waitUpdate(SAVE_WAIT_S)
    local guard = 0
    while u and not u.fileref and not u.error and not u.input and guard < SAVE_WAIT_GUARD do
        u = self:_waitUpdate(SAVE_WAIT_S); guard = guard + 1
    end
    if not (u and u.fileref) then
        self:_resyncInput(u)   -- no save prompt; leave input ready for the player
        return false
    end
    self.engine:send_fileref(path)
    local done = self:_waitUpdate(SAVE_WAIT_S)
    self:_resyncInput(done)
    return lfs.attributes(path, "size") ~= nil
end

-- Returns (ok, location_text) on success; location_text is wrapped story ready
-- for pagination.
function GameView:_engineRestore(path)
    if not self.engine then return false, nil end
    if not lfs.attributes(path, "mode") then return false, nil end
    -- Same line-prompt requirement as _engineSave.
    if self._input_kind ~= "line" then return false, nil end
    self.engine:send_line(self._input_window, "restore")
    local u = self:_waitUpdate(SAVE_WAIT_S)
    local guard = 0
    while u and not u.fileref and not u.error and not u.input and guard < SAVE_WAIT_GUARD do
        u = self:_waitUpdate(SAVE_WAIT_S); guard = guard + 1
    end
    if not (u and u.fileref) then
        self:_resyncInput(u)
        return false, nil
    end
    self.engine:send_fileref(path)
    local done = self:_waitUpdate(SAVE_WAIT_S)
    if not done or done.error then return false, nil end
    self:_resyncInput(done)
    return true, self:_storyToBuf(done)
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
    self:_removeDictModalHook()
    if self._tap_overlay then
        UIManager:close(self._tap_overlay)
        self._tap_overlay = nil
    end
    if self.engine then
        -- Autosave before quitting so the next launch can resume. Only if the
        -- game is still running (a finished game can't be saved) and the turn
        -- loop is idle. Wrapped in pcall so a save error can never skip terminate
        -- and leave KOReader's UI blocked behind a half-closed game view.
        if self._autosave_path and not self._awaiting_more and self.engine:is_alive() then
            pcall(function() self:_engineSave(self._autosave_path) end)
        end
        self.engine:terminate()
        self.engine = nil
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
