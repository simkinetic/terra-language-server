from conans import ConanFile, CMake

class ConanPackage(ConanFile):
    name = "bezier-methods"
    version = "0.1.0"

    # Optional metadata
    license = "Proprietary"
    author = "Rene Hiemstra (rene.r.hiemstra@gmail.com)"
    url = "https://gitlab.com/hyperbole-ecosystem/bezier-methods"
    description = "Implementation of Bernstein-Bezier methods."
    topics = ("Bernstein-Bezier methods", "c++20")

    # Sources are located in the same place as this recipe, copy them to the recipe
    exports_sources = "CMakeLists.txt", "include/*"
    generators = "cmake_find_package"

    no_copy_source = True

    def requirements(self):
        self.requires("gtest/cci.20210126")
        self.requires("linalg/0.5.0@hyperbole-ecosystem+core+linalg/stable")

    
    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()
        cmake.install()

    def package(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.install()

    def package_info(self):
        self.info.header_only()