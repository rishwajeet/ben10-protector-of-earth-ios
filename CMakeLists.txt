cmake_minimum_required(VERSION 3.20)
project(ProtectorNativeRuntime VERSION 0.1.0 LANGUAGES C)

include(CTest)
include(cmake/InteractiveAudio.cmake)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

option(PROTECTOR_ENABLE_LTO
       "Use supported C-runtime link-time optimization in Release builds" OFF)
if(PROTECTOR_ENABLE_LTO)
    include(CheckIPOSupported)
    # Keep numerical options independent: LTO must not imply fast math or
    # floating-point contraction. CheckIPOSupported cannot test Objective-C++;
    # the Apple shell links must also be verified with the actual C bitcode.
    check_ipo_supported(RESULT PROTECTOR_LTO_SUPPORTED
                        OUTPUT PROTECTOR_LTO_ERROR LANGUAGES C)
    if(NOT PROTECTOR_LTO_SUPPORTED)
        message(FATAL_ERROR "Requested LTO is unavailable: ${PROTECTOR_LTO_ERROR}")
    endif()
    set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE TRUE)
endif()

add_library(protector_runtime STATIC
    native/src/audio_output.c
    native/src/ax.c
    native/src/ax_audio.c
    native/src/ax_pb.c
    native/src/ax_engine.c
    native/src/ax_diagnostics.c
    native/src/boot.c
    native/src/cpu.c
    native/src/cinematic.c
    native/src/dol_loader.c
    native/src/full_state.c
    native/src/guest_pacer.c
    native/src/motion_clock.c
    native/src/live_gx.c
    native/src/visibility.c
    native/src/live_input.c
    native/src/menu_input.c
    native/src/touch_layout.c
    native/src/ui_text.c
    native/src/ui_context.c
    native/src/tutorial_context.c
    native/src/interaction_context.c
    native/src/script_flow.c
    native/src/ui_copy.c
    native/src/platform.c
    native/src/room.c
    native/src/save_store.c
)
target_include_directories(protector_runtime
    PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/native/include"
)
target_compile_options(protector_runtime PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Werror
)

if(APPLE)
    target_compile_definitions(protector_runtime PUBLIC PROTECTOR_DARWIN=1)
endif()

if(BUILD_TESTING)
    add_executable(protector_audio_output_tests native/tests/audio_output_tests.c)
    target_link_libraries(protector_audio_output_tests PRIVATE protector_runtime)
    target_compile_options(protector_audio_output_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_audio_output_tests COMMAND protector_audio_output_tests)
    add_executable(protector_cinematic_tests native/tests/cinematic_tests.c)
    target_link_libraries(protector_cinematic_tests PRIVATE protector_runtime)
    target_compile_options(protector_cinematic_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_cinematic_tests COMMAND protector_cinematic_tests)
    add_executable(protector_menu_input_tests native/tests/menu_input_tests.c)
    target_link_libraries(protector_menu_input_tests PRIVATE protector_runtime)
    target_compile_options(protector_menu_input_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_menu_input_tests COMMAND protector_menu_input_tests)
    add_executable(protector_dvd_async_tests native/tests/dvd_async_tests.c)
    target_link_libraries(protector_dvd_async_tests PRIVATE protector_runtime m)
    target_compile_options(protector_dvd_async_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_dvd_async_tests COMMAND protector_dvd_async_tests)

    add_executable(protector_guest_pacer_tests native/tests/guest_pacer_tests.c)
    target_link_libraries(protector_guest_pacer_tests PRIVATE protector_runtime m)
    target_compile_options(protector_guest_pacer_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_guest_pacer_tests COMMAND protector_guest_pacer_tests)
    add_executable(protector_motion_clock_tests native/tests/motion_clock_tests.c)
    target_link_libraries(protector_motion_clock_tests PRIVATE protector_runtime m)
    target_compile_options(protector_motion_clock_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_motion_clock_tests COMMAND protector_motion_clock_tests)
    add_executable(protector_guest_memory_inline_tests native/tests/guest_memory_inline_tests.c)
    target_link_libraries(protector_guest_memory_inline_tests PRIVATE protector_runtime m)
    target_compile_options(protector_guest_memory_inline_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_guest_memory_inline_tests COMMAND protector_guest_memory_inline_tests)

    add_executable(protector_ax_diagnostics_tests native/tests/ax_diagnostics_tests.c)
    target_link_libraries(protector_ax_diagnostics_tests PRIVATE protector_runtime)
    target_compile_options(protector_ax_diagnostics_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_ax_diagnostics_tests COMMAND protector_ax_diagnostics_tests)

    add_executable(protector_save_store_tests native/tests/save_store_tests.c)
    target_link_libraries(protector_save_store_tests PRIVATE protector_runtime)
    target_compile_options(protector_save_store_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_save_store_tests COMMAND protector_save_store_tests)
    add_executable(protector_save_commit_tests native/tests/save_commit_tests.c)
    target_link_libraries(protector_save_commit_tests PRIVATE protector_runtime m)
    target_compile_options(protector_save_commit_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_save_commit_tests COMMAND protector_save_commit_tests)

    add_executable(protector_live_input_tests native/tests/live_input_tests.c)
    target_link_libraries(protector_live_input_tests PRIVATE protector_runtime)
    target_compile_options(protector_live_input_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_live_input_tests COMMAND protector_live_input_tests)

    add_executable(protector_ui_text_tests native/tests/ui_text_tests.c)
    target_link_libraries(protector_ui_text_tests PRIVATE protector_runtime)
    target_compile_options(protector_ui_text_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_ui_text_tests COMMAND protector_ui_text_tests)
    add_executable(protector_ui_context_tests native/tests/ui_context_tests.c)
    target_link_libraries(protector_ui_context_tests PRIVATE protector_runtime)
    target_compile_options(protector_ui_context_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_ui_context_tests COMMAND protector_ui_context_tests)
    add_executable(protector_tutorial_context_tests native/tests/tutorial_context_tests.c)
    add_executable(protector_interaction_context_tests native/tests/interaction_context_tests.c)
    target_link_libraries(protector_interaction_context_tests PRIVATE protector_runtime)
    target_compile_options(protector_interaction_context_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_interaction_context_tests COMMAND protector_interaction_context_tests)
    target_link_libraries(protector_tutorial_context_tests PRIVATE protector_runtime)
    target_compile_options(protector_tutorial_context_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_tutorial_context_tests COMMAND protector_tutorial_context_tests)
    add_executable(protector_script_flow_tests native/tests/script_flow_tests.c)
    target_link_libraries(protector_script_flow_tests PRIVATE protector_runtime)
    target_compile_options(protector_script_flow_tests PRIVATE -UNDEBUG)
    add_test(NAME protector_script_flow_tests COMMAND protector_script_flow_tests)

    add_executable(protector_runtime_tests native/tests/runtime_tests.c)
    target_link_libraries(protector_runtime_tests PRIVATE protector_runtime)
    add_test(NAME protector_runtime_tests COMMAND protector_runtime_tests)

    add_executable(protector_room_tests native/tests/room_tests.c)
    target_link_libraries(protector_room_tests PRIVATE protector_runtime m)
    add_test(NAME protector_room_tests COMMAND protector_room_tests)

    add_executable(protector_ax_tests native/tests/ax_tests.c)
    target_link_libraries(protector_ax_tests PRIVATE protector_runtime)
    add_test(NAME protector_ax_tests COMMAND protector_ax_tests)

    add_executable(protector_ax_audio_tests native/tests/ax_audio_tests.c)
    target_link_libraries(protector_ax_audio_tests PRIVATE protector_runtime)
    add_test(NAME protector_ax_audio_tests COMMAND protector_ax_audio_tests)
endif()

set(PROTECTOR_GENERATED_DIR "" CACHE PATH
    "Prepared external RBNEG9 DolRecomp source directory")
option(PROTECTOR_BUILD_FULL_BOOT
       "Compile every prepared RBNEG9 translation chunk" OFF)
option(PROTECTOR_BUILD_IOS_SHELL
       "Build the thin native iPhone developer shell" OFF)
option(PROTECTOR_BUILD_METAL_HARNESS
       "Build the macOS GX-to-Metal frame harness" OFF)
option(PROTECTOR_BUILD_LIVE_METAL
       "Build the direct translated-execution macOS Metal harness" OFF)
option(PROTECTOR_BUILD_INTERACTIVE
       "Build the continuous original-game macOS developer shell" OFF)
option(PROTECTOR_BUILD_METAL_DECODER_TESTS
       "Build asset-free macOS tests of the production GX decoder" OFF)
option(PROTECTOR_BUILD_IOS_METAL_FRAME
       "Build the iPhone GX-to-Metal frame app" OFF)
option(PROTECTOR_BUILD_IOS_PLAYABLE_ROOM
       "Build the Milestone 5 iPhone playable-room app" OFF)
option(PROTECTOR_BUILD_IOS_PERF
       "Build the R1/S2 translated-frame iPhone performance runner" OFF)
option(PROTECTOR_BUILD_IOS_LIVE_METAL
       "Build the R2 translated-title iPhone Metal app" OFF)
option(PROTECTOR_BUILD_IOS_INTERACTIVE
       "Build the continuous original-game iPhone/iPad app" OFF)
option(PROTECTOR_IOS_CODE_SIGNING_ALLOWED
       "Allow Xcode to sign the playable-room app for a physical device" OFF)
set(PROTECTOR_IOS_DEVELOPMENT_TEAM "" CACHE STRING
    "Apple development-team identifier used for physical-device signing")
set(PROTECTOR_IOS_BUNDLE_IDENTIFIER "house.machine.ProtectorNative.Room"
    CACHE STRING "Bundle identifier for the playable-room app")
set(PROTECTOR_IOS_ROOM_PACK_DIR "" CACHE PATH
    "External source-bound room pack to embed before device signing")
set(PROTECTOR_IOS_SOURCE_SLICE_DIR "" CACHE PATH
    "External source-bound R1/S2 slice to embed before device signing")
set(PROTECTOR_IOS_KPAD_REFERENCE "" CACHE FILEPATH
    "Source-bound Dolphin KPAD JSON used for translated title input")

if(PROTECTOR_BUILD_METAL_DECODER_TESTS)
    if(NOT APPLE OR CMAKE_SYSTEM_NAME STREQUAL "iOS")
        message(FATAL_ERROR "Metal decoder tests require macOS")
    endif()
    enable_language(OBJCXX)
    add_executable(protector_metal_decoder_tests native/tests/live_gx_renderer_tests.mm
        native/metal/texture_pack.mm native/metal/geometry_pack.mm native/metal/cinematic_pack.mm)
    target_compile_options(protector_metal_decoder_tests PRIVATE
        -fobjc-arc -UNDEBUG -Wall -Wextra -Wpedantic -Werror)
    target_link_libraries(protector_metal_decoder_tests PRIVATE protector_runtime
        "-framework Foundation" "-framework Metal" "-framework QuartzCore"
        "-framework CoreGraphics" "-framework ImageIO"
        "-framework AVFoundation" "-framework CoreVideo" "-framework CoreMedia"
        "-framework UniformTypeIdentifiers")
    add_test(NAME protector_metal_decoder_tests COMMAND protector_metal_decoder_tests)
    add_executable(protector_texture_pack_tests native/tests/texture_pack_tests.mm)
    target_compile_options(protector_texture_pack_tests PRIVATE
        -fobjc-arc -UNDEBUG -Wall -Wextra -Wpedantic -Werror)
    target_link_libraries(protector_texture_pack_tests PRIVATE protector_runtime
        "-framework Foundation" "-framework Metal")
    add_test(NAME protector_texture_pack_tests COMMAND protector_texture_pack_tests)
    set_tests_properties(protector_texture_pack_tests PROPERTIES TIMEOUT 30)
    add_executable(protector_geometry_pack_tests native/tests/geometry_pack_tests.mm)
    target_compile_options(protector_geometry_pack_tests PRIVATE
        -fobjc-arc -UNDEBUG -Wall -Wextra -Wpedantic -Werror)
    target_link_libraries(protector_geometry_pack_tests PRIVATE protector_runtime "-framework Foundation")
    add_test(NAME protector_geometry_pack_tests COMMAND protector_geometry_pack_tests)
    add_executable(protector_cinematic_pack_tests native/tests/cinematic_pack_tests.mm)
    target_compile_options(protector_cinematic_pack_tests PRIVATE
        -fobjc-arc -UNDEBUG -Wall -Wextra -Wpedantic -Werror)
    target_link_libraries(protector_cinematic_pack_tests PRIVATE protector_runtime
        "-framework Foundation" "-framework Metal" "-framework AVFoundation"
        "-framework CoreVideo" "-framework CoreMedia")
    add_test(NAME protector_cinematic_pack_tests COMMAND protector_cinematic_pack_tests)
    add_executable(protector_cinematic_preparation_tests native/tests/cinematic_preparation_tests.mm)
    target_compile_options(protector_cinematic_preparation_tests PRIVATE
        -fobjc-arc -UNDEBUG -Wall -Wextra -Wpedantic -Werror)
    target_link_libraries(protector_cinematic_preparation_tests PRIVATE protector_runtime
        "-framework Foundation" "-framework Metal" "-framework AVFoundation"
        "-framework CoreVideo" "-framework CoreMedia")
    add_executable(protector_game_session_tests
        native/tests/game_session_tests.mm native/metal/live_gx_renderer.mm
        native/metal/texture_pack.mm native/metal/geometry_pack.mm native/metal/cinematic_pack.mm)
    target_compile_options(protector_game_session_tests PRIVATE
        -fobjc-arc -UNDEBUG -Wall -Wextra -Wpedantic -Werror)
    target_link_libraries(protector_game_session_tests PRIVATE protector_runtime
        "-framework Foundation" "-framework Metal" "-framework QuartzCore"
        "-framework CoreGraphics" "-framework ImageIO"
        "-framework AVFoundation" "-framework CoreVideo" "-framework CoreMedia"
        "-framework UniformTypeIdentifiers")
    add_test(NAME protector_game_session_tests COMMAND protector_game_session_tests)
    set_tests_properties(protector_game_session_tests PROPERTIES TIMEOUT 20)
endif()

if(PROTECTOR_BUILD_METAL_HARNESS)
    if(NOT APPLE OR CMAKE_SYSTEM_NAME STREQUAL "iOS")
        message(FATAL_ERROR
            "PROTECTOR_BUILD_METAL_HARNESS requires macOS")
    endif()
    enable_language(OBJC OBJCXX)
    add_executable(protector_metal_harness
        native/macos/metal_main.m
        native/metal/renderer.mm
    )
    target_include_directories(protector_metal_harness PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/native/include"
    )
    target_compile_options(protector_metal_harness PRIVATE
        -fobjc-arc
        -Wall
        -Wextra
        -Wpedantic
        -Werror
    )
    target_link_libraries(protector_metal_harness PRIVATE
        "-framework Foundation"
        "-framework Metal"
        "-framework CoreGraphics"
        "-framework ImageIO"
    )
endif()

if(PROTECTOR_BUILD_IOS_METAL_FRAME)
    if(NOT APPLE OR NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        message(FATAL_ERROR
            "PROTECTOR_BUILD_IOS_METAL_FRAME requires an iOS toolchain")
    endif()
    enable_language(OBJC OBJCXX)
    add_executable(protector_ios_metal MACOSX_BUNDLE
        native/ios/metal_main.m
        native/metal/renderer.mm
    )
    target_include_directories(protector_ios_metal PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/native/include"
    )
    target_link_libraries(protector_ios_metal PRIVATE
        protector_runtime
        "-framework UIKit"
        "-framework Metal"
        "-framework MetalKit"
        "-framework QuartzCore"
        "-framework CoreGraphics"
        "-framework ImageIO"
    )
    target_compile_options(protector_ios_metal PRIVATE
        -fobjc-arc
        -Wall
        -Wextra
        -Wpedantic
        -Werror
    )
    set_target_properties(protector_ios_metal PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST
            "${CMAKE_CURRENT_SOURCE_DIR}/native/ios/MetalInfo.plist.in"
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
            "house.machine.ProtectorNative.MetalFrame"
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    )
endif()

if(PROTECTOR_BUILD_IOS_PLAYABLE_ROOM)
    if(NOT APPLE OR NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        message(FATAL_ERROR
            "PROTECTOR_BUILD_IOS_PLAYABLE_ROOM requires an iOS toolchain")
    endif()
    enable_language(OBJC OBJCXX)
    add_executable(protector_ios_room MACOSX_BUNDLE
        native/ios/room_main.m
        native/metal/renderer.mm
    )
    if(NOT PROTECTOR_IOS_ROOM_PACK_DIR STREQUAL "")
        if(NOT EXISTS "${PROTECTOR_IOS_ROOM_PACK_DIR}/room.json")
            message(FATAL_ERROR
                "PROTECTOR_IOS_ROOM_PACK_DIR has no room.json")
        endif()
        file(GLOB_RECURSE PROTECTOR_IOS_ROOM_PACK_FILES CONFIGURE_DEPENDS
            "${PROTECTOR_IOS_ROOM_PACK_DIR}/*")
        foreach(PROTECTOR_ROOM_RESOURCE IN LISTS
                PROTECTOR_IOS_ROOM_PACK_FILES)
            if(NOT IS_DIRECTORY "${PROTECTOR_ROOM_RESOURCE}")
                file(RELATIVE_PATH PROTECTOR_ROOM_RELATIVE
                    "${PROTECTOR_IOS_ROOM_PACK_DIR}"
                    "${PROTECTOR_ROOM_RESOURCE}")
                get_filename_component(PROTECTOR_ROOM_SUBDIRECTORY
                    "${PROTECTOR_ROOM_RELATIVE}" DIRECTORY)
                set_source_files_properties("${PROTECTOR_ROOM_RESOURCE}"
                    PROPERTIES MACOSX_PACKAGE_LOCATION
                    "Resources/Canyon/${PROTECTOR_ROOM_SUBDIRECTORY}")
                target_sources(protector_ios_room PRIVATE
                    "${PROTECTOR_ROOM_RESOURCE}")
            endif()
        endforeach()
    endif()
    target_include_directories(protector_ios_room PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/native/include"
    )
    target_link_libraries(protector_ios_room PRIVATE
        protector_runtime
        "-framework UIKit"
        "-framework Metal"
        "-framework MetalKit"
        "-framework QuartzCore"
        "-framework CoreGraphics"
        "-framework ImageIO"
        "-framework GameController"
        "-framework AVFoundation"
        "-framework CoreHaptics"
    )
    target_compile_options(protector_ios_room PRIVATE
        -fobjc-arc
        -Wall
        -Wextra
        -Wpedantic
        -Werror
    )
    set_target_properties(protector_ios_room PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST
            "${CMAKE_CURRENT_SOURCE_DIR}/native/ios/RoomInfo.plist.in"
        XCODE_GENERATE_SCHEME TRUE
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
            "${PROTECTOR_IOS_BUNDLE_IDENTIFIER}"
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1"
    )
    if(PROTECTOR_IOS_CODE_SIGNING_ALLOWED)
        if(PROTECTOR_IOS_DEVELOPMENT_TEAM STREQUAL "")
            message(FATAL_ERROR
                "PROTECTOR_IOS_DEVELOPMENT_TEAM is required for device signing")
        endif()
        set_target_properties(protector_ios_room PROPERTIES
            XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "YES"
            XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "YES"
            XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
            XCODE_ATTRIBUTE_DEVELOPMENT_TEAM
                "${PROTECTOR_IOS_DEVELOPMENT_TEAM}"
        )
    else()
        set_target_properties(protector_ios_room PROPERTIES
            XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
            XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
        )
    endif()
endif()

if(PROTECTOR_BUILD_IOS_SHELL)
    if(NOT APPLE OR NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        message(FATAL_ERROR
            "PROTECTOR_BUILD_IOS_SHELL requires an iOS toolchain")
    endif()
    enable_language(OBJC)
    add_executable(protector_ios_shell MACOSX_BUNDLE
        native/ios/main.m
    )
    target_link_libraries(protector_ios_shell PRIVATE
        protector_runtime
        "-framework UIKit"
    )
    target_compile_options(protector_ios_shell PRIVATE
        -Wall
        -Wextra
        -Wpedantic
    )
    set_target_properties(protector_ios_shell PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST
            "${CMAKE_CURRENT_SOURCE_DIR}/native/ios/Info.plist.in"
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
            "house.machine.ProtectorNative"
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    )
endif()

if(PROTECTOR_GENERATED_DIR)
    if(PROTECTOR_BUILD_IOS_INTERACTIVE)
        include(cmake/InteractiveIOS.cmake)
    endif()
    if(NOT EXISTS "${PROTECTOR_GENERATED_DIR}/RBNEG9.h")
        message(FATAL_ERROR "PROTECTOR_GENERATED_DIR has no RBNEG9.h")
    endif()
    if(NOT EXISTS
       "${PROTECTOR_GENERATED_DIR}/chunks/chunk_0000_text0_80004000.c")
        message(FATAL_ERROR "PROTECTOR_GENERATED_DIR has no prepared entry chunk")
    endif()

    add_executable(protector_entry_harness
        native/macos/main.c
        "${PROTECTOR_GENERATED_DIR}/chunks/chunk_0000_text0_80004000.c"
    )
    target_include_directories(protector_entry_harness PRIVATE
        "${PROTECTOR_GENERATED_DIR}"
    )
    target_compile_definitions(protector_entry_harness PRIVATE
        DOLRECOMP_CPU_HEADER="protector/cpu.h"
    )
    target_compile_options(protector_entry_harness PRIVATE
        -Wall
        -Wextra
        -Wpedantic
    )
    target_link_libraries(protector_entry_harness PRIVATE
        protector_runtime
        m
    )

    if(PROTECTOR_BUILD_FULL_BOOT)
        file(GLOB PROTECTOR_FULL_CHUNKS CONFIGURE_DEPENDS
            "${PROTECTOR_GENERATED_DIR}/chunks/*.c"
        )
        list(LENGTH PROTECTOR_FULL_CHUNKS PROTECTOR_FULL_CHUNK_COUNT)
        if(NOT PROTECTOR_FULL_CHUNK_COUNT EQUAL 120)
            message(FATAL_ERROR
                "full RBNEG9 build requires 120 prepared chunks, found "
                "${PROTECTOR_FULL_CHUNK_COUNT}")
        endif()
        # Generated code only: cpu.c defines the accessors the macros wrap.
        set_property(SOURCE ${PROTECTOR_FULL_CHUNKS} APPEND PROPERTY
            COMPILE_DEFINITIONS PROTECTOR_INLINE_GUEST_MEMORY=1)
        add_executable(protector_boot_harness
            native/macos/boot_main.c
            ${PROTECTOR_FULL_CHUNKS}
        )
        target_include_directories(protector_boot_harness PRIVATE
            "${PROTECTOR_GENERATED_DIR}"
        )
        target_compile_definitions(protector_boot_harness PRIVATE
            DOLRECOMP_CPU_HEADER="protector/cpu.h"
        )
        target_compile_options(protector_boot_harness PRIVATE
            -Wall
            -Wextra
            -Wpedantic
        )
        target_link_libraries(protector_boot_harness PRIVATE
            protector_runtime
            m
        )

        # This optional boundary probe executes the user's translated SDK
        # routines. It requires the external DOL and is not an asset-free CTest.
        if(BUILD_TESTING)
            add_executable(protector_dvd_cancel_asset_probe EXCLUDE_FROM_ALL
                native/tests/dvd_cancel_asset_probe.c
                ${PROTECTOR_FULL_CHUNKS}
            )
            target_include_directories(protector_dvd_cancel_asset_probe PRIVATE
                "${PROTECTOR_GENERATED_DIR}"
            )
            target_compile_definitions(protector_dvd_cancel_asset_probe PRIVATE
                DOLRECOMP_CPU_HEADER="protector/cpu.h"
            )
            target_compile_options(protector_dvd_cancel_asset_probe PRIVATE -UNDEBUG)
            target_link_libraries(protector_dvd_cancel_asset_probe PRIVATE
                protector_runtime m
            )
            # One translated VM chunk executes an unchanged externally supplied
            # QTE predicate. This is an input boundary, not encounter acceptance.
            add_executable(protector_qte_motion_asset_probe EXCLUDE_FROM_ALL
                native/tests/qte_motion_asset_probe.c
                "${PROTECTOR_GENERATED_DIR}/chunks/chunk_0040_text1_800A6720.c"
            )
            target_include_directories(protector_qte_motion_asset_probe PRIVATE
                "${PROTECTOR_GENERATED_DIR}")
            target_compile_definitions(protector_qte_motion_asset_probe PRIVATE
                DOLRECOMP_CPU_HEADER="protector/cpu.h")
            target_compile_options(protector_qte_motion_asset_probe PRIVATE -UNDEBUG)
            target_link_libraries(protector_qte_motion_asset_probe PRIVATE
                protector_runtime m)
        endif()

        if(PROTECTOR_BUILD_INTERACTIVE)
            if(NOT APPLE OR CMAKE_SYSTEM_NAME STREQUAL "iOS")
                message(FATAL_ERROR "PROTECTOR_BUILD_INTERACTIVE requires macOS")
            endif()
            enable_language(OBJCXX)
            add_executable(protector_interactive MACOSX_BUNDLE
                native/macos/interactive_main.mm
                native/apple/game_session.mm
                native/macos/boot_main.c
                native/metal/live_gx_renderer.mm
                native/metal/texture_pack.mm
                native/metal/geometry_pack.mm
                native/metal/cinematic_pack.mm
                ${PROTECTOR_FULL_CHUNKS}
            )
            protector_embed_audio_coefficients(protector_interactive)
            target_include_directories(protector_interactive PRIVATE
                "${PROTECTOR_GENERATED_DIR}"
                "${CMAKE_CURRENT_SOURCE_DIR}/native/include")
            set_target_properties(protector_interactive PROPERTIES
                MACOSX_BUNDLE_GUI_IDENTIFIER "house.machine.ProtectorNative.Interactive"
                MACOSX_BUNDLE_BUNDLE_NAME "Protector Native"
                MACOSX_BUNDLE_BUNDLE_VERSION "1"
                MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1")
            target_compile_definitions(protector_interactive PRIVATE
                DOLRECOMP_CPU_HEADER="protector/cpu.h" PROTECTOR_LIVE_METAL=1)
            target_compile_options(protector_interactive PRIVATE
                -Wall -Wextra -Wpedantic
                $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
                $<$<COMPILE_LANGUAGE:OBJCXX>:-Werror>)
            target_link_libraries(protector_interactive PRIVATE
                protector_runtime m
                "-framework Cocoa" "-framework Metal" "-framework MetalKit"
                "-framework QuartzCore" "-framework CoreGraphics"
                "-framework AVFoundation" "-framework CoreVideo" "-framework CoreMedia"
                "-framework ImageIO" "-framework UniformTypeIdentifiers")
        endif()

        if(PROTECTOR_BUILD_LIVE_METAL)
            if(NOT APPLE OR CMAKE_SYSTEM_NAME STREQUAL "iOS")
                message(FATAL_ERROR
                    "PROTECTOR_BUILD_LIVE_METAL requires macOS")
            endif()
            enable_language(OBJCXX)
            add_executable(protector_live_metal_harness
                native/macos/live_metal_main.mm
                native/macos/boot_main.c
                native/metal/live_gx_renderer.mm
                native/metal/texture_pack.mm
                native/metal/geometry_pack.mm
                native/metal/cinematic_pack.mm
                ${PROTECTOR_FULL_CHUNKS}
            )
            target_include_directories(
                protector_live_metal_harness PRIVATE
                "${PROTECTOR_GENERATED_DIR}"
                "${CMAKE_CURRENT_SOURCE_DIR}/native/include"
            )
            target_compile_definitions(
                protector_live_metal_harness PRIVATE
                DOLRECOMP_CPU_HEADER="protector/cpu.h"
                PROTECTOR_LIVE_METAL=1
            )
            target_compile_options(
                protector_live_metal_harness PRIVATE
                -Wall
                -Wextra
                -Wpedantic
                $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
                $<$<COMPILE_LANGUAGE:OBJCXX>:-Werror>
            )
            target_link_libraries(
                protector_live_metal_harness PRIVATE
                protector_runtime
                m
                "-framework Foundation"
                "-framework Metal"
                "-framework QuartzCore"
                "-framework CoreGraphics"
                "-framework ImageIO"
                "-framework AVFoundation" "-framework CoreVideo" "-framework CoreMedia"
                "-framework UniformTypeIdentifiers"
            )
        endif()
    endif()

    if(PROTECTOR_BUILD_IOS_PERF)
        if(NOT APPLE OR NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
            message(FATAL_ERROR
                "PROTECTOR_BUILD_IOS_PERF requires an iOS toolchain")
        endif()
        if(PROTECTOR_IOS_SOURCE_SLICE_DIR STREQUAL "" OR
           NOT EXISTS
               "${PROTECTOR_IOS_SOURCE_SLICE_DIR}/source-slice.json" OR
           NOT EXISTS
               "${PROTECTOR_IOS_SOURCE_SLICE_DIR}/DATA/sys/main.dol" OR
           NOT EXISTS
               "${PROTECTOR_IOS_SOURCE_SLICE_DIR}/DATA/sys/fst.bin")
            message(FATAL_ERROR
                "R1/S2 requires a complete external source slice")
        endif()
        file(GLOB PROTECTOR_IOS_PERF_CHUNKS CONFIGURE_DEPENDS
            "${PROTECTOR_GENERATED_DIR}/chunks/*.c"
        )
        list(LENGTH PROTECTOR_IOS_PERF_CHUNKS
             PROTECTOR_IOS_PERF_CHUNK_COUNT)
        if(NOT PROTECTOR_IOS_PERF_CHUNK_COUNT EQUAL 120)
            message(FATAL_ERROR
                "R1/S2 requires 120 prepared chunks, found "
                "${PROTECTOR_IOS_PERF_CHUNK_COUNT}")
        endif()
        file(GLOB_RECURSE PROTECTOR_IOS_SOURCE_SLICE_FILES
            CONFIGURE_DEPENDS
            "${PROTECTOR_IOS_SOURCE_SLICE_DIR}/*"
        )
        add_executable(protector_ios_perf MACOSX_BUNDLE
            native/ios/perf_main.m
            native/macos/boot_main.c
            ${PROTECTOR_IOS_PERF_CHUNKS}
        )
        foreach(PROTECTOR_IOS_SOURCE_RESOURCE IN LISTS
                PROTECTOR_IOS_SOURCE_SLICE_FILES)
            if(NOT IS_DIRECTORY "${PROTECTOR_IOS_SOURCE_RESOURCE}")
                file(RELATIVE_PATH PROTECTOR_IOS_SOURCE_RELATIVE
                    "${PROTECTOR_IOS_SOURCE_SLICE_DIR}"
                    "${PROTECTOR_IOS_SOURCE_RESOURCE}")
                get_filename_component(PROTECTOR_IOS_SOURCE_SUBDIRECTORY
                    "${PROTECTOR_IOS_SOURCE_RELATIVE}" DIRECTORY)
                set_source_files_properties(
                    "${PROTECTOR_IOS_SOURCE_RESOURCE}"
                    PROPERTIES MACOSX_PACKAGE_LOCATION
                    "Resources/Source/${PROTECTOR_IOS_SOURCE_SUBDIRECTORY}")
                target_sources(protector_ios_perf PRIVATE
                    "${PROTECTOR_IOS_SOURCE_RESOURCE}")
            endif()
        endforeach()
        target_include_directories(protector_ios_perf PRIVATE
            "${PROTECTOR_GENERATED_DIR}"
        )
        target_compile_definitions(protector_ios_perf PRIVATE
            DOLRECOMP_CPU_HEADER="protector/cpu.h"
            PROTECTOR_IOS_PERF=1
        )
        target_compile_options(protector_ios_perf PRIVATE
            -Wall
            -Wextra
            -Wpedantic
            -Werror
        )
        target_link_libraries(protector_ios_perf PRIVATE
            protector_runtime
            m
            "-framework UIKit"
        )
        set_target_properties(protector_ios_perf PROPERTIES
            MACOSX_BUNDLE_INFO_PLIST
                "${CMAKE_CURRENT_SOURCE_DIR}/native/ios/PerfInfo.plist.in"
            XCODE_GENERATE_SCHEME TRUE
            XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES"
            XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
                "${PROTECTOR_IOS_BUNDLE_IDENTIFIER}"
            XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1"
        )
        if(PROTECTOR_IOS_CODE_SIGNING_ALLOWED)
            if(PROTECTOR_IOS_DEVELOPMENT_TEAM STREQUAL "")
                message(FATAL_ERROR
                    "PROTECTOR_IOS_DEVELOPMENT_TEAM is required for "
                    "device signing")
            endif()
            set_target_properties(protector_ios_perf PROPERTIES
                XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "YES"
                XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "YES"
                XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
                XCODE_ATTRIBUTE_DEVELOPMENT_TEAM
                    "${PROTECTOR_IOS_DEVELOPMENT_TEAM}"
            )
        else()
            set_target_properties(protector_ios_perf PROPERTIES
                XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
                XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
            )
        endif()
    endif()

    if(PROTECTOR_BUILD_IOS_LIVE_METAL)
        if(NOT APPLE OR NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
            message(FATAL_ERROR
                "PROTECTOR_BUILD_IOS_LIVE_METAL requires an iOS toolchain")
        endif()
        enable_language(OBJCXX)
        if(PROTECTOR_IOS_SOURCE_SLICE_DIR STREQUAL "" OR
           NOT EXISTS
               "${PROTECTOR_IOS_SOURCE_SLICE_DIR}/source-slice.json" OR
           NOT EXISTS
               "${PROTECTOR_IOS_SOURCE_SLICE_DIR}/DATA/sys/main.dol" OR
           NOT EXISTS
               "${PROTECTOR_IOS_SOURCE_SLICE_DIR}/DATA/sys/fst.bin")
            message(FATAL_ERROR
                "R2 iPhone title requires a complete external source slice")
        endif()
        if(PROTECTOR_IOS_KPAD_REFERENCE STREQUAL "" OR
           NOT EXISTS "${PROTECTOR_IOS_KPAD_REFERENCE}")
            message(FATAL_ERROR
                "R2 iPhone title requires a source-bound KPAD reference")
        endif()
        file(GLOB PROTECTOR_IOS_LIVE_METAL_CHUNKS CONFIGURE_DEPENDS
            "${PROTECTOR_GENERATED_DIR}/chunks/*.c"
        )
        list(LENGTH PROTECTOR_IOS_LIVE_METAL_CHUNKS
             PROTECTOR_IOS_LIVE_METAL_CHUNK_COUNT)
        if(NOT PROTECTOR_IOS_LIVE_METAL_CHUNK_COUNT EQUAL 120)
            message(FATAL_ERROR
                "R2 iPhone title requires 120 prepared chunks, found "
                "${PROTECTOR_IOS_LIVE_METAL_CHUNK_COUNT}")
        endif()
        file(GLOB_RECURSE PROTECTOR_IOS_LIVE_METAL_SOURCE_FILES
            CONFIGURE_DEPENDS
            "${PROTECTOR_IOS_SOURCE_SLICE_DIR}/*"
        )
        configure_file(
            "${PROTECTOR_IOS_KPAD_REFERENCE}"
            "${CMAKE_CURRENT_BINARY_DIR}/r2-kpad.json"
            COPYONLY
        )
        set_source_files_properties(
            "${CMAKE_CURRENT_BINARY_DIR}/r2-kpad.json"
            PROPERTIES MACOSX_PACKAGE_LOCATION "Resources"
        )
        add_executable(protector_ios_live_metal MACOSX_BUNDLE
            native/ios/live_metal_main.mm
            native/macos/boot_main.c
            native/metal/live_gx_renderer.mm
            native/metal/texture_pack.mm
            native/metal/geometry_pack.mm
            native/metal/cinematic_pack.mm
            "${CMAKE_CURRENT_BINARY_DIR}/r2-kpad.json"
            ${PROTECTOR_IOS_LIVE_METAL_CHUNKS}
        )
        foreach(PROTECTOR_IOS_LIVE_SOURCE IN LISTS
                PROTECTOR_IOS_LIVE_METAL_SOURCE_FILES)
            if(NOT IS_DIRECTORY "${PROTECTOR_IOS_LIVE_SOURCE}")
                file(RELATIVE_PATH PROTECTOR_IOS_LIVE_RELATIVE
                    "${PROTECTOR_IOS_SOURCE_SLICE_DIR}"
                    "${PROTECTOR_IOS_LIVE_SOURCE}")
                get_filename_component(PROTECTOR_IOS_LIVE_SUBDIRECTORY
                    "${PROTECTOR_IOS_LIVE_RELATIVE}" DIRECTORY)
                set_source_files_properties(
                    "${PROTECTOR_IOS_LIVE_SOURCE}"
                    PROPERTIES MACOSX_PACKAGE_LOCATION
                    "Resources/Source/${PROTECTOR_IOS_LIVE_SUBDIRECTORY}")
                target_sources(protector_ios_live_metal PRIVATE
                    "${PROTECTOR_IOS_LIVE_SOURCE}")
            endif()
        endforeach()
        target_include_directories(protector_ios_live_metal PRIVATE
            "${PROTECTOR_GENERATED_DIR}"
            "${CMAKE_CURRENT_SOURCE_DIR}/native/include"
        )
        target_compile_definitions(protector_ios_live_metal PRIVATE
            DOLRECOMP_CPU_HEADER="protector/cpu.h"
            PROTECTOR_IOS_LIVE_METAL=1
        )
        target_compile_options(protector_ios_live_metal PRIVATE
            -Wall
            -Wextra
            -Wpedantic
            $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
            $<$<COMPILE_LANGUAGE:OBJCXX>:-Werror>
        )
        target_link_libraries(protector_ios_live_metal PRIVATE
            protector_runtime
            m
            "-framework UIKit"
            "-framework Metal"
            "-framework MetalKit"
            "-framework QuartzCore"
            "-framework CoreGraphics"
            "-framework ImageIO"
            "-framework AVFoundation" "-framework CoreVideo" "-framework CoreMedia"
            "-framework UniformTypeIdentifiers"
        )
        set_target_properties(protector_ios_live_metal PROPERTIES
            MACOSX_BUNDLE_INFO_PLIST
                "${CMAKE_CURRENT_SOURCE_DIR}/native/ios/LiveMetalInfo.plist.in"
            XCODE_GENERATE_SCHEME TRUE
            XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES"
            XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
                "${PROTECTOR_IOS_BUNDLE_IDENTIFIER}"
            XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1"
        )
        if(PROTECTOR_IOS_CODE_SIGNING_ALLOWED)
            if(PROTECTOR_IOS_DEVELOPMENT_TEAM STREQUAL "")
                message(FATAL_ERROR
                    "PROTECTOR_IOS_DEVELOPMENT_TEAM is required for "
                    "device signing")
            endif()
            set_target_properties(protector_ios_live_metal PROPERTIES
                XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "YES"
                XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "YES"
                XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
                XCODE_ATTRIBUTE_DEVELOPMENT_TEAM
                    "${PROTECTOR_IOS_DEVELOPMENT_TEAM}"
            )
        else()
            set_target_properties(protector_ios_live_metal PROPERTIES
                XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
                XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
            )
        endif()
    endif()
endif()
