include(FetchContent)
FetchContent_Declare(
  luv
  GIT_REPOSITORY https://github.com/luvit/luv.git
  GIT_TAG        master
)

# Force luv to build the static library target (luv_a)
set(BUILD_MODULE OFF CACHE BOOL "Build luv as a library, not a Lua module" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Disable shared luv" FORCE)
set(BUILD_STATIC_LIBS ON CACHE BOOL "Enable static luv" FORCE)
set(WITH_SHARED_LIBUV ON CACHE BOOL "Use Conan's libuv" FORCE)

FetchContent_MakeAvailable(luv)

# Force luv to inherit the include directories from Conan's libuv target
target_link_libraries(libluv_a PRIVATE libuv::uv_a)


# --- Tree-sitter Terra Grammar ---
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