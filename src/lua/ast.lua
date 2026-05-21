local asdl = require("lua.asdl")

local function israwlist(l)
    if List:isclassof(l) then
        return true
    elseif type(l) == "table" and not getmetatable(l) then
        local sz = #l
        local i = 0
        for k,v in pairs(l) do i = i + 1 end
        return i == sz
    end
    return false
end

local function islist(l)
    return List:isclassof(l)
end

local T = asdl.NewContext()

-- Allows ASDL to accept native Lua tables where needed
T:Extern("TypeOrLuaExpression", function(t) return T.Type:isclassof(t) or type(t) == "table" end)

-- ==========================================
-- 1. THE OFFICIAL TERRA ASDL SCHEMA
-- ==========================================
T:Define [[
ident =     escapedident(luaexpression expression) # removed during specialization
          | namedident(string value)
          | labelident(Label value)

field = recfield(ident key, tree value)
      | listfield(tree value)
      
structbody = structentry(string key, luaexpression type)
           | structlist(structbody* entries)

param = unevaluatedparam(ident name, luaexpression? type)
      | concreteparam(Type? type, string name, Symbol symbol,boolean isnamed)

structdef = (luaexpression? metatype, structlist records)

attr = (boolean nontemporal, number? alignment, boolean isvolatile)
fenceattr = (string? syncscope, string ordering)
cmpxchgattr = (string? syncscope, string success_ordering, string failure_ordering, number? alignment, boolean isvolatile, boolean isweak)
atomicattr = (string? syncscope, string ordering, number? alignment, boolean isvolatile)
Symbol = (Type type, string displayname, number id)
Label = (string displayname, number id)
tree = 
       luaexpression(function expression, boolean isexpression)
     | constructoru(field* records) #untyped version
     | selectu(tree value, ident field) #untyped version
     | method(tree value,ident name,tree* arguments) 
     | statlist(tree* statements)
     | fornumu(param variable, tree initial, tree limit, tree? step,block body) #untyped version
     | defvar(param* variables,  boolean hasinit, tree* initializers)
     | forlist(param* variables, tree iterator, block body)
     | functiondefu(param* parameters, boolean is_varargs, TypeOrLuaExpression? returntype, block body)
     | luaobject(any value)
     | setteru(function setter) 
     | quote(tree tree)
     | var(string name, Symbol? symbol)
     | literal(any? value, Type type)
     | index(tree value,tree index)
     | apply(tree value, tree* arguments)
     | letin(tree* statements, tree* expressions, boolean hasstatements)
     | operator(string operator, tree* operands)
     | block(tree* statements)
     | assignment(tree* lhs,tree* rhs)
     | gotostat(ident label)
     | breakstat()
     | label(ident label)
     | whilestat(tree condition, block body)
     | repeatstat(tree* statements, tree condition)
     | fornum(allocvar variable, tree initial, tree limit, tree? step, block body)
     | ifstat(ifbranch* branches, block? orelse)
     | switchstat(tree condition, tree* cases, block? ordefault)
     | defer(tree expression)
     | select(tree value, number index, string fieldname) 
     | globalvalueref(string name, globalvalue value)
     | constant(any value, Type type)
     | attrstore(tree address, tree value, attr attrs)
     | attrload(tree address, attr attrs)
     | fence(fenceattr attrs)
     | cmpxchg(tree address, tree cmp, tree new, cmpxchgattr attrs)
     | atomicrmw(string operator, tree address, tree value, atomicattr attrs)
     | debuginfo(string customfilename, number customlinenumber)
     | arrayconstructor(Type? oftype,tree* expressions)
     | vectorconstructor(Type? oftype,tree* expressions)
     | sizeof(Type oftype)
     | inlineasm(Type type, string asm, boolean volatile, string constraints, tree* arguments)
     | cast(Type to, tree expression)
     | allocvar(string name, Symbol symbol)
     | structcast(allocvar structvariable, tree expression, storelocation* entries)
     | constructor(tree* expressions)
     | returnstat(tree expression)
     | setter(allocvar rhs, tree setter) 
     | ifbranch(tree condition, block body)
     | switchcase(tree condition, block body)
     | storelocation(number index, tree value)

Type = primitive(string type, number bytes, boolean signed)
     | pointer(Type type, number addressspace) unique
     | vector(Type type, number N) unique
     | array(Type type, number N) unique
     | functype(Type* parameters, Type returntype, boolean isvararg) unique
     | struct(string name)
     | niltype 
     | opaque 
     | error 
     | luaobjecttype

labelstate = undefinedlabel(gotostat * gotos, table* positions)
           | definedlabel(table position, label label)

definition = functiondef(string? name, functype type, allocvar* parameters, boolean is_varargs, block body, table labeldepths, globalvalue* globalsused)
           | functionextern(string? name, functype type)
     
globalvalue = terrafunction(definition? definition)
            | globalvariable(tree? initializer, number addressspace, boolean extern, boolean constant)
            attributes(string name, Type type, table anchor)
            
overloadedterrafunction = (string name, terrafunction* definitions)
]]

-- Base attributes
T.var.lvalue = true

function T.allocvar:settype(typ)
    assert(T.Type:isclassof(typ))
    self.type, self.symbol.type = typ, typ
end

-- ==========================================
-- 2. TREE HELPERS & PRINTRAW
-- ==========================================
function T.tree:is(value)
    return self.kind == value
end

local function istree(v) 
    return T.tree:isclassof(v)
end

function T.tree:printraw()
    local function header(t)
        local mt = getmetatable(t)
        if type(t) == "table" and mt and type(mt.__fields) == "table" then
            return t.kind or tostring(mt)
        else return tostring(t) end
    end
    
    local function isList(t)
        return type(t) == "table" and #t ~= 0
    end
    
    local parents = {}
    local depth = 0
    
    local function printElem(t, spacing)
        if type(t) == "table" then
            if parents[t] then
                print(string.rep(" ", #spacing) .. "<cyclic reference>")
                return
            elseif depth > 0 and type(t.kind) == "string" and t.kind == "terrafunction" then 
                return 
            end
            
            parents[t] = true
            depth = depth + 1
            
            for k, v in pairs(t) do
                local prefix
                if type(k) == "table" and not (v and v.displayname and v.id) then
                    prefix = ("<table (mt = %s)>"):format(tostring(getmetatable(k)))
                else
                    prefix = tostring(k)
                end
                
                if k ~= "kind" and k ~= "offset" then
                    prefix = spacing .. prefix .. ": "
                    print(prefix .. header(v))
                    
                    if isList(v) then
                        printElem(v, string.rep(" ", 2 + #spacing))
                    else
                        printElem(v, string.rep(" ", 2 + #prefix))
                    end
                end
            end
            depth = depth - 1
            parents[t] = nil
        end
    end
    
    print(header(self))
    if type(self) == "table" then
        printElem(self, "  ")
    end
end

local function newobject(ref, ctor, ...)
    assert(ref.linenumber and ref.filename, "not a anchored object?")
    local r = ctor(...)
    r.linenumber, r.filename, r.offset = ref.linenumber, ref.filename, ref.offset
    return r
end

local function copyobject(ref, newfields)
    local class = getmetatable(ref)
    local fields = class.__fields
    assert(fields, "not a asdl object?")
    local function handlefield(i, ...)
        if i == 0 then
            return newobject(ref, class, ...)
        else
            local f = fields[i]
            local a = newfields[f.name] or ref[f.name]
            newfields[f.name] = nil
            return handlefield(i - 1, a, ...)
        end
    end
    local r = handlefield(#fields)
    for k, v in pairs(newfields) do
        error("unused field in copy: " .. tostring(k))
    end
    return r
end
T.tree.copy = copyobject

local function newanchor(depth)
    local info = debug.getinfo(1 + depth, "Sl")
    local body = { linenumber = info and info.currentline or 0, filename = info and info.short_src or "unknown" }
    return setmetatable(body, T.tree)
end

-- ==========================================
-- 3. SYMBOLS AND LABELS
-- ==========================================
local identcount = 0

local function issymbol(s)
    return T.Symbol:isclassof(s)
end

local function newsymbol(typ, displayname)
    displayname = displayname or tostring(identcount)
    local r = T.Symbol(typ, displayname, identcount)
    identcount = identcount + 1
    return r
end

function T.Symbol:__tostring()
    return "$" .. self.displayname
end

function T.Symbol:tocname() 
    return "__symbol" .. tostring(self.id) 
end

function T.Symbol:sethandle(v)
    if v == true then self.ishandle = true end
    return self
end

local function islabel(l) 
    return T.Label:isclassof(l) 
end

local function newlabel(displayname)
    displayname = displayname or tostring(identcount)
    local r = T.Label(displayname, identcount)
    identcount = identcount + 1
    return r
end

function T.Label:__tostring() 
    return "$" .. self.displayname 
end

function T.Label:tocname() 
    return "__label_" .. tostring(self.id) 
end

local function mkstring(self,begin,sep,finish)
    return begin..table.concat(self:map(tostring),sep)..finish
end

-- ==========================================
-- EXPORT MODULE
-- ==========================================
return {
    T = T,
    mkstring = mkstring,
    israwlist = israwlist,
    printraw = T.tree.printraw,
    istree = istree,
    newobject = newobject,
    copyobject = copyobject,
    newanchor = newanchor,
    issymbol = issymbol,
    newsymbol = newsymbol,
    islabel = islabel,
    newlabel = newlabel
}