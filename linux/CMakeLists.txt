# SebType's Fcitx5 add-on over SebType's core (../core). Built by build.sh into the sebtype RPM.
cmake_minimum_required(VERSION 3.20)
project(sebtype-linux CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(SEBTYPE_TESTS "Build the core's unit tests" ON)
add_subdirectory(../core core)

find_package(Fcitx5Core REQUIRED)
find_package(Fcitx5ModuleDBus REQUIRED)
find_package(Fcitx5ModuleNotificationItem REQUIRED)
include("${FCITX_INSTALL_CMAKECONFIG_DIR}/Fcitx5Utils/Fcitx5CompilerSettings.cmake" OPTIONAL)
include(GNUInstallDirs)
pkg_get_variable(RIME_DATA_DIR rime pkgdatadir)
pkg_check_modules(Cairo REQUIRED IMPORTED_TARGET cairo)

add_library(sebtype MODULE src/sebtype.cpp src/tray.cpp)
# Mozc's library (SEBTYPE_MOZC_LIB, from Bazel) goes to %{_libdir}/sebtype, beside Fcitx5's add-on folder. Set
# on the target: Fcitx5's compiler settings override CMAKE_INSTALL_RPATH.
set_target_properties(sebtype PROPERTIES PREFIX "" INSTALL_RPATH "$ORIGIN/../sebtype" INSTALL_RPATH_USE_LINK_PATH OFF)
target_compile_definitions(sebtype PRIVATE RIME_DATA_DIR="${RIME_DATA_DIR}")
target_link_libraries(sebtype sebtype-core Fcitx5::Core Fcitx5::Module::DBus Fcitx5::Module::NotificationItem
  PkgConfig::Cairo)

install(TARGETS sebtype DESTINATION "${CMAKE_INSTALL_LIBDIR}/fcitx5")
install(PROGRAMS ${SEBTYPE_MOZC_LIB} DESTINATION "${CMAKE_INSTALL_LIBDIR}/sebtype")
install(FILES data/sebtype.conf DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5/addon")
install(FILES data/notificationitem.conf DESTINATION "${CMAKE_INSTALL_DATADIR}/sebtype/fcitx5/addon")

# The tray icons (../pc/icons), each size drawn at its own pixels (#275). The tray item sends every size from
# sebtype/tray as its pixmaps (#441). The menu's icons are named sebtype-<state> in hicolor, where every icon
# theme looks last, so they need no icon theme of SebType's (#278); the @2 folders take the double-size
# drawing, and scalable the 48 px one as an SVG.
set(icons ${CMAKE_SOURCE_DIR}/../pc/icons)
install(DIRECTORY ${icons}/ DESTINATION "${CMAKE_INSTALL_DATADIR}/sebtype/tray" FILES_MATCHING PATTERN "*.png"
  PATTERN scalable EXCLUDE)
file(GLOB states RELATIVE ${icons}/scalable ${icons}/scalable/*.svg)
foreach(pair 16:16x16 22:22x22 24:24x24 32:32x32 48:48x48 64:64x64 32:16x16@2 44:22x22@2 48:24x24@2 64:32x32@2)
  string(REPLACE ":" ";" pair ${pair})
  list(GET pair 0 size)
  list(GET pair 1 dir)
  foreach(state ${states})
    string(REPLACE .svg .png png ${state})
    install(FILES ${icons}/${size}/${png} DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/${dir}/status"
      RENAME sebtype-${png})
  endforeach()
endforeach()
foreach(state ${states})
  install(FILES ${icons}/scalable/${state} DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/status"
    RENAME sebtype-${state})
endforeach()
