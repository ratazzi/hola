/// ANSI escape codes for terminal formatting
pub const ANSI = struct {
    pub const RESET = "\x1b[0m";
    pub const BOLD = "\x1b[1m";
    pub const DIM = "\x1b[2m";
    pub const RED = "\x1b[31m";
    pub const GREEN = "\x1b[32m";
    pub const YELLOW = "\x1b[33m";
    pub const BLUE = "\x1b[34m";
    pub const MAGENTA = "\x1b[35m";
    pub const CYAN = "\x1b[36m";
    pub const WHITE = "\x1b[37m";

    // Cursor control
    pub const CURSOR_UP = "\x1b[A";
    pub const CURSOR_DOWN = "\x1b[B";
    pub const CURSOR_RIGHT = "\x1b[C";
    pub const CURSOR_LEFT = "\x1b[D";
    pub const CURSOR_HOME = "\x1b[H";
    pub const CLEAR_LINE = "\x1b[K";
    pub const CLEAR_LINE_FROM_CURSOR = "\x1b[0K";
    pub const SAVE_CURSOR = "\x1b[s";
    pub const RESTORE_CURSOR = "\x1b[u";

    // Screen control
    pub const CLEAR_SCREEN = "\x1b[2J";
    pub const CLEAR_SCREEN_AND_HOME = "\x1b[2J\x1b[H";
};
