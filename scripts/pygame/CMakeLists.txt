cmake_minimum_required(VERSION 3.20)
project(PyPhonePygameDependencies LANGUAGES C OBJC)

# Both SDL aliases deliberately resolve to PyPhone's existing dynamic framework.
# Never compile a second SDL into an addon or an extension module.
add_library(SDL2::SDL2 SHARED IMPORTED GLOBAL)
set_target_properties(SDL2::SDL2 PROPERTIES
    IMPORTED_LOCATION "${SDL_FRAMEWORK}/SDL2"
    INTERFACE_INCLUDE_DIRECTORIES "${SDL_FRAMEWORK}/Headers")
add_library(SDL2::SDL2-static ALIAS SDL2::SDL2)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(SDL2IMAGE_INSTALL OFF CACHE BOOL "" FORCE)
set(SDL2IMAGE_SAMPLES OFF CACHE BOOL "" FORCE)
set(SDL2IMAGE_TESTS OFF CACHE BOOL "" FORCE)
set(SDL2IMAGE_AVIF OFF CACHE BOOL "" FORCE)
set(SDL2IMAGE_JXL OFF CACHE BOOL "" FORCE)
set(SDL2IMAGE_TIF OFF CACHE BOOL "" FORCE)
set(SDL2IMAGE_WEBP OFF CACHE BOOL "" FORCE)
set(SDL2IMAGE_BACKEND_IMAGEIO ON CACHE BOOL "" FORCE)
set(SDL2TTF_INSTALL OFF CACHE BOOL "" FORCE)
set(SDL2TTF_SAMPLES OFF CACHE BOOL "" FORCE)
set(SDL2TTF_VENDORED ON CACHE BOOL "" FORCE)
set(SDL2TTF_HARFBUZZ OFF CACHE BOOL "" FORCE)
set(SDL2MIXER_INSTALL OFF CACHE BOOL "" FORCE)
set(SDL2MIXER_SAMPLES OFF CACHE BOOL "" FORCE)
set(SDL2MIXER_DEPS_SHARED OFF CACHE BOOL "" FORCE)
set(SDL2MIXER_MOD OFF CACHE BOOL "" FORCE)
set(SDL2MIXER_MIDI OFF CACHE BOOL "" FORCE)
set(SDL2MIXER_OPUS OFF CACHE BOOL "" FORCE)
set(SDL2MIXER_WAVPACK OFF CACHE BOOL "" FORCE)
set(SDL2MIXER_VORBIS STB CACHE STRING "" FORCE)
add_subdirectory("${ADDON_SOURCE}/image" image)
add_subdirectory("${ADDON_SOURCE}/ttf" ttf)
add_subdirectory("${ADDON_SOURCE}/mixer" mixer)
target_link_libraries(SDL2_image PRIVATE
    "-framework Foundation" "-framework UIKit" "-framework CoreGraphics"
    "-framework ImageIO" "-framework MobileCoreServices")

# One shared copy of the addons keeps mixer and mixer_music on the same state.
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/dependencies.c" "void pyphone_pygame_dependencies(void) {}\n")
add_library(PygameDependencies SHARED "${CMAKE_CURRENT_BINARY_DIR}/dependencies.c")
set_target_properties(PygameDependencies PROPERTIES
    FRAMEWORK TRUE
    MACOSX_FRAMEWORK_IDENTIFIER com.example.pyphone.pygame-dependencies
    MACOSX_FRAMEWORK_SHORT_VERSION_STRING 2.6.1
    MACOSX_FRAMEWORK_BUNDLE_VERSION 1
    BUILD_WITH_INSTALL_NAME_DIR TRUE
    INSTALL_NAME_DIR "@rpath")
target_link_libraries(PygameDependencies PRIVATE SDL2_image SDL2_ttf SDL2_mixer)
target_link_options(PygameDependencies PRIVATE
    "-Wl,-force_load,$<TARGET_FILE:SDL2_image>"
    "-Wl,-force_load,$<TARGET_FILE:SDL2_ttf>"
    "-Wl,-force_load,$<TARGET_FILE:SDL2_mixer>")
