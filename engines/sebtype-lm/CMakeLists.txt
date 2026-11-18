# SebType's model loaders (MIT) on llama.cpp (MIT): English's and Chinese's. The parent adds llama.cpp first
# (fetch-llama.sh fetches it), so the `llama` target exists.
add_library(sebtype_lm STATIC sebtype_lm.cpp)
target_include_directories(sebtype_lm PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(sebtype_lm PUBLIC llama)
add_library(sebtype_zh_lm STATIC zh_lm.cpp)
target_include_directories(sebtype_zh_lm PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(sebtype_zh_lm PUBLIC llama)
