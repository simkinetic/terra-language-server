#include <iostream>
#include <cstdlib>
#include <filesystem>
#include "lua.hpp"

// Because Conan configures the include paths automatically, this works out of the box!
#include <tree_sitter/api.h>

namespace fs = std::filesystem;

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

    // ==========================================
    // 3. SMART DYNAMIC PATH RESOLUTION
    // ==========================================
    fs::path module_root;
    fs::path script_path;
    
    // Lambda updated to look inside the new compiler/ directory
    auto check_dir = [&](fs::path base) -> bool {
        if (fs::exists(base / "lua" / "compiler" / "core_compiler.lua")) {
            module_root = base; 
            script_path = base / "lua" / "compiler" / "core_compiler.lua";
            return true;
        }
        if (fs::exists(base / "src" / "lua" / "compiler" / "core_compiler.lua")) {
            module_root = base / "src";
            script_path = base / "src" / "lua" / "compiler" / "core_compiler.lua";
            return true;
        }
        return false;
    };

    // Attempt 1: Check Current Working Directory (handles Bash scripts perfectly)
    if (!check_dir(fs::current_path())) {
        // Attempt 2: Walk upwards from the executable's absolute location
        fs::path current_dir = fs::absolute(fs::path(argv[0])).parent_path();
        while (current_dir.has_parent_path() && current_dir != current_dir.parent_path()) {
            if (check_dir(current_dir)) break;
            current_dir = current_dir.parent_path();
        }
    }
    
    if (script_path.empty()) {
        std::cerr << "Fatal: Could not locate 'core_compiler.lua'." << std::endl;
        std::cerr << "[Debug] CWD checked: " << fs::current_path().string() << std::endl;
        std::cerr << "[Debug] Exec checked: " << fs::absolute(fs::path(argv[0])).string() << std::endl;
        lua_close(L);
        return 1;
    }

    // Inject the absolute module root into Lua so it can fix its internal requires
    lua_pushstring(L, module_root.string().c_str());
    lua_setglobal(L, "LSP_ROOT");

    // ==========================================
    // 4. THE BULLETPROOF FFI BRIDGE
    // ==========================================
    lua_newtable(L);
    lua_pushlightuserdata(L, (void*)ts_parser_new);                lua_setfield(L, -2, "ts_parser_new");
    lua_pushlightuserdata(L, (void*)ts_parser_delete);             lua_setfield(L, -2, "ts_parser_delete");
    lua_pushlightuserdata(L, (void*)ts_parser_set_language);       lua_setfield(L, -2, "ts_parser_set_language");
    lua_pushlightuserdata(L, (void*)ts_parser_parse_string);       lua_setfield(L, -2, "ts_parser_parse_string");
    lua_pushlightuserdata(L, (void*)ts_tree_delete);               lua_setfield(L, -2, "ts_tree_delete");
    lua_pushlightuserdata(L, (void*)ts_tree_root_node);            lua_setfield(L, -2, "ts_tree_root_node");
    lua_pushlightuserdata(L, (void*)ts_node_string);               lua_setfield(L, -2, "ts_node_string");
    lua_pushlightuserdata(L, (void*)tree_sitter_terra);            lua_setfield(L, -2, "tree_sitter_terra");
    lua_pushlightuserdata(L, (void*)free);                         lua_setfield(L, -2, "free");
    lua_pushlightuserdata(L, (void*)ts_node_type);                 lua_setfield(L, -2, "ts_node_type");
    lua_pushlightuserdata(L, (void*)ts_node_child_by_field_name);  lua_setfield(L, -2, "ts_node_child_by_field_name");
    lua_pushlightuserdata(L, (void*)ts_node_child_count);          lua_setfield(L, -2, "ts_node_child_count");
    lua_pushlightuserdata(L, (void*)ts_node_child);                lua_setfield(L, -2, "ts_node_child");
    lua_pushlightuserdata(L, (void*)ts_node_start_byte);           lua_setfield(L, -2, "ts_node_start_byte");
    lua_pushlightuserdata(L, (void*)ts_node_end_byte);             lua_setfield(L, -2, "ts_node_end_byte");
    
    // Injecting the missing Point APIs for exact line/col LSP tracking
    lua_pushlightuserdata(L, (void*)ts_node_start_point);          lua_setfield(L, -2, "ts_node_start_point");
    lua_pushlightuserdata(L, (void*)ts_node_end_point);            lua_setfield(L, -2, "ts_node_end_point");
    
    lua_setglobal(L, "TS_CAPI"); 

    // --- ABI DIAGNOSTICS ---
    // Shifted to std::cerr to prevent corrupting the LSP JSON-RPC stream
    const TSLanguage* lang = tree_sitter_terra();
    uint32_t grammar_abi = ts_language_version(lang);
    std::cerr << "\n[ABI Diagnostics] Grammar requires ABI: " << grammar_abi << std::endl;
    std::cerr << "[ABI Diagnostics] Conan Engine supports: " 
              << TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION << " to " 
              << TREE_SITTER_LANGUAGE_VERSION << std::endl;

    // 5. Pass CLI Arguments
    lua_newtable(L);
    for (int i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i + 1);
    }
    lua_setglobal(L, "arg");

    // ==========================================
    // 6. EXECUTE USING ABSOLUTE PATH
    // ==========================================
    if (luaL_dofile(L, script_path.string().c_str()) != LUA_OK) {
        std::cerr << "Terra LS Error: " << lua_tostring(L, -1) << std::endl;
        lua_close(L);
        return 1;
    }

    lua_close(L);
    return 0;
}