-- src/lua/lsp/core/server.lua
local uv = require("luv")

-- Reroute all print() calls to stderr so they don't corrupt the JSON-RPC stream
_G.print = function(...)
    local args = {...}
    local str = {}
    for i, v in ipairs(args) do table.insert(str, tostring(v)) end
    io.stderr:write("[Terra Compiler] " .. table.concat(str, "\t") .. "\n")
    io.stderr:flush()
end

local rpc = require("lsp.core.rpc")
local TS = require("compiler.parser.ts_ffi")
local ffi = require("ffi") 

local server = {}
local handlers = {}

-- ==========================================
-- Coordinate Math Helpers (LSP to Bytes)
-- ==========================================
local function get_byte_offset(text, target_line, target_char)
    local current_line = 0
    local byte_offset = 0
    for line_text in text:gmatch("([^\n]*\n?)") do
        if current_line == target_line then
            return byte_offset + target_char
        end
        byte_offset = byte_offset + #line_text
        current_line = current_line + 1
    end
    return byte_offset
end

local function count_newlines(str)
    local count = 0
    for _ in str:gmatch("\n") do count = count + 1 end
    return count
end

local function get_last_line_length(str)
    local last_newline = str:match(".*()\n")
    return last_newline and (#str - last_newline) or #str
end

local function byte_to_position(text, byte_offset)
    if not byte_offset then return { line = 0, character = 0 } end
    local prefix = text:sub(1, tonumber(byte_offset))
    local line = 0
    for _ in prefix:gmatch("\n") do line = line + 1 end
    local last_newline = prefix:match(".*()\n")
    local char = last_newline and (tonumber(byte_offset) - last_newline) or tonumber(byte_offset)
    return { line = line, character = char }
end

-- ==========================================
-- Initialize Engine & Memory Store
-- ==========================================
local parser = TS.parser_new()
if not parser then
    io.stderr:write("[Fatal] Failed to init Tree-sitter.\n")
    os.exit(1)
end
TS.parser_set_language(parser, TS.terra_grammar())

local documents = {}

-- ==========================================
-- LSP Compiler Imports
-- ==========================================
local diagnostics = require("compiler.semantics.diagnostics")
diagnostics.set_lsp_mode(true)

local ast_lowerer = require("compiler.parser.ast_lower")
local terra = require("init")

-- ADD THIS LINE BACK:
local typechecker = require("compiler.semantics.typechecker")

-- ==========================================
-- The LSP Compiler Pipeline
-- ==========================================
local function run_diagnostics_pipeline(uri, doc)
    diagnostics.pop_lsp_errors()

    local success, err = pcall(function()
        local root_node = TS.tree_root_node(doc.tree)
        local child_count = tonumber(TS.node_child_count(root_node))
        
        if child_count == 0 then return end
        
        local ASTEngine = ast_lowerer.create(TS, uri)
        local LowerAST = ASTEngine.lower
        local module_env = setmetatable({}, { __index = _G })
        
        local fmt = ""
        local define_args = {}
        
        -- PASS 1: Extraction
        io.stderr:write("[LSP] Starting Extraction. Root has " .. child_count .. " children.\n")
        io.stderr:flush()
        
        for i = 0, child_count - 1 do
            local node = TS.node_child(root_node, i)
            local node_type = TS.safe_node_type(node)
            
            io.stderr:write("[LSP]  -> Inspecting child " .. i .. " of type: '" .. node_type .. "'\n")
            io.stderr:flush()
            
            -- Functions & Local Macros
            if node_type == "local_declaration" or node_type == "function_declaration" then
                local func_node = node
                if node_type == "local_declaration" then
                    for j = 0, tonumber(TS.node_child_count(node)) - 1 do
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
                        local func_name = ffi.string(TS.get_node_text(name_node, doc.text))
                        local start_byte = tonumber(TS.node_start_byte(node))
                        local end_byte = tonumber(TS.node_end_byte(node))
                        local macro_code = string.sub(doc.text, start_byte + 1, end_byte)
                        
                        local chunk = loadstring(macro_code .. "\nreturn " .. func_name)
                        if chunk then
                            setfenv(chunk, module_env)
                            local status, macro_fn = pcall(chunk)
                            if status and type(macro_fn) == "function" then
                                module_env[func_name] = macro_fn
                            end
                        end
                    end
                end
                
            -- Terra Implementations
            elseif node_type == "terra_function_implementation" then
                local name_node = TS.node_child_by_field_name(node, "name", 4)
                if not ffi.C.ts_node_is_null(name_node) then
                    local func_name = ffi.string(TS.get_node_text(name_node, doc.text))
                    io.stderr:write("[LSP]  ✨ Found Terra Function: " .. func_name .. "\n")
                    io.stderr:flush()
                    
                    local my_lua_ast = LowerAST(node, doc.text)
                    
                    if my_lua_ast then
                        io.stderr:write("[LSP]  ✅ Successfully lowered: " .. func_name .. "\n")
                        io.stderr:flush()
                        fmt = fmt .. "f"
                        table.insert(define_args, func_name)
                        table.insert(define_args, my_lua_ast)
                    else
                        io.stderr:write("[LSP]  ❌ Failed to lower: " .. func_name .. "\n")
                        io.stderr:flush()
                    end
                end
                
            -- Struct Declarations
            elseif node_type == "struct_definition" or node_type == "struct_declaration" then
                local named_children = {}
                for j = 0, tonumber(TS.node_child_count(node)) - 1 do
                    local child = TS.node_child(node, j)
                    if ffi.C.ts_node_is_named(child) then
                        table.insert(named_children, child)
                    end
                end
                
                if #named_children >= 1 then
                    local struct_name = ffi.string(TS.get_node_text(named_children[1], doc.text))
                    io.stderr:write("[LSP]  🏗️ Found Struct: " .. struct_name .. "\n")
                    io.stderr:flush()
                    
                    local entries = terra.asdl.List()
                    local anchor = terra.newanchor(1, 1, uri)
                    
                    for j = 2, #named_children, 2 do
                        if j + 1 <= #named_children then
                            local f_name = ffi.string(TS.get_node_text(named_children[j], doc.text))
                            local f_type_str = ffi.string(TS.get_node_text(named_children[j+1], doc.text))
                            
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
        
        io.stderr:write("[LSP] Extraction complete. Format string: '" .. fmt .. "'\n")
        io.stderr:flush()
        
        -- PASS 2: Native Typechecking
        _G.CURRENT_ENV = module_env 
        
        if #fmt > 0 then
            local typecheck_status, typecheck_err = pcall(function()
                -- 1. Register the scopes and symbols (Lazy)
                terra.defineobjects(fmt, function() return module_env end, unpack(define_args))
                
                -- 2. FORCE TYPECHECKING for the LSP!
                for i = 2, #define_args, 2 do
                    local ast_node = define_args[i]
                    -- Manually run the typechecker over the ASDL node
                    typechecker.typecheck(ast_node, module_env)
                end
            end)
            if not typecheck_status then
                io.stderr:write("[LSP] typechecking natively caught error: " .. tostring(typecheck_err) .. "\n")
                io.stderr:flush()
            end
        end
    end)

    if not success then
        io.stderr:write("[LSP] Pipeline crashed: " .. tostring(err) .. "\n")
        io.stderr:flush()
    end

    -- 3. Harvest and Publish Non-Fatal Diagnostics
    local collected_errors = diagnostics.pop_lsp_errors()
    local vs_code_diagnostics = {}

    for _, err_data in ipairs(collected_errors) do
        local anchor = err_data.anchor
        local start_pos = byte_to_position(doc.text, anchor.offset)
        local end_pos = byte_to_position(doc.text, (anchor.end_offset or anchor.offset) + 1)

        table.insert(vs_code_diagnostics, {
            range = { start = start_pos, ["end"] = end_pos },
            severity = 1,
            message = err_data.message,
            source = "terra"
        })
    end

    io.stderr:write("[LSP] Pipeline finished. Publishing " .. #vs_code_diagnostics .. " diagnostics to VS Code.\n")
    io.stderr:flush()

    rpc.send({
        jsonrpc = "2.0",
        method = "textDocument/publishDiagnostics",
        params = {
            uri = uri,
            diagnostics = vs_code_diagnostics
        }
    })
end

-- ==========================================
-- LSP Handlers
-- ==========================================
handlers["initialize"] = function(msg)
    rpc.send({
        jsonrpc = "2.0",
        id = msg.id,
        result = {
            capabilities = { textDocumentSync = 2, hoverProvider = false },
            serverInfo = { name = "TerraLS", version = "0.1.0" }
        }
    })
end

handlers["initialized"] = function(msg)
    io.stderr:write("[LSP] Handshake Complete (Incremental Mode).\n")
    io.stderr:flush()
end

handlers["textDocument/didOpen"] = function(msg)
    local uri = msg.params.textDocument.uri
    local text = msg.params.textDocument.text
    
    local tree = TS.parser_parse_string(parser, nil, text, #text)
    documents[uri] = { text = text, version = msg.params.textDocument.version, tree = tree }
    
    local root = TS.tree_root_node(tree)
    io.stderr:write("[LSP] Opened & Parsed: " .. tostring(uri) .. " (Nodes: " .. tostring(TS.node_child_count(root)) .. ")\n")
    io.stderr:flush()
    
    run_diagnostics_pipeline(uri, documents[uri])
end

handlers["textDocument/didChange"] = function(msg)
    local uri = msg.params.textDocument.uri
    local doc = documents[uri]
    if not doc then return end

    for _, change in ipairs(msg.params.contentChanges) do
        if change.range then
            local start_byte = get_byte_offset(doc.text, change.range.start.line, change.range.start.character)
            local old_end_byte = get_byte_offset(doc.text, change.range["end"].line, change.range["end"].character)
            local new_text_newlines = count_newlines(change.text)
            local new_end_row = change.range.start.line + new_text_newlines
            local new_end_col = (new_text_newlines > 0) 
                and get_last_line_length(change.text) 
                or (change.range.start.character + #change.text)

            TS.edit_tree(doc.tree, {
                start_byte   = start_byte,
                old_end_byte = old_end_byte,
                new_end_byte = start_byte + #change.text,
                start_row    = change.range.start.line,
                start_col    = change.range.start.character,
                old_end_row  = change.range["end"].line,
                old_end_col  = change.range["end"].character,
                new_end_row  = new_end_row,
                new_end_col  = new_end_col
            })

            local pre = doc.text:sub(1, start_byte)
            local post = doc.text:sub(old_end_byte + 1)
            doc.text = pre .. change.text .. post
        else
            doc.text = change.text
            if doc.tree then TS.tree_delete(doc.tree); doc.tree = nil end
        end
    end

    local new_tree = TS.parser_parse_string(parser, doc.tree, doc.text, #doc.text)
    if doc.tree then TS.tree_delete(doc.tree) end
    doc.tree = new_tree
    doc.version = msg.params.textDocument.version

    local root = TS.tree_root_node(new_tree)
    io.stderr:write("[LSP] Incremental Parse! Nodes: " .. tostring(TS.node_child_count(root)) .. "\n")
    io.stderr:flush()
    
    run_diagnostics_pipeline(uri, doc)
end

handlers["textDocument/didClose"] = function(msg)
    local uri = msg.params.textDocument.uri
    if documents[uri] and documents[uri].tree then
        TS.tree_delete(documents[uri].tree)
    end
    documents[uri] = nil
end

handlers["textDocument/didSave"] = function(msg) end
handlers["shutdown"] = function(msg) rpc.send({ jsonrpc = "2.0", id = msg.id, result = nil }) end
handlers["exit"] = function(msg) os.exit(0) end
handlers["textDocument/hover"] = function(msg) rpc.send({ jsonrpc = "2.0", id = msg.id, result = nil }) end
handlers["$/cancelRequest"] = function(msg) end
handlers["$/setTrace"] = function(msg) end

local function on_message(msg)
    if not msg.method then return end
    io.stderr:write("[LSP] ---> Received: " .. msg.method .. "\n")
    io.stderr:flush()

    local handler = handlers[msg.method]
    if handler then 
        local success, err = pcall(handler, msg)
        if not success then
            io.stderr:write("[LSP] 💥 CRASH in handler for " .. msg.method .. ": " .. tostring(err) .. "\n")
            io.stderr:flush()
        end
    else 
        io.stderr:write("[LSP] Unhandled method: " .. msg.method .. "\n")
        io.stderr:flush()
    end
end

function server.start()
    rpc.start(on_message)
    uv.run("default") 
end

return server