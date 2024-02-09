# C++20- template

[![pipeline status](https://gitlab.com/hyperbole-ecosystem/core/bezier-methods/badges/master/pipeline.svg)](https://gitlab.com/hyperbole-ecosystem/core/bezier-methods/-/commits/master)
[![coverage report](https://gitlab.com/hyperbole-ecosystem/core/bezier-methods/badges/master/coverage.svg)](https://hyperbole-ecosystem.gitlab.io/core/bezier-methods/)


## Building and installing
The library has a header only design. Cmake is used in combination with [Conan](https://conan.io/) to automatically handle the depencies, which will be automatically downloaded, build and installed on the fly. If cmake and conan are installed on your system then you can simply build this project as follows
```
git clone git@gitlab.com:hyperbole-ecosystem/templates/cxx-20-template.git
cd cxx-20-template
mkdir -p build && cd build
conan install ..
cmake .. -DBUILD_TESTING=ON
cmake --build .
ctest
```
