local ast = require("lua.ast")
local asdl = require("lua.asdl")
local types_module = require("lua.types")

local List = asdl.List
local T = ast.T
local types = types_module.types

-- ==========================================
-- 1. TERRAFUNCTION METHODS
-- ==========================================
if T.terrafunction then
    function T.terrafunction:isextern() 
        return self.definition and self.definition.kind == "functionextern" 
    end
    
    function T.terrafunction:isdefined() 
        return self.definition ~= nil 
    end
    
    function T.terrafunction:getname()
        return self.name
    end

    function T.terrafunction:setname(name) 
        self.name = tostring(name) 
        if self.definition then self.definition.name = name end
        return self
    end

    function T.terrafunction:adddefinition(functiondef)
        if self.definition then error("terra function "..tostring(self.name).." already defined") end
        self:resetdefinition(functiondef)
    end
    
    function T.terrafunction:resetdefinition(functiondef)
        if T.terrafunction:isclassof(functiondef) and functiondef:isdefined() then 
            functiondef = functiondef.definition
        end
        assert(T.definition:isclassof(functiondef), "expected a defined terra function")
        if self.readytocompile then error("cannot reset a definition of function that has already been compiled", 2) end
        if self.type ~= functiondef.type and self.type ~= types.placeholderfunction then 
            error(("attempting to define terra function declaration with type %s with a terra function definition of type %s"):format(tostring(self.type), tostring(functiondef.type)))
        end
        
        self.definition = functiondef
        self.type = functiondef.type
        functiondef.name = assert(self.name)
    end
    
    function T.terrafunction:gettype(nop)
        assert(nop == nil, ":gettype no longer takes any callbacks for when a function is complete")
        if self.type == types.placeholderfunction then 
            error("function being recursively referenced needs an explicit return type.")
        end
        return self.type
    end
    
    -- LSP-Safe Attribute Setters
    function T.terrafunction:setinlined(v)
        assert(self:isdefined(), "attempting to set the inlining state of an undefined function")
        self.definition.alwaysinline = not not v
    end
    
    function T.terrafunction:setoptimized(v)
        assert(self:isdefined(), "attempting to set the optimization state of an undefined function")
        self.definition.dontoptimize = not v
    end
    
    function T.terrafunction:setcallingconv(v)
        assert(self:isdefined(), "attempting to set the calling convention of an undefined function")
        self.definition.callingconv = tostring(v)
    end
    
    function T.terrafunction:setnoreturn(v)
        assert(self:isdefined(), "attempting to set the noreturn state of an undefined function")
        self.definition.noreturn = not not v
    end
end

local function isfunction(obj)
    return T.terrafunction and T.terrafunction:isclassof(obj)
end

-- ==========================================
-- 2. OVERLOADED TERRAFUNCTION METHODS
-- ==========================================
if T.overloadedterrafunction then
    function T.overloadedterrafunction:adddefinition(d)
        assert(T.terrafunction:isclassof(d),"expected a terra function")
        d:setname(self.name)
        self.definitions:insert(d)
        return self
    end
    
    function T.overloadedterrafunction:getdefinitions() 
        return self.definitions 
    end
end

local function isoverloadedfunction(obj) 
    return T.overloadedterrafunction and T.overloadedterrafunction:isclassof(obj) 
end

local function overloadedfunction(name, init)
    init = init or {}
    return T.overloadedterrafunction(name, List{unpack(init)})
end

-- ==========================================
-- 3. EXPORT MODULE
-- ==========================================
return {
    isfunction = isfunction,
    isoverloadedfunction = isoverloadedfunction,
    overloadedfunction = overloadedfunction
}