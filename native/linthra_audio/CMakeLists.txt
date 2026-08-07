cmake_minimum_required(VERSION 3.16)
project(linthra_audio LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(linthra_audio STATIC
    src/dsp.cpp
    src/c_api.cpp
)

target_include_directories(linthra_audio
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(linthra_audio PRIVATE
    $<$<CXX_COMPILER_ID:Clang,GNU>:-Wall -Wextra -Wpedantic -Werror>
)

add_executable(linthra_audio_tests tests/dsp_test.cpp)
target_link_libraries(linthra_audio_tests PRIVATE linthra_audio)

add_executable(linthra_audio_benchmark tests/realtime_benchmark.cpp)
target_link_libraries(linthra_audio_benchmark PRIVATE linthra_audio)

enable_testing()
add_test(NAME linthra_audio_tests COMMAND linthra_audio_tests)
add_test(NAME linthra_audio_realtime_budget COMMAND linthra_audio_benchmark)
