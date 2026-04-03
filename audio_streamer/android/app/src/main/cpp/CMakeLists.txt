cmake_minimum_required(VERSION 3.22.1)
project("audio_streamer_native")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(oboe REQUIRED CONFIG)

add_library(audio_streamer_native SHARED
    AudioEngine.cpp
    UdpReceiver.cpp
)

target_link_libraries(audio_streamer_native
    oboe::oboe
    log
    android
)

target_include_directories(audio_streamer_native PRIVATE
    .
)

