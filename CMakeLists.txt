cmake_minimum_required(VERSION 3.15)

project(terra-analyzer
        VERSION 0.1.0
        DESCRIPTION "Terra analyzer"
        LANGUAGES C CXX
)

set(CMAKE_CXX_STANDARD 20)            
set(CMAKE_CXX_STANDARD_REQUIRED ON)   
set(CMAKE_CXX_EXTENSIONS OFF)         

# look in binary dir for find_package generator files
LIST(APPEND CMAKE_MODULE_PATH ${CMAKE_BINARY_DIR})

include(CMakeDependentOption)

# locate external Conan dependencies
find_package(luajit REQUIRED)
find_package(tree-sitter REQUIRED)
find_package(libuv REQUIRED)

# download external packages not hosted by conan
add_subdirectory(external)

# build
add_subdirectory(src)

# test
cmake_dependent_option(TERRA_BUILD_TESTS 
    "Enable tests" ON
    "BUILD_TESTING" OFF)

if(TERRA_BUILD_TESTS)
    enable_testing()
    add_subdirectory(test)
endif()