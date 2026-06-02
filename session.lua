local lfs     = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local logger  = require("logger")

local Session = {}
Session.__index = Session

-- dfrotz_path: absolute path to the dfrotz binary
-- gamefile:    absolute path to the story file
-- cols, rows:  screen width/height in characters
function Session:new(dfrotz_path, gamefile, cols, rows)
    local ts       = tostring(os.time()) .. "_" .. tostring(math.random(10000))
    local base     = "/tmp/frotz_" .. ts
    local fifo_in  = base .. "_in.fifo"
    local out_file = base .. "_out.txt"
    local pid_file = base .. "_pid.txt"

    cols = cols or 80
    rows = rows or 50

    os.execute("mkfifo '" .. fifo_in .. "'")
    local f = io.open(out_file, "w"); f:close()

    -- Launch dfrotz with stdin from FIFO and stdout appended to out_file.
    -- The shell opens the FIFO read-end before backgrounding so our
    -- subsequent io.open(fifo_in, "w") does not block.
    --
    -- -m disables dfrotz's own MORE prompts (equivalent to the \mp0 runtime
    -- setting, but applied before any intro text can pause).  Pagination is
    -- handled in the UI instead.  This relies on 'rows' being tall enough that
    -- a whole turn's output fits in the screen buffer without scrolling lines
    -- off the top (dfrotz only flushes what's still in the buffer).
    local cmd = string.format(
        "'%s' -m -w %d -h %d '%s' < '%s' >> '%s' 2>&1 & echo $! > '%s'",
        dfrotz_path, cols, rows, gamefile, fifo_in, out_file, pid_file
    )
    os.execute(cmd)

    ffiUtil.usleep(200000)  -- give shell time to write PID file

    local pid
    local pf = io.open(pid_file, "r")
    if pf then
        pid = tonumber(pf:read("*l"))
        pf:close()
    end
    if not pid then
        os.execute(string.format("rm -f '%s' '%s' '%s'", fifo_in, out_file, pid_file))
        error("Failed to start dfrotz — binary missing or not executable: " .. dfrotz_path)
    end

    local stdin_handle = io.open(fifo_in, "w")
    if not stdin_handle then
        os.execute("kill " .. pid .. " 2>/dev/null")
        os.execute(string.format("rm -f '%s' '%s' '%s'", fifo_in, out_file, pid_file))
        error("Failed to open input pipe to dfrotz")
    end

    logger.info("FrotzSession: started PID=" .. pid)

    return setmetatable({
        fifo_in   = fifo_in,
        out_file  = out_file,
        pid_file  = pid_file,
        pid       = pid,
        _stdin    = stdin_handle,
        _read_pos = 0,
    }, self)
end

function Session:is_alive()
    if not self.pid then return false end
    local ret = os.execute("kill -0 " .. self.pid .. " 2>/dev/null")
    return ret == 0 or ret == true
end

function Session:send_input(command)
    if not self._stdin then return end
    self._stdin:write(command .. "\n")
    self._stdin:flush()
end

-- Returns new text appended since last call, or nil if nothing new.
function Session:read_output_nonblocking()
    local sz = lfs.attributes(self.out_file, "size") or 0
    if sz <= self._read_pos then return nil end

    local fh = io.open(self.out_file, "r")
    if not fh then return nil end
    fh:seek("set", self._read_pos)
    local chunk = fh:read("*a")
    fh:close()

    self._read_pos = sz
    return (#chunk > 0) and chunk or nil
end

-- ── Synchronous save/restore ────────────────────────────────────────────────────
--
-- dfrotz drives save/restore as an interactive prompt: we send "save"/"restore",
-- it replies "Please enter a filename [..]: " and blocks on stdin, we send a
-- path, and (on save over an existing file) it asks "Overwrite existing file? ".
-- These helpers drive that exchange synchronously.  They are quick and bounded,
-- and must only be called when the UI's async poller is idle (between turns, at
-- close, or right after the intro settles) so they don't fight over out_file.
--
-- Success/failure text after the opcode comes from the *game's* Z-code, not
-- dfrotz, so it is not a reliable signal.  We instead detect completion by the
-- output going quiet (same as a turn) and verify a save by stat-ing the file.

local POLL_STEP_US = 20000   -- 20 ms between reads while driving a prompt

-- Block until the accumulated output contains `needle` (a plain substring), or
-- `timeout_s` elapses.  Returns the accumulated text, or nil + text on timeout.
function Session:_read_until(needle, timeout_s)
    local waited = 0
    local acc    = ""
    while waited < timeout_s * 1e6 do
        local chunk = self:read_output_nonblocking()
        if chunk then
            acc = acc .. chunk
            if acc:find(needle, 1, true) then return acc end
        end
        ffiUtil.usleep(POLL_STEP_US)
        waited = waited + POLL_STEP_US
    end
    return nil, acc
end

-- Drain output until it stops growing for `quiet_s`, or `timeout_s` total.
-- Returns everything read.
function Session:_read_until_settle(quiet_s, timeout_s)
    local waited       = 0
    local since_growth = 0
    local acc          = ""
    while waited < timeout_s * 1e6 do
        local chunk = self:read_output_nonblocking()
        if chunk then
            acc          = acc .. chunk
            since_growth = 0
        else
            since_growth = since_growth + POLL_STEP_US
            if acc ~= "" and since_growth >= quiet_s * 1e6 then break end
        end
        ffiUtil.usleep(POLL_STEP_US)
        waited = waited + POLL_STEP_US
    end
    return acc
end

-- Save the current game to `path` (a full path ending in .qzl).  Overwrites
-- silently.  Returns true if the save file exists and is non-empty afterwards.
function Session:save_game(path)
    if not self._stdin then return false end
    self:send_input("save")
    if not self:_read_until("enter a filename", 3) then
        return false
    end
    self:send_input(path)
    local resp = self:_read_until_settle(0.2, 3)
    if resp:find("Overwrite", 1, true) then
        self:send_input("y")
        self:_read_until_settle(0.2, 3)
    end
    local sz = lfs.attributes(path, "size")
    return sz ~= nil and sz > 0
end

-- Restore the game from `path`.  Returns success (boolean) and the game text
-- dfrotz printed after restoring (the current location), already read off the
-- stream so the UI can show it.  Fails fast if the file is missing.
function Session:restore_game(path)
    if not self._stdin then return false end
    if not lfs.attributes(path, "mode") then return false, nil end
    self:send_input("restore")
    if not self:_read_until("enter a filename", 3) then
        return false, nil
    end
    self:send_input(path)
    local resp = self:_read_until_settle(0.2, 3)
    -- A failed restore makes the game print "Failed."; anything else is a win.
    local ok = not resp:lower():find("failed", 1, true)
    return ok, resp
end

function Session:terminate()
    if self._stdin then
        self._stdin:close()
        self._stdin = nil
    end
    if self.pid then
        os.execute("kill "   .. self.pid .. " 2>/dev/null")
        ffiUtil.usleep(200000)
        os.execute("kill -9 " .. self.pid .. " 2>/dev/null")
        self.pid = nil
    end
    os.execute(string.format("rm -f '%s' '%s' '%s'",
        self.fifo_in, self.out_file, self.pid_file))
    logger.info("FrotzSession: terminated")
end

return Session
