# License

## Project License

`:native`, the phone's native library (#191): SebType's own files (build.gradle, build-mozc.sh,
src/main/cpp/CMakeLists.txt, src/main/cpp/cmake/protobuf.cmake, src/main/cpp/sebtype_jni.cpp and
src/main/java/) are under the MIT licence in ../../LICENSE-SebType. The other files in src/main/cpp/cmake/
are RimeJni's build scripts with SebType's changes, under RimeJni's [MIT License](src/main/cpp/cmake/LICENSE).
It links core/ (../../core, see its README for its files' licences) and Mozc's libmozc.so, built from
../../engines/mozc under Mozc's licence (BSD-3-Clause). English (stage 4) builds in AOSP LatinIME's decoder
(../../engines/latinime, Apache-2.0) and llama.cpp (MIT), which ../../engines/sebtype-lm/fetch-llama.sh
fetches at build time.

## Third-party License

`src/main/assets/licenses` (which ships in the APK) contains license texts for all third-party dependencies used in this project.

### Files

| Library | License File | License Type |
|---------|--------------|--------------|
| Boost | [Boost-LICENSE.txt](src/main/assets/licenses/Boost-LICENSE.txt) | BSL-1.0 |
| LevelDB | [LevelDB-LICENSE.txt](src/main/assets/licenses/LevelDB-LICENSE.txt) |  BSD-3-Clause |
| Librime | [RIME-LICENSE.txt](src/main/assets/licenses/RIME-LICENSE.txt) | BSD-3-Clause |
| Librime-Lua | [Librime-lua-LICENSE.txt](src/main/assets/licenses/Librime-lua-LICENSE.txt) | BSD-3-Clause |
| Librime-Octagram | [Librime-octagram-LICENSE.txt](src/main/assets/licenses/Librime-octagram-LICENSE.txt) | BSD-3-Clause |
| Lua | [Lua-LICENSE.txt](src/main/assets/licenses/Lua-LICENSE.txt) | MIT |
| Marisa-Trie | [Marisa-trie-LICENSE.txt](src/main/assets/licenses/Marisa-trie-LICENSE.txt) | BSD-2-Clause (CHOSEN) |
| Protobuf (protobuf-lite 3.21.12) | [Protobuf-LICENSE.txt](src/main/assets/licenses/Protobuf-LICENSE.txt) | BSD-3-Clause |
| OpenCC | [OpenCC-LICENSE.txt](src/main/assets/licenses/OpenCC-LICENSE.txt) | Apache-2.0 |
| Yaml-cpp | [Yaml-cpp-LICENSE.txt](src/main/assets/licenses/Yaml-cpp-LICENSE.txt) | MIT |
| llama.cpp | [Llama.cpp-LICENSE.txt](src/main/assets/licenses/Llama.cpp-LICENSE.txt) | MIT |
| AOSP LatinIME's decoder | [AOSP-LatinIME-LICENSE.txt](src/main/assets/licenses/AOSP-LatinIME-LICENSE.txt) | Apache-2.0 |
| utf8_range (in Mozc's Protocol Buffers 34.1) | [Utf8-range-LICENSE.txt](src/main/assets/licenses/Utf8-range-LICENSE.txt) | MIT |
| RapidJSON (in OpenCC) | [RapidJSON-LICENSE.txt](src/main/assets/licenses/RapidJSON-LICENSE.txt) | MIT |
| llamafile's sgemm (in ggml) | [Llamafile-sgemm-LICENSE.txt](src/main/assets/licenses/Llamafile-sgemm-LICENSE.txt) | MIT |
| YaRN (in ggml) | [YaRN-LICENSE.txt](src/main/assets/licenses/YaRN-LICENSE.txt) | MIT |
| Japanese Usage Dictionary (in Mozc's dictionary) | [Japanese-usage-dictionary-LICENSE.txt](src/main/assets/licenses/Japanese-usage-dictionary-LICENSE.txt) | BSD-2-Clause |
| Japan Post postal codes (in Mozc's dictionary) | [Japan-Post-zipcode-NOTICE.txt](src/main/assets/licenses/Japan-Post-zipcode-NOTICE.txt) | no copyright claimed |

The app adds the texts the repository already holds (android/app/build.gradle's `copyLicences`), among them
darts-clone and the X11 keysym notice from librime's bundled headers.
