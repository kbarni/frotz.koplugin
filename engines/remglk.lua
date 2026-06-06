-- engines/remglk.lua — the single RemGlk JSON engine.
--
-- One engine drives both VMs (bocfel for Z-machine, git for Glulx): they link
-- the same RemGlk Glk I/O layer and emit the *same* JSON `update` objects, so
-- only the binary differs (chosen by extension in main.lua).
--
-- The engine is deliberately free of KOReader dependencies. It is handed:
--   * a transport — spawn/send/read/terminate of the VM subprocess (session.lua
--     in KOReader; a host shim in the headless harness);
--   * a json codec — { decode(str)->table, encode(table)->str } (rapidjson in
--     KOReader; a hand-rolled codec in the harness).
-- This keeps the whole engine unit-testable off-device (see notes/harness/).
--
-- Transport contract:
--   transport:send(str)              -- write a newline-terminated JSON command
--   transport:read_nonblocking()     -- return any new stdout bytes, or nil
--   transport:is_alive()             -- bool
--   transport:terminate()            -- kill + cleanup
--
-- Protocol facts this engine relies on (verified against real bocfel/git output,
-- see notes/remglk_devlog.md):
--   * The VM blocks for input after each `update`; one update == one turn.
--   * Updates are pretty-printed, multi-line JSON objects on stdout. We frame on
--     brace depth (string/escape aware) and only ever hand a *complete* object to
--     the parser — never accept on a quiet flush, which could split a turn.
--   * NEVER hardcode window id or input gen: ids are not stable across runs and
--     RemGlk fatal-errors if the echoed gen != current gen. We read both from each
--     update's `input` block and echo them on the next command.

local RemGlk = {}
RemGlk.__index = RemGlk

-- Find the first complete top-level JSON object in `buf`.
-- Returns start_index, end_index (inclusive) of the object, or nil if no
-- complete object is buffered yet. String- and escape-aware so braces inside
-- string values are not counted.
local function find_object(buf)
    local start = buf:find("{", 1, true)
    if not start then return nil end
    local depth, in_str, esc = 0, false, false
    local n = #buf
    for i = start, n do
        local c = buf:sub(i, i)
        if in_str then
            if esc then
                esc = false
            elseif c == "\\" then
                esc = true
            elseif c == '"' then
                in_str = false
            end
        else
            if c == '"' then
                in_str = true
            elseif c == "{" then
                depth = depth + 1
            elseif c == "}" then
                depth = depth - 1
                if depth == 0 then
                    return start, i
                end
            end
        end
    end
    return nil  -- incomplete; need more bytes
end

-- cols/rows: screen size in characters, sent in the JSON `init` (not -w/-h).
function RemGlk:new(transport, json, cols, rows)
    local o = setmetatable({
        transport      = transport,
        json           = json,
        cols           = cols or 80,
        rows           = rows or 50,
        _buf           = "",
        _gen           = 0,            -- gen to echo on the next command
        _input_window  = nil,          -- window the VM is waiting on
        _status        = nil,          -- last known status line (carried forward)
        _buf_pending   = false,        -- a non-append line needs a leading newline
        windows        = nil,          -- last seen window geometry (for gameview)
    }, self)

    -- Handshake: send `init` immediately so the VM produces its first update.
    transport:send(json.encode({
        type    = "init",
        gen     = 0,
        metrics = { width = o.cols, height = o.rows },
        support = { "timer", "hyperlinks" },
    }) .. "\n")

    return o
end

-- ── Outgoing commands ───────────────────────────────────────────────────────
-- gen is always the engine's tracked gen (from the last input request); window
-- defaults to the window the VM last asked on, so callers can omit it.

function RemGlk:send_line(window, text)
    self.transport:send(self.json.encode({
        type = "line", gen = self._gen,
        window = window or self._input_window, value = text,
    }) .. "\n")
end

function RemGlk:send_char(window, key)
    self.transport:send(self.json.encode({
        type = "char", gen = self._gen,
        window = window or self._input_window, value = key,
    }) .. "\n")
end

-- Answer a fileref_prompt (save/restore/transcript) with the chosen path.
function RemGlk:send_fileref(path)
    self.transport:send(self.json.encode({
        type = "specialresponse", gen = self._gen,
        response = "fileref_prompt", value = { filename = path },
    }) .. "\n")
end

function RemGlk:is_alive()  return self.transport:is_alive()  end
function RemGlk:terminate() return self.transport:terminate() end

-- ── Update parsing ──────────────────────────────────────────────────────────

-- Flatten a grid window's content lines into { {line=N, text=".."}, ... } and
-- update the carried-forward status string.
function RemGlk:_absorb_grid(c, status_parts)
    local lines = {}
    for _, l in ipairs(c.lines or {}) do
        local parts = {}
        for _, span in ipairs(l.content or {}) do
            if span.text then parts[#parts + 1] = span.text end
        end
        local text = table.concat(parts)
        lines[#lines + 1] = { line = l.line, text = text }
        if text:find("%S") then status_parts[#status_parts + 1] = text:gsub("^%s+", ""):gsub("%s+$", "") end
    end
    return { id = c.id, lines = lines }
end

-- Append a buffer window's content as styled runs into `runs`, honoring the
-- append/blank-line/clear semantics of RemGlk's `text` array. Returns whether a
-- clear was requested.
function RemGlk:_absorb_buffer(c, runs)
    local cleared = false
    if c.clear then
        cleared = true
        self._buf_pending = false  -- transcript reset: no leading newline
    end
    for _, line in ipairs(c.text or {}) do
        local is_append = line.append == true
        if not is_append and self._buf_pending then
            runs[#runs + 1] = { text = "\n", style = "normal" }
        end
        for _, span in ipairs(line.content or {}) do
            if span.text then
                runs[#runs + 1] = {
                    text = span.text,
                    style = span.style or "normal",
                    hyperlink = span.hyperlink,
                }
            end
            -- Phase A: image/setcolor/fill special spans are ignored (no pixels
            -- on e-ink yet); see remglk_migration_plan.md §4a.
        end
        self._buf_pending = true
    end
    return cleared
end

-- Turn a decoded RemGlk object into the normalized Update gameview consumes.
function RemGlk:_normalize(obj)
    if obj.type == "error" then
        return { error = obj.message or "VM error", raw = obj }
    end

    local update = { gen = obj.gen, raw = obj, story = {}, grids = {} }

    if obj.windows then self.windows = obj.windows end

    local status_parts = {}
    for _, c in ipairs(obj.content or {}) do
        if c.lines then                                   -- grid window
            update.grids[#update.grids + 1] = self:_absorb_grid(c, status_parts)
        elseif c.text then                                -- buffer window
            if self:_absorb_buffer(c, update.story) then update.cleared = true end
        end
    end
    if #status_parts > 0 then
        self._status = table.concat(status_parts, "  ")
    end
    update.status = self._status

    -- Turn boundary: the input request. line/char/specialinput(fileref).
    for _, inp in ipairs(obj.input or {}) do
        if inp.type == "line" or inp.type == "char" then
            self._gen = inp.gen
            self._input_window = inp.id
            update.input = { kind = inp.type, window = inp.id, gen = inp.gen, maxlen = inp.maxlen }
            break
        elseif inp.type == "specialinput" then
            local si = inp.specialinput or {}
            if si.type == "fileref_prompt" then
                self._gen = inp.gen
                self._input_window = inp.id
                update.fileref = {
                    purpose  = si.filetype,    -- "save" / "restore" / "transcript" / ...
                    filemode = si.filemode,    -- "read" / "write" / "readwrite"
                    gen      = inp.gen,
                    window   = inp.id,
                }
            end
            break
        end
    end

    if obj.exit == true then update.exited = true end
    return update
end

-- Non-blocking. Pull any available bytes, and if a complete update has arrived,
-- parse + normalize it and return the Update. Returns nil while a turn is still
-- in flight (no complete object yet) — the caller polls again later. The UI
-- drives this from a scheduler; the harness drives it from a sleep loop.
function RemGlk:poll()
    local chunk = self.transport:read_nonblocking()
    if chunk then self._buf = self._buf .. chunk end

    local s, e = find_object(self._buf)
    if not e then return nil end

    local objstr = self._buf:sub(s, e)
    self._buf = self._buf:sub(e + 1)

    local ok, obj = pcall(self.json.decode, objstr)
    if not ok or type(obj) ~= "table" then
        return { error = "JSON decode failed", raw = objstr }
    end
    return self:_normalize(obj)
end

-- Exposed for tests.
RemGlk._find_object = find_object

return RemGlk
