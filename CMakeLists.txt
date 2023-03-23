cmake_minimum_required(VERSION 3.15)

project(bezier-methods
        VERSION 0.1.0
        DESCRIPTION "Implementation of Bernstein-Bezier methods."
        LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 20)            # Use C++20
set(CMAKE_CXX_STANDARD_REQUIRED ON)   # Require (at least) it
set(CMAKE_CXX_EXTENSIONS OFF)         # Don't use e.g. GNU extension (like -std=gnu++11) for portability

# look in binary dir for find_package generator files
# for external dependencies
LIST(APPEND CMAKE_MODULE_PATH ${CMAKE_BINARY_DIR})

# check if project is the toplevel project
set(PROJECT_IS_TOP_LEVEL FALSE)
if(CMAKE_SOURCE_DIR STREQUAL PROJECT_SOURCE_DIR)
	set(PROJECT_IS_TOP_LEVEL TRUE)
endif()

# enable dependent options
include(CMakeDependentOption)

# choose predefined conan profile
set(CONAN_PROFILE "default-release")
if(CMAKE_BUILD_TYPE MATCHES "Debug")
	set(CONAN_PROFILE "default-debug")
endif()

# install required conan packages
execute_process(
	COMMAND conan install ${PROJECT_SOURCE_DIR} --profile=${CONAN_PROFILE} --build=missing
	WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
)

# build
add_subdirectory(include)

# test
cmake_dependent_option(BEZIERMETHODS_BUILD_TESTS 
	"Enable bezier-methods::bezier-methods" ON
	"BUILD_TESTING;PROJECT_IS_TOP_LEVEL" OFF)

if(BEZIERMETHODS_BUILD_TESTS)
	enable_testing()
	add_subdirectory(test)
endif()
