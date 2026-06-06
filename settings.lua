local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Settings = {}

local DEFAULTS = {
    font_size        = 18,
    game_directory   = "/mnt/us/documents",
    show_keyboard    = true,
    history_size     = 20,
    last_game        = nil,
}

function Settings:load()
    local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/frotz.lua")
    local data = {}
    for k, default in pairs(DEFAULTS) do
        local v = s:readSetting(k)
        data[k] = (v ~= nil) and v or default
    end
    data._store = s
    return data
end

function Settings:save(data)
    for k in pairs(DEFAULTS) do
        data._store:saveSetting(k, data[k])
    end
    data._store:flush()
end

return Settings
