set(PROTECTOR_IOS_TEXTURE_PACK_MANIFEST "" CACHE FILEPATH
    "Optional external, source-bound restored-art pack; omitted means no replacement artwork")

function(protector_embed_texture_pack target)
    if(PROTECTOR_IOS_TEXTURE_PACK_MANIFEST STREQUAL "")
        return()
    endif()
    if(NOT IS_ABSOLUTE "${PROTECTOR_IOS_TEXTURE_PACK_MANIFEST}" OR
       NOT EXISTS "${PROTECTOR_IOS_TEXTURE_PACK_MANIFEST}" OR
       IS_DIRECTORY "${PROTECTOR_IOS_TEXTURE_PACK_MANIFEST}")
        message(FATAL_ERROR "Texture pack requires an existing absolute manifest path")
    endif()
    file(REAL_PATH "${CMAKE_SOURCE_DIR}" source_real)
    file(REAL_PATH "${CMAKE_BINARY_DIR}" build_real)
    file(REAL_PATH "${PROTECTOR_IOS_TEXTURE_PACK_MANIFEST}" manifest_real)
    get_filename_component(pack_root "${manifest_real}" DIRECTORY)
    foreach(external IN ITEMS "${manifest_real}" "${build_real}")
        cmake_path(IS_PREFIX source_real "${external}" NORMALIZE inside)
        if(inside)
            message(FATAL_ERROR "Restored artwork and its build must remain outside Git")
        endif()
    endforeach()
    # Match TexturePack's bounded 32 MiB manifest reader. Full source provenance
    # can exceed the old 16 MiB packaging cap without increasing resident art.
    file(READ "${manifest_real}" manifest LIMIT 33554433)
    string(LENGTH "${manifest}" manifest_length)
    if(manifest_length GREATER 33554432)
        message(FATAL_ERROR "Texture pack manifest exceeds 32 MiB")
    endif()
    string(JSON schema ERROR_VARIABLE parse_error GET "${manifest}" schema)
    string(JSON title ERROR_VARIABLE title_error GET "${manifest}" title_dol_sha256)
    string(JSON count ERROR_VARIABLE entries_error LENGTH "${manifest}" entries)
    if(parse_error OR title_error OR entries_error OR
       (NOT schema STREQUAL "protector-native.texture-pack/v1" AND
        NOT schema STREQUAL "protector-native.texture-pack/v2" AND
        NOT schema STREQUAL "protector-native.texture-pack/v3" AND
        NOT schema STREQUAL "protector-native.texture-pack/v4" AND
        NOT schema STREQUAL "protector-native.texture-pack/v5" AND
        NOT schema STREQUAL "protector-native.texture-pack/v6") OR
       NOT title STREQUAL "03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566" OR
       count LESS 1 OR count GREATER 65536)
        message(FATAL_ERROR "Texture pack must be a bounded source-bound RBNEG9 v1/v2/v3/v4/v5/v6 manifest")
    endif()
    set(payloads "")
    math(EXPR last "${count} - 1")
    foreach(index RANGE 0 ${last})
        # CMake reparses the supplied JSON string on every query. Extract one
        # small record once instead of reparsing a multi-MiB pack for each field.
        # Payload hashes, sizes and path containment are still checked below.
        string(JSON replacement ERROR_VARIABLE replacement_error GET "${manifest}" entries ${index} replacement)
        if(replacement_error)
            message(FATAL_ERROR "Texture entry requires replacement metadata")
        endif()
        string(JSON relative ERROR_VARIABLE path_error GET "${replacement}" path)
        if(schema STREQUAL "protector-native.texture-pack/v2")
            set(extension "astcmips")
        elseif(schema STREQUAL "protector-native.texture-pack/v3" OR
               schema STREQUAL "protector-native.texture-pack/v4" OR
               schema STREQUAL "protector-native.texture-pack/v5" OR
               schema STREQUAL "protector-native.texture-pack/v6")
            string(JSON format ERROR_VARIABLE format_error GET "${replacement}" format)
            if(NOT format_error AND format STREQUAL "rgba8-unorm")
                set(extension "rgba")
            elseif(NOT format_error AND (format STREQUAL "astc-4x4-ldr" OR format STREQUAL "astc-6x6-ldr"))
                set(extension "astcmips")
            elseif(NOT format_error AND (schema STREQUAL "protector-native.texture-pack/v5" OR
                   schema STREQUAL "protector-native.texture-pack/v6") AND
                   format STREQUAL "astc-4x4-ldr-rgba8-tail")
                set(extension "hybridmips")
            else()
                message(FATAL_ERROR "Mixed texture payload requires an explicit supported per-entry format")
            endif()
        else()
            set(extension "rgba")
        endif()
        if(path_error OR IS_ABSOLUTE "${relative}" OR
           NOT relative MATCHES "^textures/[A-Za-z0-9._-]+\\.${extension}$")
            message(FATAL_ERROR "Texture payload must be a direct textures/*.rgba child (v1) or *.astcmips child (v2)")
        endif()
        file(REAL_PATH "${pack_root}/${relative}" payload_real)
        cmake_path(IS_PREFIX pack_root "${payload_real}" NORMALIZE inside)
        if(NOT inside OR NOT EXISTS "${payload_real}" OR IS_DIRECTORY "${payload_real}")
            message(FATAL_ERROR "Texture payload is missing or escapes its external pack")
        endif()
        cmake_path(IS_PREFIX source_real "${payload_real}" NORMALIZE inside_source)
        if(inside_source)
            message(FATAL_ERROR "Restored artwork must remain outside Git")
        endif()
        string(JSON expected_hash ERROR_VARIABLE hash_error GET "${replacement}" sha256)
        string(JSON expected_size ERROR_VARIABLE size_error GET "${replacement}" byte_length)
        file(SHA256 "${payload_real}" actual_hash)
        file(SIZE "${payload_real}" actual_size)
        if(hash_error OR size_error OR NOT actual_hash STREQUAL expected_hash OR
           NOT actual_size EQUAL expected_size)
            message(FATAL_ERROR "Texture payload does not match its declared hash and size")
        endif()
        list(APPEND payloads "${pack_root}/${relative}")
    endforeach()
    list(REMOVE_DUPLICATES payloads)
    set(destination "${CMAKE_BINARY_DIR}/runtime-resources/RestoredArt/pack.json")
    configure_file("${manifest_real}" "${destination}" COPYONLY)
    set_source_files_properties("${destination}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/RestoredArt")
    set_source_files_properties(${payloads} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/RestoredArt/textures")
    target_sources(${target} PRIVATE "${destination}" ${payloads})
endfunction()
