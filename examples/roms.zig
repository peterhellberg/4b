//! Embedded example ROM images for the 4d round-trip tests (docs/4DD.md).
//!
//! This file is rooted in `examples/` so `@embedFile` can reach the sibling
//! `.4b` images; `src/test/roundtrip.zig` imports it as a module.

pub const halt = @embedFile("halt.4b");
pub const halt_4c = @embedFile("halt-4c.4b");
pub const line = @embedFile("line.4b");
pub const line_4c = @embedFile("line-4c.4b");
pub const fill = @embedFile("fill.4b");
pub const fill_4c = @embedFile("fill-4c.4b");
pub const diag = @embedFile("diag.4b");
pub const diag_4a = @embedFile("diag-4a.4b");
pub const move = @embedFile("move-4a.4b");
pub const move_4a = @embedFile("move-4a.4b");
pub const dpad = @embedFile("dpad.4b");
pub const dpad_4a = @embedFile("dpad-4a.4b");
