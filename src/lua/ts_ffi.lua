-- lua/ts_ffi.lua
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

    bool ts_node_is_null(TSNode node);
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

return TS