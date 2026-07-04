//! Shared constants, types, and utilities for TIVTC Zig port.
//!
//! Every CPU cycle matters. Memory is a resource. Together we serve users.

const vs = @import("vapoursynth").vapoursynth4;

// ---------------------------------------------------------------------------
// Match type constants — same values as original internal.h
// ---------------------------------------------------------------------------

pub const MatchP: i32 = 0; // p — previous frame match
pub const MatchC: i32 = 1; // c — current frame match
pub const MatchN: i32 = 2; // n — next frame match
pub const MatchB: i32 = 3; // b — blend (deinterlaced c, bottom field)
pub const MatchU: i32 = 4; // u — unmatched
pub const MatchDB: i32 = 5; // l — deinterlaced c, bottom field
pub const MatchDT: i32 = 6; // h — deinterlaced c, top field

pub fn matchToChar(m: i32) u8 {
    return switch (m) {
        0 => 'p',
        1 => 'c',
        2 => 'n',
        3 => 'b',
        4 => 'u',
        5 => 'l',
        6 => 'h',
        else => 'x',
    };
}

// ---------------------------------------------------------------------------
// Frame flags (stored in frame properties integer)
// ---------------------------------------------------------------------------

pub const TOP_FIELD: i32 = 0x00000008;
pub const COMBED: i32 = 0x00000010;
pub const D2VFILM: i32 = 0x00000020;

// ---------------------------------------------------------------------------
// TDecimate constants
// ---------------------------------------------------------------------------

pub const DROP_FRAME: i32 = 0x00000001;
pub const KEEP_FRAME: i32 = 0x00000002;
pub const FILM: i32 = 0x00000004;
pub const VIDEO: i32 = 0x00000008;
pub const ISMATCH: i32 = 0x00000070;
pub const ISD2VFILM: i32 = 0x00000080;

pub const D2VARRAY_DUP_MASK: i32 = 0x03;
pub const D2VARRAY_MATCH_MASK: i32 = 0x3C;

// Ovr file constants
pub const FILE_COMBED: i32 = 0x00000030;
pub const FILE_NOTCOMBED: i32 = 0x00000020;
pub const FILE_ENTRY: i32 = 0x00000080;
pub const FILE_D2V: i32 = 0x00000008;

// ---------------------------------------------------------------------------
// Frame property names
// ---------------------------------------------------------------------------

pub const PROP_TFM_DISPLAY = "TFMDisplay";
pub const PROP_TFM_MATCH = "TFMMatch";
pub const PROP_TFM_MICS = "TFMMics";
pub const PROP_COMBED = "_Combed";
pub const PROP_TFM_D2VFILM = "TFMD2VFilm";
pub const PROP_TFM_FIELD = "TFMField";
pub const PROP_TFM_PP = "TFMPP";

pub const PROP_TDECIMATE_DISPLAY = "TDecimateDisplay";
pub const PROP_TDECIMATE_CYCLE_START = "TDecimateCycleStart";
pub const PROP_TDECIMATE_CYCLE_MAX_BLOCK_DIFF = "TDecimateCycleMaxBlockDiff";
pub const PROP_TDECIMATE_ORIGINAL_FRAME = "TDecimateOriginalFrame";
pub const PROP_DURATION_NUM = "_DurationNum";
pub const PROP_DURATION_DEN = "_DurationDen";

// ---------------------------------------------------------------------------
// Plugin version
// ---------------------------------------------------------------------------

pub const PLUGIN_ID = "com.planesight.tivtc";
pub const PLUGIN_NAMESPACE = "tivtc";
pub const PLUGIN_NAME = "TIVTC";

// ---------------------------------------------------------------------------
// Sentinels (original uses -20 for "unset")
// ---------------------------------------------------------------------------

pub const SENTINEL: i32 = -20; // nothing set / not applicable

// ---------------------------------------------------------------------------
// Max path length for file I/O
// ---------------------------------------------------------------------------

pub const MAX_PATH: usize = 4096;

// ---------------------------------------------------------------------------
// Helper: clamp n to [0, max]
// ---------------------------------------------------------------------------

pub fn clampFrame(n: i32, max: i32) i32 {
    if (n < 0) return 0;
    if (n > max) return max;
    return n;
}

// ---------------------------------------------------------------------------
// Helper: get field parity from _FieldBased frame property
// ---------------------------------------------------------------------------

pub fn getFieldBased(props: ?*const vs.Map, vsapi: ?*const vs.API) ?i32 {
    var err: c_int = undefined;
    const fb = vsapi.?.mapGetInt.?(props, "_FieldBased", 0, &err);
    if (err != 0) return null;
    return @as(i32, @intCast(fb));
}
