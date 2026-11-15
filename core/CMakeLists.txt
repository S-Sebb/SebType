cmake_minimum_required(VERSION 3.20)
project(sebtype-core CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

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

# Mozc runs in this process when SEBTYPE_MOZC_LIB names a Mozc library with the C interface in
# src/sebtype_mozc.h (the phone's libmozc.so, #220); without one, core/ talks to mozc_server over Mozc's IPC
# (the PCs, until #233).
set(SEBTYPE_MOZC_LIB "" CACHE FILEPATH "A Mozc library to run in this process instead of mozc_server")
set(MOZC_PROTOS protocol/commands.proto protocol/candidate_window.proto protocol/config.proto
  protocol/engine_builder.proto)
if(SEBTYPE_MOZC_LIB)
  set(MOZC_TRANSPORT src/mozc_inprocess.cpp)
else()
  set(MOZC_TRANSPORT src/mozc_ipc.cpp)
  list(APPEND MOZC_PROTOS ipc/ipc.proto)
endif()

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

# Switching, menus and paging: no engine needed, so the unit tests link only this.
add_library(sebtype-logic STATIC src/core.cpp src/pager.cpp)
target_include_directories(sebtype-logic PUBLIC include)

add_library(sebtype-core STATIC src/rime.cpp src/mozc.cpp ${MOZC_TRANSPORT} ${PROTO_SRCS})
target_include_directories(sebtype-core PRIVATE ${PROTO_OUT})
target_link_libraries(sebtype-core PUBLIC sebtype-logic ${RIME_TARGET} ${PROTOBUF_TARGET})
if(SEBTYPE_MOZC_LIB)
  target_compile_definitions(sebtype-core PUBLIC SEBTYPE_MOZC_INPROC)
  target_link_libraries(sebtype-core PUBLIC ${SEBTYPE_MOZC_LIB})
endif()

option(SEBTYPE_TESTS "Build the core's unit tests" ON)
if(SEBTYPE_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(core-test test/core_test.cpp)
  target_link_libraries(core-test sebtype-logic GTest::gtest_main)
  add_test(NAME core-test COMMAND core-test)
endif()
