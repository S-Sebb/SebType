# The English harness's two host executables (#231); bench.sh configures it.
#   english-today: FUTO's decoder and transformer, compiled in place from android/app/src/main/cpp.
#   english-aosp:  pristine AOSP LatinIME's decoder, from AOSP_JNI (bench.sh fetches it into the cache).
#   english-sebtype: the same decoder with SebType's own model (engines/sebtype-lm on llama.cpp, LLAMA_DIR).
#   english-core: the new keyboard's English, core/src/english.cpp (#244), with the same model.
cmake_minimum_required(VERSION 3.22)
project(english_harness C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Both decoders run at -O3 as in the app. x86-64-v3 (AVX2) lets ggml use SIMD, as it uses NEON on the phone.
set(CMAKE_C_FLAGS_RELEASE "-O3 -DNDEBUG")
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG")
add_compile_options(-march=x86-64-v3 -fexceptions -DHAVE_PTHREAD)

find_path(JNI_H jni.h PATHS ENV JAVA_HOME PATH_SUFFIXES include REQUIRED NO_DEFAULT_PATH)
set(JNI_INCLUDE ${JNI_H} ${JNI_H}/linux)

set(HARNESS_SRC src/main.cpp src/fake_jni.cpp src/decoder.cpp)

# Today's: FUTO's own file list, used in place.
set(FUTO_CPP ${CMAKE_CURRENT_SOURCE_DIR}/../../app/src/main/cpp)
set(CMAKE_CURRENT_SOURCE_DIR_SAVED ${CMAKE_CURRENT_SOURCE_DIR})
set(CMAKE_CURRENT_SOURCE_DIR ${FUTO_CPP})
include(${FUTO_CPP}/NativeFileList.cmake)
set(CMAKE_CURRENT_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR_SAVED})
add_library(futo_latinime STATIC ${LATIN_IME_CORE_SRC_FILES} ${LATIN_IME_JNI_SRC_FILES})
target_include_directories(futo_latinime PRIVATE ${LATIN_IME_CORE_INCLUDE} ${LATIN_IME_JNI_INCLUDE} ${JNI_INCLUDE})
# FUTO's code relies on headers the NDK's libc++ pulls in by itself.
target_compile_options(futo_latinime PRIVATE -w -D_GNU_SOURCE "SHELL:-include string.h" "SHELL:-include math.h")
add_executable(english-today ${HARNESS_SRC} src/today.cpp)
target_include_directories(english-today PRIVATE ${JNI_INCLUDE})
# Whole archive: the decoders register their methods from files nothing else references.
target_link_libraries(english-today PRIVATE -Wl,--whole-archive futo_latinime -Wl,--no-whole-archive pthread dl m)

# AOSP's: every source of its native library (Android.bp's LATIN_IME_CORE_SRC_FILES and the JNI files).
if(NOT AOSP_JNI)
  message(FATAL_ERROR "AOSP_JNI: AOSP LatinIME's native/jni folder")
endif()
file(GLOB_RECURSE AOSP_SRC ${AOSP_JNI}/src/*.cpp)
file(GLOB AOSP_JNI_SRC ${AOSP_JNI}/*.cpp)
add_library(aosp_latinime STATIC ${AOSP_SRC} ${AOSP_JNI_SRC})
target_include_directories(aosp_latinime PRIVATE ${AOSP_JNI}/src ${JNI_INCLUDE})
target_compile_options(aosp_latinime PRIVATE -w)
add_executable(english-aosp ${HARNESS_SRC} src/aosp.cpp)
target_include_directories(english-aosp PRIVATE ${JNI_INCLUDE})
target_link_libraries(english-aosp PRIVATE -Wl,--whole-archive aosp_latinime -Wl,--no-whole-archive pthread dl m)

# SebType's: AOSP's decoder and engines/sebtype-lm on llama.cpp, built for the CPU as the other two are.
if(LLAMA_DIR)
  foreach(off LLAMA_BUILD_TESTS LLAMA_BUILD_TOOLS LLAMA_BUILD_EXAMPLES LLAMA_BUILD_SERVER LLAMA_CURL
              BUILD_SHARED_LIBS GGML_NATIVE GGML_OPENMP GGML_AVX512 GGML_BACKEND_DL)
    set(${off} OFF CACHE BOOL "" FORCE)
  endforeach()
  foreach(on GGML_AVX GGML_AVX2 GGML_FMA GGML_F16C GGML_BMI2)
    set(${on} ON CACHE BOOL "" FORCE)
  endforeach()
  add_subdirectory(${LLAMA_DIR} llama EXCLUDE_FROM_ALL)
  add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../engines/sebtype-lm sebtype-lm)
  add_executable(english-sebtype ${HARNESS_SRC} src/sebtype.cpp)
  target_include_directories(english-sebtype PRIVATE ${JNI_INCLUDE})
  target_link_libraries(english-sebtype PRIVATE -Wl,--whole-archive aosp_latinime -Wl,--no-whole-archive
                        sebtype_lm pthread dl m)
  # The new keyboard's: core/'s English engine (core/src/english.cpp) on the rebuilt dictionary.
  set(SEBTYPE_CJK OFF CACHE BOOL "" FORCE)
  set(SEBTYPE_ENGLISH ON CACHE BOOL "" FORCE)
  set(SEBTYPE_TESTS OFF CACHE BOOL "" FORCE)
  add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../core core)
  add_executable(english-core src/main.cpp src/core.cpp)
  set_target_properties(english-core PROPERTIES CXX_STANDARD 20)
  target_link_libraries(english-core PRIVATE sebtype-english pthread)
endif()
