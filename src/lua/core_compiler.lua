-- Add the local lua directory to the search path so requires work from the C++ host
package.path = "./lua/?.lua;" .. package.path

local ffi = require("ffi")
local uv = require("luv")

-- ==========================================
-- 1. IMPORT SUB-MODULES
-- ==========================================
local asdl = require("lua.asdl")
local TS = require("lua.ts_ffi")            -- Our new Tree-sitter C-API module
local ast_lowerer = require("lua.ast_lower")-- Our new Visitor module

-- ==========================================
-- 2. COMPATIBILITY LAYER FOR EXTENSIONS
-- ==========================================
_G.terralib = {}
_G.terra = _G.terralib

-- A clean, LSP-safe polyfill for Terra's user function executor.
_G.invokeuserfunction = function(anchor, what, speculate, userfn, ...)
    if not speculate then return userfn(...) end
    return xpcall(userfn, debug.traceback, ...)
end

-- ==========================================
-- 3. IMPORT MODULAR COMPILER ENGINE
-- ==========================================
local ast = require("lua.ast")
local T = ast.T
local typechecker = require("lua.typechecker")
local environment = require("lua.environment")
local types_module = require("lua.types")
local types = types_module.types

-- ==========================================
-- 3.5 RESTORE MISSING GLOBALS FOR TYPECHECKER
-- ==========================================
_G.T = T
_G.newobject = ast.newobject
_G.newanchor = ast.newanchor
_G.List = asdl.List

_G.terralib.types = types
_G.terralib.newlist = asdl.List

-- ==========================================
-- 3.6 TERRA TYPE UTILITIES (LSP-Safe)
-- ==========================================
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

_G.terra.type = function(t)
    if type(t) ~= "table" then return type(t) end
    if _G.terra.isfunction and _G.terra.isfunction(t) then return "terrafunction"
    elseif types.istype and types.istype(t) then return "terratype"
    elseif _G.terra.ismacro and _G.terra.ismacro(t) then return "terramacro"
    elseif _G.terra.isglobalvar and _G.terra.isglobalvar(t) then return "terraglobalvariable"
    elseif _G.terra.isquote and _G.terra.isquote(t) then return "terraquote"
    elseif ast.istree and ast.istree(t) then return "terratree"
    elseif asdl.islist and asdl.islist(t) then return "list"
    elseif _G.terra.issymbol and _G.terra.issymbol(t) then return "terrasymbol"
    elseif _G.terra.islabel and _G.terra.islabel(t) then return "terralabel"
    elseif _G.terra.isoverloadedfunction and _G.terra.isoverloadedfunction(t) then return "overloadedterrafunction"
    else return type(t) end
end

-- ==========================================
-- 4. GRAB ARGUMENTS & PRINT INFO
-- ==========================================
local args = _G.arg or {}
print("========================================")
print("🚀 Terra Analyzer Boot Sequence Initiated")
print("========================================")

for i, v in ipairs(args) do print("Arg [" .. i .. "]: " .. v) end
print("\n[System Info]")
print("Luv Version: " .. uv.version_string())
print("Resident Set Size: " .. math.floor(uv.resident_set_memory() / 1024 / 1024) .. " MB")
print("\n[Tree-sitter FFI Initialization]")

-- Initialize our Lowering Architecture
local ASTEngine = ast_lowerer.create(TS)
local LowerAST = ASTEngine.lower

-- ==========================================
-- 5. ENGINE EXECUTION
-- ==========================================
local parser = TS.parser_new()

if parser ~= nil then
    print("✅ Tree-sitter parser successfully allocated via memory pointers!")
    local success = TS.parser_set_language(parser, TS.terra_grammar())

    if success then
        print("✅ Terra grammar successfully loaded and attached!")

        local test_file_path = "test.t"
        local file = io.open(test_file_path, "r")
        if not file then
            print("❌ Failed to open file: " .. test_file_path)
            os.exit(1)
        end

        local source_code = file:read("*a")
        file:close()

        print("Parsing file: " .. test_file_path)
        print("----------------------------------------\n" .. source_code .. "\n----------------------------------------")

        local tree = TS.parser_parse_string(parser, nil, source_code, #source_code)

        if tree ~= nil then
            local root_node = TS.tree_root_node(tree)
            local cst_string_ptr = TS.node_string(root_node)

            print("\n[Parsed CST]")
            print(ffi.string(cst_string_ptr))

            -- --- AST LOWERING STEP ---
            local child_count = TS.node_child_count(root_node)

            if child_count > 0 then
                local root_env = environment.newenvironment()

                ASTEngine.clear_diagnostics()

                for i = 0, child_count - 1 do
                    local node = TS.node_child(root_node, i)
                    local node_type = TS.safe_node_type(node)

                    if node_type == "terra_function_implementation" then
                        print("\n========================================")
                        print("⚙️ Lowering Function #" .. (i+1))
                        print("========================================")

                        local my_lua_ast = LowerAST(node, source_code)

                        if my_lua_ast then
                            print("--- UNTYPED AST ---")
                            my_lua_ast:printraw()

                            print("\n--- TYPECHECKING ---")
                            local status, typed_ast_or_err = pcall(typechecker.typecheck, my_lua_ast, root_env)

                            if status then
                                print("\n--- TYPED AST ---")
                                if typed_ast_or_err.printraw then
                                    typed_ast_or_err:printraw()
                                else
                                    print(tostring(typed_ast_or_err))
                                end
                            else
                                print("\n[Semantic Error Caught by LSP]")
                                print(typed_ast_or_err)
                            end
                        else
                            print("\n❌ Failed to lower AST for Function #" .. (i+1))
                        end
                    end
                end

                local diags = ASTEngine.get_diagnostics()
                if #diags > 0 then
                    print("\n🚨 [SYNTAX ERRORS CAUGHT FOR LSP]")
                    for _, diag in ipairs(diags) do
                        print("- " .. diag.message .. " (Bytes: " .. diag.start_byte .. "-" .. diag.end_byte .. ")")
                    end
                end
            end

            -- Clean up memory
            TS.free(cst_string_ptr)
            TS.tree_delete(tree)
        else
            print("❌ Failed to parse source code.")
        end
    else
        print("❌ Failed to attach Terra grammar to parser.")
    end

    TS.parser_delete(parser)
else
    print("❌ Failed to allocate Tree-sitter parser.")
end