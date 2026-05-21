# The Thin C++ Host
add_executable(terra-analyze main.cpp)
set_target_properties(terra-analyze PROPERTIES ENABLE_EXPORTS ON)

# Link LuaJIT, Tree-sitter, libuv (using its exact static target name), and luv
target_link_libraries(terra-analyze PRIVATE 
    luajit::luajit 
    tree-sitter::tree-sitter 
    libuv::uv_a
    libluv_a
    tree-sitter-terra-grammar
)

# Pass the install prefix to C++ so it knows where to look for Lua scripts
target_compile_definitions(terra-analyze PRIVATE 
    TERRA_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX}"
)

# Find all Lua files recursively in the src directory
file(GLOB_RECURSE LUA_SCRIPTS "*.lua")

# Copy Lua scripts to the build output directory after each build
add_custom_command(TARGET terra-analyze POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different ${LUA_SCRIPTS} $<TARGET_FILE_DIR:terra-analyze>
    COMMENT "Copying Lua scripts to build directory"
)

# install target executable
install(TARGETS terra-analyze DESTINATION bin)

# You will eventually add commands here to install your .lua compiler files
# install(DIRECTORY ${CMAKE_SOURCE_DIR}/lua_src/ DESTINATION share/terra/lua)
