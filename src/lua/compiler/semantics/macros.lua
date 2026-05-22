-- lua/macros.lua
local macro = {}
macro.__index = macro

macro.__call = function(self, ...)
    if not self.fromlua then
        error("macros must be called from inside terra code", 2)
    end
    return self.fromlua(...)
end

function macro:run(ctx, tree, ...)
    if self._internal then
        return self.fromterra(ctx, tree, ...)
    else
        return self.fromterra(...)
    end
end

local function ismacro(t)
    return getmetatable(t) == macro
end

local function createmacro(fromterra, fromlua)
    return setmetatable({fromterra = fromterra, fromlua = fromlua}, macro)
end

local function internalmacro(...) 
    local m = createmacro(...)
    m._internal = true
    return m
end

return {
    ismacro = ismacro,
    createmacro = createmacro,
    internalmacro = internalmacro
}