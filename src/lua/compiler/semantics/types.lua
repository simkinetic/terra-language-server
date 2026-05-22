-- lua/types.lua
local ffi = require("ffi")
local asdl = require("compiler.semantics.asdl")
local List = asdl.List
local diagnostics = require("compiler.semantics.diagnostics")
local ast = require("compiler.semantics.ast")
local macros = require("compiler.semantics.macros")

local T = ast.T
local types = {}

-- ==========================================
-- 1. LOCAL UTILITIES (No Global Pollution!)
-- ==========================================

local function invokeuserfunction(anchor, what, speculate, userfn, ...)
    if not speculate then return userfn(...) end
    return xpcall(userfn, debug.traceback, ...)
end

-- returns a function string -> string that makes names unique by appending numbers
local function uniquenameset(sep)
    local cache = {}
    local function get(name)
        local count = cache[name]
        if not count then
            cache[name] = 1
            return name
        end
        local rename = name .. sep .. tostring(count)
        cache[name] = count + 1
        return get(rename) 
    end
    return get
end

-- sanitize a string, making it a valid lua/C identifier
local function tovalididentifier(name)
    return tostring(name):gsub("[^_%w]","_"):gsub("^(%d)","_%1"):gsub("^$","_") 
end

local function memoizefunction(fn)
    local info = debug.getinfo(fn,'u')
    local nparams = not info.isvararg and info.nparams
    local cachekey = {}
    local values = {}
    local nilkey = {}
    return function(...)
        local key = cachekey
        for i = 1, nparams or select('#', ...) do
            local e = select(i, ...)
            if e == nil then e = nilkey end
            local n = key[e]
            if not n then
                n = {}; key[e] = n
            end
            key = n
        end
        local v = values[key]
        if not v then
            v = fn(...)
            values[key] = v
        end
        return v
    end
end

local uniquetypenameset = uniquenameset("_")
local getuniquestructname = uniquenameset("$")

-- ==========================================
-- 2. AST TYPE MONKEY-PATCHING
-- ==========================================

function T.tree:aserror() 
    return self:copy{}:withtype(types.error)
end

function T.tree:setlvalue(v)
    if v then self.lvalue = true end
    return self
end

function T.tree:withtype(type)
    assert(types.istype(type))
    self.type = type
    return self
end

function T.tree:setassignment(v)
    if v then self.assignment = v end
    return self
end

local defaultproperties = { "name", "tree", "undefined", "incomplete", "convertible", "cachedcstring", "llvm_definingfunction" }
for i,dp in ipairs(defaultproperties) do
    T.Type[dp] = false
end

T.Type.__index = nil 
function T.Type:__index(key)
    local N = tonumber(key)
    if N then
        return T.array(self, N)
    else
        return getmetatable(self)[key]
    end
end

T.Type.__tostring = nil 
T.Type.__tostring = memoizefunction(function(self)
    if self:isstruct() then 
        if self.metamethods.__typename then
            local status, r = pcall(function() return tostring(self.metamethods.__typename(self)) end)
            if status then return r end
        end
        return self.name
    elseif self:ispointer() then
        if not self.addressspace or self.addressspace == 0 then
            return "&"..tostring(self.type)
        else
            return "pointer("..tostring(self.type)..","..tostring(self.addressspace)..")"
        end
    elseif self:isvector() then return "vector("..tostring(self.type)..","..tostring(self.N)..")"
    elseif self:isfunction() then return "{"..table.concat(self.parameters, ",")..(self.isvararg and " ...}" or "}").." -> "..tostring(self.returntype)
    elseif self:isarray() then
        local t = tostring(self.type)
        if self.type:ispointer() then t = "("..t..")" end
        return t.."["..tostring(self.N).."]"
    end
    if not self.name then error("unknown type?") end
    return self.name
end)

T.Type.printraw = T.tree.printraw
function T.Type:isprimitive() return self.kind == "primitive" end
function T.Type:isintegral() return self.kind == "primitive" and self.type == "integer" end
function T.Type:isfloat() return self.kind == "primitive" and self.type == "float" end
function T.Type:isarithmetic() return self.kind == "primitive" and (self.type == "integer" or self.type == "float") end
function T.Type:islogical() return self.kind == "primitive" and self.type == "logical" end
function T.Type:canbeord() return self:isintegral() or self:islogical() end
function T.Type:ispointer() return self.kind == "pointer" end
function T.Type:isarray() return self.kind == "array" end
function T.Type:isfunction() return self.kind == "functype" end
function T.Type:isstruct() return self.kind == "struct" end
function T.Type:ispointertostruct() return self:ispointer() and self.type:isstruct() end
function T.Type:ispointertofunction() return self:ispointer() and self.type:isfunction() end
function T.Type:isaggregate() return self:isstruct() or self:isarray() end
function T.Type:iscomplete() return not self.incomplete end
function T.Type:isvector() return self.kind == "vector" end
function T.Type:isunit() return types.unit == self end

local applies_to_vectors = {"isprimitive","isintegral","isarithmetic","islogical", "canbeord"}
for i,n in ipairs(applies_to_vectors) do
    T.Type[n.."orvector"] = function(self)
        return self[n](self) or (self:isvector() and self.type[n](self.type))  
    end
end

-- ==========================================
-- 3. TYPE LAYOUTS AND PROPERTIES
-- ==========================================

function T.Type:layoutstring()
    local seen = {}
    local parts = List()
    local function print_layout(self, d)
        local function indent(l)
            parts:insert("\n")
            parts:insert(string.rep("  ", d + 1 + (l or 0)))
        end
        parts:insert(tostring(self))
        if seen[self] then return end
        seen[self] = true
        if self:isstruct() then
            parts:insert(":")
            local layout = self:getlayout()
            for i, e in ipairs(layout.entries) do
                indent()
                parts:insert(tostring(e.key)..": ")
                print_layout(e.type, d + 1)
            end
        elseif self:isarray() or self:ispointer() then
            parts:insert(" ->")
            indent()
            print_layout(self.type, d + 1)
        elseif self:isfunction() then
            parts:insert(": ")
            indent() parts:insert("parameters: ")
            print_layout(types.tuple(unpack(self.parameters)), d + 1)
            indent() parts:insert("returntype:")
            print_layout(self.returntype, d + 1)
        end
    end
    print_layout(self, 0)
    parts:insert("\n")
    return parts:concat()
end
function T.Type:printpretty() io.write(self:layoutstring()) end

local function memoizeproperty(data)
    local name = data.name
    local erroronrecursion = data.erroronrecursion
    local getvalue = data.getvalue

    local key = "cached"..name
    local inside = "inget"..name
    T.struct[key],T.struct[inside] = false,false
    return function(self)
        if not self[key] then
            if self[inside] then
                diagnostics.erroratlocation(self.anchor, erroronrecursion)
            else 
                self[inside] = true
                self[key] = getvalue(self)
                self[inside] = nil
            end
        end
        return self[key]
    end
end

T.struct.getentries = memoizeproperty{
    name = "entries";
    erroronrecursion = "recursively calling getentries on type, or using a type whose getentries failed";
    getvalue = function(self)
        local entries = self.entries
        if type(self.metamethods.__getentries) == "function" then
            entries = invokeuserfunction(self.anchor, "invoking __getentries for struct", false, self.metamethods.__getentries, self)
        elseif self.undefined then
            diagnostics.erroratlocation(self.anchor, "attempting to use type ", self, " before it is defined.")
        end
        if type(entries) ~= "table" then
            diagnostics.erroratlocation(self.anchor, "computed entries are not a table")
        end
        local function checkentry(e, results)
            if type(e) == "table" then
                local f = e.field or e[1] 
                local t = e.type or e[2]
                if types.istype(t) and (type(f) == "string" or (f and f.islabel)) then
                    results:insert { type = t, field = f }
                    return
                elseif type(e) == "table" and e.islist then
                    local union = List()
                    for i, se in ipairs(e) do checkentry(se, union) end
                    results:insert(union)
                    return
                end
            end
            diagnostics.erroratlocation(self.anchor, "expected either a field type pair or a list of valid entries representing a union")
        end
        local checkedentries = List()
        for i,e in ipairs(entries) do checkentry(e, checkedentries) end
        return checkedentries
    end
}

local function reportopaque(type)
    local msg = "attempting to use an opaque type "..tostring(type).." where the layout of the type is needed"
    if type.anchor then diagnostics.erroratlocation(type.anchor, msg) else error(msg, 4) end
end

T.struct.getlayout = memoizeproperty {
    name = "layout"; 
    erroronrecursion = "type recursively contains itself, or using a type whose layout failed";
    getvalue = function(self)
        local tree = self.anchor
        local entries = self:getentries()
        local nextallocation = 0
        local uniondepth = 0
        local unionsize = 0
        
        local layout = { entries = List(), keytoindex = {} }
        local function addentry(k,t)
            local function ensurelayout(t)
                if t:isstruct() then t:getlayout()
                elseif t:isarray() then ensurelayout(t.type)
                elseif t == types.opaque then reportopaque(self) end
            end
            ensurelayout(t)
            local entry = { type = t, key = k, allocation = nextallocation, inunion = uniondepth > 0 }
            
            if layout.keytoindex[entry.key] ~= nil then diagnostics.erroratlocation(tree, "duplicate field ", tostring(entry.key)) end

            layout.keytoindex[entry.key] = #layout.entries
            layout.entries:insert(entry)
            if uniondepth > 0 then unionsize = unionsize + 1 else nextallocation = nextallocation + 1 end
        end
        local function beginunion() uniondepth = uniondepth + 1 end
        local function endunion()
            uniondepth = uniondepth - 1
            if uniondepth == 0 and unionsize > 0 then
                nextallocation = nextallocation + 1
                unionsize = 0
            end
        end
        local function addentrylist(entries)
            for i,e in ipairs(entries) do
                if type(e) == "table" and e.islist then
                    beginunion()
                    addentrylist(e)
                    endunion()
                else addentry(e.field, e.type) end
            end
        end
        addentrylist(entries)
        return layout
    end;
}

function T.functype:completefunction()
    for i, p in ipairs(self.parameters) do p:complete() end
    self.returntype:complete()
    return self
end

function T.Type:complete() 
    if self.incomplete then
        if self:isarray() then
            self.type:complete()
            self.incomplete = self.type.incomplete
        elseif self == types.opaque or self:isfunction() then
            reportopaque(self)
        else
            assert(self:isstruct())
            local layout = self:getlayout()
            if not layout.invalid then
                self.incomplete = nil 
                for i, e in ipairs(layout.entries) do e.type:complete() end
                if type(self.metamethods.__staticinitialize) == "function" then
                    invokeuserfunction(self.anchor, "invoking __staticinitialize", false, self.metamethods.__staticinitialize, self)
                end
            end
        end
    end
    return self
end

function T.functype:tcompletefunction(anchor)
    return invokeuserfunction(anchor, "finalizing type", false, self.completefunction, self)
end

function T.Type:tcomplete(anchor)
    return invokeuserfunction(anchor, "finalizing type", false, self.complete, self)
end

local function defaultgetmethod(self, methodname)
    local fnlike = self.methods[methodname]
    if not fnlike and macros.ismacro(self.metamethods.__methodmissing) then
        fnlike = macros.internalmacro(function(ctx, tree, ...)
            return self.metamethods.__methodmissing:run(ctx, tree, methodname, ...)
        end)
    end
    return fnlike
end

function T.struct:getmethod(methodname)
    local gm = (type(self.metamethods.__getmethod) == "function" and self.metamethods.__getmethod) or defaultgetmethod
    local success, result = pcall(gm, self, methodname)
    if not success then return nil, "error while looking up method: "..result
    elseif result == nil then return nil, "no such method "..tostring(methodname).." defined for type "..tostring(self)
    else return result end
end

function T.struct:getfield(fieldname)
    local l = self:getlayout()
    local i = l.keytoindex[fieldname]
    if not i then return nil, ("field name '%s' is not a raw field of type %s"):format(tostring(self), tostring(fieldname)) end
    return l.entries[i+1]
end

function T.struct:getfields()
    return self:getlayout().entries
end

function types.istype(t)
    return T.Type:isclassof(t)
end

-- ==========================================
-- 4. PRIMITIVE TYPE INSTANTIATION
-- ==========================================

local function globaltype(name, typ, min_v, max_v)
    typ.name = typ.name or name
    types[name] = typ
    if min_v then function typ:min() return min_v end end
    if max_v then function typ:max() return max_v end end
end

local integer_sizes = {1, 2, 4, 8}
for _, size in ipairs(integer_sizes) do
    for _, s in ipairs{true, false} do
        local bits = size * 8
        local name = "int"..tostring(bits)
        if not s then name = "u"..name end
        local min, max
        if not s then
            min = 0ULL
            max = -1ULL
        else
            min = 2LL ^ (bits - 1)
            max = min - 1
        end
        local typ = T.primitive("integer", size, s)
        globaltype(name, typ, min, max)
    end
end  

globaltype("float", T.primitive("float", 4, true), -math.huge, math.huge)
globaltype("double", T.primitive("float", 8, true), -math.huge, math.huge)
globaltype("bool", T.primitive("logical", 1, false))

types.error, T.error.name = T.error, "<error>"
T.luaobjecttype.name = "luaobjecttype"

types.niltype = T.niltype
globaltype("niltype", T.niltype)

types.opaque, T.opaque.incomplete = T.opaque, true
globaltype("opaque", T.opaque)

types.array, types.vector, types.functype = T.array, T.vector, T.functype
T.functype.incomplete = true

function T.functype:init()
    if self.isvararg and #self.parameters == 0 then error("vararg functions must have at least one concrete parameter") end
end

function types.pointer(t, as) return T.pointer(t, as or 0) end
function T.array:init() self.incomplete = true end
function T.vector:init()
    if not self.type:isprimitive() and self.type ~= T.error then
        error("vectors must be composed of primitive types (for now...) but found type "..tostring(self.type))
    end
end

types.tuple = memoizefunction(function(...)
    local args = List {...}
    local t = types.newstruct()
    for i, e in ipairs(args) do
        if not types.istype(e) then error("expected a type but found "..type(e)) end
        t.entries:insert {"_"..(i-1), e}
    end
    t.metamethods.__typename = function(self) return "{"..table.concat(args, ",").."}" end
    t:setconvertible("tuple")
    return t
end)

function types.newstruct(displayname, depth)
    displayname = displayname or "anon"
    depth = depth or 1
    return types.newstructwithanchor(displayname, ast.newanchor(1 + depth))
end

function T.struct:setconvertible(b)
    assert(self.incomplete)
    self.convertible = b
end

function types.newstructwithanchor(displayname, anchor)
    assert(displayname ~= "")
    local name = getuniquestructname(displayname)
    local tbl = T.struct(name) 
    tbl.entries = List()
    tbl.methods = {}
    tbl.metamethods = {}
    tbl.anchor = anchor
    tbl.incomplete = true
    return tbl
end

function types.funcpointer(parameters, ret, isvararg)
    if types.istype(parameters) then parameters = {parameters} end
    if not types.istype(ret) and type(ret) == "table" and ret.islist then
        ret = #ret == 1 and ret[1] or types.tuple(unpack(ret))
    end
    return types.pointer(types.functype(List{unpack(parameters)}, ret, not not isvararg))
end

types.unit = types.tuple():complete()
types.placeholderfunction = types.functype(List(), types.error, false) 
globaltype("int", types.int32)
globaltype("uint", types.uint32)
globaltype("long", types.int64)
globaltype("intptr", types.uint64)
globaltype("ptrdiff", types.int64)
globaltype("rawstring", types.pointer(types.int8))

function types.cast(terratype, obj)
    return ffi.cast(terratype.name or "void*", obj)
end

return {
    types = types,
    memoize = memoizefunction
}