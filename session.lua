-- session.lua — subprocess transport for the RemGlk engine.
--
-- Spawns a RemGlk-linked VM (bocfel/git) and carries raw bytes both ways:
--   stdin  ← a named FIFO (Lua writes newline-terminated JSON commands)
--   stdout → a plain file (Lua polls and reads new bytes; the engine frames them
--            into complete JSON updates)
-- RemGlk blocks for input after each update, so this FIFO-in / file-out / poll
-- loop is all the framing the transport needs — it knows nothing about JSON.
--
-- This is the transport kept from the old dfrotz design; the text-scraping
-- save/restore and the settle-as-turn-detector are gone (RemGlk gives us a real
-- protocol). It runs unchanged under KOReader and the headless harness — the
-- KOReader-only modules are resolved with host fallbacks.

-- lfs: KOReader bundles it as libs/libkoreader-lfs; the host has plain lfs.
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end

-- logger: optional; stub it out off-device.
local ok_log, logger = pcall(require, "logger")
if not ok_log then logger = { info = function() end, warn = function() end } end

-- A short sleep, used only to let the spawning shell write the pidfile.
local sleep
local ok_ffi, ffiUtil = pcall(require, "ffi/util")
if ok_ffi then
    sleep = function(us) ffiUtil.usleep(us) end
else
    sleep = function(us) os.execute(string.format("sleep %f", us / 1e6)) end
end

local Session = {}
Session.__index = Session

-- vm_binary: absolute path to bocfel or git
-- gamefile:  absolute path to the story file
-- No -w/-h/-m: geometry travels in the JSON `init`, and the VM never paginates
-- (we advertise a tall window and own paging in the UI).
function Session:new(vm_binary, gamefile)
    local ts       = tostring(os.time()) .. "_" .. tostring(math.random(100000))
    local base     = "/tmp/remglk_" .. ts
    local fifo_in  = base .. "_in.fifo"
    local out_file = base .. "_out.json"
    local err_file = base .. "_err.txt"
    local pid_file = base .. "_pid.txt"

    os.execute("mkfifo '" .. fifo_in .. "'")
    local f = io.open(out_file, "w"); if f then f:close() end

    -- The shell opens the FIFO read-end (via the VM's stdin redirect) before we
    -- open the write-end below, so our io.open(fifo, "w") does not block.
    -- stderr goes to its own file so VM warnings can never corrupt the JSON
    -- stream on stdout.
    local cmd = string.format(
        "'%s' '%s' < '%s' > '%s' 2> '%s' & echo $! > '%s'",
        vm_binary, gamefile, fifo_in, out_file, err_file, pid_file
    )
    os.execute(cmd)

    sleep(200000)  -- 200 ms: let the shell write the pidfile

    local pid
    local pf = io.open(pid_file, "r")
    if pf then
        pid = tonumber(pf:read("*l"))
        pf:close()
    end
    if not pid then
        os.execute(string.format("rm -f '%s' '%s' '%s' '%s'",
            fifo_in, out_file, err_file, pid_file))
        error("Failed to start VM — binary missing or not executable: " .. vm_binary)
    end

    local stdin_handle = io.open(fifo_in, "w")
    if not stdin_handle then
        os.execute("kill " .. pid .. " 2>/dev/null")
        os.execute(string.format("rm -f '%s' '%s' '%s' '%s'",
            fifo_in, out_file, err_file, pid_file))
        error("Failed to open input pipe to VM")
    end

    logger.info("RemGlk session: started PID=" .. pid .. " (" .. vm_binary .. ")")

    return setmetatable({
        fifo_in   = fifo_in,
        out_file  = out_file,
        err_file  = err_file,
        pid_file  = pid_file,
        pid       = pid,
        _stdin    = stdin_handle,
        _read_pos = 0,
    }, self)
end

-- Write a command (the engine appends its own newline).
function Session:send(data)
    if not self._stdin then return end
    self._stdin:write(data)
    self._stdin:flush()
end

-- Return any stdout bytes written since the last call, or nil if none.
function Session:read_nonblocking()
    local sz = lfs.attributes(self.out_file, "size") or 0
    if sz <= self._read_pos then return nil end

    local fh = io.open(self.out_file, "r")
    if not fh then return nil end
    fh:seek("set", self._read_pos)
    local chunk = fh:read("*a")
    fh:close()

    self._read_pos = sz
    return (chunk and #chunk > 0) and chunk or nil
end

function Session:is_alive()
    if not self.pid then return false end
    local ret = os.execute("kill -0 " .. self.pid .. " 2>/dev/null")
    return ret == 0 or ret == true
end

function Session:terminate()
    if self._stdin then
        self._stdin:close()
        self._stdin = nil
    end
    if self.pid then
        os.execute("kill " .. self.pid .. " 2>/dev/null")
        sleep(200000)
        os.execute("kill -9 " .. self.pid .. " 2>/dev/null")
        self.pid = nil
    end
    os.execute(string.format("rm -f '%s' '%s' '%s' '%s'",
        self.fifo_in, self.out_file, self.err_file, self.pid_file))
    logger.info("RemGlk session: terminated")
end

return Session
