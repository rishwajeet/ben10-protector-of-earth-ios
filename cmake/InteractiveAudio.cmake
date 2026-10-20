# Coefficients are a local runtime resource, not a source-controlled asset.
set(PROTECTOR_AX_COEFFICIENTS_FILE "" CACHE FILEPATH
    "External 4096-byte DSP coefficient table for the original AX mixer")

function(protector_embed_audio_coefficients target)
    if(NOT EXISTS "${PROTECTOR_AX_COEFFICIENTS_FILE}" OR
       IS_DIRECTORY "${PROTECTOR_AX_COEFFICIENTS_FILE}")
        message(FATAL_ERROR "Interactive audio requires PROTECTOR_AX_COEFFICIENTS_FILE")
    endif()
    file(REAL_PATH "${CMAKE_SOURCE_DIR}" audio_source_root)
    file(REAL_PATH "${CMAKE_BINARY_DIR}" audio_build_root)
    file(REAL_PATH "${PROTECTOR_AX_COEFFICIENTS_FILE}" audio_coefficients)
    foreach(audio_external IN ITEMS "${audio_build_root}" "${audio_coefficients}")
        cmake_path(IS_PREFIX audio_source_root "${audio_external}" NORMALIZE audio_inside)
        if(audio_inside)
            message(FATAL_ERROR "Audio coefficients and interactive build must remain outside Git")
        endif()
    endforeach()
    file(SIZE "${audio_coefficients}" audio_size)
    file(SHA256 "${audio_coefficients}" audio_sha256)
    if(NOT audio_size EQUAL 4096 OR NOT audio_sha256 STREQUAL
       "d7741279c2e8ec5c5fb318f8fbdd6de6bf583520d288e836a5383233a4238179")
        message(FATAL_ERROR "DSP coefficients differ from the admitted table")
    endif()
    set(audio_resource "${CMAKE_BINARY_DIR}/runtime-resources/ax-coefficients.bin")
    configure_file("${audio_coefficients}" "${audio_resource}" COPYONLY)
    set_source_files_properties("${audio_resource}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
    target_sources(${target} PRIVATE "${audio_resource}")
endfunction()
