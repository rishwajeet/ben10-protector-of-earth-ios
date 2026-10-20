/* Exercise the actual host NAND-close boundary and filesystem failure. No
 * translated executable or substitute gameplay is run by this unit test. */
#include "protector/cpu.h"
#include <assert.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
static int dolrecomp_call(CPUState* cpu, u32 address) {
    (void)cpu; (void)address;
    assert(!"save commit tests must not execute translated code");
    return 0;
}
#define PROTECTOR_BOOT_DISPATCH_TEST 1
#define main protector_unused_boot_main
#include "../macos/boot_main.c"
#undef main

static void test_native_menu_exit(BootTrace* trace) {
    CPUState cpu;
    assert(protector_cpu_init(&cpu));
    cpu.external_user_data = trace;
    mem_write32(&cpu, 0x800b4438u, 0x806d9c14u);
    mem_write32(&cpu, 0x800b443cu, 0x4bf83ddcu);
    protector_live_gx_set_sink(NULL, NULL);
    protector_live_input_enable(false);
    trace->native_ui_text = true;
    assert(!request_native_menu_exit(trace, &cpu, 0x800b4438u));
    protector_live_input_enable(true);
    trace->native_ui_text = false;
    assert(!request_native_menu_exit(trace, &cpu, 0x800b4438u));
    trace->native_ui_text = true;
    assert(!request_native_menu_exit(trace, &cpu, 0x800b443cu));
    mem_write32(&cpu, 0x800b443cu, 0x4bf83dddu);
    assert(!request_native_menu_exit(trace, &cpu, 0x800b4438u));
    assert(!protector_live_gx_stop_requested());
    mem_write32(&cpu, 0x800b443cu, 0x4bf83ddcu);
    // The real dispatch boundary yields without a guest write, save attempt,
    // invented retry, CPU error or console teardown. Pending failure survives.
    trace->save_store_failed = true;
    ProtectorSaveStatus before, after;
    protector_save_status_read(&before);
    CPUState unchanged = cpu;
    assert(trace_host_call(&cpu, 0x800b4438u));
    assert(protector_live_gx_stop_requested() && trace->save_store_failed);
    unchanged.memory_read_count += 2; // Executable identity inspection only.
    assert(!memcmp(&cpu, &unchanged, sizeof(cpu)));
    protector_save_status_read(&after);
    assert(!memcmp(&before, &after, sizeof(before)));
    protector_live_gx_set_sink(NULL, NULL);
    protector_live_input_enable(false);
    trace->native_ui_text = false;
    trace->save_store_failed = false;
    protector_cpu_destroy(&cpu);
}

int main(void) {
    char directory[] = "/tmp/protector-save-close-XXXXXX";
    assert(mkdtemp(directory));
    BootTrace* trace = calloc(1, sizeof(*trace));
    assert(trace);
    test_native_menu_exit(trace);
    char error[256];
    assert(protector_save_store_open(&trace->save_store, directory, error, sizeof(error)));
    const u8 previous[] = {1, 2, 3}, pending[] = {4, 5, 6, 7};
    assert(protector_save_store_write(&trace->save_store, 0, previous, sizeof(previous), error, sizeof(error)));
    // Renaming the backup over this directory must fail before current changes.
    assert(mkdirat(trace->save_store.directory_fd, "SavedGames.previous", 0700) == 0);
    trace->save_store_enabled = true;
    trace->last_ios_command = IOS_COMMAND_CLOSE;
    trace->last_ios_fd = 1;
    NativeNandFile* file = &trace->nand_files[0];
    file->data = malloc(sizeof(pending));
    assert(file->data);
    memcpy(file->data, pending, sizeof(pending));
    file->size = file->capacity = sizeof(pending);
    file->exists = file->open = file->dirty = true;
    protector_save_status_reset(true);
    assert(complete_ios_request(trace, NULL) == -5);
    assert(trace->save_store_failed && file->dirty && file->open);
    ProtectorSaveStatus status;
    protector_save_status_read(&status);
    assert(status.pending_failure_mask == 1 && status.attempts[0] == 1 && status.failures[0] == 1);
    u8* bytes = NULL; size_t size = 0; bool exists = false;
    assert(protector_save_store_load(&trace->save_store, 0, &bytes, &size, &exists, error, sizeof(error)));
    assert(exists && size == sizeof(previous) && !memcmp(bytes, previous, size));
    free(bytes);
    assert(!memcmp(file->data, pending, sizeof(pending)));

    // Retry is still an ordinary guest-owned close. The host does not generate
    // another request or synthesize a successful response after the failure.
    assert(unlinkat(trace->save_store.directory_fd, "SavedGames.previous", AT_REMOVEDIR) == 0);
    assert(complete_ios_request(trace, NULL) == 0);
    assert(!trace->save_store_failed && !file->dirty && !file->open);
    protector_save_status_read(&status);
    assert(!status.pending_failure_mask && status.attempts[0] == 2 && status.commits[0] == 1 && status.failures[0] == 1);
    assert(protector_save_store_load(&trace->save_store, 0, &bytes, &size, &exists, error, sizeof(error)));
    assert(exists && size == sizeof(pending) && !memcmp(bytes, pending, size));
    free(bytes);
    int backup = openat(trace->save_store.directory_fd, "SavedGames.previous", O_RDONLY);
    assert(backup >= 0);
    u8 backup_bytes[sizeof(previous)];
    assert(read(backup, backup_bytes, sizeof(backup_bytes)) == sizeof(backup_bytes));
    assert(!memcmp(backup_bytes, previous, sizeof(previous)));
    close(backup);
    assert(unlinkat(trace->save_store.directory_fd, "SavedGames", 0) == 0);
    assert(unlinkat(trace->save_store.directory_fd, "SavedGames.previous", 0) == 0);
    free(file->data);
    protector_save_store_close(&trace->save_store);
    free(trace);
    assert(rmdir(directory) == 0);
    protector_save_status_reset(false);
    puts("NAND close: failed atomic commit preserves bytes; guest retry clears only durable failure");
    return 0;
}
