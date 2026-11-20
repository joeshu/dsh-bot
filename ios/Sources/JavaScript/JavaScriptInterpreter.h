#ifndef DS_BOT_JAVASCRIPT_INTERPRETER_H
#define DS_BOT_JAVASCRIPT_INTERPRETER_H

#include <stddef.h>

typedef struct {
    char *value;
    char *logs;
    char *error;
} DSBotJavaScriptResult;

DSBotJavaScriptResult dsbot_evaluate_javascript(const char *script, size_t length, int timeout_ms);
void dsbot_free_javascript_result(DSBotJavaScriptResult result);

#endif
