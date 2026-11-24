#include <stdint.h>

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
