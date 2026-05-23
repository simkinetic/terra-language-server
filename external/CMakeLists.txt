include(FetchContent)

# ==========================================
# LUV (Libuv bindings for Lua)
# ==========================================

# 1. Force luv to build the static library target (libluv_a)
set(BUILD_MODULE OFF CACHE BOOL "Build luv as a library, not a Lua module" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Disable shared luv" FORCE)
set(BUILD_STATIC_LIBS ON CACHE BOOL "Enable static luv" FORCE)

# 2. Force luv to use our pre-compiled Conan libraries
set(WITH_SHARED_LIBUV ON CACHE BOOL "Use system libuv" FORCE)
set(LUA_BUILD_TYPE "System" CACHE STRING "Use system Lua" FORCE)
set(WITH_LUA_ENGINE "LuaJIT" CACHE STRING "Use LuaJIT" FORCE)

# 3. Extract Conan's include paths and FORCE them into luv's expected variables
get_target_property(CONAN_LUAJIT_INC luajit::luajit INTERFACE_INCLUDE_DIRECTORIES)
set(LUAJIT_INCLUDE_DIR "${CONAN_LUAJIT_INC}" CACHE PATH "LuaJIT Headers" FORCE)
set(LUAJIT_LIBRARIES luajit::luajit CACHE STRING "LuaJIT Library" FORCE)

# 4. Bridge Conan's target names
if(TARGET luajit::luajit AND NOT TARGET LuaJIT::LuaJIT)
    add_library(LuaJIT::LuaJIT ALIAS luajit::luajit)
endif()
if(TARGET libuv::uv_a AND NOT TARGET libuv::libuv)
    add_library(libuv::libuv ALIAS libuv::uv_a)
endif()

# 5. Fetch luv (GIT_SUBMODULES is omitted to allow lua-compat-5.3 to fetch)
FetchContent_Declare(
  luv
  GIT_REPOSITORY https://github.com/luvit/luv.git
  GIT_TAG        master
  GIT_SUBMODULES "deps/lua-compat-5.3"
)
FetchContent_MakeAvailable(luv)

# Force luv to inherit the include directories from Conan's libuv target
target_link_libraries(libluv_a PRIVATE libuv::uv_a)


# ==========================================
# Tree-sitter Terra Grammar
# ==========================================
FetchContent_Declare(
  tree_sitter_terra
  GIT_REPOSITORY https://github.com/tpkessler/tree-sitter-terra-rewrite.git
  GIT_TAG        master
)

# We use Populate instead of MakeAvailable because the grammar likely lacks a CMakeLists.txt
FetchContent_Populate(tree_sitter_terra)

# Compile the auto-generated parser.c into a static library
add_library(tree-sitter-terra-grammar STATIC 
    ${tree_sitter_terra_SOURCE_DIR}/src/parser.c
    ${tree_sitter_terra_SOURCE_DIR}/src/scanner.c
)

# Let the parser find its own internal headers
target_include_directories(tree-sitter-terra-grammar PRIVATE ${tree_sitter_terra_SOURCE_DIR}/src)