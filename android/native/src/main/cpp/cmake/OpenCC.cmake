set(OPENCC_VERSION "1.2.0")
set(OPENCC_URL "https://github.com/BYVoid/OpenCC/archive/refs/tags/ver.${OPENCC_VERSION}.tar.gz")

download_and_extract(
    "OpenCC"
    ${OPENCC_VERSION}
    ".tar.gz"
    ${OPENCC_URL}
    "f4f86eb25e239450d075081e08594801aa063c298d21d9f6c6aa85cd55241962"
)

set(USE_SYSTEM_MARISA ON CACHE BOOL "" FORCE)
# No DartsDict (.ocd), as on Linux: the Chinese data's OpenCC dictionaries are ocd2 (marisa) and text, so
# darts-clone would only add code.
set(ENABLE_DARTS OFF CACHE BOOL "" FORCE)
set(LIBMARISA marisa CACHE STRING "" FORCE)

add_subdirectory(${OPENCC_SOURCE_DIR} ${RIME_JNI_BUILD_DIR}/opencc_build EXCLUDE_FROM_ALL)

add_to_include(OpenCC "${OPENCC_SOURCE_DIR}/src")

unset(USE_SYSTEM_MARISA CACHE)
unset(LIBMARISA CACHE)
unset(ENABLE_DARTS CACHE)
