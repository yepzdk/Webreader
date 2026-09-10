/*
 * The two symbols Sources/ReaderKitAndroid exports with C linkage.
 *
 * Declared here rather than imported from the Swift target: SwiftPM only emits a generated
 * header for targets a Swift *client* imports, and this shim is a C leaf with no Swift
 * dependents — the dependency edge runs shim -> Swift, which SwiftPM has no way to spell.
 * Two prototypes are the whole coupling; the Swift side pins the same signatures with
 * `@_cdecl`, and a missing one is a link error when the product is assembled.
 */
#ifndef READERKIT_BRIDGE_H
#define READERKIT_BRIDGE_H

/*
 * Dispatches the call `name` with `json_args` (a JSON object) and returns a JSON object.
 * The reply is `strdup`ed by Swift and owned by the caller, hence `char *` and not
 * `const char *`: it is a buffer to be handed back to `readerkit_free`, not a literal. A
 * null reply means that `strdup` failed, and nothing else — an unknown call name and a call
 * made before `start` both answer `{"commands":[]}`, so a caller that treats null as a
 * routine "nothing to say" is treating an allocation failure as one too.
 */
char *readerkit_call(const char *name, const char *json_args);

/* Releases a string returned by `readerkit_call`. Tolerates null. */
void readerkit_free(char *s);

#endif
