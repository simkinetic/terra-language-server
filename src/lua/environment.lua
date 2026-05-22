local asdl = require("lua.asdl")
local List = asdl.List

local environment = {}
environment.__index = environment

function environment:enterblock()
    local e = {}
    local q = {}
    self.scopedepth = self.scopedepth + 1
    self._localenv = setmetatable(e,{ __index = self._localenv })
    self._queue = setmetatable(q,{ __index = self._queue })
end

function environment:leaveblock()
    self.scopedepth = self.scopedepth - 1
    self._localenv = getmetatable(self._localenv).__index
    self._queue = getmetatable(self._queue).__index
end

function environment:localenv()
    return self._localenv
end

function environment:luaenv()
    return self._luaenv
end

function environment:combinedenv()
    return self._combinedenv
end

function environment:queue()
    return self._queue
end

local function newenvironment(_luaenv)
    local self = setmetatable({}, environment)
    self._luaenv = _luaenv or {}
    self._combinedenv = setmetatable({}, {
        __index = function(_,idx)
            return self._localenv[idx] or self._luaenv[idx]
        end;
        __newindex = function() 
            error("cannot define global variables or assign to upvalues in an escape")
        end;
    })
    self.scopedepth = -1
    self.isfundef = false --flag to signal type-checked code is a terra function or a let-in block
    self._queue = List()
    self:enterblock()
    return self
end

return {
    environment = environment,
    newenvironment = newenvironment
}