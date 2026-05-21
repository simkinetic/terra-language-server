# code coverage
option(CODE_COVERAGE "Enable coverage reporting" OFF)
if(CODE_COVERAGE)
    add_subdirectory(coverage)
endif()

find_package(GTest REQUIRED)
include(CTest)
include(GoogleTest)

# Note: Since 'terra' is an executable, if you want to unit test C++ functions,
# you should refactor the core C++ logic into a STATIC library and link both
# the 'terra' executable and your test executables to it.
# For now, we stub out a basic C++ host test.

# add_executable(test_host "test_host.cpp")
# target_link_libraries(test_host PRIVATE GTest::gtest_main luajit::luajit)
# gtest_discover_tests(test_host)