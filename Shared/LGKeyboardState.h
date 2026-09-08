#ifndef LG_KEYBOARD_STATE_H
#define LG_KEYBOARD_STATE_H

#include <stdbool.h>
#include <stdint.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define LG_KEYBOARD_STATE_MAGIC 0x4c474b42u

typedef struct {
    uint32_t magic;
    uint32_t sequence;
    uint32_t active;
    uint32_t deviceOrientation;
} LGKeyboardSharedState;

static inline LGKeyboardSharedState *LGKeyboardMapSharedState(bool writable) {
    static LGKeyboardSharedState *readOnlyState;
    static LGKeyboardSharedState *writableState;
    LGKeyboardSharedState **slot = writable ? &writableState : &readOnlyState;
    if (*slot) return *slot;
    int fd = open("/var/mobile/Library/Accessibility/liquidglass-keyboard-state.bin",
                  writable ? O_RDWR | O_CREAT : O_RDONLY, 0666);
    if (fd < 0) return NULL;
    if (writable && ftruncate(fd, sizeof(LGKeyboardSharedState)) != 0) {
        close(fd);
        return NULL;
    }
    struct stat info = {};
    if (fstat(fd, &info) != 0 || info.st_size < sizeof(LGKeyboardSharedState)) {
        close(fd);
        return NULL;
    }
    void *mapping = mmap(NULL, sizeof(LGKeyboardSharedState),
                         PROT_READ | (writable ? PROT_WRITE : 0),
                         MAP_SHARED, fd, 0);
    close(fd);
    if (mapping == MAP_FAILED) return NULL;
    *slot = (LGKeyboardSharedState *)mapping;
    if (writable && (*slot)->magic != LG_KEYBOARD_STATE_MAGIC) {
        memset(*slot, 0, sizeof(**slot));
        (*slot)->magic = LG_KEYBOARD_STATE_MAGIC;
    }
    return *slot;
}

static inline void LGKeyboardWriteSharedState(bool active,
                                               uint32_t orientation) {
    LGKeyboardSharedState *state = LGKeyboardMapSharedState(true);
    if (!state) return;
    uint32_t sequence = __atomic_load_n(&state->sequence, __ATOMIC_RELAXED);
    uint32_t writing = (sequence + 1u) | 1u;
    __atomic_store_n(&state->sequence, writing, __ATOMIC_RELEASE);
    state->active = active;
    state->deviceOrientation = orientation;
    __atomic_store_n(&state->sequence, writing + 1u, __ATOMIC_RELEASE);
}

static inline bool LGKeyboardReadSharedState(LGKeyboardSharedState *snapshot) {
    LGKeyboardSharedState *state = LGKeyboardMapSharedState(false);
    if (!snapshot || !state || state->magic != LG_KEYBOARD_STATE_MAGIC) return false;
    for (int attempt = 0; attempt < 4; attempt++) {
        uint32_t before = __atomic_load_n(&state->sequence, __ATOMIC_ACQUIRE);
        if (before & 1u) continue;
        memcpy(snapshot, state, sizeof(*snapshot));
        uint32_t after = __atomic_load_n(&state->sequence, __ATOMIC_ACQUIRE);
        if (before == after && !(after & 1u)) return true;
    }
    return false;
}

#endif
