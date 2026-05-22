-- lua/quotes.lua
local ffi = require("ffi")
local ast = require("compiler.semantics.ast")
local T = ast.T
local newobject = ast.newobject

local function isquote(t)
    return T.quote and T.quote:isclassof(t)
end

-- Inject the necessary methods directly into the ASDL T.quote class
if T.quote then
    function T.quote:astype()
        if not self.tree:is("luaobject") or not T.Type:isclassof(self.tree.value) then
            error("quoted value is not a type")
        end
        return self.tree.value
    end
    
    function T.quote:isluaobject() return self.tree.type == T.luaobjecttype end
    function T.quote:gettype() return self.tree.type end
    function T.quote:islvalue() return not not self.tree.lvalue end
    
    function T.quote:asvalue()
        local function getvalue(e)
            if e:is("literal") then
                if type(e.value) == "userdata" then
                    return tonumber(ffi.cast("uint64_t *", e.value)[0])
                else
                    return e.value
                end
            elseif e:is("globalvalueref") then return e.value
            elseif e:is("constant") then
                return tonumber(e.value) or e.value or error("no value?")
            elseif e:is("constructor") then
                local t, typ = {}, e.type
                for i, r in ipairs(typ:getentries()) do
                    local v, err = getvalue(e.expressions[i]) 
                    if err then return nil, err end
                    local key = typ.convertible == "tuple" and i or r.field
                    t[key] = v
                end
                return t
            elseif e:is("var") then return e.symbol
            elseif e:is("luaobject") then
                 return e.value
            else
                local runconstantprop = function()
                    -- Safe runtime lookup to avoid circular require
                    return _G.terra.constant(self):get()
                end
                local status, value = pcall(runconstantprop)
                if not status then
                    return nil, "not a constant value (note: :asvalue() isn't implemented for all constants yet), error propagating constant was: "..tostring(value)
                end
                return value
            end
        end
        return getvalue(self.tree)
    end
    
    function T.quote:init()
        assert(T.Type:isclassof(self.tree.type), "quote tree must have a type")
    end
end

local function newquote(tree) 
    return newobject(tree, T.quote, tree)
end

return {
    isquote = isquote,
    newquote = newquote
}