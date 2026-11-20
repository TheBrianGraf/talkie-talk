cmake_minimum_required(VERSION 3.20)
project(handy-qvac LANGUAGES CXX)

find_package(qvac-parakeet CONFIG REQUIRED)

add_executable(handy-qvac main.cpp)
target_link_libraries(handy-qvac PRIVATE qvac::parakeet)

if(APPLE)
    # Static ggml registers Metal from a constructor. Force the Metal archive
    # in so the linker does not drop it for lack of a direct reference.
    if(TARGET ggml-metal)
        target_link_libraries(handy-qvac PRIVATE ggml-metal)
    elseif(TARGET ggml::ggml-metal)
        target_link_libraries(handy-qvac PRIVATE ggml::ggml-metal)
    endif()
endif()
