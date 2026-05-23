-- lua/compiler/core_compiler.lua
package.path = _G.LSP_ROOT .. "/lua/?.lua;" .. _G.LSP_ROOT .. "/lua/?/init.lua;" .. package.path
-- require("mobdebug").start()

local ffi = require("ffi")
local uv = require("luv")

-- 1. BOOTSTRAP UNIFIED NAMESPACE
local terra = require("init")
local TS = require("compiler.parser.ts_ffi")
local ast_lowerer = require("compiler.parser.ast_lower")

pcall(function() ffi.cdef[[ char *ts_node_string(TSNode node); ]] end)

-- ==========================================
-- 2. ENGINE EXECUTION OR LSP BOOT
-- ==========================================
local args = _G.arg or {}

local is_lsp = false
for _, v in ipairs(args) do
    if v == "--lsp" then is_lsp = true end
end

-- If the user passed "--lsp", boot the server!
if is_lsp then
    local server = require("lsp.core.server")
    server.start()
    os.exit(0)
end

-- Otherwise, run in CLI Test Mode
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
        
        local fmt = ""
        local define_args = {}
        
        for i = 0, child_count - 1 do
            local node = TS.node_child(root_node, i)
            local node_type = TS.safe_node_type(node)
            
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
                            
                            local expr = terra.newobject(anchor, terra.T.luaexpression, function() 
                                return _G.CURRENT_ENV[f_type_str] or terra.types[f_type_str] 
                            end, true)
                            
                            entries:insert(terra.T.structentry(f_name, expr))
                        end
                    end
                    
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
        
        _G.CURRENT_ENV = module_env 
        
        local status, err = pcall(function()
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


local args = _G.arg or {}

if #args == 0 or args[1] == "--lsp" then
    local server = require("lsp.core.server")
    server.start()
    os.exit(0)
end