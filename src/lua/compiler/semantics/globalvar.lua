-- src/lua/compiler/semantics/globalvar.lua
local ast = require("compiler.semantics.ast")
local types = require("compiler.semantics.types")
local diagnostics = require("compiler.semantics.diagnostics")

local T = ast.T

-- ==========================================
-- 1. LOCAL UTILITIES
-- ==========================================

local function constantcheck(e, checklvalue)
    local kind = e.kind
    if "literal" == kind or "constant" == kind or "sizeof" == kind then -- trivially ok
    elseif "index" == kind and checklvalue then
        constantcheck(e.value, true)
        constantcheck(e.index)
    elseif "operator" == kind then
        local op = e.operator
        if "@" == op then
            constantcheck(e.operands[1])
            if not checklvalue then
                diagnostics.erroratlocation(e.anchor or e, "non-constant result of dereference used as a constant initializer")
            end
        elseif "&" == op then
            constantcheck(e.operands[1], true)
        else
            for _, ee in ipairs(e.operands) do constantcheck(ee) end
        end
    elseif "select" == kind then
        constantcheck(e.value, checklvalue)
    elseif "globalvalueref" == kind then
        if e.value.kind == "globalvariable" and not (e.value:isconstant() or checklvalue) then
            diagnostics.erroratlocation(e.anchor or e, "non-constant use of global variable used as a constant initializer")
        end
    elseif "arrayconstructor" == kind or "vectorconstructor" == kind then
        for _, ee in ipairs(e.expressions) do constantcheck(ee) end
    elseif "cast" == kind then
        if e.expression.type:isarray() then
            if checklvalue then
                constantcheck(e.expression, true)
            else 
                diagnostics.erroratlocation(e.anchor or e, "non-constant cast of array to pointer used as a constant initializer")
            end
        else constantcheck(e.expression) end
    elseif "structcast" == kind then
        constantcheck(e.expression)
    elseif "constructor" == kind then
        for _, ee in ipairs(e.expressions) do constantcheck(ee) end
    else
        diagnostics.erroratlocation(e.anchor or e, "non-constant expression being used as a constant initializer")
    end
    return e 
end

local function createglobalinitializer(anchor, typ, c)
    if not c then return nil end
    if not T.quote:isclassof(c) then
        local c_ = c
        c = ast.newobject(anchor, T.luaexpression, function() return c_ end, true)
    end
    if typ then
        c = ast.newobject(anchor, T.cast, typ, c)
    end
    
    local typechecker = require("compiler.semantics.typechecker")
    return constantcheck(typechecker.typecheck(c))
end

-- ==========================================
-- 2. AST METHODS & WIRING
-- ==========================================

local function init(self)
    self.symbol = ast.newsymbol and ast.newsymbol(self.type, self.name) or {}
end

local function isextern(self) return self.extern end
local function isconstant(self) return self.constant end

local function globalvar_setinitializer(self, init)
    if self.readytocompile then 
        error("cannot change global variable initializer after it has been compiled.", 2) 
    end
    self.initializer = createglobalinitializer(self.anchor, self.type, init)
end

local function globalvar_get(self)
    local ptr = self:getpointer()
    return ptr[0]
end

local function globalvar_set(self, v)
    local ptr = self:getpointer()
    ptr[0] = v
end

local function globalvar_tostring(self)
    local kind = self:isconstant() and "constant" or "global"
    local extern = self:isextern() and "extern " or ""
    local r = ("%s%s %s : %s"):format(extern, kind, self.name, tostring(self.type))
    if self.initializer then
        local prettystring = ast.prettystring or tostring
        r = ("%s = %s"):format(r, prettystring(self.initializer, false))
    end
    return r
end

-- Inject directly into the AST node here so the caller doesn't have to
T.globalvariable.init = globalvar_init
T.globalvariable.isextern = globalvar_isextern
T.globalvariable.isconstant = globalvar_isconstant
T.globalvariable.setinitializer = globalvar_setinitializer
T.globalvariable.get = globalvar_get
T.globalvariable.set = globalvar_set
T.globalvariable.__tostring = globalvar_tostring

-- ==========================================
-- 4. EXPORT
-- ==========================================
return {
    isglobalvar = isglobalvar,
    global = global_constructor
}