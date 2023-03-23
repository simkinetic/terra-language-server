cmake_minimum_required(VERSION 3.15)
project(PackageTest CXX)

set(CMAKE_CXX_STANDARD 20)            # Use C++20
set(CMAKE_CXX_STANDARD_REQUIRED ON)   # Require (at least) it
set(CMAKE_CXX_EXTENSIONS OFF)         # Don't use e.g. GNU extension (like -std=gnu++11) for portability

find_package(splines REQUIRED)

add_executable(example src/example.cpp)
target_link_libraries(example bezier-methods::bezier-methods)
