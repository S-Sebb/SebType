cmake_minimum_required(VERSION 3.22)
project(rime-jni)

set(CMAKE_BUILD_TYPE Release)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(BUILD_TEST OFF)
set(BUILD_STATIC ON)

set(RIME_JNI_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
list(APPEND CMAKE_MODULE_PATH ${RIME_JNI_ROOT}/cmake)

# SebType: android/rime/build.gradle passes LIBRIME_SOURCE_DIR (engines/librime) and RIME_DEPS_CACHE
# (outside the tree, shared by worktrees). Nothing is written into the source tree.
set(DOWNLOAD_PATH "${RIME_DEPS_CACHE}/downloads")
set(JNI_DEPS_DIR "${RIME_DEPS_CACHE}/deps")
set(JNI_INCLUDE_DIR "${CMAKE_BINARY_DIR}/include")
file(MAKE_DIRECTORY ${DOWNLOAD_PATH} ${JNI_DEPS_DIR} ${JNI_INCLUDE_DIR})

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

include(Helper)

include(Boost)
include(LevelDB)
include(yaml-cpp)
include(marisa-trie)
include(OpenCC)
include(librime)

include(jni)
