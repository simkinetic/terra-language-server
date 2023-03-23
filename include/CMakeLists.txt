add_library(bezier-methods INTERFACE)
target_include_directories(bezier-methods
    INTERFACE 
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>)

# on GNU compilers use -fcoroutines option
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU")
    target_compile_options(bezier-methods INTERFACE
        -fcoroutines
    )
endif()

# locate external dependencies
find_package(linalg REQUIRED)

# link with external library
target_link_libraries(bezier-methods INTERFACE linalg::linalg)

# set public headers
set(public_headers
    bezier-methods/base.hpp
    bezier-methods/primatives.hpp
)

set_target_properties(bezier-methods 
    PROPERTIES 
    PUBLIC_HEADER "${public_headers}"
)

# install target dolphinmesh
install(TARGETS bezier-methods DESTINATION "."
        PUBLIC_HEADER DESTINATION "include/bezier-methods"
        RUNTIME DESTINATION bin
        ARCHIVE DESTINATION lib
        LIBRARY DESTINATION lib
)