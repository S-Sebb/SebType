# SebType: librime is engines/librime, the source the PCs build too.
file(STRINGS "${LIBRIME_SOURCE_DIR}/CMakeLists.txt" LIBRIME_VERSION REGEX "^set\\(rime_version ")
string(REGEX REPLACE "^set\\(rime_version ([^)]+)\\)$" "\\1" LIBRIME_VERSION "${LIBRIME_VERSION}")

include(librime-plugins)

# Do not use add_subdirectory(${LIBRIME_SOURCE_DIR}),
# because its find_package() could not find external libraries.
include(override/librime/main)

add_to_include(librime "${LIBRIME_SOURCE_DIR}/src")
