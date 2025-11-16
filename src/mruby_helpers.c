#include <mruby.h>
#include <mruby/array.h>

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
