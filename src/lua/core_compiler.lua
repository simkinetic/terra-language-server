-- Add the local lua directory to the search path so requires work from the C++ host
package.path = _G.LSP_ROOT .. "/?.lua;" .. package.path
require("lua.mobdebug").start()

local ffi = require("ffi")
local uv = require("luv")

-- ==========================================
-- 1. BOOTSTRAP UNIFIED NAMESPACE
-- ==========================================
-- This completely replaces the old requires, compatibility layer, and polyfills.
local terra = require("lua.init")
local TS = require("lua.ts_ffi")
local ast_lowerer = require("lua.ast_lower")

pcall(function() ffi.cdef[[ char *ts_node_string(TSNode node); ]] end)

-- ==========================================
-- 2. ENGINE EXECUTION
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
        
        print("\n========================================")
        print("🔍 PASS 1: TREE-SITTER COLLECTION")
        print("========================================")
        
        -- We no longer typecheck manually! We build the format string and arguments 
        -- for terra.defineobjects, just like the real compiler.
        local fmt = ""
        local define_args = {}
        
        for i = 0, child_count - 1 do
            local node = TS.node_child(root_node, i)
            local node_type = TS.safe_node_type(node)
            
            -- EXTRACT LUA MACROS
            if node_type == "local_declaration" or node_type == "function_declaration" then
                local func_node = node
                if node_type == "local_declaration" then
                    for j = 0, TS.node_child_count(node) - 1 do
                        local child = TS.node_child(node, j)
                        if TS.safe_node_type(child) == "function_declaration" then
                            func_node = child
                            break
                        end
                    end
                end
                
                if TS.safe_node_type(func_node) == "function_declaration" then
                    local name_node = TS.node_child_by_field_name(func_node, "name", 4)
                    if not ffi.C.ts_node_is_null(name_node) then
                        local func_name = ffi.string(TS.get_node_text(name_node, source_code))
                        local start_byte = TS.node_start_byte(node)
                        local end_byte = TS.node_end_byte(node)
                        local macro_code = string.sub(source_code, start_byte + 1, end_byte)
                        
                        local chunk = loadstring(macro_code .. "\nreturn " .. func_name)
                        if chunk then
                            setfenv(chunk, module_env)
                            local status, macro_fn = pcall(chunk)
                            if status and type(macro_fn) == "function" then
                                print("🧠 Extracted Lua Macro: " .. func_name)
                                module_env[func_name] = macro_fn
                            end
                        end
                    end
                end
                
            -- EXTRACT TERRA FUNCTIONS
            elseif node_type == "terra_function_implementation" then
                local name_node = TS.node_child_by_field_name(node, "name", 4)
                if not ffi.C.ts_node_is_null(name_node) then
                    local func_name = ffi.string(TS.get_node_text(name_node, source_code))
                    local my_lua_ast = LowerAST(node, source_code)
                    
                    if my_lua_ast then
                        print("✨ Collected function: " .. func_name)
                        fmt = fmt .. "f"
                        table.insert(define_args, func_name)
                        table.insert(define_args, my_lua_ast)
                    end
                end
                
            -- EXTRACT STRUCTS
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
                    print("🏗️  Collected struct: " .. struct_name)
                    
                    local entries = terra.asdl.List()
                    local anchor = terra.newanchor(1, 1, test_file_path)
                    
                    for j = 2, #named_children, 2 do
                        if j + 1 <= #named_children then
                            local f_name = ffi.string(TS.get_node_text(named_children[j], source_code))
                            local f_type_str = ffi.string(TS.get_node_text(named_children[j+1], source_code))
                            
                            -- The typechecker expects field types to be Lua expressions it can evaluate!
                            local expr = terra.newobject(anchor, terra.T.luaexpression, function() 
                                return _G.CURRENT_ENV[f_type_str] or terra.types[f_type_str] 
                            end, true)
                            
                            entries:insert(terra.T.structentry(f_name, expr))
                        end
                    end
                    
                    -- ASDL: structdef = (luaexpression? metatype, structlist records)
                    local my_struct_ast = terra.newobject(anchor, terra.T.structdef, nil, terra.T.structlist(entries))
                    
                    fmt = fmt .. "s"
                    table.insert(define_args, struct_name)
                    table.insert(define_args, my_struct_ast)
                end
            end
        end
        
        print("\n========================================")
        print("⚙️ PASS 2: NATIVE TYPECHECKING (defineobjects)")
        print("========================================")
        
        -- Expose environment for ast_lower deferred evaluations
        _G.CURRENT_ENV = module_env 
        
        local status, err = pcall(function()
            -- We let Terra's robust native architecture take the wheel!
            _G.terra.defineobjects(fmt, function() return module_env end, unpack(define_args))
        end)
        
        if status then
            print("[ OK ] Module Typechecked Successfully!")
        else
            print("[FAIL] Semantic Error During Execution:")
            print(err)
        end
        
    end
    TS.tree_delete(tree)
end
TS.parser_delete(parser)