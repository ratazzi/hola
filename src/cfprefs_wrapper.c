#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

// ============================================================================
// Write operations
// ============================================================================

// Write boolean value
// Returns 1 on success, 0 on failure
int cfpreferences_write_boolean(const char *domain, const char *key, int value) {
    CFStringRef domain_cf = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
    CFStringRef key_cf = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);

    CFBooleanRef bool_val = value ? kCFBooleanTrue : kCFBooleanFalse;

    CFPreferencesSetAppValue(key_cf, bool_val, domain_cf);
    Boolean sync_result = CFPreferencesAppSynchronize(domain_cf);

    CFRelease(key_cf);
    CFRelease(domain_cf);

    return sync_result ? 1 : 0;
}

// Write integer value
// Returns 1 on success, 0 on failure
int cfpreferences_write_integer(const char *domain, const char *key, long long value) {
    CFStringRef domain_cf = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
    CFStringRef key_cf = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);

    CFNumberRef num = CFNumberCreate(NULL, kCFNumberLongLongType, &value);
    if (!num) {
        CFRelease(key_cf);
        CFRelease(domain_cf);
        return 0;
    }

    CFPreferencesSetAppValue(key_cf, num, domain_cf);
    Boolean sync_result = CFPreferencesAppSynchronize(domain_cf);

    CFRelease(num);
    CFRelease(key_cf);
    CFRelease(domain_cf);

    return sync_result ? 1 : 0;
}

// Write float value
// Returns 1 on success, 0 on failure
int cfpreferences_write_float(const char *domain, const char *key, double value) {
    CFStringRef domain_cf = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
    CFStringRef key_cf = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);

    CFNumberRef num = CFNumberCreate(NULL, kCFNumberDoubleType, &value);
    if (!num) {
        CFRelease(key_cf);
        CFRelease(domain_cf);
        return 0;
    }

    CFPreferencesSetAppValue(key_cf, num, domain_cf);
    Boolean sync_result = CFPreferencesAppSynchronize(domain_cf);

    CFRelease(num);
    CFRelease(key_cf);
    CFRelease(domain_cf);

    return sync_result ? 1 : 0;
}

// Write string value
// Returns 1 on success, 0 on failure
int cfpreferences_write_string(const char *domain, const char *key, const char *value) {
    CFStringRef domain_cf = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
    CFStringRef key_cf = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFStringRef value_cf = CFStringCreateWithCString(NULL, value, kCFStringEncodingUTF8);

    if (!value_cf) {
        CFRelease(key_cf);
        CFRelease(domain_cf);
        return 0;
    }

    CFPreferencesSetAppValue(key_cf, value_cf, domain_cf);
    Boolean sync_result = CFPreferencesAppSynchronize(domain_cf);

    CFRelease(value_cf);
    CFRelease(key_cf);
    CFRelease(domain_cf);

    return sync_result ? 1 : 0;
}

// ============================================================================
// Read operations
// ============================================================================

// Read boolean value
// Returns: 1 if value exists and is boolean, 0 otherwise
// out_value: pointer to store the boolean value (0 or 1)
int cfpreferences_read_boolean(const char *domain, const char *key, int *out_value) {
    CFStringRef domain_cf = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
    CFStringRef key_cf = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);

    CFTypeRef value = CFPreferencesCopyAppValue(key_cf, domain_cf);

    CFRelease(key_cf);
    CFRelease(domain_cf);

    if (!value) {
        return 0; // Key doesn't exist
    }

    if (CFGetTypeID(value) != CFBooleanGetTypeID()) {
        CFRelease(value);
        return 0; // Not a boolean
    }

    *out_value = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
    CFRelease(value);
    return 1;
}

// Read integer value
// Returns: 1 if value exists and is number, 0 otherwise
// out_value: pointer to store the integer value
int cfpreferences_read_integer(const char *domain, const char *key, long long *out_value) {
    CFStringRef domain_cf = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
    CFStringRef key_cf = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);

    CFTypeRef value = CFPreferencesCopyAppValue(key_cf, domain_cf);

    CFRelease(key_cf);
    CFRelease(domain_cf);

    if (!value) {
        return 0; // Key doesn't exist
    }

    if (CFGetTypeID(value) != CFNumberGetTypeID()) {
        CFRelease(value);
        return 0; // Not a number
    }

    Boolean success = CFNumberGetValue((CFNumberRef)value, kCFNumberLongLongType, out_value);
    CFRelease(value);
    return success ? 1 : 0;
}

// Read float value
// Returns: 1 if value exists and is number, 0 otherwise
// out_value: pointer to store the float value
int cfpreferences_read_float(const char *domain, const char *key, double *out_value) {
    CFStringRef domain_cf = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
    CFStringRef key_cf = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);

    CFTypeRef value = CFPreferencesCopyAppValue(key_cf, domain_cf);

    CFRelease(key_cf);
    CFRelease(domain_cf);

    if (!value) {
        return 0; // Key doesn't exist
    }

    if (CFGetTypeID(value) != CFNumberGetTypeID()) {
        CFRelease(value);
        return 0; // Not a number
    }

    Boolean success = CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, out_value);
    CFRelease(value);
    return success ? 1 : 0;
}

// Read string value
// Returns: 1 if value exists and is string, 0 otherwise
// buffer: buffer to store the string (must be pre-allocated)
// buffer_size: size of the buffer
int cfpreferences_read_string(const char *domain, const char *key, char *buffer, int buffer_size) {
    CFStringRef domain_cf = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
    CFStringRef key_cf = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);

    CFTypeRef value = CFPreferencesCopyAppValue(key_cf, domain_cf);

    CFRelease(key_cf);
    CFRelease(domain_cf);

    if (!value) {
        return 0; // Key doesn't exist
    }

    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return 0; // Not a string
    }

    Boolean success = CFStringGetCString((CFStringRef)value, buffer, buffer_size, kCFStringEncodingUTF8);
    CFRelease(value);
    return success ? 1 : 0;
}

// ============================================================================
// Utility functions
// ============================================================================

// Check if a key exists
// Returns: 1 if exists, 0 if not
int cfpreferences_key_exists(const char *domain, const char *key) {
    CFStringRef domain_cf = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
    CFStringRef key_cf = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);

    CFTypeRef value = CFPreferencesCopyAppValue(key_cf, domain_cf);

    CFRelease(key_cf);
    CFRelease(domain_cf);

    if (value) {
        CFRelease(value);
        return 1;
    }
    return 0;
}

// Delete a key
// Returns: 1 on success, 0 on failure
int cfpreferences_delete_key(const char *domain, const char *key) {
    CFStringRef domain_cf = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
    CFStringRef key_cf = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);

    CFPreferencesSetAppValue(key_cf, NULL, domain_cf);
    Boolean sync_result = CFPreferencesAppSynchronize(domain_cf);

    CFRelease(key_cf);
    CFRelease(domain_cf);

    return sync_result ? 1 : 0;
}
