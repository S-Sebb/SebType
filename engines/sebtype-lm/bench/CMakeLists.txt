# sebtype-lm-window (window.cpp): the model's context window in long text, cost and quality (#359). bench.sh
# configures it with LLAMA_DIR, built for the CPU as the English harness is.
cmake_minimum_required(VERSION 3.22)
project(sebtype_lm_bench C CXX)
set(CMAKE_CXX_STANDARD 17)
add_compile_options(-march=x86-64-v3)
foreach(off LLAMA_BUILD_TESTS LLAMA_BUILD_TOOLS LLAMA_BUILD_EXAMPLES LLAMA_BUILD_SERVER LLAMA_CURL
            BUILD_SHARED_LIBS GGML_NATIVE GGML_OPENMP GGML_AVX512 GGML_BACKEND_DL)
  set(${off} OFF CACHE BOOL "" FORCE)
endforeach()
foreach(on GGML_AVX GGML_AVX2 GGML_FMA GGML_F16C GGML_BMI2)
  set(${on} ON CACHE BOOL "" FORCE)
endforeach()
add_subdirectory(${LLAMA_DIR} llama EXCLUDE_FROM_ALL)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/.. sebtype-lm)
add_executable(sebtype-lm-window window.cpp)
target_link_libraries(sebtype-lm-window PRIVATE sebtype_lm pthread)
