#include "JavaScriptInterpreter.h"
#include "quickjs.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { max_output = 16384 };

typedef struct {
    uint64_t deadline;
    char logs[max_output + 1];
    size_t length;
} Evaluation;

static uint64_t milliseconds(void) {
    struct timespec now = {0};
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}

static int should_interrupt(JSContext *context, void *opaque) {
    (void)context;
    return milliseconds() >= ((Evaluation *)opaque)->deadline;
}

static void append_log(Evaluation *evaluation, const char *text, size_t length) {
    const size_t remaining = max_output - evaluation->length;
    if (length > remaining) {
        length = remaining;
        while (length && ((unsigned char)text[length] & 0xc0) == 0x80) --length;
    }
    memcpy(evaluation->logs + evaluation->length, text, length);
    evaluation->length += length;
}

static JSValue log_message(JSContext *context, JSValueConst receiver, int argc, JSValueConst *argv) {
    (void)receiver;
    Evaluation *evaluation = JS_GetContextOpaque(context);
    for (int index = 0; index < argc && evaluation->length < max_output; ++index) {
        size_t length;
        const char *text = JS_ToCStringLen(context, &length, argv[index]);
        if (!text) return JS_EXCEPTION;
        if (index != 0) append_log(evaluation, " ", 1);
        append_log(evaluation, text, length);
        JS_FreeCString(context, text);
    }
    append_log(evaluation, "\n", 1);
    return JS_UNDEFINED;
}

static char *copy_value(JSContext *context, JSValueConst value) {
    size_t length;
    const char *text = JS_ToCStringLen(context, &length, value);
    if (!text) return NULL;
    if (length > max_output) {
        length = max_output;
        while (length && ((unsigned char)text[length] & 0xc0) == 0x80) --length;
    }
    char *copy = strndup(text, length);
    JS_FreeCString(context, text);
    return copy;
}

DSBotJavaScriptResult dsbot_evaluate_javascript(const char *script, size_t length, int timeout_ms) {
    DSBotJavaScriptResult result = {0};
    if (length > 262144 || timeout_ms <= 0) {
        result.error = strdup("脚本超过执行限制。");
        return result;
    }
    JSRuntime *runtime = JS_NewRuntime();
    if (!runtime) {
        result.error = strdup("无法初始化 JavaScript。");
        return result;
    }
    JS_SetMemoryLimit(runtime, 16 * 1024 * 1024);
    JS_SetMaxStackSize(runtime, 256 * 1024);
    JSContext *context = JS_NewContext(runtime);
    if (!context) {
        JS_FreeRuntime(runtime);
        result.error = strdup("无法创建 JavaScript 上下文。");
        return result;
    }
    Evaluation evaluation = { .deadline = milliseconds() + (uint64_t)timeout_ms };
    JS_SetContextOpaque(context, &evaluation);
    JS_SetInterruptHandler(runtime, should_interrupt, &evaluation);

    JSValue global = JS_GetGlobalObject(context);
    JSValue console = JS_NewObject(context);
    JS_SetPropertyStr(context, console, "log", JS_NewCFunction(context, log_message, "log", 1));
    JS_SetPropertyStr(context, console, "warn", JS_NewCFunction(context, log_message, "warn", 1));
    JS_SetPropertyStr(context, console, "error", JS_NewCFunction(context, log_message, "error", 1));
    JS_SetPropertyStr(context, global, "console", console);
    JS_FreeValue(context, global);

    JSValue value = JS_Eval(context, script, length, "script.js", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsObject(value)) {
        JSValue rendered = JS_JSONStringify(context, value, JS_UNDEFINED, JS_UNDEFINED);
        JS_FreeValue(context, value);
        value = rendered;
    }
    if (JS_IsException(value)) {
        JSValue error = JS_GetException(context);
        result.error = milliseconds() >= evaluation.deadline ? strdup("JavaScript 执行超时。") : copy_value(context, error);
        if (!result.error) result.error = strdup("JavaScript 执行失败。");
        JS_FreeValue(context, error);
    } else if (!JS_IsUndefined(value) && !JS_IsNull(value)) {
        result.value = copy_value(context, value);
        if (!result.value) result.error = strdup("JavaScript 结果无法转换。");
    }
    JS_FreeValue(context, value);
    result.logs = strdup(evaluation.logs);
    JS_FreeContext(context);
    JS_FreeRuntime(runtime);
    return result;
}

void dsbot_free_javascript_result(DSBotJavaScriptResult result) {
    free(result.value);
    free(result.logs);
    free(result.error);
}
