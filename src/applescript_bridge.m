// applescript_bridge.m - Objective-C bridge for runtime calls
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// objc_msgSend is a macro, so we need to use the actual function pointer
// We'll use the runtime functions directly with proper ARC bridging

void* objc_msgSend_wrapper(void* obj, SEL sel) {
    return ((void*(*)(id, SEL))objc_msgSend)((__bridge id)obj, sel);
}

void* objc_msgSend1_wrapper(void* obj, SEL sel, void* arg1) {
    return ((void*(*)(id, SEL, id))objc_msgSend)((__bridge id)obj, sel, (__bridge id)arg1);
}

void* objc_msgSend2_wrapper(void* obj, SEL sel, void* arg1, unsigned long arg2, unsigned int arg3) {
    return ((void*(*)(id, SEL, const void*, NSUInteger, NSUInteger))objc_msgSend)((__bridge id)obj, sel, arg1, arg2, arg3);
}

_Bool objc_msgSend_bool_wrapper(void* obj, SEL sel, void** error_ptr) {
    NSDictionary* __autoreleasing dict = nil;
    NSDictionary* __autoreleasing* dict_ptr = &dict;
    BOOL result = ((BOOL(*)(id, SEL, NSDictionary* __autoreleasing*))objc_msgSend)((__bridge id)obj, sel, dict_ptr);
    if (error_ptr) {
        *error_ptr = (__bridge void*)dict;
    }
    return result;
}

void* objc_msgSend_error_wrapper(void* obj, SEL sel, void** error_ptr) {
    NSDictionary* __autoreleasing dict = nil;
    NSDictionary* __autoreleasing* dict_ptr = &dict;
    void* result = ((void*(*)(id, SEL, NSDictionary* __autoreleasing*))objc_msgSend)((__bridge id)obj, sel, dict_ptr);
    if (error_ptr) {
        *error_ptr = (__bridge void*)dict;
    }
    return result;
}

const char* nsstring_utf8string(void* ns_string) {
    return [(__bridge NSString*)ns_string UTF8String];
}

// Helper function to create NSString from C string and return as id
// This ensures proper alignment by returning the object directly as id
id nsstring_with_utf8string(const char* c_str) __attribute__((ns_returns_retained));
id nsstring_with_utf8string(const char* c_str) {
    if (c_str == NULL) return nil;
    NSString* ns_str = [[NSString alloc] initWithUTF8String:c_str];
    return ns_str;
}

// Helper function to cast void* to id with proper alignment
// This ensures the returned pointer is properly aligned
// Note: This is just a type cast, no ownership transfer or retain
// We return void* to avoid ARC retain issues - Zig will handle the type conversion
void* cast_to_id(void* ptr) {
    if (ptr == NULL) return NULL;
    // Objective-C objects are always properly aligned
    // Just return the pointer as-is - no ARC retain because we return void*
    return ptr;
}
