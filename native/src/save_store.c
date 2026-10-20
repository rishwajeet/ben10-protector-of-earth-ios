#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "protector/save_store.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char* const names[] = {"SavedGames", "banner.bin"};
static atomic_uint_fast64_t next_temporary;
static atomic_flag status_lock = ATOMIC_FLAG_INIT;
static ProtectorSaveStatus save_status;

void protector_save_status_reset(bool enabled) {
    while (atomic_flag_test_and_set_explicit(&status_lock, memory_order_acquire)) {}
    memset(&save_status, 0, sizeof(save_status));
    save_status.enabled = enabled;
    atomic_flag_clear_explicit(&status_lock, memory_order_release);
}

void protector_save_status_record(unsigned slot, bool committed) {
    if (slot >= 2) return;
    while (atomic_flag_test_and_set_explicit(&status_lock, memory_order_acquire)) {}
    if (save_status.enabled) {
        ++save_status.attempts[slot];
        if (committed) {
            ++save_status.commits[slot];
            save_status.pending_failure_mask &= ~(1u << slot);
        } else {
            ++save_status.failures[slot];
            save_status.pending_failure_mask |= 1u << slot;
        }
    }
    atomic_flag_clear_explicit(&status_lock, memory_order_release);
}

void protector_save_status_read(ProtectorSaveStatus* status) {
    if (!status) return;
    while (atomic_flag_test_and_set_explicit(&status_lock, memory_order_acquire)) {}
    *status = save_status;
    atomic_flag_clear_explicit(&status_lock, memory_order_release);
}

static bool failure(char* error, size_t capacity, const char* action) {
    const int code = errno;
    if (error && capacity) snprintf(error, capacity, "%s: %s", action, strerror(code));
    return false;
}

bool protector_save_store_open(ProtectorSaveStore* store, const char* directory,
                               char* error, size_t capacity) {
    if (!store) { errno = EINVAL; return failure(error, capacity, "save store"); }
    store->directory_fd = -1;
    if (!directory || directory[0] != '/') {
        errno = EINVAL; return failure(error, capacity, "save directory must be absolute");
    }
    store->directory_fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (store->directory_fd < 0) return failure(error, capacity, "open save directory");
    return true;
}

void protector_save_store_close(ProtectorSaveStore* store) {
    if (store && store->directory_fd >= 0) {
        close(store->directory_fd);
        store->directory_fd = -1;
    }
}

bool protector_save_store_load(ProtectorSaveStore* store, unsigned slot,
                               uint8_t** data, size_t* size, bool* exists,
                               char* error, size_t capacity) {
    if (!store || store->directory_fd < 0 || slot >= 2 || !data || !size || !exists) {
        errno = EINVAL; return failure(error, capacity, "load save arguments");
    }
    *data = NULL; *size = 0; *exists = false;
    const int fd = openat(store->directory_fd, names[slot], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ENOENT) return true;
        return failure(error, capacity, "open save file");
    }
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
        info.st_size > PROTECTOR_SAVE_MAX_BYTES) {
        close(fd); errno = EINVAL;
        return failure(error, capacity, "save file type or length");
    }
    const size_t length = (size_t)info.st_size;
    uint8_t* bytes = length ? malloc(length) : NULL;
    if (length && !bytes) { close(fd); errno = ENOMEM; return failure(error, capacity, "allocate save"); }
    size_t offset = 0;
    while (offset < length) {
        const ssize_t count = read(fd, bytes + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            free(bytes); close(fd); errno = EIO;
            return failure(error, capacity, "read complete save");
        }
        offset += (size_t)count;
    }
    close(fd);
    *data = bytes; *size = length; *exists = true;
    return true;
}

bool protector_save_store_write(ProtectorSaveStore* store, unsigned slot,
                                const uint8_t* data, size_t size,
                                char* error, size_t capacity) {
    if (!store || store->directory_fd < 0 || slot >= 2 ||
        (size && !data) || size > PROTECTOR_SAVE_MAX_BYTES) {
        errno = EINVAL; return failure(error, capacity, "write save arguments");
    }
    const int root = store->directory_fd;
    struct stat existing;
    const int found = fstatat(root, names[slot], &existing, AT_SYMLINK_NOFOLLOW);
    if ((found == 0 && !S_ISREG(existing.st_mode)) || (found != 0 && errno != ENOENT)) {
        errno = EINVAL; return failure(error, capacity, "existing save is not a regular file");
    }
    char temporary[96], previous[64], backup[96];
    const unsigned long long serial = (unsigned long long)atomic_fetch_add(&next_temporary, 1);
    snprintf(temporary, sizeof(temporary), ".%s.%ld.%llu.tmp", names[slot], (long)getpid(), serial);
    snprintf(previous, sizeof(previous), "%s.previous", names[slot]);
    snprintf(backup, sizeof(backup), ".%s.%ld.%llu.previous", names[slot], (long)getpid(), serial);
    const int fd = openat(root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return failure(error, capacity, "create atomic save");
    size_t offset = 0;
    while (offset < size) {
        const ssize_t count = write(fd, data + offset, size - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            const int code = errno ? errno : EIO;
            close(fd); unlinkat(root, temporary, 0); errno = code;
            return failure(error, capacity, "write atomic save");
        }
        offset += (size_t)count;
    }
    if (fsync(fd) != 0) {
        const int code = errno; close(fd); unlinkat(root, temporary, 0); errno = code;
        return failure(error, capacity, "sync atomic save");
    }
    if (close(fd) != 0) {
        const int code = errno; unlinkat(root, temporary, 0); errno = code;
        return failure(error, capacity, "close atomic save");
    }
    if (found == 0) {
        if (linkat(root, names[slot], root, backup, 0) != 0 ||
            renameat(root, backup, root, previous) != 0) {
            const int code = errno;
            unlinkat(root, backup, 0); unlinkat(root, temporary, 0); errno = code;
            return failure(error, capacity, "preserve previous save");
        }
    }
    if (renameat(root, temporary, root, names[slot]) != 0) {
        const int code = errno; unlinkat(root, temporary, 0); errno = code;
        return failure(error, capacity, "commit atomic save");
    }
    if (fsync(root) != 0) return failure(error, capacity, "sync save directory");
    return true;
}
