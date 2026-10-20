set(PROTECTOR_IOS_GEOMETRY_PACK_MANIFEST "" CACHE FILEPATH
    "Optional external source-bound model refinement candidate; empty keeps original models")

function(protector_embed_geometry_pack target)
    if(PROTECTOR_IOS_GEOMETRY_PACK_MANIFEST STREQUAL "")
        return()
    endif()
    if(NOT IS_ABSOLUTE "${PROTECTOR_IOS_GEOMETRY_PACK_MANIFEST}" OR
       NOT EXISTS "${PROTECTOR_IOS_GEOMETRY_PACK_MANIFEST}" OR
       IS_DIRECTORY "${PROTECTOR_IOS_GEOMETRY_PACK_MANIFEST}")
        message(FATAL_ERROR "Geometry pack requires an existing absolute manifest path")
    endif()
    file(REAL_PATH "${CMAKE_SOURCE_DIR}" source_real)
    file(REAL_PATH "${CMAKE_BINARY_DIR}" build_real)
    file(REAL_PATH "${PROTECTOR_IOS_GEOMETRY_PACK_MANIFEST}" manifest_real)
    foreach(external IN ITEMS "${manifest_real}" "${build_real}")
        cmake_path(IS_PREFIX source_real "${external}" NORMALIZE inside)
        if(inside)
            message(FATAL_ERROR "Model geometry and its build must remain outside Git")
        endif()
    endforeach()
    file(SIZE "${manifest_real}" manifest_size)
    if(manifest_size GREATER 25165824)
        message(FATAL_ERROR "Geometry pack manifest exceeds 24 MiB")
    endif()
    file(READ "${manifest_real}" manifest)
    string(JSON schema ERROR_VARIABLE schema_error GET "${manifest}" schema)
    string(JSON title ERROR_VARIABLE title_error GET "${manifest}" title_dol_sha256)
    string(JSON count ERROR_VARIABLE entries_error LENGTH "${manifest}" entries)
    if(schema_error OR title_error OR entries_error OR
       NOT schema STREQUAL "protector-native.geometry-pack/v1" OR
       NOT title STREQUAL "03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566" OR
       count LESS 1 OR count GREATER 256)
        message(FATAL_ERROR "Geometry pack must be a bounded source-bound RBNEG9 v1 manifest")
    endif()
    # Profiles are entirely inside the manifest. The native loader independently
    # checks hashes, finite affine stencils, source indices and topology bounds.
    set(destination "${CMAKE_BINARY_DIR}/runtime-resources/EnhancedModels/geometry.json")
    configure_file("${manifest_real}" "${destination}" COPYONLY)
    set_source_files_properties("${destination}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/EnhancedModels")
    target_sources(${target} PRIVATE "${destination}")
endfunction()
