-- Add the local lua directory to the search path so requires work from the C++ host
package.path = _G.LSP_ROOT .. "/?.lua;" .. package.path
require("lua.mobdebug").start()

local ffi = require("ffi")
local uv = require("luv")

-- ==========================================
-- 1. IMPORT SUB-MODULES
-- ==========================================
local asdl = require("lua.asdl")
local TS = require("lua.ts_ffi")
local ast_lowerer = require("lua.ast_lower")
local macros = require("lua.macros")
local quotes = require("lua.quotes")
local functions = require("lua.functions")
local ast = require("lua.ast")
local types_module = require("lua.types")

local T = ast.T
local types = types_module.types

pcall(function() ffi.cdef[[ char *ts_node_string(TSNode node); ]] end)

-- ==========================================
-- 2. SETUP COMPATIBILITY LAYER
-- ==========================================
_G.terralib = {}
_G.terra = _G.terralib

_G.T = T
_G.newobject = ast.newobject
_G.newanchor = ast.newanchor
_G.List = asdl.List
_G.terralib.types = types
_G.terralib.newlist = asdl.List

-- Clean, silent macro execution
_G.invokeuserfunction = function(anchor, what, speculate, userfn, ...)
    if not speculate then return userfn(...) end
    return xpcall(userfn, debug.traceback, ...)
end

-- ==========================================
-- 3. APPLY CORE POLYFILLS
-- ==========================================

-- Type Resolvers
_G.terra.typeof = function(obj)
    if type(obj) ~= "cdata" then error("cannot get the type of a non cdata object") end
    return types.ctypetoterra[tonumber(ffi.typeof(obj))]
end

_G.terra.isglobalvar = function(obj)
    return T.globalvariable and T.globalvariable:isclassof(obj)
end

if T.globalvariable then
    function T.globalvariable:isextern() return self.extern end
    function T.globalvariable:isconstant() return self.constant end
end

-- Modular Polyfills
_G.terra.ismacro = macros.ismacro
_G.terra.isquote = quotes.isquote
_G.terra.newquote = quotes.newquote
_G.terra.isfunction = functions.isfunction
_G.terra.isoverloadedfunction = functions.isoverloadedfunction

-- ASDL Structure Polyfills
_G.terra.issymbol = function(obj) return T.Symbol and T.Symbol:isclassof(obj) end
_G.terra.istree = function(obj) return T.tree and T.tree:isclassof(obj) end
_G.terra.islist = function(l) return asdl.List:isclassof(l) end

_G.terra.type = function(t)
    if type(t) ~= "table" then return type(t) end
    if _G.terra.isfunction(t) then return "terrafunction"
    elseif types.istype and types.istype(t) then return "terratype"
    elseif _G.terra.ismacro(t) then return "terramacro"
    elseif _G.terra.isglobalvar(t) then return "terraglobalvariable"
    elseif _G.terra.isquote(t) then return "terraquote"
    elseif _G.terra.istree(t) then return "terratree"
    elseif _G.terra.islist(t) then return "list"
    elseif _G.terra.issymbol(t) then return "terrasymbol"
    elseif T.Label and T.Label:isclassof(t) then return "terralabel"
    elseif _G.terra.isoverloadedfunction(t) then return "overloadedterrafunction"
    else return type(t) end
end

-- Sync terralib globals
for k, v in pairs(_G.terra) do _G.terralib[k] = v end

-- ==========================================
-- 4. LOAD TYPECHECKER (MUST HAPPEN LAST)
-- ==========================================
local typechecker = require("lua.typechecker")

-- ==========================================
-- 5. ENGINE EXECUTION
-- ==========================================
local args = _G.arg or {}
print("========================================")
print("🚀 Terra Analyzer Boot Sequence Initiated")
print("========================================")

local parser = TS.parser_new()
if not parser then
    print("❌ Failed to initialize Tree-sitter parser.")
    os.exit(1)
end

TS.parser_set_language(parser, TS.terra_grammar())

local test_file_path = args[2] or "test.t" 
local file = io.open(test_file_path, "r")
if not file then
    print("❌ Failed to open file: " .. test_file_path)
    os.exit(1)
end

local source_code = file:read("*a")
file:close()

local tree = TS.parser_parse_string(parser, nil, source_code, #source_code)
if tree ~= nil then
    local root_node = TS.tree_root_node(tree)

    local cst_string = ffi.C.ts_node_string(root_node)
    print("🌳 RAW TREE-SITTER CST:")
    print(ffi.string(cst_string))
    io.flush()

    local child_count = TS.node_child_count(root_node)
    
    if child_count > 0 then
        local ASTEngine = ast_lowerer.create(TS, test_file_path)
        local LowerAST = ASTEngine.lower
        local module_env = setmetatable({}, { __index = _G })
        local functions_to_typecheck = {}
        
        print("\n========================================")
        print("🔍 PASS 1: HOISTING & AST LOWERING")
        print("========================================")
        
        for i = 0, child_count - 1 do
            local node = TS.node_child(root_node, i)
            local node_type = TS.safe_node_type(node)
            
            -- HOIST FUNCTIONS
            if node_type == "terra_function_implementation" then
                local name_node = TS.node_child_by_field_name(node, "name", 4)
                local func_name = nil
                
                if not ffi.C.ts_node_is_null(name_node) then
                    func_name = TS.get_node_text(name_node, source_code)
                    if type(func_name) == "cdata" then func_name = ffi.string(func_name) end
                end
                
                local my_lua_ast = LowerAST(node, source_code)
                
                if my_lua_ast and func_name then
                    print("✨ Hoisting function: " .. func_name)
                    local fn_obj = T.terrafunction(nil, func_name, types.placeholderfunction, my_lua_ast)
                    module_env[func_name] = fn_obj
                    
                    table.insert(functions_to_typecheck, {
                        name = func_name, 
                        ast = my_lua_ast, 
                        obj = fn_obj
                    })
                end
                
            -- HOIST STRUCTS
            elseif node_type == "struct_definition" or node_type == "struct_declaration" then
                local named_children = {}
                for j = 0, TS.node_child_count(node) - 1 do
                    local child = TS.node_child(node, j)
                    if ffi.C.ts_node_is_named(child) then
                        table.insert(named_children, child)
                    end
                end
                
                if #named_children >= 1 then
                    local struct_name = ffi.string(TS.get_node_text(named_children[1], source_code))
                    print("🏗️  Hoisting struct: " .. struct_name)
                    
                    local my_struct = types.newstruct(struct_name)
                    my_struct.entries = asdl.List()
                    
                    for j = 2, #named_children, 2 do
                        if j + 1 <= #named_children then
                            local f_name = ffi.string(TS.get_node_text(named_children[j], source_code))
                            local f_type_str = ffi.string(TS.get_node_text(named_children[j+1], source_code))
                            
                            local t_type = types[f_type_str] or types.int
                            my_struct.entries:insert({field = f_name, type = t_type})
                        end
                    end
                    
                    module_env[struct_name] = my_struct
                end
            end
        end
        
        print("\n========================================")
        print("⚙️ PASS 2: LAZY TYPECHECKING")
        print("========================================")
        
        for k, v in pairs(module_env) do
            if T.terrafunction and T.terrafunction:isclassof(v) then
                print("📦 Mapped Function: " .. k)
            elseif types.istype and types.istype(v) and v:isstruct() then
                print("📦 Mapped Struct:   " .. k)
            end
        end
        print("----------------------------------------")
        
        for _, fn_data in ipairs(functions_to_typecheck) do
            -- Expose current environment to global scope for ast_lower.lua deferred evaluation
            _G.CURRENT_ENV = module_env 
            
            local status, typed_ast_or_err = pcall(typechecker.typecheck, fn_data.ast, module_env)
            
            if status then
                fn_data.obj:adddefinition(typed_ast_or_err)
                print("[ OK ] Typechecked: " .. fn_data.name)
            else
                print("[FAIL] Semantic Error in " .. fn_data.name .. ":")
                print(typed_ast_or_err)
            end
        end
    end
    TS.tree_delete(tree)
end
TS.parser_delete(parser)