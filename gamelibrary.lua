-- library.lua — what we know about the games on this device.
--
-- One index for every game, keyed by the story file's absolute path:
--   DataDir/frotz_library/index.lua    { games = { [path] = entry } }
--   DataDir/frotz_library/covers/      cover images, named in entry.cover
-- A central store rather than a sidecar file next to each game, so it works
-- for folders the player organised themselves (or read-only ones) and the
-- menus read one file instead of probing every game.
--
-- Entry fields (all optional): tuid, ifids, title, author, year, rating,
-- ratings, playtime, pageversion, cover, source ("ifdb"), added.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs         = require("libs/libkoreader-lfs")
local util        = require("util")

local Library = {}
Library.__index = Library

function Library.dir()
    return DataStorage:getDataDir() .. "/frotz_library"
end

function Library.open()
    local self = setmetatable({}, Library)
    util.makePath(Library.dir() .. "/covers")
    self.store = LuaSettings:open(Library.dir() .. "/index.lua")
    self.games = self.store:readSetting("games") or {}
    return self
end

function Library:get(path)
    return self.games[path]
end

--- Merge fields into a game's entry (creating it) and save.
function Library:put(path, fields)
    local entry = self.games[path] or { added = os.time() }
    for k, v in pairs(fields) do entry[k] = v end
    self.games[path] = entry
    self:save()
    return entry
end

function Library:remove(path)
    self.games[path] = nil
    self:save()
end

function Library:save()
    self.store:saveSetting("games", self.games)
    self.store:flush()
end

--- The story file we already have for an IFDB game, if it still exists.
-- @return path, entry — or nil
function Library:findByTuid(tuid)
    if not tuid then return nil end
    for path, entry in pairs(self.games) do
        if entry.tuid == tuid and lfs.attributes(path, "mode") == "file" then
            return path, entry
        end
    end
    return nil
end

--- Absolute path of a cover file name stored in an entry.
function Library.coverPath(name)
    return Library.dir() .. "/covers/" .. name
end

return Library
