#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "protector/save_store.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    ProtectorSaveStatus status;
    protector_save_status_reset(false);
    protector_save_status_record(0, false);
    protector_save_status_read(&status);
    assert(!status.enabled && !status.pending_failure_mask && !status.attempts[0]);
    protector_save_status_reset(true);
    protector_save_status_record(0, false);
    protector_save_status_record(1, false);
    protector_save_status_record(0, true);
    protector_save_status_record(2, false);
    protector_save_status_read(NULL);
    protector_save_status_read(&status);
    assert(status.enabled && status.pending_failure_mask == 2u);
    assert(status.attempts[0] == 2 && status.commits[0] == 1 && status.failures[0] == 1);
    assert(status.attempts[1] == 1 && status.commits[1] == 0 && status.failures[1] == 1);
    protector_save_status_record(1, true);
    protector_save_status_read(&status);
    assert(!status.pending_failure_mask && status.commits[1] == 1);
    protector_save_status_reset(false);
    char directory[] = "/tmp/protector-save-tests-XXXXXX";
    assert(mkdtemp(directory));
    char error[256];
    ProtectorSaveStore store;
    assert(!protector_save_store_open(&store, "relative", error, sizeof(error)));
    assert(protector_save_store_open(&store, directory, error, sizeof(error)));
    uint8_t* data; size_t size; bool exists;
    assert(protector_save_store_load(&store, 0, &data, &size, &exists, error, sizeof(error)));
    assert(!exists && !data && size == 0);
    const uint8_t first[] = {0, 1, 2, 255};
    const uint8_t second[] = {9, 8};
    assert(protector_save_store_write(&store, 0, first, sizeof(first), error, sizeof(error)));
    protector_save_store_close(&store);
    assert(protector_save_store_open(&store, directory, error, sizeof(error)));
    assert(protector_save_store_load(&store, 0, &data, &size, &exists, error, sizeof(error)));
    assert(exists && size == sizeof(first) && memcmp(data, first, size) == 0);
    free(data);
    assert(protector_save_store_write(&store, 0, second, sizeof(second), error, sizeof(error)));
    int previous = openat(store.directory_fd, "SavedGames.previous", O_RDONLY);
    assert(previous >= 0);
    uint8_t backup[4];
    assert(read(previous, backup, sizeof(backup)) == sizeof(backup));
    assert(memcmp(backup, first, sizeof(first)) == 0);
    close(previous);
    assert(protector_save_store_load(&store, 0, &data, &size, &exists, error, sizeof(error)));
    assert(size == sizeof(second) && memcmp(data, second, size) == 0);
    free(data);
    assert(!protector_save_store_write(&store, 2, first, sizeof(first), error, sizeof(error)));
    assert(!protector_save_store_write(&store, 0, first, PROTECTOR_SAVE_MAX_BYTES + 1u, error, sizeof(error)));
    assert(symlinkat("SavedGames", store.directory_fd, "banner.bin") == 0);
    assert(!protector_save_store_load(&store, 1, &data, &size, &exists, error, sizeof(error)));
    assert(!protector_save_store_write(&store, 1, second, sizeof(second), error, sizeof(error)));
    assert(unlinkat(store.directory_fd, "banner.bin", 0) == 0);
    assert(protector_save_store_write(&store, 1, NULL, 0, error, sizeof(error)));
    assert(protector_save_store_load(&store, 1, &data, &size, &exists, error, sizeof(error)));
    assert(exists && !data && size == 0);
    assert(unlinkat(store.directory_fd, "SavedGames", 0) == 0);
    assert(unlinkat(store.directory_fd, "SavedGames.previous", 0) == 0);
    assert(unlinkat(store.directory_fd, "banner.bin", 0) == 0);
    protector_save_store_close(&store);
    assert(rmdir(directory) == 0);
    puts("save store: round trip, replacement, previous generation, bounds, symlinks passed");
    return 0;
}
