local History = {}
History.__index = History

function History:new(max_size)
    return setmetatable({
        max_size = max_size or 20,
        items    = {},
        cursor   = 0,
    }, self)
end

function History:push(line)
    if line == "" then return end
    for i = #self.items, 1, -1 do
        if self.items[i] == line then table.remove(self.items, i) end
    end
    table.insert(self.items, line)
    if #self.items > self.max_size then table.remove(self.items, 1) end
    self.cursor = #self.items + 1
end

-- Returns the previous (older) command, or nil at the start of history.
function History:prev()
    if #self.items == 0 then return nil end
    self.cursor = math.max(1, self.cursor - 1)
    return self.items[self.cursor]
end

-- Returns the next (newer) command, or "" when past the newest entry.
function History:next()
    if #self.items == 0 then return nil end
    self.cursor = math.min(#self.items + 1, self.cursor + 1)
    return (self.cursor > #self.items) and "" or self.items[self.cursor]
end

function History:resetCursor()
    self.cursor = #self.items + 1
end

return History
