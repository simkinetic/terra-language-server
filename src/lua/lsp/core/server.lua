-- src/lua/lsp/core/server.lua
local uv = require("luv")
local rpc = require("lsp.core.rpc")
local TS = require("compiler.parser.ts_ffi")

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
-- LSP Handlers
-- ==========================================
handlers["initialize"] = function(msg)
    rpc.send({
        jsonrpc = "2.0",
        id = msg.id,
        result = {
            capabilities = {
                textDocumentSync = 2, -- 2 = INCREMENTAL SYNC!
                hoverProvider = false
            },
            serverInfo = { name = "TerraLS", version = "0.1.0" }
        }
    })
end

handlers["initialized"] = function(msg)
    io.stderr:write("[LSP] Handshake Complete (Incremental Mode).\n")
end

handlers["textDocument/didOpen"] = function(msg)
    local uri = msg.params.textDocument.uri
    local text = msg.params.textDocument.text
    
    local tree = TS.parser_parse_string(parser, nil, text, #text)
    documents[uri] = { text = text, version = msg.params.textDocument.version, tree = tree }
    
    io.stderr:write("[LSP] Opened & Parsed: " .. uri .. " (Nodes: " .. TS.node_child_count(TS.tree_root_node(tree)) .. ")\n")
end

handlers["textDocument/didChange"] = function(msg)
    local uri = msg.params.textDocument.uri
    local doc = documents[uri]
    if not doc then return end

    for _, change in ipairs(msg.params.contentChanges) do
        if change.range then
            -- 1. Calculate Offsets
            local start_byte = get_byte_offset(doc.text, change.range.start.line, change.range.start.character)
            local old_end_byte = get_byte_offset(doc.text, change.range["end"].line, change.range["end"].character)
            local new_text_newlines = count_newlines(change.text)
            local new_end_row = change.range.start.line + new_text_newlines
            local new_end_col = (new_text_newlines > 0) 
                and get_last_line_length(change.text) 
                or (change.range.start.character + #change.text)

            -- 2. Patch the Tree-sitter AST via our clean FFI wrapper
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

            -- 3. Splice the Lua text string
            local pre = doc.text:sub(1, start_byte)
            local post = doc.text:sub(old_end_byte + 1)
            doc.text = pre .. change.text .. post
        else
            -- Fallback
            doc.text = change.text
            if doc.tree then TS.tree_delete(doc.tree); doc.tree = nil end
        end
    end

    -- 4. Incremental Parse! (Passes the patched tree in)
    local new_tree = TS.parser_parse_string(parser, doc.tree, doc.text, #doc.text)
    
    if doc.tree then TS.tree_delete(doc.tree) end
    doc.tree = new_tree
    doc.version = msg.params.textDocument.version

    local root = TS.tree_root_node(new_tree)
    io.stderr:write("[LSP] Incremental Parse! Nodes: " .. TS.node_child_count(root) .. "\n")
end

handlers["textDocument/didClose"] = function(msg)
    local uri = msg.params.textDocument.uri
    if documents[uri] and documents[uri].tree then
        TS.tree_delete(documents[uri].tree)
    end
    documents[uri] = nil
end

handlers["textDocument/didSave"] = function(msg)
    -- The user saved the file. 
    -- Since we continuously compile live on keystrokes, we don't need to do much here.
    io.stderr:write("[LSP] File saved to disk.\n")
end

handlers["shutdown"] = function(msg) rpc.send({ jsonrpc = "2.0", id = msg.id, result = nil }) end
handlers["exit"] = function(msg) os.exit(0) end
handlers["textDocument/hover"] = function(msg) rpc.send({ jsonrpc = "2.0", id = msg.id, result = nil }) end
handlers["$/cancelRequest"] = function(msg) end
handlers["$/setTrace"] = function(msg) end

-- ==========================================
-- Event Loop
-- ==========================================
local function on_message(msg)
    if not msg.method then return end
    local handler = handlers[msg.method]
    if handler then handler(msg) else io.stderr:write("[LSP] Unhandled method: " .. msg.method .. "\n") end
end

function server.start()
    rpc.start(on_message)
    uv.run("default") 
end

return server