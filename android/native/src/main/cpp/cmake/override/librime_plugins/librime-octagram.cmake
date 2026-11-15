set(PLUGIN_SRC_DIR ${LIBRIME_OCTAGRAM_SOURCE_DIR}/src)

file(GLOB PLUGIN_SOURCES ${PLUGIN_SRC_DIR}/*.cc)

add_library(rime-octagram-objs OBJECT
    ${PLUGIN_SOURCES}
)

target_include_directories(rime-octagram-objs PRIVATE
    ${PLUGIN_SRC_DIR}
    ${JNI_INCLUDE_DIR}
    ${JNI_INCLUDE_DIR}/marisa
)

target_link_libraries(rime-octagram-objs PRIVATE ${BOOST_DEPS})

set(plugin_modules "octagram")
set(plugin_objs $<TARGET_OBJECTS:rime-octagram-objs>)
