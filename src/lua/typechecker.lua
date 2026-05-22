local List = require("lua.asdl").List
local ast = require("lua.ast")
local macros = require("lua.macros")
local quotes = require("lua.quotes")
local T = ast.T
local diagnostics = require("lua.diagnostics")
local environment = require("lua.environment")
local types = require("lua.types").types


local function evalluaexpression(env, e)
    if not T.luaexpression:isclassof(e) then
       error("not a lua expression?") 
    end
    assert(type(e.expression) == "function")
    local fn = e.expression
    local oldenv = getfenv(fn)
    setfenv(fn,env)
    local v = invokeuserfunction(e,"evaluating Lua code from Terra",false,fn)
    setfenv(fn,oldenv) --otherwise, we hold false reference to env, -- in the case of an error, this function will still hold a reference
                       -- but without a good way of doing 'finally' without messing with the error trace there is no way around this
    return v
end

local function evaltype(diag,env,typ)
    local v = evalluaexpression(env,typ)
    if types.istype(v) then return v end
    if ast.israwlist(v) then
        for i,t in ipairs(v) do
            if not types.istype(t) then
                diag:reporterror(typ,"expected a type but found ",terra.type(v))
                return types.error
            end
        end
        return #v == 1 and v[1] or types.tuple(unpack(v))
    end
    diag:reporterror(typ,"expected a type but found ",terra.type(v))
    return types.error
end
    
local function evaluateparameterlist(diag, env, paramlist, requiretypes)
    local result = List()
    for i,p in ipairs(paramlist) do
        if p.kind == "unevaluatedparam" then
            if p.name.kind == "namedident" then
                local typ = p.type and evaltype(diag,env,p.type)
                local sym = ast.newsymbol(typ or T.error,p.name.value)
                result:insert(ast.newobject(p,T.concreteparam,typ,p.name.value,sym,true))
            else assert(p.name.kind == "escapedident")
                local value = evalluaexpression(env,p.name.expression)
                if not value then
                    diag:reporterror(p,"expected a symbol or string but found nil")
                end
                local symlist = (ast.israwlist(value) and value) or List { value }
                for i,entry in ipairs(symlist) do
                    if ast.issymbol(entry) then
                        result:insert(ast.newobject(p,T.concreteparam, entry.type, tostring(entry),entry,false))
                    else
                        diag:reporterror(p,"expected a symbol but found ",terra.type(entry))
                    end
                end
            end
        else
            result:insert(p)
        end
    end
    for i,entry in ipairs(result) do
        assert(entry.type == nil or types.istype(entry.type))
        if requiretypes and not entry.type then
            diag:reporterror(entry,"type must be specified for parameters and uninitialized variables")
        end
    
    end
    return result
end
    
local function semanticcheck(diag,parameters,block)
    local symbolenv = environment.newenvironment()
    
    local labelstates = {} -- map from label value to labelstate object, either representing a defined or undefined label
    local globalsused = List() 
    
    local loopdepth = 0
    local function enterloop() loopdepth = loopdepth + 1 end
    local function leaveloop() loopdepth = loopdepth - 1 end
    
    local scopeposition = List()
    local function getscopeposition() return List { unpack(scopeposition) } end
    local function getscopedepth(position)
        local c = 0
        for _,d in ipairs(position) do
            c = c + d
        end
        return c
    end
    local function defersinlocalscope()
        return scopeposition[#scopeposition]
    end
    local function checklocaldefers(anchor,c)
        if defersinlocalscope() ~= c then
            diag:reporterror(anchor, "defer statements are not allowed in conditional expressions")
        end
    end
    --calculate the number of deferred statements that will fire when jumping from stack position 'from' to 'to'
    --if a goto crosses a deferred statement, we detect that and report an error
    local function checkdeferredpassed(anchor,from,to)
        local N = math.max(#from,#to)
        for i = 1,N do
            local t,f = to[i] or 0, from[i] or 0
            if t < f then
                for j = i+1,N do
                    if (to[j] or 0) ~= 0 then
                        diag:reporterror(anchor,"goto crosses the scope of a deferred statement")
                    end
                end
            elseif t > f then
                diag:reporterror(anchor,"goto crosses the scope of a deferred statement")
            end
        end
    end
    local visit
    local function visitnolocaldefers(anchor,e)
        local ndefers = defersinlocalscope()
        visit(e)
        checklocaldefers(anchor,ndefers)
    end
    function visit(e)
        if List:isclassof(e) then
            for _,ee in ipairs(e) do visit(ee) end
        elseif T.tree:isclassof(e) then
            if e:is "var" then
                local definition = symbolenv:localenv()[e.symbol]
                if not definition then
                    diag:reporterror(e, "definition of variable with symbol ",e.symbol, " is not in scope in this context")
                end
            elseif e:is "globalvalueref" then
                globalsused:insert(e.value)
            elseif e:is "allocvar" then
                symbolenv:localenv()[e.symbol] = e
            elseif e:is "letin" then
                symbolenv:enterblock()
                visit(e.statements)
                visit(e.expressions)
                symbolenv:leaveblock()
            elseif e:is "block" then
                symbolenv:enterblock()
                scopeposition:insert(0)
                visit(e.statements)
                scopeposition:remove()
                symbolenv:leaveblock()
            elseif e:is "label" then
                local label = e.label.value
                local state = labelstates[label]
                local position = getscopeposition()
                if state and state.kind == "definedlabel" then
                    diag:reporterror(e,"label defined twice")
                    diag:reporterror(state.label,"previous definition here")
                elseif state then assert(state.kind == "undefinedlabel")
                    for i,g in ipairs(state.gotos) do
                        checkdeferredpassed(g,state.positions[i],position)
                    end
                end
                labelstates[label] = T.definedlabel(position,e)
            elseif e:is "gotostat" then
                local label = e.label.value
                local state = labelstates[label] or T.undefinedlabel(List(),List())
                local position = getscopeposition()
                if state.kind == "definedlabel" then
                    checkdeferredpassed(e,scopeposition,state.position)
                else assert(state.kind == "undefinedlabel")
                    state.gotos:insert(e)
                    state.positions:insert(getscopeposition())
                end
                labelstates[label] = state
            elseif e:is "breakstat" then
                if loopdepth == 0 then
                    diag:reporterror(e,"break found outside a loop")
                end
            elseif e:is "whilestat" then
                enterloop()
                visitnolocaldefers(e.condition,e.condition)
                visit(e.body)
                leaveloop()
            elseif e:is "repeatstat" then
                enterloop()
                visit(e.statements)
                visitnolocaldefers(e.condition,e.condition)
            elseif e:is "ifbranch" then
                visitnolocaldefers(e.condition,e.condition)
                visit(e.body)
            elseif e:is "switchcase" then
                visitnolocaldefers(e.condition,e.condition)
                visit(e.body)
            elseif e:is "fornum" then
                visit(e.initial); visit(e.limit); visit(e.step)
                visit(e.variable)
                enterloop()
                visit(e.body)
                leaveloop()
            elseif e:is "defer" then
                visit(e.expression)
                scopeposition[#scopeposition] = scopeposition[#scopeposition] + 1
            elseif e:is "operator" and (e.operator == "and" or e.operator == "or") and e.operands[1].type:islogical() then
                visitnolocaldefers(e,e.operands)
            else --generic traversal
                for _,field in ipairs(e.__fields) do
                    visit(e[field.name])
                end
            end
        end
    end
    visit(parameters)
    visit(block)
    
    --check the label table for any labels that have been referenced but not defined
    local labeldepths = {}
    for k,state in pairs(labelstates) do
        if state.kind == "undefinedlabel" then
            diag:reporterror(state.gotos[1],"goto to undefined label")
        else
            labeldepths[k] = getscopedepth(state.position)
        end
    end
    
    return labeldepths, globalsused
end

local function typecheck(topexp,luaenv,simultaneousdefinitions)
    local env = environment.newenvironment(luaenv or {})
    local diag = diagnostics.newdiagnostics()
    simultaneousdefinitions = simultaneousdefinitions or {}
    
    local invokeuserfunction = function(...)
        diag:finishandabortiferrors("Errors reported during typechecking.",2)
        return invokeuserfunction(...)
    end
    local evalluaexpression = function(...)
        diag:finishandabortiferrors("Errors reported during typechecking.",2)
        return evalluaexpression(...)
    end
    
    local function checklabel(e,stringok)
        if e.kind == "namedident" then return e end
        local r = evalluaexpression(env:combinedenv(),e.expression)
        if type(r) == "string" then
            if not stringok then
                diag:reporterror(e,"expected a label but found string")
                return ast.newobject(e,T.labelident,ast.newlabel(r))
            end
            return ast.newobject(e,T.namedident,r)
        elseif not ast.islabel(r) then
            diag:reporterror(e,"expected a string or label but found ",terra.type(r))
            r = ast.newlabel("error")
        end
        return ast.newobject(e,T.labelident,r)
    end


    -- TYPECHECKING FUNCTION DECLARATIONS
    --declarations major driver functions for typechecker
    local checkexp -- (e.g. 3 + 4)
    local checkstmts,checkblock -- (e.g. var a = 3)
    local checkcall -- any invocation (method, function call, macro, overloaded operator) gets translated into a call to checkcall (e.g. sizeof(int), foobar(3), obj:method(arg))

    --tree constructors for trees created in the typechecking process
    local function createcast(exp,typ)
        return ast.newobject(exp,T.cast,typ,exp):withtype(typ:tcomplete(exp))
    end

    local function createfunctionreference(anchor,e)
        local fntyp = e.type
        if fntyp == types.placeholderfunction then
            local functiondef = simultaneousdefinitions[e]
            if functiondef == nil then
                diag:reporterror(anchor,"referenced function needs an explicit return type (it is recursively referenced or used before its own defintion).")
                diag:reporterror(e.anchor,"definition of function is here.")
            else
                simultaneousdefinitions[e] = nil
                local body = typecheck(functiondef,luaenv,simultaneousdefinitions) -- can throw, but we just want to pass the error through
                e:adddefinition(body)
                fntyp = e.type
            end
        end
        return ast.newobject(anchor,T.globalvalueref,e.name,e):withtype(types.pointer(fntyp))
    end

    local function insertaddressof(ee)
        return ast.newobject(ee,T.operator,"&",List {ee}):withtype(types.pointer(ee.type))
    end

    local function insertdereference(e)
        local ret = ast.newobject(e,T.operator,"@",List{e}):setlvalue(true)
        if not e.type:ispointer() then
            diag:reporterror(e,"argument of dereference is not a pointer type but ",e.type)
            ret:withtype(types.error)
        else
            ret:withtype(e.type.type:tcomplete(e))
        end
        return ret
    end

    local function insertselect(v, field)
        assert(v.type:isstruct())

        local layout = v.type:getlayout(v)
        local index = layout.keytoindex[field]
    
        if index == nil then
            return nil,false
        end

        local type = layout.entries[index+1].type:tcomplete(v)
        local tree = ast.newobject(v,T.select,v,index,tostring(field)):setlvalue(v.lvalue):withtype(type)
        return tree,true
    end

    local function ensurelvalue(e)
        if not e.lvalue then
            diag:reporterror(e,"argument to operator must be an lvalue")
        end
        return e
    end
    local createlet
    --convert a lua value 'v' into the terra tree representing that value
    local function asterraexpression(anchor,v,location)
        location = location or "expression"
        local function createsingle(v)
            if terra.isglobalvar(v) or ast.issymbol(v) then
                local name = T.var:isclassof(anchor) and anchor.name --propage original variable name for debugging purposes
                return ast.newobject(anchor,terra.isglobalvar(v) and T.globalvalueref or T.var,name or tostring(v),v):setlvalue(true):withtype(v.type)
            elseif terra.isquote(v) then
                return v.tree
            elseif ast.istree(v) then
                --if this is a raw tree, we just drop it in place and hope the user knew what they were doing
                return v
            elseif type(v) == "cdata" then
                local typ = terra.typeof(v)
                if typ:isaggregate() then --when an aggregate is directly referenced from Terra we get its pointer
                                          --a constant would make an entire copy of the object
                    local ptrobj = createsingle(terra.constant(types.pointer(typ),v))
                    return insertdereference(ptrobj)
                end
                return createsingle(terra.constant(typ,v))
            elseif type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                return createsingle(terra.constant(v))
            elseif terra.isfunction(v) then
                return createfunctionreference(anchor,v)
            end
            local mt = getmetatable(v)
            if type(mt) == "table" and mt.__toterraexpression then
                return asterraexpression(anchor,mt.__toterraexpression(v),location)
            end
            if not (terra.isoverloadedfunction(v) or macros.ismacro(v) or types.istype(v) or type(v) == "table") then
                diag:reporterror(anchor,"lua object of type ", terra.type(v), " not understood by terra code.")
                if type(v) == "function" then
                    diag:reporterror(anchor, "to call a lua function from terra first use terralib.cast to cast it to a terra function type.")
                end
            end
            return newobject(anchor,T.luaobject,v):withtype(T.luaobjecttype)
        end
        if not ast.israwlist(v) then
            return createsingle(v)
        end
        local values = List()
        for _,v in ipairs(v) do
            local r = createsingle(v)
            if r:is "letin"  and not r.hasstatements then
                values:insertall(r.expressions)
            else
                values:insert(r)
            end
        end
        if location == "statement" then
            return newobject(anchor,T.statlist,values):withtype(types.unit)
        end
        return createlet(anchor, List(), values, false)
    end
    --functions handling casting between types

    local insertcast --handles implicitly allowed casts (e.g. var a : int = 3.5)
    local insertexplicitcast --handles casts performed explicitly (e.g. var a = int(3.5))
    local structcast -- handles casting from an anonymous structure type to another struct type (e.g. StructFoo { 3, 5 })
    local insertrecievercast -- handles casting for method recievers, which allows for an implicit addressof operator to be inserted
    -- all implicit casts (struct,reciever,generic) take a speculative argument
    --if speculative is true, then errors will not be reported (caller must check)
    --this is used to see if an overloaded function can apply to the argument list

    --create a new variable allocation and a var node that refers to it, used to create temporary variables
    local function allocvar(anchor,typ,name)
        local av = newobject(anchor,T.allocvar,name,ast.newsymbol(typ,name)):setlvalue(true):withtype(typ:tcomplete(anchor))
        local v = newobject(anchor,T.var,name,av.symbol):setlvalue(true):withtype(typ)
        return av,v
    end
    local createassignment

    function structcast(explicit,exp,typ,speculative)
        local from = exp.type:getlayout(exp)
        local to = typ:getlayout(exp)

        --take care of (managed and partial) struct initialization
        if terralib.ext and exp:is "constructor" and terralib.ext.ismanaged(typ) then
            local f = terralib.ext.addmissing.constructor(exp.type, typ)
            local fnlike = asterraexpression(exp, f, "luaobject")
            local arguments = List {unpack(exp.expressions)}
            return checkcall(exp, List { fnlike } , arguments, "none", false, "expression")
        end

        local valid = true
        local function err(...)
            valid = false
            if not speculative then
                diag:reporterror(exp,...)
            end
        end
        local structvariable, var_ref = allocvar(exp,exp.type,"<structcast>")
    
        local entries = List()
        if #from.entries > #to.entries or (not explicit and #from.entries ~= #to.entries) then
            err("structural cast invalid, source has ",#from.entries," fields but target has only ",#to.entries)
            return exp:copy{}:withtype(typ), valid
        end
        for i,entry in ipairs(from.entries) do
            local selected = insertselect(var_ref,entry.key)
            local offset = exp.type.convertible == "tuple" and i - 1 or to.keytoindex[entry.key]
            if not offset then
                err("structural cast invalid, result structure has no key ", entry.key)
            else
                local v = insertcast(selected,to.entries[offset+1].type)
                entries:insert(newobject(exp,T.storelocation,offset,v))
            end
        end
        return newobject(exp,T.structcast,structvariable,exp,entries):withtype(typ)
    end

    function insertcast(exp,typ,speculative) --if speculative is true, then an error will not be reported and the caller should check the second return value to see if the cast was valid
        if typ == nil or not types.istype(typ) or not exp.type then
            print(debug.traceback())
        end
        if typ == exp.type or typ == types.error or exp.type == types.error then
            return exp, true
        else
            if ((typ:isprimitive() and exp.type:isprimitive()) or
                (typ:isvector() and exp.type:isvector() and typ.N == exp.type.N)) and
               not typ:islogicalorvector() and not exp.type:islogicalorvector() then
                return createcast(exp,typ), true
            elseif typ:ispointer() and exp.type:ispointer() and typ.type == types.opaque then --implicit cast from any pointer to &opaque
                return createcast(exp,typ), true
            elseif typ:ispointer() and exp.type == types.niltype then --niltype can be any pointer
                return createcast(exp,typ), true
            elseif typ:isstruct() and typ.convertible and exp.type:isstruct() and exp.type.convertible then 
                return structcast(false,exp,typ,speculative), true
            elseif typ:ispointer() and exp.type:isarray() and typ.type == exp.type.type then
                return createcast(exp,typ), true
            elseif typ:isvector() and exp.type:isprimitive() then
                local primitivecast, valid = insertcast(exp,typ.type,speculative)
                local broadcast = createcast(primitivecast,typ)
                return broadcast, valid
            end

            --no builtin casts worked... now try user-defined casts
            local cast_fns = List()
            local function addcasts(typ)
                if typ:isstruct() and typ.metamethods.__cast then
                    cast_fns:insert(typ.metamethods.__cast)
                elseif typ:ispointertostruct() then
                    addcasts(typ.type)
                end
            end
            addcasts(exp.type)
            addcasts(typ)

            local errormsgs = List()
            for i,__cast in ipairs(cast_fns) do
                local quotedexp = quotes.newquote(exp)
                local success,result = invokeuserfunction(exp, "invoking __cast", true,__cast,exp.type,typ,quotedexp)
                if success then
                    local result = asterraexpression(exp,result)
                    if result.type ~= typ then 
                        diag:reporterror(exp,"user-defined cast returned expression with the wrong type.")
                    end
                    return result,true
                else
                    errormsgs:insert(result)
                end
            end

            if not speculative then
                diag:reporterror(exp,"invalid conversion from ",exp.type," to ",typ)
                for i,e in ipairs(errormsgs) do
                    diag:reporterror(exp,"user-defined cast failed: ",e)
                end
            end
            return createcast(exp,typ), false
        end
    end
    function insertexplicitcast(exp,typ) --all implicit casts are allowed plus some additional casts like from int to pointer, pointer to int, and int to int
        if typ == exp.type then
            return exp
        elseif typ:ispointer() and exp.type:ispointer() then
            return createcast(exp,typ)
        elseif typ:ispointer() and exp.type:isintegral() then --int to pointer
            return createcast(exp,typ)
        elseif typ:isintegral() and exp.type:ispointer() then
            if typ.bytes < types.intptr.bytes then
                diag:reporterror(exp,"pointer to ",typ," conversion loses precision")
            end
            return createcast(exp,typ)
        elseif (typ:isprimitive() and exp.type:isprimitive())
            or (typ:isvector() and exp.type:isvector() and typ.N == exp.type.N) then --explicit conversions from logicals to other primitives are allowed
            return createcast(exp,typ)
        elseif typ:isstruct() and exp.type:isstruct() and exp.type.convertible then 
            return structcast(true,exp,typ)
        else
            return insertcast(exp,typ) --otherwise, allow any implicit casts
        end
    end
    function insertrecievercast(exp,typ,speculative) --casts allow for method recievers a:b(c,d) ==> b(a,c,d), but 'a' has additional allowed implicit casting rules
                                                      --type can also be == "vararg" if the expected type of the reciever was an argument to the varargs of a function (this often happens when it is a lua function)
         if typ == "vararg" then
             return insertaddressof(exp), true
         elseif typ:ispointer() and not exp.type:ispointer() then
             --implicit address of allowed for recievers
             return insertcast(insertaddressof(exp),typ,speculative)
         else
            return insertcast(exp,typ,speculative)
        end
        --notes:
        --we force vararg recievers to be a pointer
        --an alternative would be to return reciever.type in this case, but when invoking a lua function as a method
        --this would case the lua function to get a pointer if called on a pointer, and a value otherwise
        --in other cases, you would consistently get a value or a pointer regardless of receiver type
        --for consistency, we all lua methods take pointers
    end


    --functions to typecheck operator expressions

    local function typemeet(op,a,b)
        local function err()
            diag:reporterror(op,"incompatible types: ",a," and ",b)
        end
        if a == types.error or b == types.error then
            return types.error
        elseif a == b then
            return a
        elseif a.kind == tokens.primitive and b.kind == tokens.primitive then
            if a:isintegral() and b:isintegral() then
                if a.bytes < b.bytes then
                    return b
                elseif a.bytes > b.bytes then
                    return a
                elseif a.signed then
                    return b
                else --a is unsigned but b is signed
                    return a
                end
            elseif a:isintegral() and b:isfloat() then
                return b
            elseif a:isfloat() and b:isintegral() then
                return a
            elseif a:isfloat() and b:isfloat() then
                return types.double
            else
                err()
                return types.error
            end
        elseif a:ispointer() and b == types.niltype then
            return a
        elseif a == types.niltype and b:ispointer() then
            return b
        elseif a:isvector() and b:isvector() and a.N == b.N then
            local rt = typemeet(op,a.type,b.type)
            return (rt == types.error and rt) or types.vector(rt,a.N)
        elseif (a:isvector() and b:isprimitive()) or (b:isvector() and a:isprimitive()) then
            if a:isprimitive() then
                a,b = b,a --ensure a is vector and b is primitive
            end
            local rt = typemeet(op,a.type,b)
            return (rt == types.error and rt) or types.vector(rt,a.N)
        elseif a:isstruct() and b:isstruct() and a.convertible == "tuple" and b.convertible == "tuple" and #a.entries == #b.entries then
            local entries = List()
            local as,bs = a:getentries(),b:getentries()
            for i,ae in ipairs(as) do
                local be = bs[i]
                local rt = typemeet(op,ae.type,be.type)
                if rt == types.error then return rt end
                entries:insert(rt)
            end
            return types.tuple(unpack(entries))
        else    
            err()
            return types.error
        end
    end

    local function typematch(op,lstmt,rstmt)
        local inputtype = typemeet(op,lstmt.type,rstmt.type)
        return inputtype, insertcast(lstmt,inputtype), insertcast(rstmt,inputtype)
    end

    local function checkunary(ee,operands,property)
        local e = operands[1]
        if e.type ~= types.error and not e.type[property](e.type) then
            diag:reporterror(e,"argument of unary operator is not valid type but ",e.type)
            return e:aserror()
        end
        return ee:copy { operands = List{e} }:withtype(e.type)
    end 


    local function meetbinary(e,property,lhs,rhs)
        local t,l,r = typematch(e,lhs,rhs)
        if t ~= types.error and not t[property](t) then
            diag:reporterror(e,"arguments of binary operator are not valid type but ",t)
            return e:aserror()
        end
        return e:copy { operands = List {l,r} }:withtype(t)
    end

    local function checkbinaryorunary(e,operands,property)
        if #operands == 1 then
            return checkunary(e,operands,property)
        end
        return meetbinary(e,property,operands[1],operands[2])
    end

    local function checkarith(e,operands)
        return checkbinaryorunary(e,operands,"isarithmeticorvector")
    end

    local function checkarithpointer(e,operands)
        if #operands == 1 then
            return checkunary(e,operands,"isarithmeticorvector")
        end
    
        local l,r = unpack(operands)
    
        local function pointerlike(t)
            return t:ispointer() or t:isarray()
        end
        local function ascompletepointer(exp) --convert pointer like things into pointers to _complete_ types
            exp.type.type:tcomplete(exp)
            return (insertcast(exp,types.pointer(exp.type.type, exp.type.addressspace))) --parens are to truncate to 1 argument
        end
        -- subtracting 2 pointers
        if  pointerlike(l.type) and pointerlike(r.type) and l.type.type == r.type.type and e.operator == tokens["-"] then
            return e:copy { operands = List {ascompletepointer(l),ascompletepointer(r)} }:withtype(types.ptrdiff)
        elseif pointerlike(l.type) and r.type:isintegral() then -- adding or subtracting a int to a pointer
            return e:copy {operands = List {ascompletepointer(l),r} }:withtype(types.pointer(l.type.type, l.type.addressspace))
        elseif l.type:isintegral() and pointerlike(r.type) then
            return e:copy {operands = List {ascompletepointer(r),l} }:withtype(types.pointer(r.type.type, r.type.addressspace))
        else
            return meetbinary(e,"isarithmeticorvector",l,r)
        end
    end

    local function checkintegralarith(e,operands)
        return checkbinaryorunary(e,operands,"isintegralorvector")
    end

    local function checkcomparision(e,operands)
        local t,l,r = typematch(e,operands[1],operands[2])
        local rt = types.bool
        if t:isaggregate() then
            diag:reporterror(e,"cannot compare aggregate type ",t)
        elseif t:isvector() then
            rt = types.vector(types.bool,t.N)
        end
        return e:copy { operands = List {l,r} }:withtype(rt)
    end

    local function checklogicalorintegral(e,operands)
        return checkbinaryorunary(e,operands,"canbeordorvector")
    end

    local function checkshift(ee,operands)
        local a,b = unpack(operands)
        local typ = types.error
        if a.type ~= types.error and b.type ~= types.error then
            if a.type:isintegralorvector() and b.type:isintegralorvector() then
                if a.type:isvector() then
                    typ = a.type
                elseif b.type:isvector() then
                    typ = types.vector(a.type,b.type.N)
                else
                    typ = a.type
                end
            
                a = insertcast(a,typ)
                b = insertcast(b,typ)
        
            else
                diag:reporterror(ee,"arguments to shift must be integers but found ",a.type," and ", b.type)
            end
        end
    
        return ee:copy { operands =  List{a,b} }:withtype(typ)
    end


    local function checkifelse(ee,operands)
        local cond = operands[1]
        local t,l,r = typematch(ee,operands[2],operands[3])
        if cond.type ~= types.error and t ~= types.error then
            if cond.type:isvector() and cond.type.type == types.bool then
                if not t:isvector() or t.N ~= cond.type.N then
                    diag:reporterror(ee,"conditional in select is not the same shape as ",cond.type)
                end
            elseif cond.type ~= types.bool then
                diag:reporterror(ee,"expected a boolean or vector of booleans but found ",cond.type)   
            end
        end
        return ee:copy {operands = List {cond,l,r}}:withtype(t)
    end

    local operator_table = {
        ["-"] = { checkarithpointer, "__sub", "__unm" };
        ["+"] = { checkarithpointer, "__add" };
        ["*"] = { checkarith, "__mul" };
        ["/"] = { checkarith, "__div" };
        ["%"] = { checkarith, "__mod" };
        ["<"] = { checkcomparision, "__lt" };
        ["<="] = { checkcomparision, "__le" };
        [">"] = { checkcomparision, "__gt" };
        [">="] =  { checkcomparision, "__ge" };
        ["=="] = { checkcomparision, "__eq" };
        ["~="] = { checkcomparision, "__ne" };
        ["and"] = { checklogicalorintegral, "__and" };
        ["or"] = { checklogicalorintegral, "__or" };
        ["not"] = { checklogicalorintegral, "__not" };
        ["^"] =  { checkintegralarith, "__xor" };
        ["<<"] = { checkshift, "__lshift" };
        [">>"] = { checkshift, "__rshift" };
        ["select"] = { checkifelse, "__select"}
    }

    local function checkoperator(ee)
        local op_string = ee.operator
    
        --check non-overloadable operators first
        if op_string == "@" then
            local e = checkexp(ee.operands[1])
            return insertdereference(e)
        elseif op_string == "&" then
            local e = ensurelvalue(checkexp(ee.operands[1]))
            local ty = types.pointer(e.type)
            return ee:copy { operands = List {e} }:withtype(ty)
        end
    
        local op, genericoverloadmethod, unaryoverloadmethod = unpack(operator_table[op_string] or {})
    
        if op == nil then
            diag:reporterror(ee,"operator ",op_string," not defined in terra code.")
            return ee:aserror()
        end
    
        local operands = ee.operands:map(checkexp)
    
        local overloads = List()
        for i,e in ipairs(operands) do
            if e.type:isstruct() then
                local overloadmethod = (#operands == 1 and unaryoverloadmethod) or genericoverloadmethod
                local overload = e.type.metamethods[overloadmethod] --TODO: be more intelligent here about merging overloaded functions so that all possibilities are considered
                if overload then
                    overloads:insert(asterraexpression(ee, overload, "luaobject"))
                end
            end
        end
    
        if #overloads > 0 then
            return checkcall(ee, overloads, operands, "all", true, "expression")
        end
        return op(ee,operands)
    end

    --functions to handle typecheck invocations (functions,methods,macros,operator overloads)
    local function removeluaobject(e)
        if not e:is "luaobject" or e.type == types.error then 
            return e --don't repeat error messages
        else
            if types.istype(e.value) then
                diag:reporterror(e, "expected a terra expression but found terra type ", tostring(e.value), ". If this is a cast, you may have omitted the required parentheses: [T](exp)")
            else
                diag:reporterror(e, "expected a terra expression but found ",terra.type(e.value))
            end
            return e:aserror()
        end
    end

    local function checkexpressions(expressions,location)
        local nes = List()
        for i,e in ipairs(expressions) do
            local ne = checkexp(e,location)
            if ne:is "letin"  and not ne.hasstatements then
                nes:insertall(ne.expressions)
            else
                nes:insert(ne)
            end
        end
        return nes
    end

    function createlet(anchor, ns, ne, hasstatements)
        local r = newobject(anchor,T.letin,ns,ne,hasstatements)
        if #ne == 1 then
            r:withtype(ne[1].type):setlvalue(ne[1].lvalue):setassignment(ne[1].assignment)
        else
            r:withtype(types.tuple(unpack(ne:map("type"))))
        end
        r.type:tcomplete(anchor)
        return r
    end

    local function insertvarargpromotions(param)
        if param.type == types.float then
            return insertcast(param,types.double)
        elseif param.type:isarray() then
            --varargs are only possible as an interface to C (or Lua) where arrays are not value types
            --this can cause problems (e.g. calling printf) when Terra passes the value
            --so we degrade the array into pointer when it is an argument to a vararg parameter
            return insertcast(param,types.pointer(param.type.type))
        end
        --TODO: do we need promotions for integral data types or does llvm already do that?
        return param
    end

    local function tryinsertcasts(anchor, typelists,castbehavior, speculate, allowambiguous, paramlist)
        local PERFECT_MATCH,CAST_MATCH,TOP = 1,2,math.huge
     
        local function trylist(typelist, speculate)
            if #typelist ~= #paramlist then
                if not speculate then
                    local fromt,tot = typelist:map(tostring):concat(","),paramlist:map("type"):map(tostring):concat(",")
                    diag:reporterror(anchor,"expected ",#typelist," parameters (",fromt,"), but found ",#paramlist, " (",tot,")")
                end
                return false
            end
            local results,matches = List(),List()
            for i,typ in ipairs(typelist) do
                local param,result,match,valid = paramlist[i]
                if typ == "passthrough" or typ == param.type then
                    result,match = param,PERFECT_MATCH
                else
                    match = CAST_MATCH
                    if castbehavior == "all" or i == 1 and castbehavior == "first" then
                        result,valid = insertrecievercast(param,typ,speculate)
                    elseif typ == "vararg" then
                        result,valid = insertvarargpromotions(param),true
                    else
                        result,valid = insertcast(param,typ,speculate)
                    end
                    if not valid then return false end
                end
                results[i],matches[i] = result,match
            end
            return true,results,matches
        end
        if #typelists == 1 then
            local valid,results = trylist(typelists[1],speculate)
            if not valid then
                return paramlist,nil
            else
                return results, 1
            end
        else
            local function meetwith(a,b)
                local ale, ble = true,true
                local meet = List()
                for i = 1,#paramlist do
                    local m = math.min(a[i] or TOP,b[i] or TOP)
                    ale = ale and a[i] == m
                    ble = ble and b[i] == m
                    a[i] = m
                end
                return ale,ble --a = a meet b, a <= b, b <= a
            end

            local results,matches = List(),List()
            for i,typelist in ipairs(typelists) do
                local valid,nr,nm = trylist(typelist,true)
                if valid then
                    local ale,ble = meetwith(matches,nm)
                    if ale == ble then
                        if ale and not matches.exists then
                            results = List()
                        end
                        results:insert( { expressions = nr, idx = i } )
                        matches.exists = ale
                    elseif ble then
                        results = List { { expressions = nr, idx = i } }
                        matches.exists = true
                    end
                end
            end
            if #results == 0 then
                --no options were valid and our caller wants us to, lets emit some errors
                if not speculate then
                    diag:reporterror(anchor,"call to overloaded function does not apply to any arguments")
                    for i,typelist in ipairs(typelists) do
                        diag:reporterror(anchor,"option ",i," with type ",mkstring(typelist,"(",",",")"))
                        trylist(typelist,false)
                    end
                end
                return paramlist,nil
            else
                if #results > 1 and not allowambiguous then
                    local strings = results:map(function(x) return mkstring(typelists[x.idx],"type list (",",",") ") end)
                    diag:reporterror(anchor,"call to overloaded function is ambiguous. can apply to ",unpack(strings))
                end 
                return results[1].expressions, results[1].idx
            end
        end
    end

    local function insertcasts(anchor, typelist,paramlist) --typelist is a list of target types (or the value "passthrough"), paramlist is a parameter list that might have a multiple return value at the end
        return tryinsertcasts(anchor, List { typelist }, "none", false, false, paramlist)
    end

    local function checkmethodwithreciever(anchor, ismeta, methodname, reciever, arguments, location)
        local objtyp
        reciever.type:tcomplete(anchor)
        if reciever.type:isstruct() then
            objtyp = reciever.type
        elseif reciever.type:ispointertostruct() then
            objtyp = reciever.type.type
            reciever = insertdereference(reciever)
        else
            diag:reporterror(anchor,"attempting to call a method on a non-structural type ",reciever.type)
            return anchor:aserror()
        end

        local fnlike,errmsg
        if ismeta then
            fnlike = objtyp.metamethods[methodname]
            errmsg = fnlike == nil and "no such metamethodmethod "..methodname.." defined for type "..tostring(objtyp)
        else
            fnlike,errmsg = objtyp:getmethod(methodname)
        end

        if not fnlike then
            diag:reporterror(anchor,errmsg)
            return anchor:aserror()
        end

        fnlike = asterraexpression(anchor, fnlike, "luaobject")
        local fnargs = List { reciever, unpack(arguments) }
        return checkcall(anchor, List { fnlike }, fnargs, "first", false, location)
    end

    --check if raii method is implemented, does not generate one
    local function hasraiimethod(receiver, method)
        if not terralib.ext then return false end
        local typ = receiver.type
        if typ and typ:isstruct() then
            terralib.ext.addmissing[method](typ)
            if typ.methods[method] then
                return true
            end
        end
        return false
    end

    --check if raii method is implemented and generates one using `terralibext.t` if it is missing
    local function ismanagedtype(T, method)
        if T:isstruct() then
            terralib.ext.addmissing[method](T)
            if T.methods[method] then
                return true
            end
        elseif T:isarray() then
            return ismanagedtype(T.type, method)
        end
        return false
    end

    --check if raii method is implemented and generates one using `terralibext.t` if it is missing
    local function ismanaged(receiver, method)
        if not terralib.ext then return false end
        local typ = receiver.type
        return typ~=nil and ismanagedtype(typ, method)
    end

    --type check raii method __init or __dtor. __copy is handled separately
    --methods are generated if they are missing
    local function checkraiimethodwithreceiver(anchor, receiver, method)
        if not terralib.ext then return end
        local typ = receiver.type
        if ismanagedtype(typ, method) then
            if receiver:is "allocvar" then
                receiver = newobject(anchor,T.var,receiver.name,receiver.symbol):setlvalue(true):withtype(typ)
            end
            if typ:isstruct() then
                return checkmethodwithreciever(anchor, false, method, receiver, List(), "statement")
            elseif typ:isarray() then
                local init = terralib.ext.addmissing.arraymethod(typ, method)
                if init then
                    local f = asterraexpression(anchor, init, "luaobject")
                    return checkcall(anchor, List{f}, List{receiver}, "all", true, "expression")
                end
            end
        end
    end

    --generate and typecheck raii __init's for use in a 'defvar' statement
    local function checkraiiinitializers(anchor, lhs)
        if not terralib.ext then return end
        local stmts = List()
        for i,e in ipairs(lhs) do
            local init = checkraiimethodwithreceiver(anchor, e, "__init")
            if init then
                stmts:insert(init)
            end
        end
        return stmts
    end

    --generate and typecheck raii __dtor's for use in `block` (scope) statement
    local function checkraiidtors(anchor, stats, exprs)
        if not terralib.ext then return stats end
        --extract the return statement from `stats`, if there is one
        local function extractreturnstat()
            local n = #stats
            if n>0 then
                local s = stats[n]
                if s:is "returnstat" or s:is "breakstat" then
                    return s
                end
            end
        end
        local rstat = extractreturnstat()
        --extract the returned `var` symbols from a return statement
        local function extractreturnedsymbols()
            local function addtoreturnedsymbols(ret, expressions)
                for i,v in ipairs(expressions) do
                    if v:is "var" then
                        ret[v.name] = v.symbol
                    end
                end
            end
            local ret = {}
            --loop over expressions in a `letin` return statement
            if rstat then
                addtoreturnedsymbols(ret, rstat.expression.expressions)
            end
            --loop over expressions from a 'letin' block
            if exprs then
                addtoreturnedsymbols(ret, exprs)
            end
            return ret
        end
        --get symbols that are returned in case of a return statement
        --or 'exprs' in a letin block
        local rsyms = (rstat and rstat:is "returnstat" or exprs) and extractreturnedsymbols() or {}
        --get position at which to add destructor statements
        local pos = rstat and #stats or #stats+1
        --place destructor calls for variables that are not returned
        local function placedestructorcall(name, sym)
            if not rsyms[name] and not sym.ishandle then
                --if not a return variable, then check for an implementation of methods.__dtor
                local typ = sym.type
                if typ:isstruct() or typ:isarray() then
                    local receiver = newobject(anchor, T.var, name, sym):setlvalue(true):withtype(typ)
                    local dtor = checkraiimethodwithreceiver(anchor, receiver, "__dtor")
                    if dtor then
                        --add deferred calls to the destructors
                        table.insert(stats, pos, newobject(anchor, T.defer, dtor))
                    end
                end
            end
        end
        --add destructor calls for variables local to current scope
        local function clearcurrentscope()
            local lenv = env:localenv()
            local queue = env:queue()
            if queue and #queue > 0 then
                --call destructor in reverse order of object creation
                for k=#queue,1,-1 do
                    local name = queue[k]
                    local sym = lenv[name]
                    placedestructorcall(name, sym)
                end
            end
        end
        --add destructor calls for variables from all outer scopes
        local clearouterscopes
        function clearouterscopes()
            env:leaveblock()
            if env:localenv() then
                clearcurrentscope()
                clearouterscopes()
            end
        end
        --clear the current scope
        clearcurrentscope()
        --clear remaining variables in a break-statement
        if rstat and rstat:is "breakstat" then
            --we've already cleaned up the managed variables corresponding to the current scope.
            --now we still need to clean up the managed variables of the outer scope, which is
            --the loop that we leave using the 'break' statement.
            local savedlocalenv = env._localenv
            local savedenvqueue = env._queue
            local scopedepth = env.scopedepth
            env:leaveblock()
            clearcurrentscope()
            --would have been nicer to use 'env:leaveblock()' followed by 'env:enterblock()' but
            --unfortunately this has side effects once you go to scopedepth zero. so we just
            --save the local environment and reset it now that we are done.
            env._localenv = savedlocalenv
            env._queue = savedenvqueue
            env.scopedepth = scopedepth
            --clear remaining input arguments
        elseif (rstat and rstat:is "returnstat") or (env.isfundef and (env.scopedepth==0 or env.scopedepth==1)) then
            --we've already cleaned up the managed variables corresponding to the current scope.
            --if this is a return statement then clear all remaining managed variables from outer
            --scopes before the return
            --if this is the outer most scope of a function (env.isfundef and env.scopedepth==1) then clean up all the
            --remaining variables. The case (env.scopedepth==0) is needed for the corner case of functions that are
            --empty - that don't do anything, but have variables that are passed by value.
            local savedlocalenv = env._localenv
            local savedenvqueue = env._queue
            local scopedepth = env.scopedepth
            clearouterscopes()
            --would have been nicer to use 'env:leaveblock()' followed by 'env:enterblock()' but
            --unfortunately this has side effects once you go to scopedepth zero. so we just
            --save the local environment and reset it now that we are done.
            env._localenv = savedlocalenv
            env._queue = savedenvqueue
            env.scopedepth = scopedepth
        end
        return stats
    end

    --__copy is only enabled for a set of right-hand-sides
    local function validcopyrhs(from)
        --allow one dereference
        if from:is "operator" and #from.operands==1 then
            from = from.operands[1]
        end
        if from:is "structcast" or from:is "apply" or from:is "returnstat" or from:is "operator" or from:is "letin" then
            return false
        else
            return true
        end
    end

    --type check raii __copy (copy-assignment) methods. They are generated
    --if they are missing.
    local function checkraiicopyormoveassignment(anchor, from, to, copyormove)
        if not terralib.ext then return end
        if not validcopyrhs(from) then return end
        --check for 'from.type.methods.[copyormove]' and 'to.type.methods.[copyormove]' and 
        --generate them if needed
        if not (ismanaged(from, copyormove) or ismanaged(to, copyormove)) then
            --return early in case types are not managed and 
            --resort to regular copy
            return
        end
        --if `to` is an allocvar then set type and turn into corresponding `var`
        if to:is "allocvar" then
            if not to.type then
                to:settype(from.type or types.error)
            end
            to = newobject(anchor,T.var,to.name,to.symbol):setlvalue(true):withtype(to.type)
        end
        --list of overloaded __copy metamethods
        local overloads = List()
        local function checkoverload(v)
            local typ = v.type
            if typ:isstruct() and hasraiimethod(v, copyormove) then
                overloads:insert(asterraexpression(anchor, v.type.methods[copyormove], "luaobject"))
            elseif typ:isarray() then
                local method = terralib.ext.addmissing.arraymethod(typ, copyormove)
                if method then
                    overloads:insert(asterraexpression(anchor, method, "luaobject"))
                end
            end
        end
        --add overloaded methods based on left- and right-hand-side of the assignment
        checkoverload(from)
        checkoverload(to)
        if #overloads > 0 then
            return checkcall(anchor, overloads, List{from, to}, "all", true, "expression")
        end
    end

    --type check raii __copy (copy-assignment) methods. They are generated
    --if they are missing.
    local function checkraiicopyassignment(anchor, from, to)
        return checkraiicopyormoveassignment(anchor, from, to, "__copy")
    end

    --type check raii __move (move-assignment) methods. They are generated
    --if they are missing.
    local function checkraiimoveassignment(anchor, from, to)
        return checkraiicopyormoveassignment(anchor, from, to, "__move")
    end

    local function checkmethod(exp, location)
        local methodname = checklabel(exp.name,true).value
        assert(type(methodname) == "string" or ast.islabel(methodname))
        local reciever = checkexp(exp.value)
        local arguments = checkexpressions(exp.arguments,"luavalue")
        return checkmethodwithreciever(exp, false, methodname, reciever, arguments, location)
    end

    local function checkapply(exp, location)
        if exp.value.name == "__move__" then
            local arguments = checkexpressions(exp.arguments,"luavalue")
            assert(#arguments == 1, "__move__ takes only a single argument.")
            local v = arguments[1]
            if ismanaged(v, "__move") then
                v:setassignment("move")
            end
            return v
        elseif exp.value.name == "__handle__" then
            local arguments = checkexpressions(exp.arguments,"luavalue")
            assert(#arguments == 1, "__handle__ takes only a single argument.")
            local v = arguments[1]
            v:setassignment("handle")
            return v
        end
        local fnlike = checkexp(exp.value,"luavalue")
        local arguments = checkexpressions(exp.arguments,"luavalue")
        if not fnlike:is "luaobject" then
            local typ = fnlike.type
            typ = typ:ispointer() and typ.type or typ
            if typ:isstruct() then
                if location == "lexpression" and typ.metamethods.__update then
                    local function setter(rhs)
                        arguments:insert(rhs)
                        return checkmethodwithreciever(exp, true, "__update", fnlike, arguments, "statement") 
                    end
                    return newobject(exp,T.setteru,setter)
                end
                return checkmethodwithreciever(exp, true, "__apply", fnlike, arguments, location) 
            end
        end
        return checkcall(exp, List { fnlike } , arguments, "none", false, location)
    end

    function checkcall(anchor, fnlikelist, arguments, castbehavior, allowambiguous, location)
        --arguments are always typed trees, or a lua object
        assert(#fnlikelist > 0)
        --collect all the terra functions, stop collecting when we reach the first 
        --macro and record it as themacro
        local terrafunctions = List()
        local themacro = nil
        for i,fn in ipairs(fnlikelist) do
            if fn:is "luaobject" then
                if macros.ismacro(fn.value) then
                    themacro = fn.value
                    break
                elseif types.istype(fn.value) then
                    local castmacro = macros.internalmacro(function(diag,tree,arg)
                        return insertexplicitcast(arg.tree,fn.value)
                    end)
                    themacro = castmacro
                    break
                elseif terra.isoverloadedfunction(fn.value) then
                    if #fn.value:getdefinitions() == 0 then
                        diag:reporterror(anchor,"attempting to call overloaded function without definitions")
                    end
                    for i,v in ipairs(fn.value:getdefinitions()) do
                        local fnlit = createfunctionreference(anchor,v)
                        if fnlit.type ~= types.error then
                            terrafunctions:insert( fnlit )
                        end
                    end
                else
                    diag:reporterror(anchor,"expected a function or macro but found lua value of type ",terra.type(fn.value))
                end
            elseif fn.type:ispointertofunction() then
                terrafunctions:insert(fn)
            else
                if fn.type ~= types.error then
                    diag:reporterror(anchor,"expected a function but found ",fn.type)
                end
            end 
        end

        local function createcall(callee, paramlist)
            local function tryinjectcopyormoveassignment(i, p)
                local stmts = List()
                local lv,l = allocvar(p, p.type, "<tmp>")
                --only update the parameter if a copy-/move-assignment is implemented
                --that maps 'from' onto 'to' of the same type.
                local cp = (p.assignment ~= "move") and checkraiicopyassignment(p, p, l) or checkraiimoveassignment(p, p, l)
                if cp then
                    --allocate temporary
                    stmts:insert(lv)
                    --insert __init for temporary
                    local init = checkraiimethodwithreceiver(p, l, "__init")
                    if init then
                        stmts:insert(init)
                    end
                    --inject copy/move assignment
                    stmts:insert(cp)
                    --reset parameter input as the temporary object that is initialized using
                    --the copy-assignment
                    paramlist[i] = createlet(p, stmts, List{l}, true)
                end
            end
            --inject copy/move-assignment for all managed variables that are passed by value
            --and that are not pased as a `__handle__`
            for i,p in ipairs(paramlist) do
                local typ = p.type
                if (typ:isstruct() or typ:isarray()) and validcopyrhs(p) and p.assignment ~= "handle" then
                    tryinjectcopyormoveassignment(i, p)
                end
            end
            --create actual call with this parameterlist
            callee.type.type:tcompletefunction(anchor)
            return newobject(anchor,T.apply,callee,paramlist):withtype(callee.type.type.returntype)
        end
    
        if #terrafunctions > 0 then
            local paramlist = arguments:map(removeluaobject)
            local function getparametertypes(fn) --get the expected types for parameters to the call (this extends the function type to the length of the parameters if the function is vararg)
                local fntyp = fn.type.type
                if not fntyp.isvararg then return fntyp.parameters end
                local vatypes = List()
                vatypes:insertall(fntyp.parameters)
                for i = 1,#paramlist - #fntyp.parameters do
                    vatypes:insert("vararg")
                end
                return vatypes
            end
            local typelists = terrafunctions:map(getparametertypes)
            local castedarguments,valididx = tryinsertcasts(anchor,typelists,castbehavior, themacro ~= nil, allowambiguous, paramlist)
            if valididx then
                return createcall(terrafunctions[valididx],castedarguments)
            end
        end

        if themacro then
            local quotes = arguments:map(quotes.newquote)
            local result = invokeuserfunction(anchor,"invoking macro",false, themacro.run, themacro, diag, anchor, unpack(quotes))
            return asterraexpression(anchor,result,location)
        end
        assert(diag:haserrors())
        return anchor:aserror()
    end

    --functions that handle the checking of expressions
    local function checkluaexpression(e,location)
        local value = {}
        if e.isexpression then
            value = evalluaexpression(env:combinedenv(),e)
        else
            env:enterblock()
            env:localenv().emit = function(arg) table.insert(value,arg) end
            evalluaexpression(env:combinedenv(),e)
            env:leaveblock()
        end
        return asterraexpression(e, value, location)
    end
    function checkexp(e_, location)
        location = location or "expression"
        assert(type(location) == "string")
        local function docheck(e)
            if not ast.istree(e) then
                print("not a tree?")
                print(debug.traceback())
                ast.printraw(e)
            end
            if e:is "literal" then
                return e
            elseif e:is "var" then
                local v = env:combinedenv()[e.name]
                if v == nil then
                    diag:reporterror(e,"variable '"..e.name.."' not found")
                    return e:aserror()
                end
                return asterraexpression(e,v, location)
            elseif e:is "quote" then
                return e.tree -- already checked tree, quotes get injected directly into some untyped trees by macros
            elseif e:is "selectu" then
                local v = checkexp(e.value,"luavalue")
                local f = checklabel(e.field,true)
                local field = f.value
            
                if v:is "luaobject" then -- handle A.B where A is a luatable or type
                    --check for and handle Type.staticmethod
                    if types.istype(v.value) and v.value:isstruct() then
                        local fnlike, errmsg = v.value:getmethod(field)
                        if not fnlike then
                            diag:reporterror(e,errmsg)
                            return e:aserror()
                        end
                        return asterraexpression(e,fnlike, location)
                    elseif type(v.value) ~= "table" then
                        diag:reporterror(e,"expected a table but found ", terra.type(v.value))
                        return e:aserror()
                    else
                        local selected = invokeuserfunction(e,"extracting field "..tostring(field),false,function() return v.value[field] end)
                        if selected == nil then
                            diag:reporterror(e,"no field ", field," in lua object")
                            return e:aserror()
                        end
                        return asterraexpression(e,selected,location)
                    end
                end
            
                if v.type:ispointertostruct() then --allow 1 implicit dereference
                    v = insertdereference(v)
                end

                if v.type:isstruct() then
                    local ret, success = insertselect(v,field)
                    if not success then
                        --struct has no member field, call metamethod __entrymissing
                        local typ = v.type
                    
                        local function checkmacro(metamethod,arguments,location)
                            local named = macros.internalmacro(function(ctx,tree,...)
                                return typ.metamethods[metamethod]:run(ctx,tree,field,...)
                            end)
                            local getter = asterraexpression(e, named, "luaobject") 
                            return checkcall(v, List{ getter }, arguments, "first", false, location)
                        end
                        if location == "lexpression" and typ.metamethods.__setentry then
                            local function setter(rhs)
                                return checkmacro("__setentry", List { v , rhs }, "statement")
                            end
                            return newobject(v,T.setteru,setter)
                        elseif macros.ismacro(typ.metamethods.__entrymissing) then
                            return checkmacro("__entrymissing",List { v },location)
                        else
                            diag:reporterror(v,"no field ",field," in terra object of type ",v.type)
                            return e:aserror()
                        end
                    else
                        return ret
                    end
                else
                    diag:reporterror(v,"expected a structural type")
                    return e:aserror()
                end
            elseif e:is "luaexpression" then
                return checkluaexpression(e,location)
            elseif e:is "operator" then
                return checkoperator(e)
            elseif e:is "cast" then -- inserted by global to force a cast in the initializer
                return insertcast(checkexp(e.expression), e.to)
            elseif e:is "index" then
                local v = checkexp(e.value)
                local idx = checkexp(e.index)
                local typ,lvalue = types.error, v.type:ispointer() or (v.type:isarray() and v.lvalue) 
                if v.type:ispointer() or v.type:isarray() or v.type:isvector() then
                    typ = v.type.type
                    if not idx.type:isintegral() and idx.type ~= types.error then
                        diag:reporterror(e,"expected integral index but found ",idx.type)
                    end
                    if v.type:isarray() then
                        v = insertcast(v,types.pointer(typ))
                    end
                else
                    if v.type ~= types.error then
                        diag:reporterror(e,"expected an array or pointer but found ",v.type)
                    end
                end
                return e:copy { value = v, index = idx }:withtype(typ):setlvalue(lvalue)
            elseif e:is "sizeof" then
                e.oftype:tcomplete(e)
                return e:copy{}:withtype(types.uint64)
            elseif e:is "vectorconstructor" or e:is "arrayconstructor" then
                local entries = checkexpressions(e.expressions)
                local N = #entries
                     
                local typ
                if e.oftype ~= nil then
                    typ = e.oftype:tcomplete(e)
                else
                    if N == 0 then
                        diag:reporterror(e,"cannot determine type of empty aggregate")
                        return e:aserror()
                    end
                
                    --figure out what type this vector has
                    typ = entries[1].type
                    for i,e2 in ipairs(entries) do
                        typ = typemeet(e,typ,e2.type)
                    end
                end
            
                local aggtype
                if e:is "vectorconstructor" then
                    if not typ:isprimitive() and typ ~= types.error then
                        diag:reporterror(e,"vectors must be composed of primitive types (for now...) but found type ",terra.type(typ))
                        return e:aserror()
                    end
                    aggtype = types.vector(typ,N)
                else
                    aggtype = types.array(typ,N)
                end
            
                --insert the casts to the right type in the parameter list
                local typs = entries:map(function(x) return typ end)
                entries = insertcasts(e,typs,entries)
                return e:copy { expressions = entries }:withtype(aggtype)
            elseif e:is "attrload" then
                local addr = checkexp(e.address)
                if not addr.type:ispointer() then
                    diag:reporterror(e,"address must be a pointer but found ",addr.type)
                    return e:aserror()
                end
                return e:copy { address = addr }:withtype(addr.type.type)
            elseif e:is "attrstore" then
                local addr = checkexp(e.address)
                if not addr.type:ispointer() then
                    diag:reporterror(e,"address must be a pointer but found ",addr.type)
                    return e:aserror()
                end
                local value = insertcast(checkexp(e.value),addr.type.type)
                return e:copy { address = addr, value = value }:withtype(types.unit)
            elseif e:is "fence" then
                return e:copy{}:withtype(types.unit)
            elseif e:is "cmpxchg" then
                local addr = checkexp(e.address)
                if not addr.type:ispointer() then
                    diag:reporterror(e,"address must be a pointer but found ",addr.type)
                    return e:aserror()
                end
                if not (addr.type.type:isintegral() or addr.type.type:ispointer()) then
                  diag:reporterror(e,"for cmpxchg address must be a pointer to an integral or pointer type, but found ", addr.type.type)
                  return e:aserror()
                end
                local cmp = insertcast(checkexp(e.cmp),addr.type.type)
                local new = insertcast(checkexp(e.new),addr.type.type)
                return e:copy { address = addr, cmp = cmp, new = new }:withtype(types.tuple(addr.type.type, bool))
            elseif e:is "atomicrmw" then
                local addr = checkexp(e.address)
                if not addr.type:ispointer() then
                    diag:reporterror(e,"address must be a pointer but found ",addr.type)
                    return e:aserror()
                end
                if e.operator == "xchg" then
                  if not (addr.type.type:isintegral() or addr.type.type:isfloat()) then
                    diag:reporterror(e,"for operator " .. e.operator .. " address must be a pointer to an integral or floating point type, but found ", addr.type.type)
                    return e:aserror()
                  end
                elseif e.operator == "fadd" or e.operator == "fsub" or e.operator == "fmax" or e.operator == "fmin" then
                  if not addr.type.type:isfloat() then
                    diag:reporterror(e,"for operator " .. e.operator .. " address must be a pointer to a floating point type, but found ", addr.type.type)
                    return e:aserror()
                  end
                else
                  if not (addr.type.type:isintegral() or addr.type.type:ispointer()) then
                    diag:reporterror(e,"for operator " .. e.operator .. " address must be a pointer to an integral or pointer type, but found ", addr.type.type)
                    return e:aserror()
                  end
                end
                local value = insertcast(checkexp(e.value),addr.type.type)
                return e:copy { address = addr, value = value }:withtype(addr.type.type)
            elseif e:is "apply" then
                return checkapply(e,location)
            elseif e:is "method" then
                return checkmethod(e,location)
            elseif e:is "letin" then
                local ns = checkstmts(e.statements)
                local ne = checkexpressions(e.expressions)
                if e.hasstatements then
                    --in case of statements check for dtors of managed variables
                    ns = checkraiidtors(e, ns, ne)
                end
                return createlet(e,ns,ne,e.hasstatements)
           elseif e:is "constructoru" then
                local paramlist = List()
                local named = 0
                for i,f in ipairs(e.records) do
                    local value = checkexp(f.value)
                    named = named + (f.key and 1 or 0)
                    if not f.key and value:is "letin" and not value.hasstatements then
                        paramlist:insertall(value.expressions)
                    else
                        paramlist:insert(value)
                    end
                end
                local typ = types.error
                if named == 0 then
                    typ = types.tuple(unpack(paramlist:map("type")))
                elseif named == #e.records then
                    typ = types.newstructwithanchor("anon",e)
                    typ:setconvertible("named")
                    for i,e in ipairs(e.records) do
                        typ.entries:insert({field = checklabel(e.key,true).value, type = paramlist[i].type})
                    end
                else
                    diag:reporterror(e, "some entries in constructor are named while others are not")
                end
                return newobject(e,T.constructor,paramlist):withtype(typ:tcomplete(e))
            elseif e:is "inlineasm" then
                return e:copy { arguments = checkexpressions(e.arguments) }
            elseif e:is "debuginfo" then
                return e:copy{}:withtype(types.unit)
            else
                diag:reporterror(e,"statement found where an expression is expected ", e.kind)
                return e:aserror()
            end
        end
    
        local result = docheck(e_)
        --freeze all types returned by the expression (or list of expressions)
        if not result:is "luaobject" and not result:is "setteru" then
            assert(types.istype(result.type))
            result.type:tcomplete(result)
        end

        --remove any lua objects if they are not allowed in this context
        if location ~= "luavalue" then
            result = removeluaobject(result)
        end
    
        return result
    end

    --helper functions used in checking statements:

    local function checkexptyp(re,target)
        local e = checkexp(re)
        if e.type ~= target then
            diag:reporterror(e,"expected a ",target," expression but found ",e.type)
            e.type = types.error
        end
        return e
    end
    local function checkcond(c)
        return checkexptyp(c,types.bool)
    end
    local function checkcondbranch(s)
        local e = checkcond(s.condition)
        local body = checkblock(s.body)
        return ast.copyobject(s,{condition = e, body = body})
    end
    local function checkexpintegral(re)
        local e = checkexp(re)
        if not e.type:isintegral() then
            diag:reporterror(e,"expected an integral expression but found ",e.type)
            e.type = types.error
        end
        return e
    end
    local function checkcasebranch(s)
        local e = checkexpintegral(s.condition)
        local body = checkblock(s.body)
        return ast.copyobject(s,{condition = e, body = body})
    end

    local function checkformalparameterlist(paramlist, requiretypes)
        local evalparams = evaluateparameterlist(diag,env:combinedenv(),paramlist,requiretypes)
        local result = List()
        for i,p in ipairs(evalparams) do
            if p.isnamed then
                local lenv = env:localenv()
                local queue = env:queue()
                if rawget(lenv,p.name) then
                    diag:reporterror(p,"duplicate definition of variable ",p.name)
                end
                lenv[p.name] = p.symbol
                queue[#queue+1] = p.name
            end
            local r = newobject(p,T.allocvar,p.name,p.symbol)
            if p.type then
                r:withtype(p.type:tcomplete(p))
            end
            result:insert(r)
        end
        return result
    end

    local function createstatementlist(anchor,stmts)
        return newobject(anchor,T.letin, stmts, List {}, true):withtype(types.unit)
    end

    --divide assignment into regular assignments and copy assignments
    local function divideintoregularandmanagedassignment(anchor, lhs, rhs)
        local regular = {lhs = List(), rhs = List()}
        local byfcall = {lhs = List(), rhs = List()}
        for i=1,#lhs do
            local to, from = lhs[i], rhs[i]
            if from.assignment == "handle" then
                --we return a handle to the object, which does not invoke a __dtor
                to.symbol:sethandle(true)
                regular.rhs:insert(from)
                regular.lhs:insert(to)
            elseif (from.assignment~="move") and checkraiicopyassignment(anchor, from, to) or checkraiimoveassignment(anchor, from, to) then
                --add assignment by __copy call
                byfcall.rhs:insert(from)
                byfcall.lhs:insert(to)
            else
                --default to regular assignment
                regular.rhs:insert(from)
                regular.lhs:insert(to)
            end
        end
        if #byfcall.lhs>0 and #byfcall.lhs+#regular.lhs>1 then
            --__copy can potentially mutate left and right-handsides in an
            --assignment. So we prohibit assignments that may involve something
            --like a swap: u,v = v, u.
            --for now we prohibit this by limiting such assignments
            diag:reporterror(anchor, "assignments of managed objects is not supported for tuples.")
        end
        return regular, byfcall
    end

    --struct assignment pattern matching applies? true / false
    local function patterncanbematched(lhs, rhs)
        local last = rhs[#rhs]
        if last.type:isstruct() and last.type.convertible == "tuple" and #last.type.entries + #rhs - 1 == #lhs then
            return true
        end
        return false
    end

    local createregularassignment

    --try unpack struct and perform pattern match
    local function trystructpatternmatching(anchor, lhs, rhs)
        local last = rhs[#rhs]
        local av,v = allocvar(anchor,last.type,"<structpattern>")   --temporary variable "<structpattern>"
        local newlhs,lhsp,rhsp = List(),List(),List()
        for i,l in ipairs(lhs) do
            if i < #rhs then
                newlhs:insert(l)
            else
                lhsp:insert(l)
                rhsp:insert((insertselect(v,"_"..tostring(i - #rhs))))
            end
        end
        newlhs[#rhs] = av
        local a1 = createassignment(anchor, newlhs, rhs)            --potential managed assignment
        local a2 = createregularassignment(anchor, lhsp, rhsp)      --regular assignment - __copy and __dtor are possibly already called in 'a1'
        return createstatementlist(anchor, List {a1, a2})
    end

    local function createregularsingleassignment(anchor, lhs, rhs)
        local rhstype = rhs and rhs.type or types.error
        if lhs:is "setteru" then
            local rv,r = allocvar(lhs, rhstype,"<rhs>")
            lhs = newobject(lhs,T.setter, rv,lhs.setter(r))
        elseif lhs:is "allocvar" then
            lhs:settype(rhstype)
        else
            ensurelvalue(lhs)
        end
        return lhs, rhs
    end

    local function createunmanagedsingleassignment(anchor, stmts, lhs, rhs)
        local rhstype = rhs and rhs.type or types.error
        if lhs:is "setteru" then
            local rv,r = allocvar(lhs, rhstype,"<rhs>")
            lhs = newobject(lhs, T.setter, rv, lhs.setter(r))
        elseif lhs:is "allocvar" then
            lhs:settype(rhstype)
        else
            ensurelvalue(lhs)
            --if 'v' is a managed variable then
            --(1) var tmp = v       --store v in tmp
            --(2) v = rhs[i]        --perform assignment (will be done by the callee)
            --(3) tmp:__dtor()      --delete old v (will be a defered call)
            --the temporary is necessary because rhs[i] may involve a function of 'v'
            if ismanaged(lhs, "__dtor") then
                local tmpa, tmp = allocvar(lhs, lhs.type, "<tmp>")
                --store v in tmp
                stmts:insert(newobject(anchor,T.assignment, List{tmpa}, List{lhs}))
                --add defered destructor call - tmp:__dtor()
                stmts:insert(newobject(anchor, T.defer, checkraiimethodwithreceiver(anchor, tmp, "__dtor")))
            end
        end
        return lhs, rhs
    end

    local function createmanagedsingleassignment(anchor, stmts, lhs, rhs)
        local rhstype = rhs and rhs.type or types.error
        if lhs:is "setteru" then
            local rv,r = allocvar(lhs, rhstype,"<rhs>")
            local copyassignment = checkraiicopyassignment(anchor, rhs, r)
            if copyassignment then stmts:insert(copyassignment) end
            stmts:insert(newobject(lhs, T.setter, rv, lhs.setter(r)))
        elseif lhs:is "allocvar" then
            if not lhs.type then
                lhs:settype(rhstype)
            end
            stmts:insert(lhs)
            local init = checkraiimethodwithreceiver(anchor, lhs, "__init")
            if init then
                stmts:insert(init)
            end
            --insert copy-/move-assignment
            local cp = (rhs.assignment~="move") and checkraiicopyassignment(anchor, rhs, lhs) or checkraiimoveassignment(anchor, rhs, lhs)
            if cp then
                stmts:insert(cp)
            end
        else
            ensurelvalue(lhs)
            --apply copy/move assignment - memory resource management is in the
            --hands of the programmer
            --insert copy-/move-assignment
            local cp = (rhs.assignment~="move") and checkraiicopyassignment(anchor, rhs, lhs) or checkraiimoveassignment(anchor, rhs, lhs)
            if cp then stmts:insert(cp) end
        end
        return lhs, rhs
    end

    --create regular assignment - no managed types
    function createregularassignment(anchor,lhs,rhs)
        --special case where a rhs struct is unpacked
        if #lhs > #rhs and #rhs > 0 then
            if patterncanbematched(lhs, rhs) then
                return trystructpatternmatching(anchor, lhs, rhs)
            end
        end
        --if #lhs~=#rhs an error may be reported later during type-checking:
        --'expected #lhs parameters (...), but found #rhs (...)'
        local vtypes = lhs:map(function(v) return v.type or "passthrough" end)
        rhs = insertcasts(anchor,vtypes,rhs)
        for i,v in ipairs(lhs) do
            lhs[i], rhs[i] = createregularsingleassignment(anchor, v, rhs[i])
        end
        return newobject(anchor,T.assignment,lhs,rhs)
    end


    --create unmanaged/managed regular or copy assignments
    local function createmanagedassignment(anchor, lhs, rhs)
        --special case where a rhs struct is unpacked
        if #lhs > #rhs and #rhs > 0 then
            if patterncanbematched(lhs, rhs) then
                return trystructpatternmatching(anchor, lhs, rhs)
            end
        end
        --sanity check
        assert(#lhs == #rhs)
        --standard case #lhs == #rhs
        local stmts, post = List(), List()
        --first take care of regular assignments
        local regular, byfcall = divideintoregularandmanagedassignment(anchor, lhs, rhs)
        local vtypes = regular.lhs:map(function(v) return v.type or "passthrough" end)
        regular.rhs = insertcasts(anchor, vtypes, regular.rhs)
        --take care of regular assignments of managed variables
        for i,v in ipairs(regular.lhs) do
            regular.lhs[i], regular.rhs[i] = createunmanagedsingleassignment(anchor, stmts, v, regular.rhs[i])
        end
        --take care of copy assignments using methods.__copy
        for i,v in ipairs(byfcall.lhs) do
            byfcall.lhs[i], byfcall.rhs[i] = createmanagedsingleassignment(anchor, stmts, v, byfcall.rhs[i])
        end
        if #stmts==0 then
            --standard case, no meta-copy-assignments
            return newobject(anchor,T.assignment, regular.lhs, regular.rhs)
        else
            --managed case using meta-copy-assignments
            --the calls to `__copy` are in `stmts`
            if #regular.lhs>0 then
                stmts:insert(newobject(anchor,T.assignment, regular.lhs, regular.rhs))
            end
            return createstatementlist(anchor, stmts)
        end
    end

    --create assignment - regular / copy assignment
    function createassignment(anchor, lhs, rhs)
        if not terralib.ext or #lhs < #rhs then
            --regular assignment - __init, __copy and __dtor will not be scheduled
            return createregularassignment(anchor, lhs, rhs)
        else
            --managed assignment - __init, __copy and __dtor are scheduled for managed
            --variables
            return createmanagedassignment(anchor, lhs, rhs)
        end
    end

    --check block statements and generate and typecheck raii __dtor's
    function checkblock(s)
        env:enterblock()
        local stats = checkraiidtors(s, checkstmts(s.statements))
        env:leaveblock()
        return s:copy {statements = stats}
    end

    function checkstmts(stmts)
        local function checksingle(s)
            if s:is "block" then
                return checkblock(s)
            elseif s:is "returnstat" then
                return s:copy { expression = checkexp(s.expression)}
            elseif s:is "label" or s:is "gotostat" then    
                local ss = checklabel(s.label)
                return ast.copyobject(s, { label = ss })
            elseif s:is "breakstat" then
                return s
            elseif s:is "whilestat" then
                return checkcondbranch(s)
            elseif s:is "fornumu" then
                local initial, limit, step = checkexp(s.initial), checkexp(s.limit), s.step and checkexp(s.step)
                local t = typemeet(initial,initial.type,limit.type) 
                t = step and typemeet(limit,t,step.type) or t
                local variables = checkformalparameterlist(List {s.variable },false)
                if #variables ~= 1 then
                    diag:reporterror(s.variable, "expected a single iteration variable but found ",#variables)
                    return s
                end
                local variable = variables[1]
                variable:settype(variable.type or t)
                if not variable.type:isintegral() then diag:reporterror(variable,"expected an integral type for loop initialization but found ",variable.type) end
                initial,step,limit = insertcast(initial,variable.type), step and insertcast(step,variable.type), insertcast(limit,variable.type)
                local body = checkblock(s.body)
                return newobject(s,T.fornum,variable,initial,limit,step,body)
            elseif s:is "forlist" then
                local iterator = checkexp(s.iterator)
            
                local typ = iterator.type
                if typ:ispointertostruct() then
                    typ,iterator = typ.type, insertdereference(iterator)
                end
                if not typ:isstruct() or type(typ.metamethods.__for) ~= "function" then
                    diag:reporterror(iterator,"expected a struct with a __for metamethod but found ",typ)
                    return s
                end
                local generator = typ.metamethods.__for
            
                local function bodycallback(...)
                    local exps = List()
                    for i = 1,select("#",...) do
                        local v = select(i,...)
                        exps:insert(asterraexpression(s,v))
                    end
                    env:enterblock()
                    local variables = checkformalparameterlist(s.variables,false)
                    local assign = createassignment(s,variables,exps)
                    local body = checkblock(s.body)
                    env:leaveblock()
                    local stats = createstatementlist(s, List { assign, body })
                    return quotes.newquote(stats)
                end
            
                local value = invokeuserfunction(s, "invoking __for", false ,generator,ast.newquote(iterator), bodycallback)
                return asterraexpression(s,value,"statement")
            elseif s:is "ifstat" then
                local br = s.branches:map(checkcondbranch)
                local els = (s.orelse and checkblock(s.orelse))
                return s:copy{ branches = br, orelse = els }
            elseif s:is "switchstat" then
                local cond = checkexpintegral(s.condition)
                local br = checkstmts(s.cases)
                local def = (s.ordefault and checkblock(s.ordefault))
                return s:copy{ condition = cond, cases = br, ordefault = def }
            elseif s:is "switchcase" then
                local cond = checkexpintegral(s.condition)
                local body = checkblock(s.body)
                return s:copy{ condition = cond, body = body }
            elseif s:is "repeatstat" then
                local stmts = checkstmts(s.statements)
                local e = checkcond(s.condition)
                return s:copy { statements = stmts, condition = e }
            elseif s:is "defvar" then
                local rhs = s.hasinit and checkexpressions(s.initializers)
                local lhs = checkformalparameterlist(s.variables, not s.hasinit)
                if s.hasinit then
                    return createassignment(s,lhs,rhs)
                else
                    local res = createstatementlist(s,lhs)
                    local ini = checkraiiinitializers(s, lhs)
                    if ini then
                        res.statements:insertall(ini)
                    end
                    return res
                end
            elseif s:is "assignment" then
                local rhs = checkexpressions(s.rhs)
                local lhs = checkexpressions(s.lhs,"lexpression")
                return createassignment(s,lhs,rhs)
            elseif s:is "apply" then
                return checkapply(s,"statement")
            elseif s:is "method" then
                return checkmethod(s,"statement")
            elseif s:is "defer" then
                local call = checkexp(s.expression)
                if not call:is "apply" then
                    diag:reporterror(s.expression,"deferred statement must resolve to a function call")
                end
                return s:copy { expression = call }
            else
                return checkexp(s,"statement")
            end
            error("NYI - "..s.kind,2)
        end
        local newstats = List()
        local function addstat(s)
            if s.kind == "letin" then --let blocks are collapsed into surrounding scope
                newstats:insertall(s.statements)
                newstats:insertall(s.expressions)
            else
                newstats:insert(s)
            end
        end 
        for _,s in ipairs(stmts) do
            local r = checksingle(s)
            if r.kind == "statlist" then -- lists of statements are spliced directly into the list
                for _,rr in ipairs(r.statements) do
                    addstat(rr)
                end
            else addstat(r) end
        end
        return newstats
    end
    local function checkreturns(body,returntype)
        local returnstats = List()
        local function copytree(tree,newfields)
            local r = ast.copyobject(tree,newfields)
            r.type,r.lvalue = tree.type,tree.lvalue
            return r
        end
        local visitlist,visittree,visit
        function visitlist(list)
            local newlist --created when the first change is found
            for i,e in ipairs(list) do
                local ee = visittree(e)
                if not newlist and e ~= ee then
                    newlist = List()
                    for j = 1,i-1 do
                        newlist[j] = list[j]
                    end
                end
                if newlist then
                    newlist[i] = ee
                end
            end
            return newlist or list
        end
        function visittree(tree)
            if T.returnstat:isclassof(tree) then
                local rs = ast.copyobject(tree, {expression = visit(tree.expression) }) -- copy will be mutated later to insert casts
                returnstats:insert(rs)
                return rs
            end
            local newfields
            for _,f in ipairs(tree.__fields) do
                local field = tree[f.name]
                local newfield = visit(field)
                if newfield ~= field then
                    if not newfields then
                        newfields = {}
                    end
                    newfields[f.name] = newfield
                end
            end
            return newfields and copytree(tree,newfields) or tree
        end
        function visit(tree)
            if List:isclassof(tree) then
                return visitlist(tree)
            elseif T.tree:isclassof(tree) then
                return visittree(tree)
            end
            return tree
        end
        local newbody = visit(body)
        assert(#returnstats == 0 and newbody == body or #returnstats > 0 and newbody ~= body)
        if not returntype then
            if #returnstats == 0 then
                returntype = types.unit
            else
                returntype = returnstats[1].expression.type
                for i = 2,#returnstats do
                    local rs = returnstats[i]
                    returntype = typemeet(rs.expression,returntype,rs.expression.type)
                end
            end
            assert(returntype)
        end
        for _,rs in ipairs(returnstats) do
            rs.expression = insertcast(rs.expression,returntype) -- mutation is safe because we just made a unique copy of any parents
        end
        return newbody, returntype
    end

    local result
    if topexp:is "functiondefu" then
        env.isfundef = true
        local typed_parameters = checkformalparameterlist(topexp.parameters, true)
        local parameter_types = typed_parameters:map("type")
        local body,returntype = checkreturns(checkblock(topexp.body),topexp.returntype)
 
        local fntype = types.functype(parameter_types,returntype,topexp.is_varargs):tcompletefunction(topexp)
        diag:finishandabortiferrors("Errors reported during typechecking.",2)
        local labeldepths,globalsused = semanticcheck(diag,typed_parameters,body)
        result = newobject(topexp,T.functiondef,nil,fntype,typed_parameters,topexp.is_varargs, body, labeldepths, globalsused)
    else
        result = checkexp(topexp)
    end
    diag:finishandabortiferrors("Errors reported during typechecking.",2)
    return result
end

-- ==========================================
-- CONSTANT & QUOTE HELPERS
-- ==========================================
local function newquote(tree)
    -- Creates a quote object exactly how Terra's macro system expects it
    local q = ast.newobject(tree, T.quote, tree)
    function q:gettype() return tree.type end
    return q
end

local function build_constant(typ, init)
    if typ ~= nil and not types.istype(typ) then 
        typ, init = nil, typ
    end
    
    if typ == nil then 
        if type(init) == "number" then
            typ = (math.floor(init) == init and types.int32) or types.double
        elseif type(init) == "boolean" then
            typ = types.bool
        elseif type(init) == "string" then
            typ = types.rawstring
        elseif T.quote:isclassof(init) then
            typ = init:gettype()
        else
            -- Note: We dropped cdata/typeof inference because we don't have FFI type mapping anymore
            error("constant constructor requires explicit type for objects of type " .. terra_type(init))
        end
    end
    
    if init == nil or T.quote:isclassof(init) then 
        -- Replace LLVM terra.global allocation with the pure ASDL node
        return T.globalvariable(nil, 0, false, true, typ)
    end
    
    local anchor = ast.newanchor(2)
    
    if type(init) == "string" and typ == types.rawstring then
        return newquote(ast.newobject(anchor, T.literal, init, typ))
    end
    
    -- If it's not an aggregate, return the standard constant quote
    if not typ:isaggregate() then
        -- Note: We skip the FFI terra.cast(typ, init) here because Lua numbers/bools 
        -- are perfectly fine for the LSP's semantic pass.
        return newquote(ast.newobject(anchor, T.constant, init, typ))
    end 
    
    -- LSP SAFE FALLBACK FOR AGGREGATES:
    -- Instead of packing raw memory into an FFI string, we just return a dummy
    -- constructor node of the correct type so the typechecker doesn't panic.
    local tree = ast.newobject(anchor, T.constructor, List{}):withtype(typ)
    return newquote(tree)
end

local function isconstant(obj)
    if T.globalvariable:isclassof(obj) then return obj.constant
    elseif T.quote:isclassof(obj) then return obj.tree.kind == "literal" or obj.tree.kind == "constant"
    else return false end
end

-- Export to globals for extensions
_G["constant"] = build_constant
_G.terralib.isconstant = isconstant

_G["operator"] = macros.internalmacro(function(diag,anchor,op,...)
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

return {
    typecheck = typecheck
}