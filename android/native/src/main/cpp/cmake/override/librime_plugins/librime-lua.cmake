set(LUA_SRC_DIR ${LUA_SOURCE_DIR})
set(PLUGIN_SRC_DIR ${LIBRIME_LUA_SOURCE_DIR}/src)

# The lua/lua mirror keeps the interpreter, the amalgamation and the test
# library next to the core sources; only the core library is wanted.
file(GLOB LUA_SOURCES ${LUA_SRC_DIR}/*.c)
list(REMOVE_ITEM LUA_SOURCES
    ${LUA_SRC_DIR}/lua.c
    ${LUA_SRC_DIR}/onelua.c
    ${LUA_SRC_DIR}/ltests.c
)
set_property(SOURCE ${LUA_SOURCES} PROPERTY COMPILE_DEFINITIONS LUA_USE_POSIX)

file(GLOB PLUGIN_SOURCES
    ${PLUGIN_SRC_DIR}/*.cc
    ${PLUGIN_SRC_DIR}/lib/*.c
    ${PLUGIN_SRC_DIR}/lib/*.cc
)

add_library(rime-lua-objs OBJECT
    ${LUA_SOURCES}
    ${PLUGIN_SOURCES}
)

target_include_directories(rime-lua-objs PRIVATE
    ${LUA_SRC_DIR}
    ${PLUGIN_SRC_DIR}
    ${PLUGIN_SRC_DIR}/lib
    ${JNI_INCLUDE_DIR}
    ${JNI_INCLUDE_DIR}/marisa
)

# Same definition librime-lua's own CMakeLists uses for in-tree Lua.
target_compile_definitions(rime-lua-objs PRIVATE LUA_COMPAT_5_3)

target_link_libraries(rime-lua-objs PRIVATE ${BOOST_DEPS} libopencc)

set(plugin_modules "lua")
set(plugin_objs $<TARGET_OBJECTS:rime-lua-objs>)
