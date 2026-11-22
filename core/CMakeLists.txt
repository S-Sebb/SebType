cmake_minimum_required(VERSION 3.20)
project(sebtype-core CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(SEBTYPE_CJK "Build 中文 (librime) and 日本語 (Mozc)" ON)
option(SEBTYPE_ENGLISH "Build English (AOSP's decoder and SebType's model, engines/latinime and engines/sebtype-lm)" OFF)
option(SEBTYPE_CHINESE_MODEL "Build SebType's Chinese model around Rime (engines/sebtype-lm, OpenCC)" OFF)

# Switching, menus and paging: no engine needed, so the unit tests link only this.
add_library(sebtype-logic STATIC src/core.cpp src/pager.cpp)
target_include_directories(sebtype-logic PUBLIC include)

if(SEBTYPE_CJK)
# librime and protobuf: pkg-config and the system's on Linux; on Windows RIME_ROOT holds include/rime_api.h
# and lib/rime.lib (the rime.dll pc/windows/rime/build.ps1 makes, engines/librime). On Android the app's
# android/native builds both (protobuf-lite) and sets RIME_TARGET, PROTOBUF_TARGET and PROTOC first.
if(ANDROID)
  set(PROTOC_OUT lite:)
else()
  if(WIN32)
    add_library(rime SHARED IMPORTED)
    set_target_properties(rime PROPERTIES IMPORTED_IMPLIB ${RIME_ROOT}/lib/rime.lib
      INTERFACE_INCLUDE_DIRECTORIES ${RIME_ROOT}/include)
    set(RIME_TARGET rime)
  else()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(Rime REQUIRED IMPORTED_TARGET rime)
    set(RIME_TARGET PkgConfig::Rime)
  endif()
  find_package(Protobuf REQUIRED)
  set(PROTOBUF_TARGET protobuf::libprotobuf)
  set(PROTOC protobuf::protoc)
  set(PROTOC_OUT)
endif()

# Mozc runs in this process (#220, #233): SEBTYPE_MOZC_LIB names the Mozc library with the C interface in
# src/sebtype_mozc.h, built from engines/mozc/src/sebtype (libsebtype-mozc.so on Linux, the import library of
# sebtype-mozc.dll on Windows, the phone's libmozc.so).
set(SEBTYPE_MOZC_LIB "" CACHE FILEPATH "The Mozc library with SebType's C interface")
set(MOZC_PROTOS protocol/commands.proto protocol/candidate_window.proto protocol/config.proto
  protocol/engine_builder.proto)

# Mozc's protocol, from the one Mozc source (engines/mozc).
set(MOZC_SRC ${CMAKE_CURRENT_SOURCE_DIR}/../engines/mozc/src)
set(PROTO_OUT ${CMAKE_CURRENT_BINARY_DIR}/proto)
set(PROTO_SRCS)
foreach(p ${MOZC_PROTOS})
  string(REGEX REPLACE "\\.proto$" "" base ${p})
  list(APPEND PROTO_SRCS ${PROTO_OUT}/${base}.pb.cc)
  add_custom_command(OUTPUT ${PROTO_OUT}/${base}.pb.cc ${PROTO_OUT}/${base}.pb.h
    COMMAND ${CMAKE_COMMAND} -E make_directory ${PROTO_OUT}
    COMMAND ${PROTOC} --cpp_out=${PROTOC_OUT}${PROTO_OUT} -I ${MOZC_SRC} ${MOZC_SRC}/${p}
    DEPENDS ${MOZC_SRC}/${p})
endforeach()

add_library(sebtype-core STATIC src/rime.cpp src/mozc.cpp src/mozc_inprocess.cpp src/mozc_learned.cpp ${PROTO_SRCS})
target_include_directories(sebtype-core PRIVATE ${PROTO_OUT})
target_link_libraries(sebtype-core PUBLIC sebtype-logic ${RIME_TARGET} ${PROTOBUF_TARGET} ${SEBTYPE_MOZC_LIB})
endif()

# SebType's models on llama.cpp (engines/sebtype-lm): the parent adds llama.cpp first, or LLAMA_DIR names its
# source (engines/sebtype-lm/fetch-llama.sh).
set(ENGINES ${CMAKE_CURRENT_SOURCE_DIR}/../engines)
if(SEBTYPE_ENGLISH OR SEBTYPE_CHINESE_MODEL)
  if(NOT TARGET llama)
    foreach(off LLAMA_BUILD_TESTS LLAMA_BUILD_TOOLS LLAMA_BUILD_EXAMPLES LLAMA_BUILD_SERVER LLAMA_CURL
                BUILD_SHARED_LIBS GGML_OPENMP GGML_BACKEND_DL)
      set(${off} OFF CACHE BOOL "" FORCE)
    endforeach()
    add_subdirectory(${LLAMA_DIR} llama EXCLUDE_FROM_ALL)
    # llama.cpp is C++17: in C++20 its u8"" literals are char8_t, which MSVC won't take as char (#495).
    set_target_properties(llama PROPERTIES CXX_STANDARD 17)
  endif()
  if(NOT TARGET sebtype_lm)
    add_subdirectory(${ENGINES}/sebtype-lm sebtype-lm)
  endif()
endif()

# English: AOSP LatinIME's decoder, untouched (Apache-2.0), called without Java, and SebType's model.
# jni.h, for the decoder's types: the NDK's on Android, a JDK's (JAVA_HOME) elsewhere.
if(SEBTYPE_ENGLISH)
  file(GLOB_RECURSE LATINIME_SRC ${ENGINES}/latinime/src/*.cpp)
  add_library(latinime STATIC ${LATINIME_SRC})
  target_include_directories(latinime PUBLIC ${ENGINES}/latinime/src)
  set_target_properties(latinime PROPERTIES CXX_STANDARD 17)
  target_compile_options(latinime PRIVATE -w)
  if(NOT ANDROID)
    find_path(JNI_H jni.h PATHS ENV JAVA_HOME PATH_SUFFIXES include REQUIRED NO_DEFAULT_PATH)
    target_include_directories(latinime PUBLIC ${JNI_H} ${JNI_H}/linux)
  endif()
  add_library(sebtype-english STATIC src/english.cpp)
  target_link_libraries(sebtype-english PUBLIC sebtype-logic PRIVATE latinime sebtype_lm)
  # llama.cpp's Unicode tables (src/unicode.h), linked already, for Java's letters in english.cpp
  target_include_directories(sebtype-english PRIVATE $<TARGET_PROPERTY:llama,SOURCE_DIR>)
endif()

# 中文's model around Rime (src/chinese.cpp, #264), with OpenCC for 繁: the target libopencc on Android
# (android/native builds it for librime), vcpkg's on Windows, the system's on Linux.
if(SEBTYPE_CHINESE_MODEL)
  add_library(sebtype-chinese STATIC src/chinese.cpp)
  if(TARGET libopencc)
    set(OPENCC_TARGET libopencc)
  elseif(WIN32)
    find_package(OpenCC CONFIG REQUIRED)  # vcpkg's (windows/build.ps1)
    set(OPENCC_TARGET OpenCC::OpenCC)
  else()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(OpenCC REQUIRED IMPORTED_TARGET opencc)
    set(OPENCC_TARGET PkgConfig::OpenCC)
  endif()
  target_link_libraries(sebtype-chinese PUBLIC sebtype-logic PRIVATE sebtype_zh_lm ${OPENCC_TARGET})
endif()

option(SEBTYPE_TESTS "Build the core's unit tests" ON)
if(SEBTYPE_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(core-test test/core_test.cpp)
  target_link_libraries(core-test sebtype-logic GTest::gtest_main)
  if(SEBTYPE_ENGLISH)
    # The English tests load the rebuilt dictionary and the committed model.
    target_link_libraries(core-test sebtype-english sebtype_lm)
    target_compile_definitions(core-test PRIVATE SEBTYPE_ENGLISH
      EN_DICT="${CMAKE_CURRENT_SOURCE_DIR}/../data/en-dict/en_US.dict"
      EN_MODEL="${ENGINES}/sebtype-lm/english.gguf" EN_USER_DIR="${CMAKE_CURRENT_BINARY_DIR}/english-user"
      EN_LEGACY_HISTORY="${CMAKE_CURRENT_SOURCE_DIR}/test/data/UserHistoryDictionary.en_US.dict")
  endif()
  if(SEBTYPE_CHINESE_MODEL)
    # The model around a stand-in Rime: the committed model, and OpenCC's tables (ZH_OPENCC, the system's).
    set(ZH_OPENCC /usr/share/opencc CACHE PATH "The folder with OpenCC's s2t.json and t2s.json")
    target_link_libraries(core-test sebtype-chinese)
    target_compile_definitions(core-test PRIVATE SEBTYPE_CHINESE_MODEL
      ZH_MODEL="${ENGINES}/sebtype-lm/chinese.gguf" ZH_OPENCC="${ZH_OPENCC}")
  endif()
  add_test(NAME core-test COMMAND core-test)
  if(SEBTYPE_CJK)
    # 日本語's engine around a stand-in Mozc (the test's own makeMozcTransport).
    add_executable(mozc-test test/mozc_test.cpp src/mozc.cpp src/mozc_learned.cpp ${PROTO_SRCS})
    target_include_directories(mozc-test PRIVATE src ${PROTO_OUT})
    target_link_libraries(mozc-test sebtype-logic ${PROTOBUF_TARGET} GTest::gtest_main)
    add_test(NAME mozc-test COMMAND mozc-test)
  endif()
endif()
