#ifndef PROTECTOR_RUNTIME_RESULT_H
#define PROTECTOR_RUNTIME_RESULT_H

/* Host failures, not translated-game error codes. Keep save startup failures
 * distinct from generic configuration failure (8) and write failure (12). */
enum {
    PROTECTOR_RUNTIME_SAVE_COMMIT_FAILED = 12,
    PROTECTOR_RUNTIME_SAVE_DIRECTORY_FAILED = 17,
    PROTECTOR_RUNTIME_SAVE_LOAD_FAILED = 18,
};

#endif
