#ifndef LG_LENS_RECT_STATE_H
#define LG_LENS_RECT_STATE_H


#include <stdbool.h>
#include <stdint.h>
#include <notify.h>

enum {
    LGLensRectSlotPrefsSegment = 0,
    LGLensRectSlotTabBarSelection = 1,
    LGLensRectSlotNowPlayingArtwork = 2,
    LGLensRectSlotCount = 4,
};

typedef struct {
    uint32_t active;
    float originXRatio;
    float originYRatio;
    float widthRatio;
    float heightRatio;
} LGLensRectSlot;

static inline const char *LGLensRectNotifyName(uint32_t slotIndex) {
    switch (slotIndex) {
        case LGLensRectSlotPrefsSegment:
            return "dylv.liquidglass.lensrect.prefssegment";
        case LGLensRectSlotTabBarSelection:
            return "dylv.liquidglass.lensrect.tabbarselect";
        case LGLensRectSlotNowPlayingArtwork:
            return "dylv.liquidglass.lensrect.npartwork";
        default:
            return NULL;
    }
}

static inline int LGLensRectToken(uint32_t slotIndex) {
    static int sTokens[LGLensRectSlotCount];
    static bool sRegistered[LGLensRectSlotCount];
    if (slotIndex >= (uint32_t)LGLensRectSlotCount) return -1;
    if (!sRegistered[slotIndex]) {
        const char *name = LGLensRectNotifyName(slotIndex);
        if (!name) return -1;
        int token = 0;
        if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return -1;
        sTokens[slotIndex] = token;
        sRegistered[slotIndex] = true;
    }
    return sTokens[slotIndex];
}

#define LG_LENS_RECT_RATIO_MIN  (-0.5f)
#define LG_LENS_RECT_RATIO_SPAN (2.0f)

static inline uint64_t LGLensRectQuantize(float ratio) {
    float t = (ratio - LG_LENS_RECT_RATIO_MIN) / LG_LENS_RECT_RATIO_SPAN;
    if (!(t > 0.f)) t = 0.f;
    if (t > 1.f) t = 1.f;
    return (uint64_t)(t * 65535.f + 0.5f);
}

static inline float LGLensRectDequantize(uint64_t raw) {
    return (float)(raw & 0xffffu) / 65535.f * LG_LENS_RECT_RATIO_SPAN
         + LG_LENS_RECT_RATIO_MIN;
}

static inline bool LGLensRectWrite(uint32_t slotIndex, bool active,
                                   float originXRatio, float originYRatio,
                                   float widthRatio, float heightRatio) {
    int token = LGLensRectToken(slotIndex);
    if (token < 0) return false;
    uint64_t packed = 0;
    if (active) {
        packed = (LGLensRectQuantize(originXRatio) << 48) |
                 (LGLensRectQuantize(originYRatio) << 32) |
                 (LGLensRectQuantize(widthRatio)   << 16) |
                  LGLensRectQuantize(heightRatio);
    }
    return notify_set_state(token, packed) == NOTIFY_STATUS_OK;
}

static inline bool LGLensRectRead(uint32_t slotIndex, LGLensRectSlot *out) {
    if (!out) return false;
    int token = LGLensRectToken(slotIndex);
    if (token < 0) return false;
    uint64_t packed = 0;
    if (notify_get_state(token, &packed) != NOTIFY_STATUS_OK) return false;
    out->originXRatio = LGLensRectDequantize(packed >> 48);
    out->originYRatio = LGLensRectDequantize(packed >> 32);
    out->widthRatio   = LGLensRectDequantize(packed >> 16);
    out->heightRatio  = LGLensRectDequantize(packed);
    out->active = (out->widthRatio > 0.f && out->heightRatio > 0.f) ? 1u : 0u;
    return out->active != 0u;
}

#endif
