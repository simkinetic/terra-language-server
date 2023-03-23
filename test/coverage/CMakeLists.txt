# perform code coverage on gnu or clang
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")

message("Adding compile options for code coverage.")

# Add required flags (GCC & LLVM/Clang)
    target_compile_options(bezier-methods INTERFACE
        -O0        # no optimization
        -g         # generate debug info
        --coverage # sets all required flags
    )

    target_link_libraries(bezier-methods INTERFACE --coverage)
    
endif(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
