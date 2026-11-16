# libsebtype.so, the phone's native library (#191 stage 1): core/ with English (stage 4), librime (engines/librime, built by
# RimeJni's scripts in cmake/, MIT, see cmake/LICENSE) and protobuf-lite for Mozc's protocol, and the JNI
# glue NativeCore.kt calls. Mozc itself is libmozc.so (Bazel, ../../../build-mozc.sh), which it links to.
cmake_minimum_required(VERSION 3.22)
project(sebtype-native CXX C)

set(CMAKE_BUILD_TYPE Release)
set(BUILD_TEST OFF)
set(BUILD_STATIC ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
set(RIME_JNI_ROOT ${CMAKE_CURRENT_SOURCE_DIR})

# build.gradle passes LIBRIME_SOURCE_DIR (engines/librime) and RIME_DEPS_CACHE (outside the tree, shared by
# worktrees). Nothing is written into the source tree.
set(DOWNLOAD_PATH "${RIME_DEPS_CACHE}/downloads")
set(JNI_DEPS_DIR "${RIME_DEPS_CACHE}/deps")
# SebType (#223): the third-party builds, core/'s, and the headers they generate or link go to a folder of the
# same relative path in every checkout, not AGP's .cxx/<hash>/, whose hash differs per checkout. Their paths
# are compiler arguments (-I), so in .cxx/<hash>/ every new worktree missed sccache and rebuilt Rime, and they
# went into the debug info and so into the library's build ID.
get_filename_component(RIME_JNI_BUILD_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../build/rime-cmake/${ANDROID_ABI}" ABSOLUTE)
set(JNI_INCLUDE_DIR "${RIME_JNI_BUILD_DIR}/include")
file(MAKE_DIRECTORY ${DOWNLOAD_PATH} ${JNI_DEPS_DIR} ${JNI_INCLUDE_DIR})

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

include(Helper)
include(Boost)
include(LevelDB)
include(yaml-cpp)
include(marisa-trie)
include(OpenCC)
include(librime)
include(protobuf)

# core/, as the PCs build it; its CMake takes these targets on Android, and runs Mozc in this process from
# libmozc.so (MOZC_LIBS_DIR: build.gradle's buildMozcNative output, one folder per ABI).
set(RIME_TARGET rime-static)
set(SEBTYPE_MOZC_LIB ${MOZC_LIBS_DIR}/${ANDROID_ABI}/libmozc.so CACHE FILEPATH "" FORCE)
set(SEBTYPE_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(${SEBTYPE_CORE_DIR} ${RIME_JNI_BUILD_DIR}/core)

add_library(sebtype SHARED sebtype_jni.cpp)
set_target_properties(sebtype PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_link_libraries(sebtype PRIVATE sebtype-core sebtype-english c++_static log)
target_link_options(sebtype PRIVATE
    -Wl,--gc-sections
    -Wl,--as-needed
    -Wl,-z,max-page-size=16384
    -Wl,--exclude-libs,ALL
    -flto
)
