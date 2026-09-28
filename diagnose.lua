-- diagnose.lua — why won't the interpreter start a game?
--
-- Checks what actually goes wrong between "tap a game" and a running VM, writes
-- the detail to a log file and returns a short report in plain words:
--
--   * which architecture was picked, and whether the binaries match it
--   * whether the binaries exist, are executable, and really run
--   * whether the plugin sits on a noexec mount
--   * whether /tmp is usable (the transport puts its FIFO and files there)
--   * whether session.lua itself can start the VM from KOReader's process, and
--     the launching shell's own complaint when it cannot
--   * a full handshake with the game that failed, when there is one
--   * the plugin's lines in KOReader's crash.log
--
-- Free of KOReader dependencies (like session.lua): runs in the plugin and under
-- the headless harness. It blocks for a few seconds; the caller shows a
-- "please wait" first. The Lua port of the old diagnose.sh.

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end

local ok_ffi, ffiUtil = pcall(require, "ffi/util")

local function sleep_ms(ms)
    if ok_ffi then ffiUtil.usleep(ms * 1000)
    else os.execute(string.format("sleep %f", ms / 1000)) end
end

-- Wall-clock milliseconds (os.clock is CPU time, useless for this).
local function now_ms()
    if ok_ffi and ffiUtil.gettime then
        local s, us = ffiUtil.gettime()
        return s * 1000 + math.floor(us / 1000)
    end
    local p = io.popen("date +%s%N 2>/dev/null")
    local t = p and p:read("*l"); if p then p:close() end
    local n = tonumber(t)
    return n and math.floor(n / 1e6) or os.time() * 1000
end

-- Binaries the plugin can use; the first two cover almost every game.
local ALL_VMS = { "bocfel", "git", "tadsr", "qjs" }
local CORE    = { bocfel = true, git = true }

local LOADERS = {
    { "/lib/ld-linux-armhf.so.3",    "armhf"   },
    { "/lib/ld-linux.so.3",          "armel"   },
    { "/lib64/ld-linux-x86-64.so.2", "x86_64"  },
    { "/lib/ld-linux-aarch64.so.1",  "aarch64" },
}

local function exists(p) return lfs.attributes(p, "mode") ~= nil end

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function read_file(path, max)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read(max or "*a")
    f:close()
    return s
end

local function sh(cmd)
    local p = io.popen(cmd .. " 2>&1")
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return out
end

local function sh_ok(cmd)
    local r = os.execute(cmd)
    return r == 0 or r == true
end

-- ── The run: results + log ──────────────────────────────────────────────────────

local Run = {}
Run.__index = Run

function Run:log(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    table.insert(self.lines, line)
end

function Run:section(title)
    self:log("")
    self:log("── %s ──────────────────────────────", title)
end

-- kind: PASS/WARN/FAIL; why/fix are what the report turns into plain words.
function Run:res(kind, msg, why, fix)
    table.insert(self.results, { kind = kind, msg = msg, why = why, fix = fix })
    self:log("[%s] %s", kind, msg)
    if why then self:log("       why: %s", why) end
    if fix then self:log("       fix: %s", fix) end
end

function Run:tmp(name) return self.work .. "_" .. name end

-- Run a shell command line in the background with a watchdog: a VM that keeps
-- waiting for input must not hang the diagnosis. Returns the exit status
-- (number) or "timeout".
function Run:run_limited(cmdline, secs)
    local pidf, stf = self:tmp("rl.pid"), self:tmp("rl.st")
    os.remove(pidf); os.remove(stf)
    os.execute(string.format("sh -c %s 2>/dev/null &",
        q(cmdline .. " & p=$!; echo $p > " .. q(pidf) .. "; wait $p; echo $? > " .. q(stf))))
    local deadline = now_ms() + secs * 1000
    while now_ms() < deadline do
        local st = read_file(stf)
        if st and st:match("%d") then
            os.remove(pidf); os.remove(stf)
            return tonumber(st:match("%d+"))
        end
        sleep_ms(50)
    end
    local pid = tonumber(read_file(pidf) or "")
    if pid then
        os.execute("kill " .. pid .. " 2>/dev/null")
        sleep_ms(300)
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
    os.remove(pidf); os.remove(stf)
    return "timeout"
end

-- ── Checks ──────────────────────────────────────────────────────────────────────

function Run:check_system()
    self:section("System")
    self:log("%s", (sh("uname -a"):gsub("\n$", "")))
    self:log("user: %s", (sh("id"):gsub("\n$", "")))
    -- What differs between KOReader's process and a terminal, where the
    -- same commands may work: working dir (binary paths can be relative),
    -- environment, and the shell os.execute runs.
    self:log("working dir: %s", tostring(lfs.currentdir()))
    for _, var in ipairs({ "PATH", "LD_LIBRARY_PATH", "LD_PRELOAD", "HOME", "TMPDIR" }) do
        self:log("%s=%s", var, os.getenv(var) or "<unset>")
    end
    self:log("%s", (sh("ls -l /bin/sh"):gsub("\n$", "")))
    local meminfo = read_file("/proc/meminfo") or ""
    self:log("%s", meminfo:match("MemTotal[^\n]*") or "MemTotal: ?")
    self:log("%s", meminfo:match("MemAvailable[^\n]*") or "MemAvailable: ?")
    local device = exists("/mnt/us") and "Kindle"
        or exists("/mnt/onboard") and "Kobo" or "unknown"
    self.device = device
    self:log("device guess: %s", device)
    self:log("plugin dir: %s", self.plugin_dir)
    local rev = read_file(self.plugin_dir .. "/../../git-rev")
    if rev then self:log("KOReader version: %s", (rev:gsub("\n$", ""))) end
    local meta = read_file(self.plugin_dir .. "/_meta.lua")
    local ver = meta and meta:match('version%s*=%s*"([^"]+)"')
    if ver then self:log("plugin version: %s", ver) end

    if not exists("/bin/sh") then
        self:res("FAIL", "/bin/sh is missing",
            "this device has no /bin/sh, and the plugin starts the interpreter through it",
            "report this together with your device model")
    end
end

function Run:check_arch()
    self:section("Architecture")
    local found = {}
    for _, l in ipairs(LOADERS) do
        if exists(l[1]) then table.insert(found, l[2]) end
    end
    self:log("dynamic loaders present: %s", #found > 0 and table.concat(found, " ") or "none")
    self:log("plugin picked arch: %s", self.arch)
    if #found == 0 then
        self:res("WARN", "no known dynamic loader found — the plugin falls back to x86_64")
    elseif #found > 1 then
        self:res("WARN", "several loaders present (" .. table.concat(found, " ")
            .. ") — the plugin picked " .. self.arch .. ", which may be the wrong one")
    else
        self:res("PASS", "architecture detected: " .. self.arch)
    end
    self:log("binaries/:")
    self:log("%s", sh("ls -lR " .. q(self.plugin_dir .. "/binaries")))
end

-- The mount holding the plugin: a noexec one refuses to run any binary.
function Run:check_mount()
    local mounts = read_file("/proc/mounts")
    if not mounts then return end
    local best, best_opts = "", nil
    for line in mounts:gmatch("[^\n]+") do
        local mp, opts = line:match("^%S+%s+(%S+)%s+%S+%s+(%S+)")
        if mp then
            mp = mp:gsub("\\040", " ")
            local prefix = mp == "/" and "/" or mp .. "/"
            if (self.plugin_dir .. "/"):sub(1, #prefix) == prefix and #mp > #best then
                best, best_opts = mp, opts
            end
        end
    end
    if not best_opts then return end
    self:log("plugin mount: %s (%s)", best, best_opts)
    if ("," .. best_opts .. ","):find(",noexec,", 1, true) then
        self:res("FAIL", "the plugin folder is on a noexec mount (" .. best .. ")",
            "the plugin sits on a storage area where the system forbids running programs",
            "install KOReader and the plugin in the normal location for your device")
    end
end

function Run:check_tmp()
    self:section("/tmp")
    self:log("%s", sh("df -k /tmp"))
    self:log("%s", sh("df -i /tmp"))
    self:log("%s", sh("ls -ld /tmp /tmp/"))
    -- Write real bytes and read them back: on a full /tmp creating a file
    -- still works, only the write fails — and that is how the PID file
    -- comes out empty.
    local probe = "/tmp/frotz_diag_write_test"
    local payload = string.rep("0123456789", 10)
    local f = io.open(probe, "w")
    local wrote = f and f:write(payload) and f:close()
    if f and not wrote then pcall(f.close, f) end
    local back = read_file(probe)
    os.remove(probe)
    if back == payload then
        self:res("PASS", "/tmp is writable")
    else
        self:res("FAIL", "/tmp is not writable",
            "the plugin cannot write to /tmp, where it puts the interpreter's input pipe and output",
            "free space on /tmp (restart the device), then try again")
        return
    end
    local free = tonumber(sh("df -k /tmp"):match("\n%S+%s+%d+%s+%d+%s+(%d+)") or "")
    if free and free < 256 then
        self:res("WARN", "/tmp has only " .. free .. " kB free")
    end
    local fifo = self:tmp("fifo")
    os.remove(fifo)
    if sh_ok("mkfifo " .. q(fifo) .. " 2>/dev/null") and lfs.attributes(fifo, "mode") == "named pipe" then
        self:res("PASS", "mkfifo works in /tmp")
    else
        self:res("FAIL", "mkfifo does not work in /tmp",
            "named pipes do not work on this device, and the plugin feeds the interpreter through one",
            "report this with your device model — check first that /tmp is not full")
    end
    os.remove(fifo)
end

-- "class machine floatabi" straight from the ELF header.
local function elf_info(path)
    local h = read_file(path, 40)
    if not h or #h < 40 or h:sub(1, 4) ~= "\127ELF" then return nil end
    local cls = ({ [1] = "32-bit", [2] = "64-bit" })[h:byte(5)] or "unknown"
    local m = h:byte(19) + 256 * h:byte(20)
    local mach = ({ [0x28] = "ARM", [0xb7] = "aarch64", [0x3e] = "x86-64", [0x03] = "x86" })[m]
        or string.format("unknown(0x%x)", m)
    local abi = "n/a"
    -- e_flags at offset 36: EF_ARM_ABI_FLOAT_HARD (0x400) sits in byte 37.
    if cls == "32-bit" and mach == "ARM" then
        abi = (math.floor(h:byte(38) / 4) % 2 == 1) and "hard-float" or "soft-float"
    end
    return { cls = cls, mach = mach, abi = abi }
end

local EXPECTED_MACH = { armel = "ARM", armhf = "ARM", aarch64 = "aarch64", x86_64 = "x86-64" }

function Run:check_binary(name)
    local path = self.plugin_dir .. "/binaries/" .. self.arch .. "/" .. name
    self:section("Binary: " .. name)
    if not exists(path) then
        if CORE[name] or name == self.vm_exe then
            self:res("FAIL", name .. " is missing at " .. path,
                "the " .. name .. " interpreter is not in the plugin folder for this device (" .. self.arch .. ")",
                "copy the whole plugin folder to the device again, keeping binaries/" .. self.arch .. "/")
        else
            self:res("WARN", name .. " is not installed (only needed for " .. (name == "qjs" and "Twine" or "TADS") .. " games)")
        end
        return false
    end
    self:log("%s", (sh("ls -l " .. q(path)):gsub("\n$", "")))
    local perms = lfs.attributes(path, "permissions") or ""
    if not perms:match("^..x") then
        self:res("FAIL", name .. " is not executable",
            "the " .. name .. " interpreter has no execute permission, so the device refuses to run it",
            "run: chmod +x " .. self.plugin_dir .. "/binaries/" .. self.arch .. "/*")
        return false
    end
    local info = elf_info(path)
    if not info then
        self:res("FAIL", name .. " is not a program file",
            "the " .. name .. " file is not a Linux binary — the copy or the download is damaged",
            "download the plugin again and copy it over as a whole folder")
        return false
    end
    self:log("ELF header: %s %s %s", info.cls, info.mach, info.abi)
    if EXPECTED_MACH[self.arch] and info.mach ~= EXPECTED_MACH[self.arch] then
        self:res("FAIL", name .. " is built for " .. info.mach .. ", not " .. self.arch,
            "the " .. name .. " binary in binaries/" .. self.arch .. " is for another processor",
            "copy the plugin folder again from a fresh download")
        return false
    end
    if self.arch == "armel" and info.abi == "hard-float" then
        self:res("FAIL", name .. " is hard-float on a soft-float device",
            "the " .. name .. " binary is built for hard-float ARM but this device is soft-float",
            "report this — the plugin picked the wrong binaries folder")
        return false
    end

    -- Run it without a story: it complains and exits, and anything but a
    -- shell-level failure proves the binary executes here. qjs alone would
    -- start its REPL, so hand it a one-line script.
    local out, err = self:tmp("out." .. name), self:tmp("err." .. name)
    local probe_args = name == "qjs" and " -e 0" or ""
    local st = self:run_limited(string.format("LC_ALL=C LANG=C %s%s < /dev/null > %s 2> %s",
        q(path), probe_args, q(out), q(err)), 5)
    local errtext = read_file(err, 400) or ""
    self:log("exit status: %s", tostring(st))
    self:log("stdout: %s", read_file(out, 200) or "")
    self:log("stderr: %s", errtext)
    os.remove(out); os.remove(err)
    if st == 126 or st == 127
            or errtext:find("not found") or errtext:find("Exec format")
            or errtext:find("cannot execute") or errtext:find("Permission denied") then
        self:res("FAIL", name .. " cannot be executed (exit " .. tostring(st) .. ")",
            "the device refuses to run the " .. name .. " binary",
            "copy the plugin folder over again; if that does not help, post the log")
        return false
    elseif st == "timeout" then
        self:res("WARN", name .. " was still running after 5 s (it may be waiting for input)")
    elseif type(st) == "number" and st > 128 then
        self:res("WARN", name .. " crashed when run without a game (signal " .. (st - 128) .. ")")
    else
        self:res("PASS", name .. " executes (exit " .. tostring(st) .. ")")
    end
    return true
end

-- Start a session through session.lua itself, from inside KOReader's process:
-- same code, user, working dir and environment as a real game start, which a
-- terminal run of the same command line does not reproduce. With the failed
-- game's own VM and paths when there is one, else a harmless `sleep`.
function Run:check_spawn(vm_ok)
    self:section("Background spawn (session.lua)")
    local g = self.game
    local binary, gamefile, args = "sleep", "30", nil
    if g and g.binary and g.gamefile and vm_ok then
        binary, gamefile, args = g.binary, g.gamefile, g.extra_args
    end
    self:log("starting: %s %s%s", binary,
        args and (table.concat(args, " ") .. " ") or "", gamefile)
    local ok_req, Session = pcall(require, "session")
    if not ok_req then
        self:log("cannot load session.lua: %s", tostring(Session))
        return
    end
    local start = now_ms()
    local ok, s = pcall(Session.new, Session, binary, gamefile, args)
    local elapsed = now_ms() - start
    if ok then
        self:log("started PID %s after %d ms", tostring(s.pid), elapsed)
        self:res("PASS", "the plugin's own start-up code reported its PID in " .. elapsed .. " ms")
        s:terminate()
    else
        self:log("error: %s", tostring(s))
        self:res("FAIL", "the plugin's own start-up code failed: " .. tostring(s),
            "the shell that starts the interpreter did not report it — the binary is not at fault",
            "post the log — the shell's message and the /tmp details are in there")
    end
end

local SIGNALS = {
    [6]  = "it aborted (SIGABRT) — often a locale or memory problem",
    [9]  = "it was killed (SIGKILL) — often the system running out of memory",
    [11] = "it crashed (segmentation fault)",
}

-- Start the failing game's own VM, send `init`, and wait for the first update.
function Run:check_handshake()
    self:section("Handshake")
    local g = self.game
    if not g or not g.binary or not g.gamefile then
        self:res("WARN", "handshake not tested — no game given",
            nil, "open a game, and run the diagnosis when it fails")
        return
    end
    if not exists(g.gamefile) then
        self:res("FAIL", "the game file is gone: " .. g.gamefile,
            "the story file was moved or deleted", "open it again from its new place")
        return
    end
    self:log("vm: %s", g.binary)
    self:log("game: %s (%d bytes)", g.gamefile, lfs.attributes(g.gamefile, "size") or -1)

    local fifo, out, err = self:tmp("hs.fifo"), self:tmp("hs.out"), self:tmp("hs.err")
    local pidf, stf, wpidf = self:tmp("hs.pid"), self:tmp("hs.st"), self:tmp("hs.wpid")
    os.execute("mkfifo " .. q(fifo))
    local f = io.open(out, "w"); if f then f:close() end
    local args = ""
    for _, a in ipairs(g.extra_args or {}) do args = args .. q(a) .. " " end
    local vmcmd = string.format("LC_ALL=C LANG=C %s %s%s < %s > %s 2> %s",
        q(g.binary), args, q(g.gamefile), q(fifo), q(out), q(err))
    os.execute(string.format("sh -c %s 2>/dev/null &",
        q(vmcmd .. " & p=$!; echo $p > " .. q(pidf) .. "; wait $p; echo $? > " .. q(stf))))
    -- A shell writer holds the FIFO open, as the plugin does, without Lua
    -- blocking on the open if the VM never reads.
    local init = '{"type":"init","gen":0,"metrics":{"width":60,"height":200},'
        .. '"support":["timer","hyperlinks","graphics","graphicswin"]}'
    os.execute(string.format("( printf '%%s\\n' %s; sleep 30 ) > %s & echo $! > %s",
        q(init), q(fifo), q(wpidf)))

    local start, outcome = now_ms(), nil
    while now_ms() - start < 20000 do
        local o = read_file(out) or ""
        if o:find('"type"%s*:%s*"update"') then
            sleep_ms(300)   -- let the rest of the update land
            outcome = "update"; break
        end
        if o:find('"type"%s*:%s*"error"') then outcome = "error"; break end
        if read_file(stf) then sleep_ms(200); outcome = "exited"; break end
        sleep_ms(100)
    end
    local elapsed = now_ms() - start
    local o, e = read_file(out) or "", read_file(err, 600) or ""
    self:log("after %d ms: %s", elapsed, outcome or "no answer")
    self:log("VM stdout: %s", o:sub(1, 600))
    self:log("VM stderr: %s", e)

    -- A first update that already exits is the VM refusing the game; its
    -- text (e.g. "Fatal error: corrupted story") says why.
    if outcome == "update" and o:find('"exit"%s*:%s*true') then
        local said = {}
        for t in o:gmatch('"text"%s*:%s*"([^"]*)"') do
            if t:match("%S") then table.insert(said, t) end
        end
        local m = #said > 0 and table.concat(said, " "):sub(1, 200) or "no message"
        self:res("FAIL", "the interpreter ended the game at once: " .. m,
            "the interpreter could not run this game: " .. m,
            "check the game file is complete (download it again); if it is, post the log")
    elseif outcome == "update" then
        self:res("PASS", "the interpreter answered the handshake in " .. elapsed .. " ms")
    elseif outcome == "error" then
        local m = o:match('"message"%s*:%s*"([^"]*)"') or "?"
        self:res("FAIL", "the interpreter reported an error: " .. m,
            "the interpreter refused this game: " .. m,
            "check the game file is complete (download it again); if it is, post the log")
    elseif outcome == "exited" then
        local st = tonumber((read_file(stf) or ""):match("%d+"))
        local why = "the interpreter stopped before showing the game"
        if st and st > 128 and SIGNALS[st - 128] then
            why = why .. ": " .. SIGNALS[st - 128]
        elseif e:match("%S") then
            why = why .. ": " .. e:gsub("%s+$", ""):sub(1, 200)
        end
        self:res("FAIL", "the interpreter exited with status " .. tostring(st) .. " during start-up",
            why, "post the log together with the game's name")
    else
        self:res("FAIL", "the interpreter gave no answer in 20 s",
            "the interpreter starts but never replies, so the game never appears",
            "post the log together with the game's name")
    end

    for _, pf in ipairs({ pidf, wpidf }) do
        local pid = tonumber(read_file(pf) or "")
        if pid then os.execute("kill " .. pid .. " 2>/dev/null") end
    end
    for _, p in ipairs({ fifo, out, err, pidf, stf, wpidf }) do os.remove(p) end
end

function Run:check_crashlog()
    for _, c in ipairs(self.crash_logs) do
        local text = read_file(c)
        if text then
            self:section("crash.log (" .. c .. ")")
            local hits = {}
            for line in text:gmatch("[^\n]+") do
                local l = line:lower()
                if l:find("frotz") or l:find("remglk") or l:find("interpreter") then
                    table.insert(hits, line)
                end
            end
            for i = math.max(1, #hits - 30), #hits do self:log("%s", hits[i]) end
            return
        end
    end
end

-- ── Report ──────────────────────────────────────────────────────────────────────

function Run:summary()
    local fails, warns, npass = {}, {}, 0
    for _, r in ipairs(self.results) do
        if r.kind == "FAIL" then table.insert(fails, r)
        elseif r.kind == "WARN" then table.insert(warns, r)
        else npass = npass + 1 end
    end
    local t = {}
    local function add(s) table.insert(t, s or "") end
    add(string.format("%d checks passed, %d warnings, %d problems.", npass, #warns, #fails))
    add(string.format("Device: %s   arch: %s", self.device or "?", self.arch))
    add()
    for _, r in ipairs(fails) do
        add("Problem: " .. (r.why or r.msg) .. ".")
        if r.fix then add("What to do: " .. r.fix .. ".") end
        add("(failed check: " .. r.msg .. ")")
        add()
    end
    if #warns > 0 then
        add("Also worth noting:")
        for _, r in ipairs(warns) do
            add("• " .. r.msg)
            if r.fix then add("  what to do: " .. r.fix) end
        end
        add()
    end
    if #fails == 0 then
        add("No blocking problem found: the interpreter starts and runs on this device.")
        add("If a game still fails, the cause is outside these checks — post the log.")
        add()
    end
    add("Full log: " .. self.log_path)
    return table.concat(t, "\n"), #fails, #warns
end

-- ── Entry point ─────────────────────────────────────────────────────────────────

local M = {}

-- opts:
--   plugin_dir  (required) the plugin's folder
--   arch        (required) the arch main.lua picked
--   log_path    where to write the log (falls back to /tmp/frotz_diag.log)
--   crash_logs  list of crash.log paths to look through
--   game        optional { vm, binary, gamefile, extra_args } — the failed game
-- Returns { text, fails, warns, log_path }.
function M.run(opts)
    -- KOReader may give a path relative to its install dir; the mount check
    -- needs an absolute one.
    local plugin_dir = opts.plugin_dir
    if plugin_dir:sub(1, 1) ~= "/" then
        plugin_dir = lfs.currentdir() .. "/" .. plugin_dir:gsub("^%./", "")
    end
    local self = setmetatable({
        plugin_dir = plugin_dir,
        arch       = opts.arch,
        game       = opts.game,
        crash_logs = opts.crash_logs or {},
        work       = "/tmp/frotz_diag_" .. os.time() .. "_" .. math.random(100000),
        lines      = {},
        results    = {},
    }, Run)
    local vm = self.game and self.game.vm
    self.vm_exe = vm == "twine" and "qjs" or vm

    self:log("frotz.koplugin diagnostics — %s", os.date("%Y-%m-%d %H:%M:%S"))
    self:check_system()
    self:check_arch()
    self:check_mount()
    self:check_tmp()
    local runnable = {}
    for _, name in ipairs(ALL_VMS) do runnable[name] = self:check_binary(name) end
    self:check_spawn(self.vm_exe ~= nil and runnable[self.vm_exe])
    if self.vm_exe == nil or runnable[self.vm_exe] then
        self:check_handshake()
    end
    self:check_crashlog()

    -- Write the log; the report's last line names where it went.
    self.log_path = opts.log_path or "/tmp/frotz_diag.log"
    local f = io.open(self.log_path, "w")
    if not f and self.log_path ~= "/tmp/frotz_diag.log" then
        self.log_path = "/tmp/frotz_diag.log"
        f = io.open(self.log_path, "w")
    end
    local text, nfail, nwarn = self:summary()
    if f then
        f:write(text, "\n\n", table.concat(self.lines, "\n"), "\n")
        f:close()
    else
        text = text:gsub("Full log: [^\n]*$", "(the log file could not be written)")
    end
    return { text = text, fails = nfail, warns = nwarn, log_path = self.log_path }
end

return M
