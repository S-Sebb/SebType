# The Chinese harness (#259): zhbench, core/'s Rime engine (src/rime.cpp) on the system's librime with its
# Lua and octagram plugins, as SebType's Linux build runs it, and SebType's Chinese model on llama.cpp
# (LLAMA_DIR, engines/sebtype-lm/fetch-llama.sh). bench.sh configures it.
cmake_minimum_required(VERSION 3.22)
project(chinese_harness C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_FLAGS_RELEASE "-O3 -DNDEBUG")
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG")
# x86-64-v3 (AVX2) lets ggml use SIMD, as it uses NEON on the phone; the English harness does the same.
add_compile_options(-march=x86-64-v3)

find_package(PkgConfig REQUIRED)
pkg_check_modules(Rime REQUIRED IMPORTED_TARGET rime)

foreach(off LLAMA_BUILD_TESTS LLAMA_BUILD_TOOLS LLAMA_BUILD_EXAMPLES LLAMA_BUILD_SERVER LLAMA_CURL
            BUILD_SHARED_LIBS GGML_NATIVE GGML_OPENMP GGML_AVX512 GGML_BACKEND_DL)
  set(${off} OFF CACHE BOOL "" FORCE)
endforeach()
foreach(on GGML_AVX GGML_AVX2 GGML_FMA GGML_F16C GGML_BMI2)
  set(${on} ON CACHE BOOL "" FORCE)
endforeach()
add_subdirectory(${LLAMA_DIR} llama EXCLUDE_FROM_ALL)

set(CORE ${CMAKE_CURRENT_SOURCE_DIR}/../../../core)
add_executable(zhbench src/main.cpp src/zh_lm.cpp ${CORE}/src/rime.cpp ${CORE}/src/pager.cpp)
target_include_directories(zhbench PRIVATE ${CORE}/include)
target_link_libraries(zhbench PRIVATE PkgConfig::Rime llama pthread)
