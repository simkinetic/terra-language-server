#include <iostream>
#include <cstdlib>
#include "lua.hpp"

// Because Conan configures the include paths automatically, this works out of the box!
#include <tree_sitter/api.h>

extern "C" int luaopen_luv(lua_State *L);
extern "C" const TSLanguage *tree_sitter_terra(); // Forward declare your custom grammar

int main(int argc, char** argv) {
    // 1. Initialize LuaJIT
    lua_State* L = luaL_newstate();
    if (!L) {
        std::cerr << "Fatal: Failed to initialize LuaJIT state." << std::endl;
        return 1;
    }
    luaL_openlibs(L);

    // 2. Inject luv
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, luaopen_luv);
    lua_setfield(L, -2, "luv");
    lua_pop(L, 2);

    // 3. THE BULLETPROOF FFI BRIDGE
    // We pass the exact memory addresses of the C functions to Lua.
    // The macOS linker cannot hide these from us now.
    lua_newtable(L);
    lua_pushlightuserdata(L, (void*)ts_parser_new);          lua_setfield(L, -2, "ts_parser_new");
    lua_pushlightuserdata(L, (void*)ts_parser_delete);       lua_setfield(L, -2, "ts_parser_delete");
    lua_pushlightuserdata(L, (void*)ts_parser_set_language); lua_setfield(L, -2, "ts_parser_set_language");
    lua_pushlightuserdata(L, (void*)ts_parser_parse_string); lua_setfield(L, -2, "ts_parser_parse_string");
    lua_pushlightuserdata(L, (void*)ts_tree_delete);         lua_setfield(L, -2, "ts_tree_delete");
    lua_pushlightuserdata(L, (void*)ts_tree_root_node);      lua_setfield(L, -2, "ts_tree_root_node");
    lua_pushlightuserdata(L, (void*)ts_node_string);         lua_setfield(L, -2, "ts_node_string");
    lua_pushlightuserdata(L, (void*)tree_sitter_terra);      lua_setfield(L, -2, "tree_sitter_terra");
    lua_pushlightuserdata(L, (void*)free);                   lua_setfield(L, -2, "free");
    lua_pushlightuserdata(L, (void*)ts_node_type);                 lua_setfield(L, -2, "ts_node_type");
    lua_pushlightuserdata(L, (void*)ts_node_child_by_field_name);  lua_setfield(L, -2, "ts_node_child_by_field_name");
    lua_pushlightuserdata(L, (void*)ts_node_child_count);          lua_setfield(L, -2, "ts_node_child_count");
    lua_pushlightuserdata(L, (void*)ts_node_child);                lua_setfield(L, -2, "ts_node_child");
    lua_pushlightuserdata(L, (void*)ts_node_start_byte); lua_setfield(L, -2, "ts_node_start_byte");
    lua_pushlightuserdata(L, (void*)ts_node_end_byte);   lua_setfield(L, -2, "ts_node_end_byte");
    lua_setglobal(L, "TS_CAPI"); // Save this table as a global variable in Lua

    // --- ABI DIAGNOSTICS ---
    const TSLanguage* lang = tree_sitter_terra();
    uint32_t grammar_abi = ts_language_version(lang);
    std::cout << "\n[ABI Diagnostics] Grammar requires ABI: " << grammar_abi << std::endl;
    std::cout << "[ABI Diagnostics] Conan Engine supports: " 
              << TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION << " to " 
              << TREE_SITTER_LANGUAGE_VERSION << std::endl;

    // 4. Pass CLI Arguments
    lua_newtable(L);
    for (int i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i + 1);
    }
    lua_setglobal(L, "arg");

    // 5. Execute
    if (luaL_dofile(L, "lua/core_compiler.lua") != LUA_OK) {
        std::cerr << "Terra LS Error: " << lua_tostring(L, -1) << std::endl;
        lua_close(L);
        return 1;
    }

    lua_close(L);
    return 0;
}