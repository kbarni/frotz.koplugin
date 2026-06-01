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
