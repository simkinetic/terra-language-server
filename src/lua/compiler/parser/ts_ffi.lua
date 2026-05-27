-- lua/compiler/parser/ts_ffi.lua
local ffi = require("ffi")

ffi.cdef[[
    typedef struct TSParser TSParser;
    typedef struct TSTree TSTree;
    typedef struct TSLanguage TSLanguage;

    typedef struct {
        uint32_t context[4];
        const void *id;
        const TSTree *tree;
    } TSNode;

    typedef struct {
        uint32_t row;
        uint32_t column;
    } TSPoint;

    typedef struct {
        uint32_t start_byte;
        uint32_t old_end_byte;
        uint32_t new_end_byte;
        TSPoint start_point;
        TSPoint old_end_point;
        TSPoint new_end_point;
    } TSInputEdit;

    bool ts_node_is_null(TSNode node);
    bool ts_node_is_named(TSNode node);
    
    TSPoint ts_node_start_point(TSNode node);
    TSPoint ts_node_end_point(TSNode node);
]]

local TS = {
    parser_new                  = ffi.cast("TSParser* (*)()", TS_CAPI.ts_parser_new),
    parser_delete               = ffi.cast("void (*)(TSParser*)", TS_CAPI.ts_parser_delete),
    parser_set_language         = ffi.cast("bool (*)(TSParser*, const TSLanguage*)", TS_CAPI.ts_parser_set_language),
    parser_parse_string         = ffi.cast("TSTree* (*)(TSParser*, const TSTree*, const char*, uint32_t)", TS_CAPI.ts_parser_parse_string),
    tree_delete                 = ffi.cast("void (*)(TSTree*)", TS_CAPI.ts_tree_delete),
    tree_root_node              = ffi.cast("TSNode (*)(const TSTree*)", TS_CAPI.ts_tree_root_node),
    node_string                 = ffi.cast("char* (*)(TSNode)", TS_CAPI.ts_node_string),
    terra_grammar               = ffi.cast("const TSLanguage* (*)()", TS_CAPI.tree_sitter_terra),
    free                        = ffi.cast("void (*)(void*)", TS_CAPI.free),
    node_type                   = ffi.cast("const char* (*)(TSNode)", TS_CAPI.ts_node_type),
    node_child_by_field_name    = ffi.cast("TSNode (*)(TSNode, const char*, uint32_t)", TS_CAPI.ts_node_child_by_field_name),
    node_child_count            = ffi.cast("uint32_t (*)(TSNode)", TS_CAPI.ts_node_child_count),
    node_child                  = ffi.cast("TSNode (*)(TSNode, uint32_t)", TS_CAPI.ts_node_child),
    node_start_byte             = ffi.cast("uint32_t (*)(TSNode)", TS_CAPI.ts_node_start_byte),
    node_end_byte               = ffi.cast("uint32_t (*)(TSNode)", TS_CAPI.ts_node_end_byte),
    node_start_point            = ffi.cast("TSPoint (*)(TSNode)", TS_CAPI.ts_node_start_point),
    node_end_point              = ffi.cast("TSPoint (*)(TSNode)", TS_CAPI.ts_node_end_point),
    -- NEW: Incremental tree editing
    tree_edit                   = ffi.cast("void (*)(TSTree*, const TSInputEdit*)", TS_CAPI.ts_tree_edit),
}

function TS.safe_node_type(node)
    if ffi.C.ts_node_is_null(node) then return "null" end
    local ptr = TS.node_type(node)
    if ptr == nil then return "null" end
    return ffi.string(ptr)
end

function TS.get_node_text(node, source_code)
    local start_byte = TS.node_start_byte(node)
    local end_byte = TS.node_end_byte(node)
    return source_code:sub(start_byte + 1, end_byte)
end

-- NEW: Helper to patch the C-AST
function TS.edit_tree(tree, edit_params)
    if not tree then return end
    
    local edit = ffi.new("TSInputEdit", {
        start_byte    = edit_params.start_byte,
        old_end_byte  = edit_params.old_end_byte,
        new_end_byte  = edit_params.new_end_byte,
        start_point   = { row = edit_params.start_row, column = edit_params.start_col },
        old_end_point = { row = edit_params.old_end_row, column = edit_params.old_end_col },
        new_end_point = { row = edit_params.new_end_row, column = edit_params.new_end_col }
    })
    
    TS.tree_edit(tree, edit)
end

return TS