# SebType: protobuf-lite for core/'s Mozc protocol (the phone talks to Mozc in its process, mozc_inprocess.cpp),
# and the host's protoc of the same version to compile Mozc's .proto files. 3.21 is the last release that
# needs no Abseil. Pinned and checksum-checked like the other dependencies (Helper.cmake).
download_and_extract(
    "protobuf"
    "3.21.12"
    ".tar.gz"
    "https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protobuf-cpp-3.21.12.tar.gz"
    "4eab9b524aa5913c6fffb20b2a8abf5ef7f95a80bc0701f3a6dbb4c607f73460"
)
download_and_extract(
    "protoc"
    "21.12-linux-x86_64"
    ".zip"
    "https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protoc-21.12-linux-x86_64.zip"
    "3a4c1e5f2516c639d3079b1586e703fc7bcfa2136d58bda24d1d54f949c315e8"
)
set(PROTOC "${PROTOC_SOURCE_DIR}/bin/protoc")
file(CHMOD "${PROTOC}" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)

set(protobuf_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(protobuf_BUILD_CONFORMANCE OFF CACHE BOOL "" FORCE)
set(protobuf_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(protobuf_BUILD_PROTOC_BINARIES OFF CACHE BOOL "" FORCE)
set(protobuf_BUILD_LIBPROTOC OFF CACHE BOOL "" FORCE)
set(protobuf_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(protobuf_WITH_ZLIB OFF CACHE BOOL "" FORCE)
set(protobuf_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory("${PROTOBUF_SOURCE_DIR}" ${RIME_JNI_BUILD_DIR}/protobuf_build EXCLUDE_FROM_ALL)
set(PROTOBUF_TARGET libprotobuf-lite)
