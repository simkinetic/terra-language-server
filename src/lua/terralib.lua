-- See Copyright Notice in ../LICENSE.txt
local ffi = require("ffi")
local asdl = require("lua.asdl")
local List = asdl.List

-- LINE COVERAGE INFORMATION, must run test script with luajit and not terra to avoid overwriting coverage with old version
if false then
    local converageloader = loadfile("coverageinfo.lua")
    local linetable = converageloader and converageloader() or {}
    local function dumplineinfo()
        local F = io.open("coverageinfo.lua","w")
        F:write("return {\n")
        for k,v in pairs(linetable) do
            F:write("["..k.."] = "..v..";\n")
        end
        F:write("}\n")
        F:close()
    end
    local function debughook(event)
        local info = debug.getinfo(2,"Sl")
        if info.short_src:match("terralib%.lua") then
            linetable[info.currentline] = linetable[info.currentline] or 0
            linetable[info.currentline] = linetable[info.currentline] + 1
        end
    end
    debug.sethook(debughook,"l")
    -- make a fake ffi object that causes dumplineinfo to be called when
    -- the lua state is removed
    ffi.cdef [[
        typedef struct {} __linecoverage;
    ]]
    ffi.metatype("__linecoverage", { __gc = dumplineinfo } )
    _G[{}] = ffi.new("__linecoverage")
end

setmetatable(terra.kinds, { __index = function(self,idx)
    error("unknown kind accessed: "..tostring(idx))
end })

local T = asdl.NewContext()

T:Extern("TypeOrLuaExpression", function(t) return T.Type:isclassof(t) or T.luaexpression:isclassof(t) end)
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
     # trees that are introduced in parsing and are ...
     # removed during specialization
       luaexpression(function expression, boolean isexpression)
     # removed during typechecking
     | constructoru(field* records) #untyped version
     | selectu(tree value, ident field) #untyped version
     | method(tree value,ident name,tree* arguments) 
     | statlist(tree* statements)
     | fornumu(param variable, tree initial, tree limit, tree? step,block body) #untyped version
     | defvar(param* variables,  boolean hasinit, tree* initializers)
     | forlist(param* variables, tree iterator, block body)
     | functiondefu(param* parameters, boolean is_varargs, TypeOrLuaExpression? returntype, block body)
     
     # introduced temporarily during specialization/typing, but removed after typing
     | luaobject(any value)
     | setteru(function setter) # temporary node introduced and removed during typechecking to handle __update and __setfield
     | quote(tree tree)
     # trees that exist after typechecking and handled by the backend:
     | var(string name, Symbol? symbol) #symbol is added during specialization
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
     | select(tree value, number index, string fieldname) # typed version, fieldname for debugging
     | globalvalueref(string name, globalvalue value)
     | constant(cdata value, Type type)
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
     | setter(allocvar rhs, tree setter) # handles custom assignment behavior, real rhs is first stored in 'rhs' and then the 'setter' expression uses it
     
     # special purpose nodes, they only occur in specific locations, but are considered trees because they can contain typed trees
     | ifbranch(tree condition, block body)
     | switchcase(tree condition, block body)
     | storelocation(number index, tree value) # for struct cast, value uses structvariable

Type = primitive(string type, number bytes, boolean signed)
     | pointer(Type type, number addressspace) unique
     | vector(Type type, number N) unique
     | array(Type type, number N) unique
     | functype(Type* parameters, Type returntype, boolean isvararg) unique
     | struct(string name)
     | niltype #the type of the singleton nil (implicitly convertable to any pointer type)
     | opaque #an type of unknown layout used with a pointer (&opaque) to point to data of an unknown type (i.e. void*)
     | error #used in compiler to squelch errors
     | luaobjecttype #type of expressions that hold temporary luaobjects in the compiler, removed during typechecking

labelstate = undefinedlabel(gotostat * gotos, table* positions) #undefined label with gotos pointing to it
           | definedlabel(table position, label label) #defined label with position and label object defining it

definition = functiondef(string? name, functype type, allocvar* parameters, boolean is_varargs, block body, table labeldepths, globalvalue* globalsused)
           | functionextern(string? name, functype type)
     
globalvalue = terrafunction(definition? definition)
            | globalvariable(tree? initializer, number addressspace, boolean extern, boolean constant)
            attributes(string name, Type type, table anchor)
            
overloadedterrafunction = (string name, terrafunction* definitions)
]]
terra.irtypes = T

T.var.lvalue = true

function T.allocvar:settype(typ)
    assert(T.Type:isclassof(typ))
    self.type, self.symbol.type = typ,typ
end

-- temporary until we replace with asdl
local tokens = setmetatable({},{__index = function(self,idx) return idx end })

terra.isverbose = 0 --set by C api

local function dbprint(level,...) 
    if terra.isverbose >= level then
        print(...)
    end
end
local function dbprintraw(level,obj)
    if terra.isverbose >= level then
        terra.printraw(obj)
    end
end

--debug wrapper around cdef function to print out all the things being defined
local oldcdef = ffi.cdef
ffi.cdef = function(...)
    dbprint(2,...)
    return oldcdef(...)
end

-- TREE
function T.tree:is(value)
    return self.kind == value
end
 
function terra.printraw(self)
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
    local function printElem(t,spacing)
        if(type(t) == "table") then
            if parents[t] then
                print(string.rep(" ",#spacing).."<cyclic reference>")
                return
            elseif depth > 0 and terra.isfunction(t) then
                return --don't print the entire nested function...
            end
            parents[t] = true
            depth = depth + 1
            for k,v in pairs(t) do
                local prefix
                if type(k) == "table" and not terra.issymbol(k) then
                    prefix = ("<table (mt = %s)>"):format(tostring(getmetatable(k)))
                else
                    prefix = tostring(k)
                end
                if k ~= "kind" and k ~= "offset" then
                    prefix = spacing..prefix..": "
                    if terra.types.istype(v) then --dont print the raw form of types unless printraw was called directly on the type
                        print(prefix..tostring(v))
                    else
                        print(prefix..header(v))
                        if isList(v) then
                            printElem(v,string.rep(" ",2+#spacing))
                        else
                            printElem(v,string.rep(" ",2+#prefix))
                        end
                    end
                end
            end
            depth = depth - 1
            parents[t] = nil
        end
    end
    print(header(self))
    if type(self) == "table" then
        printElem(self,"  ")
    end
end
local prettystring --like printraw, but with syntax formatting rather than as raw lsits

local function newobject(ref,ctor,...) -- create a new object, copying the line/file info from the reference
    assert(ref.linenumber and ref.filename, "not a anchored object?")
    local r = ctor(...)
    r.linenumber,r.filename,r.offset = ref.linenumber,ref.filename,ref.offset
    return r
end

local function copyobject(ref,newfields) -- copy an object, extracting any new replacement fields from newfields table
    local class = getmetatable(ref)
    local fields = class.__fields
    assert(fields,"not a asdl object?")
    local function handlefield(i,...) -- need to do this with tail recursion rather than a loop to handle nil values
        if i == 0 then
            return newobject(ref,class,...)
        else
            local f = fields[i]
            local a = newfields[f.name] or ref[f.name]
            newfields[f.name] = nil
            return handlefield(i-1,a,...)
        end
    end
    local r = handlefield(#fields)
    for k,v in pairs(newfields) do
        error("unused field in copy: "..tostring(k))
    end
    return r
end
T.tree.copy = copyobject --support :copy directly on objects

function terra.newanchor(depth)
    local info = debug.getinfo(1 + depth,"Sl")
    local body = { linenumber = info and info.currentline or 0, filename = info and info.short_src or "unknown" }
    return setmetatable(body,terra.tree)
end

function terra.istree(v) 
    return T.tree:isclassof(v)
end

-- END TREE

local function mkstring(self,begin,sep,finish)
    return begin..table.concat(self:map(tostring),sep)..finish
end
terra.newlist = List
function terra.islist(l) return List:isclassof(l) end




-- CUSTOM TRACEBACK

local TRACEBACK_LEVELS1 = 12
local TRACEBACK_LEVELS2 = 10
local function findfirstnilstackframe() --because stack size is not exposed we binary search for it
    local low,high = 1,1
    while debug.getinfo(high,"") ~= nil do
        low,high = high,high*2
    end --invariant: low is non-nil frame, high is nil frame, range gets smaller each iteration
    while low + 1 ~= high do
        local m = math.floor((low+high)/2)
        if debug.getinfo(m,"") ~= nil then
            low = m
        else
            high = m
        end
    end
    return high - 1 --don't count ourselves
end

--all calls to user-defined functions from the compiler go through this wrapper
local function invokeuserfunction(anchor, what, speculate, userfn,  ...)
    if not speculate then
        local result = userfn(...)
        -- invokeuserfunction is recognized by a customtraceback and we need to prevent the tail call
        return result
    end
    local success,result = xpcall(userfn,debug.traceback,...)
    -- same here
    return success, result
end
terra.fulltrace = false
terra.slimtrace = false
-- override the lua traceback function to be aware of Terra compilation contexts
function debug.traceback(msg,level)
    level = level or 1
    level = level + 1 -- don't count ourselves
    local lim = terra.fulltrace and math.huge or TRACEBACK_LEVELS1 + 1
    local lines = List()
    if msg then
        local file,outsideline,insideline,rest = msg:match "^$terra$(.*)$terra$(%d+):(%d+):(.*)"
        if file then
            msg = ("%s:%d:%s"):format(file,outsideline+insideline-1,rest)
        end
        lines:insert(("%s\n"):format(msg))
    end
    lines:insert("stack traceback:")
    while true do
        local di = debug.getinfo(level,"Snlf")
        if not di then break end
        if di.func == invokeuserfunction then
            local anchorname,anchor = debug.getlocal(level,1)
            local whatname,what = debug.getlocal(level,2)
            assert(anchorname == "anchor" and whatname == "what")
            lines:insert("\n\t")
            lines:insert(formaterror(anchor,"Errors reported during "..what):sub(1,-2)) 
        else
            local short_src,currentline,linedefined = di.short_src,di.currentline,di.linedefined
            local file,outsideline = di.source:match("^@$terra$(.*)$terra$(%d+)$")
            if not terra.slimtrace or di.source:match(".*terralib%.lua$") == nil then
                if file then
                    short_src = file
                    currentline = currentline and (currentline + outsideline - 1)
                    linedefined = linedefined and (linedefined + outsideline - 1)
                end
                lines:insert(("\n\t%s:"):format(short_src))
                if di.currentline and di.currentline >= 0 then
                    lines:insert(("%d:"):format(currentline))
                end
                if di.namewhat ~= "" then
                    lines:insert((" in function '%s'"):format(di.name))
                elseif di.what == "main" then
                    lines:insert(" in main chunk")
                elseif di.what == "C" then
                    lines:insert( (" at %s"):format(tostring(di.func)))    
                else
                    lines:insert((" in function <%s:%d>"):format(short_src,linedefined))
                end
            end
        end
        level = level + 1
        if level == lim then
            if debug.getinfo(level + TRACEBACK_LEVELS2,"") ~= nil then
                lines:insert("\n\t...")
                level = findfirstnilstackframe() - TRACEBACK_LEVELS2
            end
            lim = math.huge
        end
    end
    return table.concat(lines)
end

-- GLOBALVALUE

function T.globalvalue:gettype() return self.type end
function T.globalvalue:getname() return self.name end
function T.globalvalue:setname(name) self.name = tostring(name) return self end

local function readytocompile(root)
    local visited = {}
    local function visit(gv)
        if visited[gv] or gv.readytocompile then return end
        visited[gv] = true
        if gv.kind == "terrafunction" then
            if not gv:isdefined() then
                erroratlocation(gv.anchor,"function "..gv:getname().." is not defined.")
            end
            gv.type:completefunction()
            if gv.definition.kind == "functiondef" then
                for i,g in ipairs(gv.definition.globalsused) do
                    visit(g)
                end
            end
        elseif gv.kind == "globalvariable" then
            gv.type:complete()
        else error("unknown gv:"..tostring(gv)) end
    end
    visit(root)
    -- if we succeeded, we can mark all the globals we visited ready, so they don't have to recompute this
    for g,_ in pairs(visited) do
        g.readytocompile = true
    end
end
function T.globalvalue:checkreadytocompile()
    if not self.readytocompile then
        readytocompile(self)
    end
end
function T.globalvalue:compile()
    if not self.rawjitptr then
        self.stats = self.stats or {}
        self.rawjitptr,self.stats.jit = terra.jitcompilationunit:jitvalue(self)
    end
    return self.rawjitptr
end
function T.globalvalue:getpointer()
    if not self.ffiwrapper then
        local rawptr = self:compile()
        self.ffiwrapper = ffi.cast(terra.types.pointer(self.type):cstring(),rawptr)
    end
    return self.ffiwrapper
end


-- GLOBALVAR

function terra.isglobalvar(obj)
    return T.globalvariable:isclassof(obj)
end
function T.globalvariable:init()
    self.symbol = terra.newsymbol(self.type,self.name)
end
function T.globalvariable:isextern() return self.extern end
function T.globalvariable:isconstant() return self.constant end

local typecheck
local function constantcheck(e,checklvalue)
    local kind = e.kind
    if "literal" == kind or "constant" == kind or "sizeof" == kind then -- trivially ok
    elseif "index" == kind and checklvalue then
        constantcheck(e.value,true)
        constantcheck(e.index)
    elseif "operator" == kind then
        local op = e.operator
        if "@" == op then
            constantcheck(e.operands[1])
            if not checklvalue then
                erroratlocation(e,"non-constant result of dereference used as a constant initializer")
            end
        elseif "&" == op then
            constantcheck(e.operands[1],true)
        else
            for _,ee in ipairs(e.operands) do constantcheck(ee) end
        end
    elseif "select" == kind then
        constantcheck(e.value,checklvalue)
    elseif "globalvalueref" == kind then
        if e.value.kind == "globalvariable" and not (e.value:isconstant() or checklvalue) then
            erroratlocation(e,"non-constant use of global variable used as a constant initializer")
        end
    elseif "arrayconstructor" == kind or "vectorconstructor" == kind then
        for _,ee in ipairs(e.expressions) do constantcheck(ee) end
    elseif "cast" == kind then
        if e.expression.type:isarray() then
            if checklvalue then
                constantcheck(e.expression,true)
            else 
                erroratlocation(e,"non-constant cast of array to pointer used as a constant initializer")
            end
        else constantcheck(e.expression) end
    elseif "structcast" == kind then
        constantcheck(e.expression)
    elseif "constructor" == kind then
        for _,ee in ipairs(e.expressions) do constantcheck(ee) end
    else
        erroratlocation(e,"non-constant expression being used as a constant initializer")
    end
    return e 
end

local function createglobalinitializer(anchor, typ, c)
    if not c then return nil end
    if not T.quote:isclassof(c) then
        local c_ = c
        c = newobject(anchor,T.luaexpression,function() return c_ end,true)
    end
    if typ then
        c = newobject(anchor, T.cast, typ, c)
    end
    return constantcheck(typecheck(c))
end
function terra.global(...)
    local typ = select(1,...)
    typ = terra.types.istype(typ) and typ or nil
    local c,name,isextern,isconstant,addressspace = select(typ and 2 or 1,...)
    local anchor = terra.newanchor(2)
    c = createglobalinitializer(anchor,typ,c)
    if not typ then --set type if not set
        if not c then
            error("type must be specified for globals without an initializer",2)
        end
        typ = c.type
    end
    return T.globalvariable(c,tonumber(addressspace) or 0, isextern or false, isconstant or false, name or "<global>", typ, anchor)
end
function T.globalvariable:setinitializer(init)
    if self.readytocompile then error("cannot change global variable initializer after it has been compiled.",2) end
    self.initializer = createglobalinitializer(self.anchor,self.type,init)
end
function T.globalvariable:get()
    local ptr = self:getpointer()
    return ptr[0]
end
function T.globalvariable:set(v)
    local ptr = self:getpointer()
    ptr[0] = v
end
function T.globalvariable:__tostring()
    local kind = self:isconstant() and "constant" or "global"
    local extern = self:isextern() and "extern " or ""
    local r = ("%s%s %s : %s"):format(extern,kind,self.name,tostring(self.type))
    if self.initializer then
        r = ("%s = %s"):format(r,prettystring(self.initializer,false))
    end
    return r
end
-- END GLOBALVAR

-- TARGET
local weakkeys = { __mode = "k" }
local function newweakkeytable()
    return setmetatable({},weakkeys)
end

local function cdatawithdestructor(ud,dest)
    local cd = ffi.cast("void*",ud)
    ffi.gc(cd,dest)
    return cd
end

terra.target = {}
terra.target.__index = terra.target
function terra.istarget(a) return getmetatable(a) == terra.target end
function terra.newtarget(tbl)
    if not type(tbl) == "table" then error("expected a table",2) end
    local Triple,CPU,Features,FloatABIHard = tbl.Triple,tbl.CPU,tbl.Features,tbl.FloatABIHard
    if Triple then
        CPU = CPU or ""
        Features = Features or ""
    end
    return setmetatable({ llvm_target = cdatawithdestructor(terra.inittarget(Triple,CPU,Features,FloatABIHard),terra.freetarget),
                          Triple = Triple,
                          cnametostruct = { general = {}, tagged = {}}  --map from llvm_name -> terra type used to make c structs unique per llvm_name
                        },terra.target)
end
function terra.target:getorcreatecstruct(displayname,tagged)
    local namespace
    if displayname ~= "" then
        namespace = tagged and self.cnametostruct.tagged or self.cnametostruct.general
    end
    local typ = namespace and namespace[displayname]
    if not typ then
        typ = terra.types.newstruct(displayname == "" and "anon" or displayname)
        typ.undefined = true
        if namespace then namespace[displayname] = typ end
    end
    return typ
end

local function createoptimizationprofile(profile)
    if type(profile) ~= "table" then
        error("expected optimization profile to be a table but found " .. type(profile))
    end

    -- Handle fastmath flag.
    local fastmath = profile["fastmath"]
    if fastmath == nil then
        fastmath = {}
    elseif type(fastmath) == "boolean" then
        fastmath = fastmath and {"fast"} or {}
    elseif type(fastmath) == "string" then
        fastmath = {fastmath}
    elseif type(fastmath) == "table" then
        for _, v in ipairs(fastmath) do
            if type(v) ~= "string" then
                error("expected fastmath to be a string but found " .. type(v))
            end
        end
        -- Ok, leave it alone.
    else
      error("expected fastmath to be a boolean or string but found " .. type(fastmath))
    end
    profile["fastmath"] = fastmath -- Write it back.

    return profile
end

-- COMPILATION UNIT
local compilationunit = {}
compilationunit.__index = compilationunit
function terra.newcompilationunit(target,opt,profile)
    assert(terra.istarget(target),"expected a target object")
    profile = createoptimizationprofile(profile)
    return setmetatable({ symbols = newweakkeytable(), 
                          collectfunctions = opt,
                          llvm_cu = cdatawithdestructor(terra.initcompilationunit(target.llvm_target,opt,profile),terra.freecompilationunit) },compilationunit) -- mapping from Types,Functions,Globals,Constants -> llvm value associated with them for this compilation
end
function compilationunit:addvalue(k,v)
    if type(k) ~= "string" then k,v = nil,k end
    v:checkreadytocompile()
    return terra.compilationunitaddvalue(self,k,v)
end
function compilationunit:jitvalue(v)
    local gv = self:addvalue(v)
    return terra.jit(self.llvm_cu,gv)
end
function compilationunit:free()
    assert(not self.collectfunctions, "cannot explicitly release a compilation unit with auto-delete functions")
    ffi.gc(self.llvm_cu,nil) --unregister normal destructor object
    terra.freecompilationunit(self.llvm_cu)
end
function compilationunit:dump() terra.dumpmodule(self.llvm_cu) end

terra.nativetarget = terra.newtarget {}
terra.jitcompilationunit = terra.newcompilationunit(terra.nativetarget,true,{fastmath=false}) -- compilation unit used for JIT compilation, will eventually specify the native architecture

terra.llvm_gcdebugmetatable = { __gc = function(obj)
    print("GC IS CALLED")
end }


function terra.israwlist(l)
    if terra.islist(l) then
        return true
    elseif type(l) == "table" and not getmetatable(l) then
        local sz = #l
        local i = 0
        for k,v in pairs(l) do
            i = i + 1
        end
        return i == sz --table only has integer keys and no other keys, we treat it as a list
    end
    return false
end




local identcount = 0
-- SYMBOL
function terra.issymbol(s)
    return T.Symbol:isclassof(s)
end

function terra.newsymbol(typ,displayname)
    if not terra.types.istype(typ) then error("symbol requires a Terra type but found "..terra.type(typ).." (use label() for goto labels,method names, and field names)") end
    displayname = displayname or tostring(identcount)
    local r = T.Symbol(typ,displayname,identcount)
    identcount = identcount + 1
    return r
end

function T.Symbol:__tostring()
    return "$"..self.displayname
end
function T.Symbol:tocname() return "__symbol"..tostring(self.id) end

--flag that signals that this symbol is attached to a variable that is like
--a handle to a managed variable, and should not invoke a __dtor
function T.Symbol:sethandle(v)
    if v == true then
        self.ishandle = true
    end
    return self
end

_G["symbol"] = terra.newsymbol 

-- LABEL
function terra.islabel(l) return T.Label:isclassof(l) end
function T.Label:__tostring() return "$"..self.displayname end
function terra.newlabel(displayname)
    displayname = displayname or tostring(identcount)
    local r = T.Label(displayname,identcount)
    identcount = identcount + 1
    return r
end
function T.Label:tocname() return "__label_"..tostring(self.id) end
_G["label"] = terra.newlabel

-- INTRINSIC

function terra.intrinsic(str, typ)
    local typefn
    if typ == nil and type(str) == "function" then
        typefn = str
    elseif type(str) == "string" and terra.types.istype(typ) then
        typefn = function() return str,typ end
    else
        error("expected a name and type or a function providing a name and type but found "..tostring(str) .. ", " .. tostring(typ))
    end
    local function intrinsiccall(diag,e,...)
        local args = terra.newlist {...}
        local types = args:map("gettype")
        local name,intrinsictype = typefn(types)
        if type(name) ~= "string" then
            diag:reporterror(e,"expected an intrinsic name but found ",terra.type(name))
            name = "<unknownintrinsic>"
        elseif intrinsictype == terra.types.error then
            diag:reporterror(e,"intrinsic ",name," does not support arguments: ",unpack(types))
            intrinsictype = terra.types.funcpointer(types,{})
        elseif not terra.types.istype(intrinsictype) or not intrinsictype:ispointertofunction() then
            diag:reporterror(e,"expected intrinsic to resolve to a function type but found ",terra.type(intrinsictype))
            intrinsictype = terra.types.funcpointer(types,{})
        end
        local fn = terralib.externfunction(name,intrinsictype,e)
        local fnref = newobject(e,T.luaexpression,function() return fn end,true)
        return typecheck(newobject(e,T.apply,fnref,args))
    end
    return terra.internalmacro(intrinsiccall)
end

terra.asm = terra.internalmacro(function(diag,tree,returntype, asm, constraints,volatile,...)
    local args = List{...}
    return typecheck(newobject(tree, T.inlineasm,returntype:astype(), tostring(asm:asvalue()), not not volatile:asvalue(), tostring(constraints:asvalue()), args))
end)
    

local evalluaexpression
-- CONSTRUCTORS
local function layoutstruct(st,tree,env)
    if st.tree then
        local msg = formaterror(tree,"attempting to redefine struct")..formaterror(st.tree,"previous definition was here")
        error(msg,0)
    end
    st.undefined = nil

    local function getstructentry(v) assert(v.kind == "structentry")
        local resolvedtype = evalluaexpression(env,v.type)
        if not terra.types.istype(resolvedtype) then
            erroratlocation(v,"lua expression is not a terra type but ", terra.type(resolvedtype))
        end
        return { field = v.key, type = resolvedtype }
    end
    
    local function getrecords(records)
        return records:map(function(v)
            if v.kind == "structlist" then
                return getrecords(v.entries)
            else
                return getstructentry(v)
            end
        end)
    end
    local metatype = tree.metatype and evalluaexpression(env,tree.metatype)
    st.entries = getrecords(tree.records.entries)
    st.tree = tree --to track whether the struct has already beend defined
                   --we keep the tree to improve error reporting
    st.anchor = tree --replace the anchor generated by newstruct with this struct definition
                     --this will cause errors on the type to be reported at the definition
    if metatype then
        invokeuserfunction(tree,"invoking metatype function",false,metatype,st)
    end
end
local function desugarmethoddefinition(newtree,receiver)
    local pointerto = terra.types.pointer
    local addressof = newobject(newtree,T.luaexpression,function() return pointerto(receiver) end,true)
    local sym = newobject(newtree,T.namedident,"self")
    local implicitparam = newobject(newtree,T.unevaluatedparam,sym,addressof)
    --add the implicit parameter to the parameter list
    local newparameters = List{implicitparam}
    newparameters:insertall(newtree.parameters)
    return copyobject(newtree,{ parameters = newparameters})
end

local evaluateparameterlist,evaltype

local function evalformalparameters(diag,env,tree)
    return copyobject(tree, { parameters = evaluateparameterlist(diag,env,tree.parameters,true),
                              returntype = tree.returntype and evaltype(diag,env,tree.returntype) })
end

function terra.defineobjects(fmt,envfn,...)
    local cmds = terralib.newlist()
    local nargs = 2
    for i = 1, #fmt do --collect declaration/definition commands
        local c = fmt:sub(i,i)
        local name,tree = select(2*i - 1,...)
        cmds:insert { c = c, name = name, tree = tree }
    end
    local env = setmetatable({},{__index = envfn()})
    local function paccess(name,d,t,k,v)
        local s,r = pcall(function()
            if v then t[k] = v
            else return t[k] end
        end)
        if not s then
            error("failed attempting to index field '"..k.."' in name '"..name.."' (expected a table but found "..terra.type(t)..")" ,d)
        end
        return r
    end
    local function enclosing(name)
        local t = env
        for m in name:gmatch("([^.]*)%.") do
            t = paccess(name,4,t,m)
        end
        return t,name:match("[^.]*$")
    end
    
    local decls = terralib.newlist()
    for i,c in ipairs(cmds) do --pass: declare all structs
        if "s" == c.c then
            local tbl,lastname = enclosing(c.name)
            local v = paccess(c.name,3,tbl,lastname)
            if not T.struct:isclassof(v) or v.tree then
                v = terra.types.newstruct(c.name,1)
                v.undefined = true
            end
            decls[i] = v
            paccess(c.name,3,tbl,lastname,v)
        end
    end
    local r = terralib.newlist()
    local simultaneousdefinitions,definedfunctions = {},{}
    local diag = terra.newdiagnostics()
    local function checkduplicate(tbl,name,tree)
        local fntbl = definedfunctions[tbl] or {}
        if fntbl[name] then
            diag:reporterror(tree,"duplicate definition of function")
            diag:reporterror(fntbl[name],"previous definition is here")
        end
        fntbl[name] = tree
        definedfunctions[tbl] = fntbl
    end
    for i,c in ipairs(cmds) do -- pass: declare all functions, create return list
        local tbl,lastname = enclosing(c.name)
        if "s" ~= c.c then
            if "m" == c.c then
                if not terra.types.istype(tbl) or not tbl:isstruct() then
                    erroratlocation(c.tree,"expected a struct but found ",terra.type(tbl)," when attempting to add method ",c.name)
                end
                c.tree = desugarmethoddefinition(c.tree,tbl)
                tbl = tbl.methods
            end
            local v = paccess(c.name,3,tbl,lastname)
            if c.tree.kind == "luaexpression" then -- declaration with type
                local typ = evaltype(diag,env,c.tree)
                if not typ:ispointertofunction() then
                    diag:reporterror(c.tree,"expected a function pointer but found ",typ)
                else
                    v = T.terrafunction(nil,c.name,typ.type,c.tree)
                end
            else -- definition, evaluate the parameters to try to determine its type, create a placeholder declaration if a return type is not present
                c.tree = evalformalparameters(diag,env,c.tree)
                checkduplicate(tbl,lastname,c.tree)
                if not terra.isfunction(v) or v:isdefined() then
                    local typ = terra.types.placeholderfunction
                    if c.tree.returntype then
                        typ = terra.types.functype(c.tree.parameters:map("type"),c.tree.returntype,c.tree.is_varargs)
                    end
                    v = T.terrafunction(nil,c.name,typ,c.tree)
                end
                simultaneousdefinitions[v] = c.tree
            end
            decls[i] = v
            paccess(c.name,3,tbl,lastname,v)
        end
        if lastname == c.name then
            r:insert(decls[i])
        end
    end
    diag:finishandabortiferrors("Errors reported during function declaration.",2)
    
    for i,c in ipairs(cmds) do -- pass: define structs
        if "s" == c.c and c.tree then
            layoutstruct(decls[i],c.tree,env)
        end
    end
    for i,c in ipairs(cmds) do -- pass: define functions
        local decl = decls[i]
        if "s" ~= c.c and not decl:isdefined() and c.tree.kind ~= "luaexpression" then -- may have already been defined as part of a previous call to typecheck in this loop
            simultaneousdefinitions[decl] = nil -- so that a recursive check of this fails if there is no return type
            decl:adddefinition(typecheck(c.tree,env,simultaneousdefinitions))
        end
    end
    return unpack(r)
end

function terra.anonstruct(tree,envfn)
    local st = terra.types.newstruct("anon",2)
    layoutstruct(st,tree,envfn())
    return st
end

function terra.anonfunction(tree,envfn)
    local env = envfn()
    local diag = terra.newdiagnostics()
    tree = evalformalparameters(diag,env,tree)
    diag:finishandabortiferrors("Errors during function declaration.",2)
    tree = typecheck(tree,env)
    tree.name = "anon ("..tree.filename..":"..tree.linenumber..")"
    return T.terrafunction(tree,tree.name,tree.type,tree)
end

function terra.externfunction(name,typ,anchor)
    assert(T.Type:isclassof(typ) and typ:isfunction() or typ:ispointertofunction(),"expected a pointer to a function")
    if typ:ispointertofunction() then typ = typ.type end
    anchor = anchor or terra.newanchor(2)
    return T.terrafunction(newobject(anchor,T.functionextern,name,typ),name,typ,anchor)
end

function terra.definequote(tree,envfn)
    return terra.newquote(typecheck(tree,envfn()))
end

-- END CONSTRUCTORS






-- INCLUDEC
local function includetableindex(tbl,name)    --this is called when a table returned from terra.includec doesn't contain an entry
    local v = getmetatable(tbl).errors[name]  --it is used to report why a function or type couldn't be included
    if v then
        error("includec: error importing symbol '"..name.."': "..v, 2)
    else
        error("includec: imported symbol '"..name.."' not found.",2)
    end
    return nil
end

terra.includepath = os.getenv("INCLUDE_PATH") or "."

local internalizedfiles = {}
local function fileparts(path)
    local fileseparators = ffi.os == "Windows" and "\\/" or "/"
    local pattern = "[%s]([^%s]*)"
    return path:gmatch(pattern:format(fileseparators,fileseparators))
end
function terra.registerinternalizedfiles(names,contents,sizes)
    names,contents,sizes = ffi.cast("const char **",names),ffi.cast("uint8_t **",contents),ffi.cast("int*",sizes)
    for i = 0,math.huge do
        if names[i] == nil then break end
        local name,content,size = ffi.string(names[i]),contents[i],sizes[i]
        local cur = internalizedfiles
        for segment in fileparts(name) do
            cur.children = cur.children or {}
            cur.kind = "directory"
            if not cur.children[segment] then
                cur.children[segment] = {} 
            end
            cur = cur.children[segment]
        end
        cur.contents,cur.size,cur.kind =  terra.pointertolightuserdata(content), size, "file"
    end
end

local function getinternalizedfile(path)
    local cur = internalizedfiles
    for segment in fileparts(path) do
        if cur.children and cur.children[segment] then
            cur = cur.children[segment]
        else return end
    end
    return cur
end

local clangresourcedirectory = "$CLANG_RESOURCE$"
local function headerprovider(path)
    if path:sub(1,#clangresourcedirectory) == clangresourcedirectory then
        return getinternalizedfile(path)
    end
end



function terra.includecstring(code,cargs,target)
    local args = terra.newlist {"-O3","-Wno-deprecated","-resource-dir",clangresourcedirectory}
    target = target or terra.nativetarget

    if (target == terra.nativetarget and ffi.os == "Linux") or (target.Triple and target.Triple:match("linux")) then
        args:insert("-internal-isystem")
        args:insert(clangresourcedirectory.."/include")
    end
    for _,path in ipairs(terra.systemincludes) do
    	args:insert("-internal-isystem")
    	args:insert(path)
    end
    -- Obey the SDKROOT variable on macOS to match Clang behavior.
    local sdkroot = os.getenv("SDKROOT")
    if sdkroot then
       args:insert("-isysroot")
       args:insert(sdkroot)
    end
    -- Set GNU C version to match value set by Clang: https://github.com/llvm/llvm-project/blob/f77c948d56b09b839262e258af5c6ad701e5b168/clang/lib/Driver/ToolChains/Clang.cpp#L5750-L5753
    if ffi.os ~= "Windows" and terralib.llvm_version >= 100 then
      args:insert("-fgnuc-version=4.2.1")
    end

    if cargs then
        args:insertall(cargs)
    end
    for p in terra.includepath:gmatch("([^;]+);?") do
        args:insert("-I")
        args:insert(p)
    end
    assert(terra.istarget(target),"expected a target or nil to specify the native target")
    local result = terra.registercfile(target,code,args,headerprovider)
    local general,tagged,errors,macros = result.general,result.tagged,result.errors,result.macros
    local mt = { __index = includetableindex, errors = result.errors }
    local function addtogeneral(tbl)
        for k,v in pairs(tbl) do
            if not general[k] then
                general[k] = v
            end
        end
    end
    addtogeneral(tagged)
    addtogeneral(macros)
    setmetatable(general,mt)
    setmetatable(tagged,mt)
    return general,tagged,macros
end
function terra.includec(fname,cargs,target)
    return terra.includecstring("#include \""..fname.."\"\n",cargs,target)
end


-- GLOBAL MACROS
terra.sizeof = terra.internalmacro(
function(diag,tree,typ)
    return typecheck(newobject(tree,T.sizeof,typ:astype()))
end,
function (terratype,...)
    terratype:complete()
    return terra.llvmsizeof(terra.jitcompilationunit,terratype)
end
)
_G["sizeof"] = terra.sizeof
_G["vector"] = terra.internalmacro(
function(diag,tree,...)
    if not diag then
        error("nil first argument in vector constructor")
    end
    if not tree then
        error("nil second argument in vector constructor")
    end
    return typecheck(newobject(tree,T.vectorconstructor,nil,List{...}))
end,
terra.types.vector
)
_G["vectorof"] = terra.internalmacro(function(diag,tree,typ,...)
    return typecheck(newobject(tree,T.vectorconstructor,typ:astype(),List{...}))
end)
_G["array"] = terra.internalmacro(function(diag,tree,...)
    return typecheck(newobject(tree,T.arrayconstructor,nil,List{...}))
end)
_G["arrayof"] = terra.internalmacro(function(diag,tree,typ,...)
    return typecheck(newobject(tree,T.arrayconstructor,typ:astype(),List{...}))
end)

local function createunpacks(tupleonly)
    local function unpackterra(diag,tree,obj,from,to)
        local typ = obj:gettype()
        if not obj or not typ:isstruct() or (tupleonly and typ.convertible ~= "tuple") then
            return obj
        end
        if not obj:islvalue() then diag:reporterror("expected an lvalue") end
        local result = terralib.newlist()
        local entries = typ:getentries()
        from = from and tonumber(from:asvalue()) or 1
        to = to and tonumber(to:asvalue()) or #entries
        for i = from,to do 
            local e= entries[i]
            if e.field then
                local ident = newobject(tree,type(e.field) == "string" and T.namedident or T.labelident,e.field)
                result:insert(typecheck(newobject(tree,T.selectu,obj,ident)))
            end
        end
        return result
    end
    local function unpacklua(cdata,from,to)
        local t = type(cdata) == "cdata" and terra.typeof(cdata)
        if not t or not t:isstruct() or (tupleonly and t.convertible ~= "tuple") then 
          return cdata
        end
        local results = terralib.newlist()
        local entries = t:getentries()
        for i = tonumber(from) or 1,tonumber(to) or #entries do
            local e = entries[i]
            if e.field then
                local nm = terra.islabel(e.field) and e.field:tocname() or e.field
                results:insert(cdata[nm])
            end
        end
        return unpack(results)
    end
    return unpackterra,unpacklua
end
terra.unpackstruct = terra.internalmacro(createunpacks(false))
terra.unpacktuple = terra.internalmacro(createunpacks(true))

_G["unpackstruct"] = terra.unpackstruct
_G["unpacktuple"] = terra.unpacktuple
_G["tuple"] = terra.types.tuple
_G["global"] = terra.global

terra.select = terra.internalmacro(function(diag,tree,guard,a,b)
    return typecheck(newobject(tree,T.operator,"select", List { guard, a, b }))
end)
terra.debuginfo = terra.internalmacro(function(diag,tree,filename,linenumber)
    local customfilename,customlinenumber = tostring(filename:asvalue()), tonumber(linenumber:asvalue())
    return newobject(tree,T.debuginfo,customfilename,customlinenumber):withtype(terra.types.unit)
end)

local function createattributetable(q)
    local attr = q:asvalue()
    if type(attr) ~= "table" then
        error("attributes must be a table, not a " .. type(attr))
    end
    if attr.align ~= nil and type(attr.align) ~= "number" then
        error("align attribute must be a number, not a " .. type(attr.align))
    end
    return T.attr(attr.nontemporal and true or false, 
                  attr.align or nil,
                  attr.isvolatile and true or false)
end

terra.attrload = terra.internalmacro( function(diag,tree,addr,attr)
    if not addr or not attr then
        error("attrload requires two arguments")
    end
    return typecheck(newobject(tree,T.attrload,addr,createattributetable(attr)))
end)

terra.attrstore = terra.internalmacro( function(diag,tree,addr,value,attr)
    if not addr or not value or not attr then
        error("attrstore requires three arguments")
    end
    return typecheck(newobject(tree,T.attrstore,addr,value,createattributetable(attr)))
end)

local function createfenceattributetable(q)
    local attr = q:asvalue()
    if type(attr) ~= "table" then
        error("attributes must be a table, not a " .. type(attr))
    end
    if attr.syncscope ~= nil and type(attr.syncscope) ~= "string" then
        error("syncscope attribute must be a number, not a " .. type(attr.syncscope))
    end
    if attr.ordering == nil then
        error("ordering attribute must be specified for fence operations")
    end
    if type(attr.ordering) ~= "string" then
        error("ordering attribute must be a string, not a " .. type(attr.ordering))
    end
    return T.fenceattr(
        attr.syncscope or nil,
        attr.ordering or nil)
end

terra.fence = terra.internalmacro( function(diag,tree,attr)
    if not attr then
        error("fence requires one argument")
    end
    return typecheck(newobject(tree,T.fence,createfenceattributetable(attr)))
end)

local function createcmpxchgattributetable(q)
    local attr = q:asvalue()
    if type(attr) ~= "table" then
        error("attributes must be a table, not a " .. type(attr))
    end
    if attr.syncscope ~= nil and type(attr.syncscope) ~= "string" then
        error("syncscope attribute must be a number, not a " .. type(attr.syncscope))
    end
    if attr.success_ordering == nil then
        error("success_ordering attribute must be specified for cmpxchg operations")
    end
    if type(attr.success_ordering) ~= "string" then
        error("success_ordering attribute must be a string, not a " .. type(attr.success_ordering))
    end
    if attr.failure_ordering == nil then
        error("failure_ordering attribute must be specified for cmpxchg operations")
    end
    if type(attr.failure_ordering) ~= "string" then
        error("failure_ordering attribute must be a string, not a " .. type(attr.failure_ordering))
    end
    if attr.align ~= nil and type(attr.align) ~= "number" then
        error("align attribute must be a number, not a " .. type(attr.align))
    end
    return T.cmpxchgattr(
        attr.syncscope or nil,
        attr.success_ordering or nil,
        attr.failure_ordering or nil,
        attr.align or nil,
        attr.isvolatile and true or false,
        attr.isweak and true or false)
end

terra.cmpxchg = terra.internalmacro( function(diag,tree,addr,cmp,new,attr)
    if not addr or not cmp or not new or not attr then
        error("cmpxchg requires four arguments")
    end
    return typecheck(newobject(tree,T.cmpxchg,addr,cmp,new,createcmpxchgattributetable(attr)))
end)

local function createatomicattributetable(q)
    local attr = q:asvalue()
    if type(attr) ~= "table" then
        error("attributes must be a table, not a " .. type(attr))
    end
    if attr.syncscope ~= nil and type(attr.syncscope) ~= "string" then
        error("syncscope attribute must be a number, not a " .. type(attr.syncscope))
    end
    if attr.ordering == nil then
        error("ordering attribute must be specified for atomic operations")
    end
    if type(attr.ordering) ~= "string" then
        error("ordering attribute must be a string, not a " .. type(attr.ordering))
    end
    if attr.align ~= nil and type(attr.align) ~= "number" then
        error("align attribute must be a number, not a " .. type(attr.align))
    end
    return T.atomicattr(
        attr.syncscope or nil,
        attr.ordering or nil,
        attr.align or nil,
        attr.isvolatile and true or false)
end

terra.atomicrmw = terra.internalmacro( function(diag,tree,op,addr,value,attr)
    if not op or not addr or not value or not attr then
        error("atomicrmw requires four arguments")
    end
    local op_value = op:asvalue()
    if type(op_value) ~= "string" then
      error("operator argument to atomicrmw must be a string, not a " .. type(op_value))
    end
    return typecheck(newobject(tree,T.atomicrmw,op_value,addr,value,createatomicattributetable(attr)))
end)

-- END GLOBAL MACROS

-- DEBUG

function prettystring(toptree,breaklines)
    breaklines = breaklines == nil or breaklines
    local buffer = terralib.newlist() -- list of strings that concat together into the pretty output
    local env = terra.newenvironment({})
    local indentstack = terralib.newlist{ 0 } -- the depth of each indent level
    
    local currentlinelength = 0
    local function enterblock()
        indentstack:insert(indentstack[#indentstack] + 4)
    end
    local function enterindenttocurrentline()
        indentstack:insert(currentlinelength)
    end
    local function leaveblock()
        indentstack:remove()
    end
    local function emit(fmt,...)
        local function toformat(x)
            if type(x) ~= "number" and type(x) ~= "string" then
                return tostring(x) 
            else
                return x
            end
        end
        local strs = terra.newlist({...}):map(toformat)
        local r = fmt:format(unpack(strs))
        currentlinelength = currentlinelength + #r
        buffer:insert(r)
    end
    local function pad(str,len)
        if #str > len then return str:sub(-len)
        else return str..(" "):rep(len - #str) end
    end
    local function differentlocation(a,b)
        return (a.linenumber ~= b.linenumber or a.filename ~= b.filename)
    end 
    local lastanchor = { linenumber = "", filename = "" }
    local function begin(anchor,...)
        local fname = differentlocation(lastanchor,anchor) and (anchor.filename..":"..anchor.linenumber..": ")
                                                           or ""
        emit("%s",pad(fname,24))
        currentlinelength = 0
        emit((" "):rep(indentstack[#indentstack]))
        emit(...)
        lastanchor = anchor
    end

    local function emitList(lst,begin,sep,finish,fn)
        emit(begin)
        for i,k in ipairs(lst) do
            fn(k,i)
            if i ~= #lst then
                emit(sep)
            end
        end
        emit(finish)
    end

    local function emitType(t)
        emit("%s",t)
    end

    local function UniqueName(name,key)
        assert(name) assert(key)
        local lenv = env:localenv()
        local assignedname = lenv[key]
        --if we haven't seen this key in this scope yet, assign a name for this key, favoring the non-mangled name
        if not assignedname then
            local basename,i = name,1
            while lenv[name] do
                name,i = basename.."$"..tostring(i),i+1
            end
            lenv[name],lenv[key],assignedname = true,name,name
        end
        return assignedname
    end
    local function emitIdent(name,sym)
        assert(name) assert(terra.issymbol(sym))
        emit("%s",UniqueName(name,sym))
    end
    local luaexpression = "[ <lua exp> ]"
    local function IdentToString(ident)
        if ident.kind == "luaexpression" then return luaexpression
        else return tostring(ident.value) end
    end
    local function emitParam(p)
        assert(T.allocvar:isclassof(p) or T.param:isclassof(p))
        if T.unevaluatedparam:isclassof(p) then 
            emit("%s%s",IdentToString(p.name),p.type and " : "..luaexpression or "")
        else
            emitIdent(p.name,p.symbol) 
            if p.type then emit(" : %s",p.type) end
        end
    end
    local implicitblock = { repeatstat = true, fornum = true, fornumu = true}
    local emitStmt, emitExp,emitParamList,emitLetIn
    local function emitStmtList(lst) --nested Blocks (e.g. from quotes need "do" appended)
        for i,ss in ipairs(lst) do
            if ss:is "block" and not (#ss.statements == 1 and implicitblock[ss.statements[1].kind]) then
                begin(ss,"do\n")
                emitStmt(ss)
                begin(ss,"end\n")
            else
                emitStmt(ss)
            end
        end
    end
    local function emitAttr(a)
        emit("{ nontemporal = %s, align = %s, isvolatile = %s }",a.nontemporal,a.alignment or "native",a.isvolatile)
    end
    local function emitFenceAttr(a)
        emit('{ syncscope = "%s", ordering = "%s" }',a.syncscope or "",a.ordering)
    end
    local function emitCmpxchgAttr(a)
        emit('{ syncscope = "%s", success_ordering = "%s", failure_ordering = "%s", align = %s, isvolatile = %s, isweak = %s }',a.syncscope or "",a.success_ordering,a.failure_ordering,a.alignment or "native",a.isvolatile,a.isweak)
    end
    local function emitAtomicAttr(a)
        emit('{ syncscope = "%s", ordering = "%s", align = %s, isvolatile = %s }',a.syncscope or "",a.ordering,a.alignment or "native",a.isvolatile)
    end
    function emitStmt(s)
        if s:is "block" then
            enterblock()
            env:enterblock()
            emitStmtList(s.statements)
            env:leaveblock()
            leaveblock()
        elseif s:is "returnstat" then
            begin(s,"return ")
            emitExp(s.expression)
            emit("\n")
        elseif s:is "label" then
            begin(s,"::%s::\n",IdentToString(s.label))
        elseif s:is "gotostat" then
            begin(s,"goto %s\n",IdentToString(s.label))
        elseif s:is "breakstat" then
            begin(s,"break\n")
        elseif s:is "whilestat" then
            begin(s,"while ")
            emitExp(s.condition)
            emit(" do\n")
            emitStmt(s.body)
            begin(s,"end\n")
        elseif s:is "repeatstat" then
            begin(s,"repeat\n")
            enterblock()
            emitStmtList(s.statements)
            leaveblock()
            begin(s.condition,"until ")
            emitExp(s.condition)
            emit("\n")
        elseif s:is "fornum"or s:is "fornumu" then
            begin(s,"for ")
            emitParam(s.variable)
            emit(" = ")
            emitExp(s.initial) emit(",") emitExp(s.limit) 
            if s.step then emit(",") emitExp(s.step) end
            emit(" do\n")
            emitStmt(s.body)
            begin(s,"end\n")
        elseif s:is "forlist" then
            begin(s,"for ")
            emitList(s.variables,"",", ","",emitParam)
            emit(" in ")
            emitExp(s.iterator)
            emit(" do\n")
            emitStmt(s.body)
            begin(s,"end\n")
        elseif s:is "ifstat" then
            for i,b in ipairs(s.branches) do
                if i == 1 then
                    begin(b,"if ")
                else
                    begin(b,"elseif ")
                end
                emitExp(b.condition)
                emit(" then\n")
                emitStmt(b.body)
            end
            if s.orelse then
                begin(s.orelse,"else\n")
                emitStmt(s.orelse)
            end
            begin(s,"end\n")
        elseif s:is "switchstat" then
            begin(s, "switch ")
            emitExp(s.condition)
            emit(" do\n")
            for i,b in ipairs(s.cases) do
                begin(b,"case ")
                emitExp(b.condition)
                emit(" then\n")
                emitStmt(b.body)
            end
            if s.ordefault then
                begin(s.ordefault,"else \n")
                emitStmt(s.ordefault)
            end
            begin(s,"end\n")
        elseif s:is "defvar" then
            begin(s,"var ")
            emitList(s.variables,"",", ","",emitParam)
            if s.hasinit then
                emit(" = ")
                emitParamList(s.initializers)
            end
            emit("\n")
        elseif s:is "assignment" then
            begin(s,"")
            emitParamList(s.lhs)
            emit(" = ")
            emitParamList(s.rhs)
            emit("\n")
        elseif s:is "defer" then
            begin(s,"defer ")
            emitExp(s.expression)
            emit("\n")
        elseif s:is "statlist" then
            emitStmtList(s.statements)
        else
            begin(s,"")
            emitExp(s)
            emit("\n")
        end
    end
    
    local function makeprectable(...)
        local lst = {...}
        local sz = #lst
        local tbl = {}
        for i = 1,#lst,2 do
            tbl[lst[i]] = lst[i+1]
        end
        return tbl
    end

    local prectable = makeprectable(
     "+",7,"-",7,"*",8,"/",8,"%",8,
     "^",11,"..",6,"<<",4,">>",4,
     "==",3,"<",3,"<=",3,
     "~=",3,">",3,">=",3,
     "and",2,"or",1,
     "@",9,"&",9,"not",9,"select",12)
    
    local function getprec(e)
        if e:is "operator" then
            if "-" == e.operator and #e.operands == 1 then return 9 --unary minus case
            else return prectable[e.operator] end
        else
            return 12
        end
    end
    local function doparens(ref,e,isrhs)
        local pr, pe = getprec(ref), getprec(e)
        if pr > pe or (isrhs and pr == pe) then
            emit("(")
            emitExp(e)
            emit(")")
        else
            emitExp(e)
        end
    end

    function emitExp(e,maybeastatement)
        if breaklines and differentlocation(lastanchor,e)then
            local ll = currentlinelength
            emit("\n")
            begin(e,"")
            emit((" "):rep(ll - currentlinelength))
            lastanchor = e
        end
        if e:is "var" then
            if e.symbol then emitIdent(e.name,e.symbol)
            else emit("%s",e.name) end
        elseif e:is "globalvalueref" and e.value.kind == "globalvariable" then
            emitIdent(e.name,e.value.symbol)
        elseif e:is "globalvalueref" and e.value.kind == "terrafunction" then
            emit(e.value.name)
        elseif e:is "allocvar" then
            emit("var ")
            emitParam(e)
        elseif e:is "setter" then
            emit("<setter:") emitExp(e.setter) emit(">")
        elseif e:is "setteru" then emit("<setteru>")
        elseif e:is "operator" then
            local op = e.operator
            local function emitOperand(o,isrhs)
                doparens(e,o,isrhs)
            end
            if #e.operands == 1 then
                emit(op)
                emitOperand(e.operands[1])
            elseif #e.operands == 2 then
                emitOperand(e.operands[1])
                emit(" %s ",op)
                emitOperand(e.operands[2],true)
            elseif op == "select" then
                emit("terralib.select")
                emitList(e.operands,"(",", ",")",emitExp)
            else
                emit("<??operator:"..op.."??>")
            end
        elseif e:is "index" then
            doparens(e,e.value)
            emit("[")
            emitExp(e.index)
            emit("]")
        elseif e:is "literal" then
            if e.type:isintegral() then
                emit(e.stringvalue or "<int>")
            elseif type(e.value) == "string" then
                emit("%s",("%q"):format(e.value):gsub("\\\n","\\n"))
            else
                emit("%s",tostring(e.value))
            end
        elseif e:is "cast" or e:is "structcast" then
            emit("[")
            emitType(e.to or e.type)
            emit("](")
            emitExp(e.expression)
            emit(")")
        elseif e:is "sizeof" then
            emit("sizeof(%s)",e.oftype)
        elseif e:is "apply" then
            doparens(e,e.value)
            emit("(")
            emitParamList(e.arguments)
            emit(")")
        elseif e:is "selectu" or e:is "select" then
            doparens(e,e.value)
            emit(".")
            emit("%s",e.fieldname or IdentToString(e.field))
        elseif e:is "vectorconstructor" then
            emit("vector(")
            emitParamList(e.expressions)
            emit(")")
        elseif e:is "arrayconstructor" then
            emit("array(")
            emitParamList(e.expressions)
            emit(")")
        elseif e:is "constructor" then
            local success,keys = pcall(function() return e.type:getlayout().entries:map(function(e) return tostring(e.key) end) end)
            if not success then emit("<layouttypeerror> = ") 
            else emitList(keys,"",", "," = ",emit) end
            emitParamList(e.expressions)
        elseif e:is "constructoru" then
            emit("{")
            local function emitField(r)
                if r.type == "recfield" then
                    emit("%s = ",IdentToString(r.key))
                end
                emitExp(r.value)
            end
            emitList(e.records,"",", ","",emitField)
            emit("}")
        elseif e:is "constant" then
            if e.type:isprimitive() then
                emit("%s",tostring(tonumber(e.value)))
            else
                emit("<constant:"..tostring(e.type)..">")
            end
        elseif e:is "letin" then
            emitLetIn(e)
        elseif e:is "attrload" then
            emit("attrload(")
            emitExp(e.address)
            emit(", ")
            emitAttr(e.attrs)
            emit(")")
        elseif e:is "attrstore" then
            emit("attrstore(")
            emitExp(e.address)
            emit(", ")
            emitExp(e.value)
            emit(", ")
            emitAttr(e.attrs)
            emit(")")
        elseif e:is "fence" then
            emit("fence(")
            emitFenceAttr(e.attrs)
            emit(")")
        elseif e:is "cmpxchg" then
            emit("cmpxchg(")
            emitExp(e.address)
            emit(", ")
            emitExp(e.cmp)
            emit(", ")
            emitExp(e.new)
            emit(", ")
            emitCmpxchgAttr(e.attrs)
            emit(")")
        elseif e:is "atomicrmw" then
            emit("atomicrmw(")
            emit('"' .. e.operator .. '"')
            emit(", ")
            emitExp(e.address)
            emit(", ")
            emitExp(e.value)
            emit(", ")
            emitAtomicAttr(e.attrs)
            emit(")")
        elseif e:is "luaobject" then
            if terra.types.istype(e.value) then
                emit("[%s]",e.value)
            elseif terra.ismacro(e.value) then
                emit("<macro>")
            elseif terra.isoverloadedfunction(e.value) then
                emit("%s",e.name)
            else
                emit("<lua value: %s>",tostring(e.value))
            end
        elseif e:is "method" then
             doparens(e,e.value)
             emit(":%s",IdentToString(e.name))
             emit("(")
             emitParamList(e.arguments)
             emit(")")
        elseif e:is "debuginfo" then
            emit("debuginfo(%q,%d)",e.customfilename,e.customlinenumber)
        elseif e:is "inlineasm" then
            emit("inlineasm(")
            emitType(e.type)
            emit(",%s,%s,%s,",e.asm,tostring(e.volatile),e.constraints)
            emitParamList(e.arguments)
            emit(")")
        elseif e:is "quote" then
            emitExp(e.tree)
        elseif e:is "luaexpression" then return luaexpression
        elseif maybeastatement then
            emitStmt(e)
        else
            emit("<??"..e.kind.."??>")
            error("??"..tostring(e.kind))
        end
    end
    function emitParamList(pl)
        emitList(pl,"",", ","",emitExp)
    end
    function emitLetIn(pl)
        if pl.hasstatements then
            enterindenttocurrentline()
            emit("let\n")
            enterblock()
            emitStmtList(pl.statements)
            leaveblock()
            begin(pl,"in\n")
            enterblock()
            begin(pl,"")
        end
        emitList(pl.expressions,"",", ","",emitExp)
        if pl.hasstatements then
            leaveblock()
            emit("\n")
            begin(pl,"end")
            leaveblock()
        end
    end
    if T.functiondef:isclassof(toptree) or T.functiondefu:isclassof(toptree) then
        begin(toptree,"terra %s",toptree.name or "<anon>")
        emitList(toptree.parameters,"(",",",") ",emitParam)
        if T.functiondef:isclassof(toptree) then
            emit(": ") emitType(toptree.type.returntype)
        elseif toptree.returntype then
            emit(": ")
            if T.Type:isclassof(toptree.returntype) then emitType(toptree.returntype)
            else emitExp(toptree.returntype) end
        end
        emit("\n")
        emitStmt(toptree.body)
        begin(toptree,"end\n")
    elseif T.functionextern:isclassof(toptree) then
        begin(toptree,"terra %s :: %s = <extern>\n",toptree.name,toptree.type)
    else
        emitExp(toptree,true)
        emit("\n")
    end
    return buffer:concat()
end

function T.terrafunction:prettystring(breaklines)
    if not self:isdefined() then
        return ("terra %s :: %s\n"):format(self.name,tostring(self.type))
    end
    return prettystring(self.definition,breaklines)
end
function T.terrafunction:printpretty(bl) io.write(self:prettystring(bl)) end
function T.terrafunction:__tostring() return self:prettystring(false) end
function T.quote:prettystring(breaklines) return prettystring(self.tree,breaklines) end
function T.quote:printpretty(bl) io.write(self:prettystring(bl)) end
function T.quote:__tostring() return self:prettystring(false) end

-- END DEBUG

local allowedfilekinds = { object = true, executable = true, bitcode = true, llvmir = true, sharedlibrary = true, asm = true }
local mustbefile = { sharedlibrary = true, executable = true }
function compilationunit:saveobj(filename,filekind,arguments,optimize)
    if filekind ~= nil and type(filekind) ~= "string" then
        --filekind is missing, shift arguments to the right
        filekind,arguments,optimize = nil,filekind,arguments
    end

    if optimize == nil then
        optimize = true
    end

    if filekind == nil and filename ~= nil then
        --infer filekind from string
        if filename:match("%.o$") then
            filekind = "object"
        elseif filename:match("%.bc$") then
            filekind = "bitcode"
        elseif filename:match("%.ll$") then
            filekind = "llvmir"
        elseif filename:match("%.so$") or filename:match("%.dylib$") or filename:match("%.dll$") then
            filekind = "sharedlibrary"
        elseif filename:match("%.s") then
            filekind = "asm"
        else
            filekind = "executable"
        end
    end
    if not allowedfilekinds[filekind] then
        error("unknown output format type: " .. tostring(filekind))
    end
    if filename == nil and mustbefile[filekind] then
        error(filekind .. " must be written to a file")
    end
    return terra.saveobjimpl(filename,filekind,self,arguments or {},optimize)
end

function terra.saveobj(filename,filekind,env,arguments,target,optimize)
    if type(filekind) ~= "string" then
        filekind,env,arguments,target,optimize = nil,filekind,env,arguments,target
    end
    local profile
    if optimize == nil or type(optimize) == "boolean" then
      profile = {}
    elseif type(optimize) == "table" then
      profile = optimize
      optimize = optimize["optimize"]
    else
      error("expected optimize to be a boolean or table but found " .. type(optimize))
    end

    local cu = terra.newcompilationunit(target or terra.nativetarget,false,profile)
    for k,v in pairs(env) do
        if not T.globalvalue:isclassof(v) then error("expected terra global or function but found "..terra.type(v)) end
        cu:addvalue(k,v)
    end
    local r = cu:saveobj(filename,filekind,arguments,optimize)
    cu:free()
    return r
end


-- configure path variables
if ffi.os == "Windows" then
  terra.cudahome = os.getenv("CUDA_PATH")
else
  terra.cudahome = os.getenv("CUDA_HOME") or "/usr/local/cuda"
end
terra.cudalibpaths = ({ OSX = {driver = "/usr/local/cuda/lib/libcuda.dylib", runtime = "$CUDA_HOME/lib/libcudart.dylib", nvvm =  "$CUDA_HOME/nvvm/lib/libnvvm.dylib"}; 
                       Linux =  {driver = "libcuda.so", runtime = "$CUDA_HOME/lib64/libcudart.so", nvvm = "$CUDA_HOME/nvvm/lib64/libnvvm.so"}; 
                       Windows = {driver = "nvcuda.dll", runtime = "$CUDA_HOME\\bin\\cudart64_*.dll", nvvm = "$CUDA_HOME\\nvvm\\bin\\nvvm64_*.dll"}; })[ffi.os]
-- OS's that are not supported by CUDA will have an undefined value here
if terra.cudalibpaths and terra.cudahome then
	for name,path in pairs(terra.cudalibpaths) do
		path = path:gsub("%$CUDA_HOME",terra.cudahome)
		if path:match("%*") and ffi.os == "Windows" then
			local F = io.popen(('dir /b /s "%s" 2> nul'):format(path))
			if F then
				path = F:read("*line") or path
				F:close()
			end
		end
		terra.cudalibpaths[name] = path
	end
end                       

local cudatarget
function terra.getcudatarget()
    if cudatarget == nil then
        cudatarget = terra.newtarget {Triple = 'nvptx64-nvidia-cuda', FloatABIHard = true}
    end
    return cudatarget
end


terra.systemincludes = List()
if ffi.os == "Windows" then
    if os.getenv("VCINSTALLDIR") ~= nil then -- If terra is being run inside the developer console, use those environment variables instead
        terra.vshome = os.getenv("VCToolsInstallDir")
        if not terra.vshome then
            terra.vshome = os.getenv("VCINSTALLDIR")
            terra.vclinker = terra.vshome..[[BIN\x86_amd64\link.exe]]
        else
            terra.vclinker = ([[%sbin\Host%s\%s\link.exe]]):format(terra.vshome, os.getenv("VSCMD_ARG_HOST_ARCH"), os.getenv("VSCMD_ARG_TGT_ARCH"))
        end
        terra.includepath = os.getenv("INCLUDE")
      
        function terra.getvclinker(target)
          local vclib = os.getenv("LIB")
          local vcpath = terra.vcpath or os.getenv("Path")
          vclib,vcpath = "LIB="..vclib,"Path="..vcpath
          return terra.vclinker,vclib,vcpath
        end
    else
        local function compareversion(form, a, b)
          if (a == nil) or (b == nil) then return true end
          
          local alist = {}
          for e in string.gmatch(a, form) do table.insert(alist, tonumber(e)) end
          local blist = {}
          for e in string.gmatch(b, form) do table.insert(blist, tonumber(e)) end
          
          for i=1,#alist do
            if alist[i] ~= blist[i] then
              return alist[i] > blist[i]
            end
          end
          return false
        end
        
        -- First find the latest Windows SDK installed using the registry
        local installedroots = [[SOFTWARE\Microsoft\Windows Kits\Installed Roots]]
        local windowsdk = terra.queryregvalue(installedroots, "KitsRoot10")
        if windowsdk == nil then
          windowsdk = terra.queryregvalue(installedroots, "KitsRoot81")
          if windowsdk == nil then
            error "Can't find windows SDK version 8.1 or 10! Try running Terra in a Native Tools Developer Console instead."
          end
          
          local version = nil
          for i, v in ipairs(terra.listsubdirectories(windowsdk .. "lib")) do
            if compareversion("%d+", v, version) then
              version = v
            end
          end
          if version == nil then
            error "Can't find valid version subdirectory in the SDK! Is the Windows 8.1 SDK installation corrupt?"
          end
          
          terra.sdklib = windowsdk .. "lib\\" .. version
        else
          -- Find highest version. For sanity reasons, we assume the same version folders are in both lib/ and include/
          local version = nil
          for i, v in ipairs(terra.listsubdirectories(windowsdk .. "include")) do
            if compareversion("%d+", v, version) then
              version = v
            end
          end
          if version == nil then
            error "Can't find valid version subdirectory in the SDK! Is the SDK installation corrupt?"
          end
          
          terra.sdklib = windowsdk .. "lib\\" .. version
        end
        
        terra.vshome = terra.findvisualstudiotoolchain()
        if terra.vshome == nil then          
          terra.vshome = terra.queryregvalue([[SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0]], "ShellFolder") or
            terra.queryregvalue([[SOFTWARE\WOW6432Node\Microsoft\VisualStudio\12.0]], "ShellFolder") or
            terra.queryregvalue([[SOFTWARE\WOW6432Node\Microsoft\VisualStudio\11.0]], "ShellFolder") or
            terra.queryregvalue([[SOFTWARE\WOW6432Node\Microsoft\VisualStudio\10.0]], "ShellFolder")
            
          if terra.vshome == nil then
            error "Can't find Visual Studio either via COM or the registry! Try running Terra in a Native Tools Developer Console instead."
          end
          terra.vshome = terra.vshome .. "VC\\"
          terra.vsarch64 = "amd64" -- Before 2017, Visual Studio had it's own special architecture convention, because who needs standards
          terra.vslinkpath = function(host, target)
            if string.lower(host) == string.lower(target) then
              return ([[BIN\%s\]]):format(host)
            else
              return ([[BIN\%s_%s\]]):format(host, target)
            end
          end
        else
          if terra.vshome[#terra.vshome] ~= '\\' then
            terra.vshome = terra.vshome .. "\\"
          end
          terra.vsarch64 = "x64"
          terra.vslinkpath = function(host, target) return ([[bin\Host%s\%s\]]):format(host, target) end
        end
        
        function terra.getvclinker(target) --get the linker, and guess the needed environment variables for Windows if they are not set ...
            target = target or "x86_64"
            local winarch = target
            if target == "x86_64" then
              target = terra.vsarch64
              winarch = "x64" -- Unbelievably, Visual Studio didn't follow the Windows SDK convention until 2017+
            elseif target == "aarch64" or target == "aarch64_be" then
              target = "arm64"
              winarch = "arm64"
            end
            
            local host = ffi.arch
            if host == "x64" then
              host = terra.vsarch64
            end
            
            local linker = terra.vshome..terra.vslinkpath(host, target).."link.exe"
            local vclib = ([[%s\um\%s;%s\ucrt\%s;]]):format(terra.sdklib, winarch, terra.sdklib, winarch) .. ([[%sLIB\%s;%sATLMFC\LIB\%s;]]):format(terra.vshome, target, terra.vshome, target)
            local vcpath = terra.vcpath or (os.getenv("Path") or "")..";"..terra.vshome..[[BIN;]]..terra.vshome..terra.vslinkpath(host, host)..";" -- deals with VS2017 cross-compile nonsense: https://github.com/rust-lang/rust/issues/31063
            vclib,vcpath = "LIB="..vclib,"Path="..vcpath
            return linker,vclib,vcpath
        end
    end
    if terra.cudahome then
        terra.systemincludes:insertall{terra.cudahome.."\\include"}
    end
end


-- path to terra install, normally this is figured out based on the location of Terra shared library or binary
local defaultterrahome = ffi.os == "Windows" and "C:\\Program Files\\terra" or "/usr/local"
terra.terrahome = os.getenv("TERRA_HOME") or terra.terrahome or defaultterrahome
local terradefaultpath =  ffi.os == "Windows" and ";.\\?.t;"..terra.terrahome.."\\include\\?.t;"
                          or ";./?.t;"..terra.terrahome.."/share/terra/?.t;"

package.terrapath = (os.getenv("TERRA_PATH") or ";;"):gsub(";;",terradefaultpath)

local function terraloader(name)
    local fname = name:gsub("%.","/")
    local file = nil
    local loaderr = ""
    for template in package.terrapath:gmatch("([^;]+);?") do
        local fpath = template:gsub("%?",fname)
        local handle = io.open(fpath,"r")
        if handle then
            file = fpath
            handle:close()
            break
        end
        loaderr = loaderr .. "\n\tno file '"..fpath.."'"
    end
    local function check(fn,err) return fn or error(string.format("error loading terra module %s from file %s:\n\t%s",name,file,err)) end
    if file then return check(terra.loadfile(file)) end
    -- if we didn't find the file on the real file system, see if it is included in the binary itself
    file = ("/?.t"):gsub("%?",fname)
    local internal = getinternalizedfile(file)
    if internal and internal.kind == "file" then
        local str,done = ffi.string(ffi.cast("const char *",internal.contents)),false
        local fn,err = terra.load(function()
            if not done then
                done = true
                return str
            end
        end,file)
        return check(fn,err)
    else
        loaderr = loaderr .. "\n\tno internal file '"..file.."'"
    end
    return loaderr
end
table.insert(package.loaders,terraloader)

function terra.makeenv(env,defined,g)
    local mt = { __index = function(self,idx)
        if defined[idx] then return nil -- local variable was defined and was nil, the search ends here
        elseif getmetatable(g) == Strict then return rawget(g,idx) else return g[idx] end
    end }
    return setmetatable(env,mt)
end

function terra.new(terratype,...)
    terratype:complete()
    local typ = terratype:cstring()
    return ffi.new(typ,...)
end
function terra.offsetof(terratype,field)
    terratype:complete()
    local typ = terratype:cstring()
    if terra.islabel(field) then
        field = field:tocname()
    end
    return ffi.offsetof(typ,field)
end

function terra.cast(terratype,obj)
    terratype:complete()
    local ctyp = terratype:cstring()
    return ffi.cast(ctyp,obj)
end

function terra.constant(typ,init)
    if typ ~= nil and not terra.types.istype(typ) then -- if typ is not a typ, shift arguments
        typ,init = nil,typ
    end
    if typ == nil then --try to infer the type, and if successful build the constant
        if type(init) == "cdata" then
            typ = terra.typeof(init)
        elseif type(init) == "number" then
            typ = (terra.isintegral(init) and terra.types.int) or terra.types.double
        elseif type(init) == "boolean" then
            typ = terra.types.bool
        elseif type(init) == "string" then
            typ = terra.types.rawstring
        elseif T.quote:isclassof(init) then
            typ = init:gettype()
        else
            error("constant constructor requires explicit type for objects of type "..terra.type(init))
        end
    end
    if init == nil or T.quote:isclassof(init) then -- cases: no init, quote init -> global constant
        return terra.global(typ,init,"<constant>",false,true)
    end
    local anchor = terra.newanchor(2)
    if type(init) == "string" and typ == terra.types.rawstring then
        return terra.newquote(newobject(anchor,T.literal,init,typ))
    end
    local orig = init -- hold anchor until we capture the value
    if type(init) ~= "cdata" or terra.typeof(init) ~= typ then
        init = terra.cast(typ,init)
    end
    if not typ:isaggregate() then
        return terra.newquote(newobject(anchor,T.constant,init,typ))
    end -- otherwise this is an aggregate pack it into a string literal
    local str,ptyp = ffi.string(init,terra.sizeof(typ)),terra.types.pointer(typ)
    local tree = newobject(anchor,T.literal,str,terra.types.rawstring) -- "literal"
    tree = newobject(anchor,T.cast,ptyp,tree):withtype(ptyp) -- [&typ](literal)
    tree = newobject(anchor,T.operator,"@", List { tree }):withtype(typ):setlvalue(true) -- @[&typ](literal)
    return terra.newquote(tree)
end
function terra.isconstant(obj)
    if T.globalvariable:isclassof(obj) then return obj:isconstant()
    elseif T.quote:isclassof(obj) then return obj.tree.kind == "literal" or obj.tree.kind == "constant"
    else return false end
end
_G["constant"] = terra.constant

-- equivalent to ffi.typeof, takes a cdata object and returns associated terra type object
function terra.typeof(obj)
    if type(obj) ~= "cdata" then
        error("cannot get the type of a non cdata object")
    end
    return terra.types.ctypetoterra[tonumber(ffi.typeof(obj))]
end

--equivalent to Lua's type function, but knows about concepts in Terra to improve error reporting
function terra.type(t)
    if terra.isfunction(t) then return "terrafunction"
    elseif terra.types.istype(t) then return "terratype"
    elseif terra.ismacro(t) then return "terramacro"
    elseif terra.isglobalvar(t) then return "terraglobalvariable"
    elseif terra.isquote(t) then return "terraquote"
    elseif terra.istree(t) then return "terratree"
    elseif terra.islist(t) then return "list"
    elseif terra.issymbol(t) then return "terrasymbol"
    elseif terra.isfunction(t) then return "terrafunction"
    elseif terra.islabel(t) then return "terralabel"
    elseif terra.isoverloadedfunction(t) then return "overloadedterrafunction"
    else return type(t) end
end

function terra.linklibrary(filename)
    assert(not filename:match("%.bc$"), "linklibrary no longer supports llvm bitcode, use terralib.linkllvm instead.")
    terra.linklibraryimpl(filename)
end
function terra.linkllvm(filename,target,fromstring)
    target = target or terra.nativetarget
    assert(terra.istarget(target),"expected a target or nil to specify native target")
    terra.linkllvmimpl(target.llvm_target,filename, fromstring)
    return { extern = function(self,name,typ) return terra.externfunction(name,typ) end }
end
function terra.linkllvmstring(str,target) return terra.linkllvm(str,target,true) end

terra.languageextension = {
    tokentype = {}; --metatable for tokentype objects
    tokenkindtotoken = {}; --map from token's kind id (terra.kind.name), to the singleton table (terra.languageextension.name) 
}

function terra.importlanguage(languages,entrypoints,langstring)
    local success,lang = xpcall(function() return require(langstring) end,function(err) return debug.traceback(err,2) end)
    if not success then error(lang,0) end
    if not lang or type(lang) ~= "table" then error("expected a table to define language") end
    lang.name = lang.name or "anonymous"
    local function haslist(field,typ)
        if not lang[field] then 
            error(field .. " expected to be list of "..typ)
        end
        for i,k in ipairs(lang[field]) do
            if type(k) ~= typ then
                error(field .. " expected to be list of "..typ.." but found "..type(k))
            end
        end
    end
    haslist("keywords","string")
    haslist("entrypoints","string")
    
    for i,e in ipairs(lang.entrypoints) do
        if entrypoints[e] then
            error(("language '%s' uses entrypoint '%s' already defined by language '%s'"):format(lang.name,e,entrypoints[e].name),-1)
        end
        entrypoints[e] = lang
    end
    if not lang.keywordtable then
        lang.keywordtable = {} --keyword => true
        for i,k in ipairs(lang.keywords) do
            lang.keywordtable[k] = true
        end
        for i,k in ipairs(lang.entrypoints) do
            lang.keywordtable[k] = true
        end
    end
    table.insert(languages,lang)
end
function terra.unimportlanguages(languages,N,entrypoints)
    for i = 1,N do
        local lang = table.remove(languages)
        for i,e in ipairs(lang.entrypoints) do
            entrypoints[e] = nil
        end
    end
end

function terra.languageextension.tokentype:__tostring()
    return self.name
end

do
    local special = { "name", "string", "number", "eof", "default" }
    --note: default is not a tokentype but can be used in libraries to match
    --a token that is not another type
    for i,k in ipairs(special) do
        local name = "<" .. k .. ">"
        local tbl = setmetatable({
            name = name }, terra.languageextension.tokentype )
        terra.languageextension[k] = tbl
        terra.languageextension.tokenkindtotoken[name] = tbl
    end
end

function terra.runlanguage(lang,cur,lookahead,next,embeddedcode,source,isstatement,islocal)
    local lex = {}
    
    lex.name = terra.languageextension.name
    lex.string = terra.languageextension.string
    lex.number = terra.languageextension.number
    lex.eof = terra.languageextension.eof
    lex.default = terra.languageextension.default

    lex._references = terra.newlist()
    lex.source = source

    local function maketoken(tok)
        local specialtoken = terra.languageextension.tokenkindtotoken[tok.type]
        if specialtoken then
            tok.type = specialtoken
        end
        if type(tok.value) == "userdata" then -- 64-bit number in pointer
            tok.value = terra.cast(terra.types.pointer(tok.valuetype),tok.value)[0]
        end
        return tok
    end
    function lex:cur()
        self._cur = self._cur or maketoken(cur())
        return self._cur
    end
    function lex:lookahead()
        self._lookahead = self._lookahead or maketoken(lookahead())
        return self._lookahead
    end
    function lex:next()
        local v = self:cur()
        self._cur,self._lookahead = nil,nil
        next()
        return v
    end
    local function doembeddedcode(self,isterra,isexp)
        self._cur,self._lookahead = nil,nil --parsing an expression invalidates our lua representations 
        local expr = embeddedcode(isterra,isexp)
        return function(env)
            local oldenv = getfenv(expr)
            setfenv(expr,env)
            local function passandfree(...)
                setfenv(expr,oldenv)
                return ...
            end
            return passandfree(expr())
        end
    end
    function lex:luaexpr() return doembeddedcode(self,false,true) end
    function lex:luastats() return doembeddedcode(self,false,false) end
    function lex:terraexpr() return doembeddedcode(self,true,true) end
    function lex:terrastats() return doembeddedcode(self,true,false) end

    function lex:ref(name)
        if type(name) ~= "string" then
            error("references must be identifiers")
        end
        self._references:insert(name)
    end

    function lex:typetostring(name)
        return name
    end
    
    function lex:nextif(typ)
        if self:cur().type == typ then
            return self:next()
        else return false end
    end
    function lex:expect(typ)
        local n = self:nextif(typ)
        if not n then
            self:errorexpected(tostring(typ))
        end
        return n
    end
    function lex:matches(typ)
        return self:cur().type == typ
    end
    function lex:lookaheadmatches(typ)
        return self:lookahead().type == typ
    end
    function lex:error(msg)
        error(msg,0) --,0 suppresses the addition of line number information, which we do not want here since
                     --this is a user-caused errors
    end
    function lex:errorexpected(what)
        self:error(what.." expected")
    end
    function lex:expectmatch(typ,openingtokentype,linenumber)
       local n = self:nextif(typ)
        if not n then
            if self:cur().linenumber == linenumber then
                lex:errorexpected(tostring(typ))
            else
                lex:error(string.format("%s expected (to close %s at line %d)",tostring(typ),tostring(openingtokentype),linenumber))
            end
        end
        return n
    end

    local constructor,names
    if isstatement and islocal and lang.localstatement then
        constructor,names = lang:localstatement(lex)
    elseif isstatement and not islocal and lang.statement then
        constructor,names = lang:statement(lex)
    elseif not islocal and lang.expression then
        constructor = lang:expression(lex)
    else
        lex:error("unexpected token")
    end
    
    if not constructor or type(constructor) ~= "function" then
        error("expected language to return a construction function")
    end

    local function isidentifier(str)
        local b,e = string.find(str,"[%a_][%a%d_]*")
        return b == 1 and e == string.len(str)
    end

    --fixup names    

    if not names then 
        names = {}
    end

    if type(names) ~= "table" then
        error("names returned from constructor must be a table")
    end

    if islocal and #names == 0 then
        error("local statements must define at least one name")
    end

    for i = 1,#names do
        if type(names[i]) ~= "table" then
            names[i] = { names[i] }
        end
        local name = names[i]
        if #name == 0 then
            error("name must contain at least one element")
        end
        for i,c in ipairs(name) do
            if type(c) ~= "string" or not isidentifier(c) then
                error("name component must be an identifier")
            end
            if islocal and i > 1 then
                error("local names must have exactly one element")
            end
        end
    end

    return constructor,names,lex._references
end

_G["operator"] = terra.internalmacro(function(diag,anchor,op,...)
        local tbl = {
            __sub = "-";
            __add = "+";
            __mul = "*";
            __div = "/";
            __mod = "%";
            __lt = "<";
            __le = "<=";
            __gt = ">";
            __ge = ">=";
            __eq = "==";
            __ne = "~=";
            __and = "and";
            __or = "or";
            __not = "not";
            __xor = "^";
            __lshift = "<<";
            __rshift = ">>";
            __select = "select";
        }
    local opv = op:asvalue()
    opv = tbl[opv] or opv --operator can be __add or +
    return typecheck(newobject(anchor,T.operator,opv,List{...}))
end)
--called by tcompiler.cpp to convert userdata pointer to stacktrace function to the right type;
function terra.initdebugfns(traceback,backtrace,lookupsymbol,lookupline,disas)
    local P,FP = terra.types.pointer, terra.types.funcpointer
    local po = P(terra.types.opaque)
    local ppo = P(po)

    terra.SymbolInfo = terra.types.newstruct("SymbolInfo")
    terra.SymbolInfo.entries = { {"addr", ppo}, {"size", terra.types.uint64}, {"name",terra.types.rawstring}, {"namelength",terra.types.uint64} };
    terra.LineInfo = terra.types.newstruct("LineInfo")
    terra.LineInfo.entries = { {"name",terra.types.rawstring}, {"namelength",terra.types.uint64},{"linenum", terra.types.uint64}};

    terra.traceback = terra.cast(FP({po},{}),traceback)
    terra.backtrace = terra.cast(FP({ppo,terra.types.int,po,po},{terra.types.int}),backtrace)
    terra.lookupsymbol = terra.cast(FP({po,P(terra.SymbolInfo)},{terra.types.bool}),lookupsymbol)
    terra.lookupline   = terra.cast(FP({po,po,P(terra.LineInfo)},{terra.types.bool}),lookupline)
    terra.disas = terra.cast(FP({po,terra.types.uint64,terra.types.uint64},{}),disas)
end

-- initialize type table for a few basic types
terra.cast(uint64, 1ULL)
terra.cast(int64, 1LL)

_G["terralib"] = terra --terra code can't use "terra" because it is a keyword
