# SebType on Windows: the server (sebtype-server.exe, with the core) and the text service (sebtype.dll). The
# server runs Mozc from sebtype-mozc.dll (pc/windows/mozc/build.ps1), installed beside it.
#   cmake -S windows -B build -DRIME_ROOT=<librime> -DSEBTYPE_ICONS=<make_icons.py's output>
# A 32-bit build for 32-bit apps takes -DSEBTYPE_TIP_ONLY=ON: the text service alone; it reaches the 64-bit
# server over its pipe.
cmake_minimum_required(VERSION 3.20)
project(sebtype-windows CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# The C++ runtime inside each file: the DLL loads into every app, which may not have Visual C++'s.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

option(SEBTYPE_TIP_ONLY "Build only the text service" OFF)
set(SEBTYPE_ICONS "" CACHE PATH "The tray icons, from make_icons.py")

add_compile_definitions(UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
if(MSVC)
  add_compile_options(/utf-8 /W3)
endif()

# The text service.
set(ICONS ${SEBTYPE_ICONS})
set(PIG ${CMAKE_CURRENT_SOURCE_DIR}/data/sebtype-logo.png)
configure_file(src/tip/sebtype.rc.in ${CMAKE_CURRENT_BINARY_DIR}/sebtype.rc @ONLY)
add_library(sebtype SHARED src/tip/dll.cpp src/tip/textservice.cpp src/tip/edit.cpp src/tip/candidate_window.cpp
  src/tip/candidate_layout.cpp src/tip/langbar.cpp src/tip/sebtype.def ${CMAKE_CURRENT_BINARY_DIR}/sebtype.rc)
set_target_properties(sebtype PROPERTIES PREFIX "")
target_include_directories(sebtype PRIVATE src/tip ../core/include)
target_link_libraries(sebtype PRIVATE d2d1 dwrite windowscodecs shcore shlwapi advapi32 ole32 oleaut32 uuid)
if(NOT MSVC)
  target_link_options(sebtype PRIVATE -static)
endif()

# The candidate window's layout, tested without a screen, and the calls to a server that hangs (windows/build.ps1
# runs both).
if(NOT SEBTYPE_TIP_ONLY)
  add_executable(candidate-layout-test test/candidate_layout_test.cpp src/tip/candidate_layout.cpp)
  target_include_directories(candidate-layout-test PRIVATE src/tip)
  add_executable(pipe-test test/pipe_test.cpp)
  target_include_directories(pipe-test PRIVATE src ../core/include)
endif()

# The server, with the core.
if(NOT SEBTYPE_TIP_ONLY)
  # sebtype-mozc.dll's import library, from the exports Bazel builds it with: the DLL itself isn't needed here.
  set(MOZC_DEF ${CMAKE_CURRENT_SOURCE_DIR}/../engines/mozc/src/sebtype/sebtype_mozc.def)
  set(MOZC_IMPLIB ${CMAKE_CURRENT_BINARY_DIR}/sebtype-mozc.lib)
  add_custom_command(OUTPUT ${MOZC_IMPLIB}
    COMMAND ${CMAKE_AR} /nologo /machine:x64 /def:${MOZC_DEF} /out:${MOZC_IMPLIB} DEPENDS ${MOZC_DEF})
  add_custom_target(sebtype-mozc-implib DEPENDS ${MOZC_IMPLIB})
  set(SEBTYPE_MOZC_LIB ${MOZC_IMPLIB} CACHE FILEPATH "" FORCE)
  set(SEBTYPE_TESTS OFF CACHE BOOL "" FORCE)
  add_subdirectory(../core core)
  add_dependencies(sebtype-core sebtype-mozc-implib)
  add_executable(sebtype-server WIN32 src/server.cpp)
  target_link_libraries(sebtype-server PRIVATE sebtype-core advapi32 shell32 ole32 delayimp)
  # Mozc's DLL loads at the first 日本語 key, not with the server: Rime alone doesn't map its dictionary.
  target_link_options(sebtype-server PRIVATE /DELAYLOAD:sebtype-mozc.dll)
endif()
