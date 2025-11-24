#include <mruby.h>
#include <mruby/array.h>
#include <mruby/value.h>
#include <mruby/string.h>
#include <mruby/hash.h>
#include <stdio.h>

#ifdef __linux__
// Shim for symbols expected by some static libraries (like mruby) but missing in Zig/LLD link
// These are standard Unix linker symbols marking segment ends.
// Use weak symbols to avoid conflicts with other definitions
__attribute__((weak)) char etext;
__attribute__((weak)) char edata;
__attribute__((weak)) char end;
#endif

// Helper to get value type
uint32_t zig_mrb_type(mrb_value val) {
    return mrb_type(val);
}

// Helper to check if value is nil
int zig_mrb_nil_p(mrb_value val) {
    return mrb_nil_p(val);
}

// Helper to check if value is true
int zig_mrb_true_p(mrb_value val) {
    return mrb_true_p(val);
}

// Helper to check if value is false
int zig_mrb_false_p(mrb_value val) {
    return mrb_false_p(val);
}

// Helper to check if value is integer
int zig_mrb_integer_p(mrb_value val) {
    return mrb_integer_p(val);
}

// Helper to check if value is float
int zig_mrb_float_p(mrb_value val) {
    return mrb_float_p(val);
}

// Helper to check if value is string
int zig_mrb_string_p(mrb_value val) {
    return mrb_string_p(val);
}

// Helper to check if value is array
int zig_mrb_array_p(mrb_value val) {
    return mrb_array_p(val);
}

// Helper to check if value is hash
int zig_mrb_hash_p(mrb_value val) {
    return mrb_hash_p(val);
}

// Helper to check if value is symbol
int zig_mrb_symbol_p(mrb_value val) {
    return mrb_symbol_p(val);
}

// Type constants for reference (from mruby/value.h):
// MRB_TT_FALSE = 0  (for both false and nil)
// MRB_TT_TRUE = 2
// MRB_TT_INTEGER = 3
// MRB_TT_SYMBOL = 4
// MRB_TT_UNDEF = 5
// MRB_TT_FLOAT = 6
// MRB_TT_CPTR = 7
// MRB_TT_OBJECT = 8
// MRB_TT_CLASS = 9
// MRB_TT_MODULE = 10
// MRB_TT_ICLASS = 11
// MRB_TT_SCLASS = 12
// MRB_TT_PROC = 13
// MRB_TT_ARRAY = 14
// MRB_TT_HASH = 15
// MRB_TT_STRING = 16
// MRB_TT_RANGE = 17
// MRB_TT_EXCEPTION = 18
// MRB_TT_ENV = 20
// MRB_TT_DATA = 21
// MRB_TT_FIBER = 22
// MRB_TT_ISTRUCT = 23
// MRB_TT_BREAK = 24
// MRB_TT_COMPLEX = 25
// MRB_TT_RATIONAL = 26

// Helper to get array length
mrb_int zig_mrb_ary_len(mrb_state *mrb, mrb_value arr) {
    (void)mrb; // Unused
    return RARRAY_LEN(arr);
}

// Helper to get array element
mrb_value zig_mrb_ary_ref(mrb_state *mrb, mrb_value arr, mrb_int idx) {
    (void)mrb; // Unused
    return mrb_ary_entry(arr, idx);
}

// Helper to get integer from mrb_value
// Note: mrb_fixnum() is a macro that depends on boxing type
mrb_int zig_mrb_fixnum(mrb_state *mrb, mrb_value val) {
    (void)mrb; // Unused
    // Use mrb_integer() for word boxing (handles the bit shift properly)
    return mrb_integer(val);
}

// Helper to get float from mrb_value
// Note: mrb_float() is a macro that depends on boxing type
double zig_mrb_float(mrb_state *mrb, mrb_value val) {
    (void)mrb; // Unused
    return mrb_float(val);
}

// Helper to create integer mrb_value
// Note: mrb_int_value() is a macro that depends on boxing type
mrb_value zig_mrb_int_value(mrb_state *mrb, mrb_int i) {
    return mrb_int_value(mrb, i);
}

// Helper to create float mrb_value
mrb_value zig_mrb_float_value(mrb_state *mrb, double f) {
    return mrb_float_value(mrb, f);
}

// Helper to create true mrb_value
mrb_value zig_mrb_true_value(void) {
    return mrb_true_value();
}

// Helper to create false mrb_value
mrb_value zig_mrb_false_value(void) {
    return mrb_false_value();
}

// Helper to check if there's an exception
int zig_mrb_has_exception(mrb_state *mrb) {
    return mrb->exc != NULL ? 1 : 0;
}

// Helper to get exception object
mrb_value zig_mrb_get_exception(mrb_state *mrb) {
    if (mrb->exc) {
        return mrb_obj_value(mrb->exc);
    }
    return mrb_nil_value();
}

// Helper to convert object pointer to mrb_value
mrb_value zig_mrb_obj_value(void *obj) {
    return mrb_obj_value(obj);
}
