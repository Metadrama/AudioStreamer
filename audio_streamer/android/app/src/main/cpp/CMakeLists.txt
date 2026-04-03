cmake_minimum_required(VERSION 3.22.1)
project("audio_streamer_native")

find_package(oboe REQUIRED CONFIG)

add_library(audio_streamer_native SHARED
    AudioEngine.cpp
)

target_link_libraries(audio_streamer_native
    oboe::oboe
    log
    android
)

target_include_directories(audio_streamer_native PRIVATE
    .
)
