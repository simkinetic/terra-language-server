from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, CMakeDeps, cmake_layout

class TerraCompilerConan(ConanFile):
    name = "terra"
    version = "2.0.0"

    license = "MIT"
    author = "René Hiemstra"
    url = "https://github.com/your-org/terra"
    description = "Terra 2.0 Multi-stage Meta-compiler & Language Server"
    topics = ("compiler", "luajit", "tree-sitter", "mlir", "c++20")

    settings = "os", "compiler", "build_type", "arch"
    exports_sources = "CMakeLists.txt", "src/*", "test/*"

    def requirements(self):
        # Core Phase 1 Dependencies
        self.requires("luajit/2.1.0-beta3")
        self.requires("tree-sitter/0.25.9")
        self.requires("libuv/1.48.0") # Needed by luv
        
    def build_requirements(self):
        # In Conan 2, testing frameworks belong in test_requires or build_requirements
        self.test_requires("gtest/1.14.0")

    def layout(self):
        # This standardizes where Conan puts build files (e.g., build/Release)
        cmake_layout(self)

    def generate(self):
        # CMakeDeps replaces the old "cmake_find_package" generator
        deps = CMakeDeps(self)
        deps.generate()
        
        # CMakeToolchain generates the conan_toolchain.cmake file
        tc = CMakeToolchain(self)
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()