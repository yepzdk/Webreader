/*
 * CReaderKitJNI — the one JNI entry point, and nothing else.
 *
 *   package dk.yepz.webreader;
 *   final class ReaderBridge { static native String call(String name, String jsonArgs); }
 *
 * The shim owns no state and makes no decisions: it moves two strings into Swift, moves one
 * string back, and frees what it borrowed. Every rule lives behind `readerkit_call`.
 *
 * It is C rather than Swift because the `Java_…` symbol names and the JNIEnv function-table
 * calling convention belong to jni.h, and a C leaf keeps both out of Swift's name mangling.
 */
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "readerkit_bridge.h"

/*
 * JNI's "UTF-8" is Modified UTF-8, which is not UTF-8: U+0000 is encoded as two bytes and
 * anything outside the BMP is kept as a surrogate pair, each half encoded separately as
 * three bytes (CESU-8). `GetStringUTFChars` would therefore hand Swift an emoji as two lone
 * surrogates, and `String(cString:)` repairs those to U+FFFD — silent, unrecoverable
 * mangling of exactly the payload that matters most here, the extracted article body. So
 * both directions transcode against UTF-16, which JNI does define exactly. The Java-side
 * signature is unaffected; only the JNI calls used to read and build the strings change.
 */

/* Caller frees. Null means an exception is pending (OOM); the caller must return at once. */
static char *utf8_from_java(JNIEnv *env, jstring s) {
    const jsize units = (*env)->GetStringLength(env, s);
    const jchar *utf16 = (*env)->GetStringChars(env, s, NULL);
    if (utf16 == NULL) {
        return NULL;
    }

    /* Three bytes per UTF-16 unit is the exact worst case: the only four-byte sequence comes
     * from a surrogate pair, which is two units, and a lone surrogate becomes a three-byte
     * U+FFFD. */
    char *out = malloc((size_t)units * 3 + 1);
    if (out == NULL) {
        (*env)->ReleaseStringChars(env, s, utf16);
        return NULL;
    }

    size_t n = 0;
    for (jsize i = 0; i < units; i++) {
        uint32_t c = utf16[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < units && utf16[i + 1] >= 0xDC00 && utf16[i + 1] <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + (uint32_t)(utf16[i + 1] - 0xDC00);
            i++;
        } else if (c >= 0xD800 && c <= 0xDFFF) {
            /* A Java String may hold an unpaired surrogate; UTF-8 has no encoding for one. */
            c = 0xFFFD;
        }

        if (c < 0x80) {
            out[n++] = (char)c;
        } else if (c < 0x800) {
            out[n++] = (char)(0xC0 | (c >> 6));
            out[n++] = (char)(0x80 | (c & 0x3F));
        } else if (c < 0x10000) {
            out[n++] = (char)(0xE0 | (c >> 12));
            out[n++] = (char)(0x80 | ((c >> 6) & 0x3F));
            out[n++] = (char)(0x80 | (c & 0x3F));
        } else {
            out[n++] = (char)(0xF0 | (c >> 18));
            out[n++] = (char)(0x80 | ((c >> 12) & 0x3F));
            out[n++] = (char)(0x80 | ((c >> 6) & 0x3F));
            out[n++] = (char)(0x80 | (c & 0x3F));
        }
    }
    out[n] = '\0';

    (*env)->ReleaseStringChars(env, s, utf16);
    return out;
}

/* Null means an exception is pending (OOM) and becomes a Java null, which is harmless. */
static jstring java_from_utf8(JNIEnv *env, const char *s) {
    const size_t bytes = strlen(s);

    /* One UTF-16 unit per byte bounds it: the shortest sequence yielding one unit is one
     * byte, and the four-byte sequence yields two. The +1 keeps malloc(0) out of it. */
    jchar *utf16 = malloc((bytes + 1) * sizeof(jchar));
    if (utf16 == NULL) {
        return NULL;
    }

    size_t n = 0;
    for (size_t i = 0; i < bytes;) {
        const unsigned char lead = (unsigned char)s[i++];
        uint32_t c;
        size_t trail;
        if (lead < 0x80) {
            c = lead;
            trail = 0;
        } else if ((lead & 0xE0) == 0xC0) {
            c = lead & 0x1Fu;
            trail = 1;
        } else if ((lead & 0xF0) == 0xE0) {
            c = lead & 0x0Fu;
            trail = 2;
        } else if ((lead & 0xF8) == 0xF0) {
            c = lead & 0x07u;
            trail = 3;
        } else {
            c = 0xFFFD; /* stray continuation byte */
            trail = 0;
        }
        for (size_t k = 0; k < trail; k++) {
            if (i >= bytes || ((unsigned char)s[i] & 0xC0) != 0x80) {
                c = 0xFFFD;
                break;
            }
            c = (c << 6) | ((unsigned char)s[i++] & 0x3Fu);
        }
        if (c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)) {
            c = 0xFFFD;
        }

        if (c < 0x10000) {
            utf16[n++] = (jchar)c;
        } else {
            c -= 0x10000;
            utf16[n++] = (jchar)(0xD800 + (c >> 10));
            utf16[n++] = (jchar)(0xDC00 + (c & 0x3FF));
        }
    }

    jstring out = (*env)->NewString(env, utf16, (jsize)n);
    free(utf16);
    return out;
}

JNIEXPORT jstring JNICALL Java_dk_yepz_webreader_ReaderBridge_call(JNIEnv *env, jclass cls, jstring name, jstring json_args) {
    (void)cls;
    /* `call` is declared with non-null parameters on the Kotlin side, but JNI does not
     * enforce that, and GetStringChars on null aborts the process rather than throwing. */
    if (name == NULL || json_args == NULL) {
        return NULL;
    }

    char *c_name = utf8_from_java(env, name);
    if (c_name == NULL) {
        return NULL;
    }
    char *c_args = utf8_from_java(env, json_args);
    if (c_args == NULL) {
        free(c_name);
        return NULL;
    }

    char *reply = readerkit_call(c_name, c_args);
    free(c_name);
    free(c_args);
    if (reply == NULL) {
        return NULL;
    }

    jstring out = java_from_utf8(env, reply);
    readerkit_free(reply);
    return out;
}
