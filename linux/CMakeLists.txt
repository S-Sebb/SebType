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

add_library(sebtype MODULE src/sebtype.cpp src/tray.cpp)
# Mozc's library (SEBTYPE_MOZC_LIB, from Bazel) goes to %{_libdir}/sebtype, beside Fcitx5's add-on folder. Set
# on the target: Fcitx5's compiler settings override CMAKE_INSTALL_RPATH.
set_target_properties(sebtype PROPERTIES PREFIX "" INSTALL_RPATH "$ORIGIN/../sebtype" INSTALL_RPATH_USE_LINK_PATH OFF)
target_compile_definitions(sebtype PRIVATE RIME_DATA_DIR="${RIME_DATA_DIR}")
target_link_libraries(sebtype sebtype-core Fcitx5::Core Fcitx5::Module::DBus Fcitx5::Module::NotificationItem)

install(TARGETS sebtype DESTINATION "${CMAKE_INSTALL_LIBDIR}/fcitx5")
install(PROGRAMS ${SEBTYPE_MOZC_LIB} DESTINATION "${CMAKE_INSTALL_LIBDIR}/sebtype")
install(FILES data/sebtype.conf DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5/addon")
install(FILES data/notificationitem.conf DESTINATION "${CMAKE_INSTALL_DATADIR}/sebtype/fcitx5/addon")
