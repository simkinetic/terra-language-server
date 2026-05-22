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

# Copy the entire Lua directory tree to the build output directory after each build
# This preserves the compiler/ and lsp/ folder structure!
add_custom_command(TARGET terra-analyze POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_CURRENT_SOURCE_DIR}/lua
        $<TARGET_FILE_DIR:terra-analyze>/lua
        COMMENT "Copying Lua directory tree to build directory"
)

# install target executable
install(TARGETS terra-analyze DESTINATION bin)

# Install the lua directory tree so it ships with the executable
install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/lua DESTINATION bin)