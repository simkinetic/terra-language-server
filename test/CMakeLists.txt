# code coverage
option(CODE_COVERAGE "Enable coverage reporting" OFF)
if(CODE_COVERAGE)
	add_subdirectory(coverage)
endif(CODE_COVERAGE)

# register test executables
find_package(GTest REQUIRED)
include(CTest)
include(GoogleTest)

# add test executables
add_executable(test_primitives "primitives.cpp")
target_link_libraries(test_primitives PRIVATE bezier-methods GTest::gtest_main)
gtest_discover_tests(test_primitives)

add_executable(console "main.cpp")
target_link_libraries(console PRIVATE bezier-methods)