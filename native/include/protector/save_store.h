#ifndef PROTECTOR_SAVE_STORE_H
#define PROTECTOR_SAVE_STORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { PROTECTOR_SAVE_GAME = 0, PROTECTOR_SAVE_BANNER = 1 };
enum { PROTECTOR_SAVE_MAX_BYTES = 16 * 1024 * 1024 };
typedef struct ProtectorSaveStore { int directory_fd; } ProtectorSaveStore;

typedef struct ProtectorSaveStatus {
    bool enabled;
    unsigned pending_failure_mask;
    uint64_t attempts[2];
    uint64_t commits[2];
    uint64_t failures[2];
} ProtectorSaveStatus;

/* One translated session per process. The guest worker records completed host
 * commit attempts; UI/diagnostic readers never touch its buffers or consume
 * events. A success clears only that file's unresolved failure. */
void protector_save_status_reset(bool enabled);
void protector_save_status_record(unsigned slot, bool committed);
void protector_save_status_read(ProtectorSaveStatus* status);

/* The caller creates an isolated original-game directory. Only the two fixed
 * title filenames are accessible. Writes replace atomically and retain the
 * previous generation. No game path is joined to a host path. */
bool protector_save_store_open(ProtectorSaveStore* store, const char* directory,
                               char* error, size_t capacity);
void protector_save_store_close(ProtectorSaveStore* store);
bool protector_save_store_load(ProtectorSaveStore* store, unsigned slot,
                               uint8_t** data, size_t* size, bool* exists,
                               char* error, size_t capacity);
bool protector_save_store_write(ProtectorSaveStore* store, unsigned slot,
                                const uint8_t* data, size_t size,
                                char* error, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
