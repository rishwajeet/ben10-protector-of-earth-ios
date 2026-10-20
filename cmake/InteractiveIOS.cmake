# Local original-game app; proprietary data and the build tree stay outside Git.
if(NOT APPLE OR NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "PROTECTOR_BUILD_IOS_INTERACTIVE requires iOS")
endif()
enable_language(OBJCXX)
option(PROTECTOR_IOS_EXTERNAL_CONTENT "Import personal content outside the signed application" OFF)
set(PROTECTOR_IOS_PLATFORM_NAME "iphoneos")
set(PROTECTOR_IOS_SUPPORTED_PLATFORM "iPhoneOS")
if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
    set(PROTECTOR_IOS_PLATFORM_NAME "iphonesimulator")
    set(PROTECTOR_IOS_SUPPORTED_PLATFORM "iPhoneSimulator")
endif()
set(PROTECTOR_IOS_DATA_ROOT "" CACHE PATH "External extracted RBNEG9 DATA partition")
file(REAL_PATH "${CMAKE_SOURCE_DIR}" PROTECTOR_SOURCE_REAL)
file(REAL_PATH "${CMAKE_BINARY_DIR}" PROTECTOR_BUILD_REAL)
file(REAL_PATH "${PROTECTOR_IOS_DATA_ROOT}" PROTECTOR_DATA_REAL)
file(REAL_PATH "${PROTECTOR_GENERATED_DIR}" PROTECTOR_GENERATED_REAL)
foreach(PROTECTOR_EXTERNAL IN ITEMS "${PROTECTOR_BUILD_REAL}"
        "${PROTECTOR_DATA_REAL}" "${PROTECTOR_GENERATED_REAL}")
    cmake_path(IS_PREFIX PROTECTOR_SOURCE_REAL "${PROTECTOR_EXTERNAL}" NORMALIZE PROTECTOR_INSIDE)
    if(PROTECTOR_INSIDE)
        message(FATAL_ERROR "Interactive app build, data, and generated code must be outside Git")
    endif()
endforeach()
if(NOT EXISTS "${PROTECTOR_IOS_DATA_ROOT}/sys/main.dol" OR
   NOT EXISTS "${PROTECTOR_IOS_DATA_ROOT}/sys/fst.bin" OR
   NOT EXISTS "${PROTECTOR_IOS_KPAD_REFERENCE}")
    message(FATAL_ERROR "The extracted game and KPAD reference are required")
endif()
file(SHA256 "${PROTECTOR_IOS_DATA_ROOT}/sys/main.dol" PROTECTOR_DOL_HASH)
if(NOT PROTECTOR_DOL_HASH STREQUAL
   "03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566")
    message(FATAL_ERROR "Interactive app requires the pinned RBNEG9 DOL")
endif()
file(GLOB PROTECTOR_INTERACTIVE_CHUNKS CONFIGURE_DEPENDS
    "${PROTECTOR_GENERATED_DIR}/chunks/*.c")
list(LENGTH PROTECTOR_INTERACTIVE_CHUNKS PROTECTOR_INTERACTIVE_CHUNK_COUNT)
if(NOT PROTECTOR_INTERACTIVE_CHUNK_COUNT EQUAL 120)
    message(FATAL_ERROR "Interactive app requires 120 prepared translation chunks")
endif()
# Generated code only: cpu.c defines the out-of-line accessors the macros wrap.
set_property(SOURCE ${PROTECTOR_INTERACTIVE_CHUNKS} APPEND PROPERTY
    COMPILE_DEFINITIONS PROTECTOR_INLINE_GUEST_MEMORY=1)
configure_file("${PROTECTOR_IOS_KPAD_REFERENCE}"
    "${CMAKE_BINARY_DIR}/kpad-reference.json" COPYONLY)
set_source_files_properties("${CMAKE_BINARY_DIR}/kpad-reference.json"
    PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
add_executable(protector_ios_interactive MACOSX_BUNDLE
    native/ios/interactive_main.mm native/ios/touch_settings.mm native/ios/qa/controller_snapshot_qa.mm native/apple/game_session.mm
    native/macos/boot_main.c native/metal/live_gx_renderer.mm
    native/metal/texture_pack.mm native/metal/geometry_pack.mm native/metal/cinematic_pack.mm
    "${CMAKE_BINARY_DIR}/kpad-reference.json" ${PROTECTOR_INTERACTIVE_CHUNKS})
protector_embed_audio_coefficients(protector_ios_interactive)
if(PROTECTOR_IOS_EXTERNAL_CONTENT)
    configure_file("${CMAKE_SOURCE_DIR}/reference/personal_build_inputs.json"
        "${CMAKE_BINARY_DIR}/personal-build-inputs.json" COPYONLY)
    set_source_files_properties("${CMAKE_BINARY_DIR}/personal-build-inputs.json"
        PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
    target_sources(protector_ios_interactive PRIVATE "${CMAKE_BINARY_DIR}/personal-build-inputs.json")
    target_sources(protector_ios_interactive PRIVATE native/apple/content_store.mm native/ios/content_import.mm native/apple/audio_output.mm)
    target_sources(protector_ios_interactive PRIVATE native/apple/save_backup.mm native/ios/save_backup_controller.mm)
    target_compile_definitions(protector_ios_interactive PRIVATE PROTECTOR_IOS_EXTERNAL_CONTENT=1)
    set_property(SOURCE native/apple/game_session.mm APPEND PROPERTY
        COMPILE_DEFINITIONS PROTECTOR_NATIVE_AUDIO_OUTPUT=1)
else()
include("${CMAKE_SOURCE_DIR}/cmake/InteractiveTexturePack.cmake")
protector_embed_texture_pack(protector_ios_interactive)
include("${CMAKE_SOURCE_DIR}/cmake/InteractiveGeometryPack.cmake")
protector_embed_geometry_pack(protector_ios_interactive)
include("${CMAKE_SOURCE_DIR}/cmake/InteractiveCinematicPack.cmake")
protector_embed_cinematic_pack(protector_ios_interactive)
file(GLOB_RECURSE PROTECTOR_GAME_FILES CONFIGURE_DEPENDS
    "${PROTECTOR_IOS_DATA_ROOT}/sys/*" "${PROTECTOR_IOS_DATA_ROOT}/files/*")
foreach(PROTECTOR_GAME_FILE IN LISTS PROTECTOR_GAME_FILES)
    if(NOT IS_DIRECTORY "${PROTECTOR_GAME_FILE}")
        file(RELATIVE_PATH PROTECTOR_GAME_RELATIVE "${PROTECTOR_IOS_DATA_ROOT}" "${PROTECTOR_GAME_FILE}")
        get_filename_component(PROTECTOR_GAME_DIRECTORY "${PROTECTOR_GAME_RELATIVE}" DIRECTORY)
        set_source_files_properties("${PROTECTOR_GAME_FILE}" PROPERTIES
            MACOSX_PACKAGE_LOCATION "Resources/Game/${PROTECTOR_GAME_DIRECTORY}")
        target_sources(protector_ios_interactive PRIVATE "${PROTECTOR_GAME_FILE}")
    endif()
endforeach()
endif()
target_include_directories(protector_ios_interactive PRIVATE
    "${PROTECTOR_GENERATED_DIR}" "${CMAKE_SOURCE_DIR}/native/include")
target_compile_definitions(protector_ios_interactive PRIVATE
    DOLRECOMP_CPU_HEADER="protector/cpu.h" PROTECTOR_LIVE_METAL=1)
target_compile_options(protector_ios_interactive PRIVATE -Wall -Wextra -Wpedantic
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc> $<$<COMPILE_LANGUAGE:OBJCXX>:-Werror>)
target_link_libraries(protector_ios_interactive PRIVATE protector_runtime m objc
    "-framework Foundation" "-framework UIKit" "-framework GameController" "-framework Metal"
    "-framework MetalKit" "-framework QuartzCore" "-framework CoreGraphics"
    "-framework AVFoundation" "-framework CoreVideo" "-framework CoreMedia"
    "-framework ImageIO" "-framework UniformTypeIdentifiers")
set_target_properties(protector_ios_interactive PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/native/ios/InteractiveInfo.plist.in"
    XCODE_GENERATE_SCHEME TRUE
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${PROTECTOR_IOS_BUNDLE_IDENTIFIER}"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO")
if(PROTECTOR_IOS_CODE_SIGNING_ALLOWED)
    if(PROTECTOR_IOS_DEVELOPMENT_TEAM STREQUAL "")
        message(FATAL_ERROR "Signing requires an explicit development team")
    endif()
    set_target_properties(protector_ios_interactive PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "YES"
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "YES"
        XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
        XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${PROTECTOR_IOS_DEVELOPMENT_TEAM}")
endif()
