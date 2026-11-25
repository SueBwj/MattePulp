#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

int32_t matte_login_item_status(CFURLRef bundle);
bool matte_login_item_set_enabled(CFURLRef bundle, bool enabled);

#define MATTE_RULE_UNAVAILABLE 1
#define MATTE_RULE_INACTIVE 2
#define MATTE_RULE_ACTIVE 3

typedef struct {
    int32_t timed, sunset, start, end;
    double latitude, longitude;
} MatteRules;

typedef struct {
    int32_t timed, sunset, visible, hasNext;
    int64_t nextMinute;
} MatteScheduleEvaluation;

MatteScheduleEvaluation matte_schedule_evaluate(
    MatteRules rules, int64_t now,
    int32_t (*localMinute)(int64_t, const void *), const void *context,
    int32_t manual, int32_t suppressed, int32_t preview);

#define MATTE_TONE_ORIGINAL 0
#define MATTE_TONE_LIGHT_WARM 1
#define MATTE_TONE_WARM_PAPER 2

void matte_apply_tone(uint8_t *pixels, size_t len, uint8_t tone);
