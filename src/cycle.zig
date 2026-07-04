//! Cycle — stores per-cycle info for TDecimate decimation logic.
//!
//! Ported from Cycle.h / Cycle.cpp. Every CPU cycle matters.

const std = @import("std");
const common = @import("common.zig");

/// Stores metrics and decimation decisions for a single cycle of frames.
/// All arrays are heap-allocated and sized to `size`.
///
/// Sentinels: -20 for unset ints, -1 for unset type.
///
/// Video types:
///   -1 = nothing (not set)
///    0 = film
///    1 = film by ovr
///    2 = video by matches
///    3 = video by metrics
///    4 = video by matches/metrics
///    5 = video by ovr
///
/// Blend codes:
///  -20 = not set
///    0 = no blending
///    1 = cvr — blend video cycle down
///    2 = cvr — video cycle w/ scenechange
///    3 = cvr/vfr — 2 dup cycle workaround
pub const Cycle = struct {
    alloc: std.mem.Allocator,

    /// Number of frames per cycle (e.g. 5 for 5:1 IVTC)
    size: usize,

    /// Scene detection limit (sdlim param)
    sdlim: i32,

    // --- Per-cycle state ---
    frame: i32, // first frame in cycle
    frameE: i32, // last frame in cycle (frame + size - 1)
    offE: i32, // end offset
    cycleS: i32, // 0 + start offset
    cycleE: i32, // size - offE
    frameSO: i32, // frame + cycleS
    frameEO: i32, // frame + cycleE

    /// Video or film and how it was detected
    vtype: i32,

    /// Normalized diff metrics (one per frame in cycle)
    diffMetricsN: []f64,
    /// Unnormalized diff metrics
    diffMetricsU: []u64,
    /// Frame metrics (for scenechange detection)
    diffMetricsUF: []u64,
    /// Temp storage for sorting
    tArray: []u64,
    /// Duplicate marking
    dupArray: []i32,
    /// Sorted list of metrics (indices into diffMetricsU)
    lowest: []i32,
    /// Positions of frames to drop
    decimate: []i32,
    /// Secondary decimation array (for longest string)
    decimate2: []i32,
    /// Frame matches (for 30p identification)
    match: []i32,
    /// D2V TRF flags indicate duplicate
    filmd2v: []i32,

    /// Flags
    dupsSet: bool,
    mSet: bool, // metrics set
    lowSet: bool, // list sorted
    decSet: bool, // decimate array filled in
    isfilmd2v: bool, // D2V indicates duplicate in cycle
    dupCount: i32,

    /// Blend mode: 0 = none, 1 = blending, 2 = mkv
    blend: i32,

    /// Secondary decision tracking for TDecimate
    dect: []i32,
    dect2: []i32,

    /// Initialize a cycle with given capacity
    pub fn init(alloc: std.mem.Allocator, s: usize, sdl: i32) !Cycle {
        const diffMetricsN = try alloc.alloc(f64, s);
        const diffMetricsU = try alloc.alloc(u64, s);
        const diffMetricsUF = try alloc.alloc(u64, s);
        const tArray = try alloc.alloc(u64, s);
        const dupArray = try alloc.alloc(i32, s);
        const lowest = try alloc.alloc(i32, s);
        const decimate = try alloc.alloc(i32, s);
        const decimate2 = try alloc.alloc(i32, s);
        const match = try alloc.alloc(i32, s);
        const filmd2v = try alloc.alloc(i32, s);
        const dect = try alloc.alloc(i32, s);
        const dect2 = try alloc.alloc(i32, s);

        return Cycle{
            .alloc = alloc,
            .size = s,
            .sdlim = sdl,
            .frame = 0,
            .frameE = 0,
            .offE = 0,
            .cycleS = 0,
            .cycleE = 0,
            .frameSO = 0,
            .frameEO = 0,
            .vtype = -1,
            .diffMetricsN = diffMetricsN,
            .diffMetricsU = diffMetricsU,
            .diffMetricsUF = diffMetricsUF,
            .tArray = tArray,
            .dupArray = dupArray,
            .lowest = lowest,
            .decimate = decimate,
            .decimate2 = decimate2,
            .match = match,
            .filmd2v = filmd2v,
            .dupsSet = false,
            .mSet = false,
            .lowSet = false,
            .decSet = false,
            .isfilmd2v = false,
            .dupCount = 0,
            .blend = 0,
            .dect = dect,
            .dect2 = dect2,
        };
    }

    /// Free all allocated arrays
    pub fn deinit(self: *Cycle) void {
        self.alloc.free(self.diffMetricsN);
        self.alloc.free(self.diffMetricsU);
        self.alloc.free(self.diffMetricsUF);
        self.alloc.free(self.tArray);
        self.alloc.free(self.dupArray);
        self.alloc.free(self.lowest);
        self.alloc.free(self.decimate);
        self.alloc.free(self.decimate2);
        self.alloc.free(self.match);
        self.alloc.free(self.filmd2v);
        self.alloc.free(self.dect);
        self.alloc.free(self.dect2);
    }

    /// Reset per-cycle state for a new cycle starting at `frameIn`
    pub fn setFrame(self: *Cycle, frameIn: i32) void {
        self.frame = frameIn;
        self.frameE = frameIn + @as(i32, @intCast(self.size)) - 1;
        self.offE = 0;
        self.cycleS = 0;
        self.cycleE = @as(i32, @intCast(self.size));
        self.frameSO = self.frame + self.cycleS;
        self.frameEO = self.frame + self.cycleE;
        self.vtype = -1;
        self.mSet = false;
        self.lowSet = false;
        self.decSet = false;
        self.dupsSet = false;
        self.isfilmd2v = false;
        self.blend = -20;
        self.dupCount = 0;

        // Clear arrays
        @memset(self.diffMetricsN, 0);
        @memset(self.diffMetricsU, 0);
        @memset(self.diffMetricsUF, 0);
        @memset(self.tArray, 0);
        @memset(self.dupArray, 0);
        @memset(self.lowest, 0);
        @memset(self.match, 0);
        @memset(self.filmd2v, 0);

        // Sentinels
        for (self.decimate) |*d| d.* = common.SENTINEL;
        for (self.decimate2) |*d| d.* = common.SENTINEL;
        for (self.dect) |*d| d.* = common.SENTINEL;
        for (self.dect2) |*d| d.* = common.SENTINEL;
    }

    /// Mark duplicates by threshold comparison on normalized metrics
    pub fn setDups(self: *Cycle, thresh: f64) void {
        if (self.dupCount >= @as(i32, @intCast(self.size)) - 1) return;

        for (0..self.size - 1) |i| {
            if (self.dupArray[i] != -20) continue;
            if (self.diffMetricsN[i + 1] < thresh) {
                self.dupArray[i] = i + 1;
                self.dupCount += 1;
            } else {
                self.dupArray[i] = -20;
            }
        }
        self.dupArray[self.size - 1] = -20;
        self.dupsSet = true;
    }

    /// Sort lowest (indices) by diffMetricsU values, ascending.
    /// Simple insertion sort — cycle sizes are small (≤ 25 frames).
    pub fn setLowest(self: *Cycle, excludeD: bool) void {
        if (self.lowSet) return;

        for (0..self.size) |i| {
            self.lowest[i] = @as(i32, @intCast(i));
        }

        // Insertion sort on small arrays
        for (1..self.size) |i| {
            const idx = self.lowest[i];
            const val = self.diffMetricsU[@as(usize, @intCast(idx))];
            var j: isize = @as(isize, @intCast(i)) - 1;
            while (j >= 0) {
                const prevIdx = self.lowest[@as(usize, @intCast(j))];
                const prevVal = self.diffMetricsU[@as(usize, @intCast(prevIdx))];
                if (val >= prevVal) break;
                self.lowest[@as(usize, @intCast(j + 1))] = prevIdx;
                j -= 1;
            }
            self.lowest[@as(usize, @intCast(j + 1))] = idx;
        }
        _ = excludeD; // TODO: exclude duplicates if requested
        self.lowSet = true;
    }

    /// Set decimate to drop the `num` lowest-metric frames
    pub fn setDecimateLow(self: *Cycle, num: i32) void {
        if (self.decSet) return;
        for (0..self.size) |i| {
            self.decimate[i] = common.SENTINEL;
        }

        var count: i32 = 0;
        for (0..self.size) |i| {
            if (count >= num) break;
            const idx: usize = @as(usize, @intCast(self.lowest[i]));
            if (self.lowest[i] >= 0 and self.diffMetricsU[idx] > 0) {
                self.decimate[idx] = @as(i32, @intCast(idx));
                count += 1;
            }
        }
        self.decSet = true;
    }

    /// Clear all per-cycle data (not the arrays themselves)
    pub fn clearAll(self: *Cycle) void {
        self.frame = 0;
        self.frameE = 0;
        self.offE = 0;
        self.cycleS = 0;
        self.cycleE = 0;
        self.frameSO = 0;
        self.frameEO = 0;
        self.vtype = -1;
        self.mSet = false;
        self.lowSet = false;
        self.decSet = false;
        self.dupsSet = false;
        self.isfilmd2v = false;
        self.blend = -20;
        self.dupCount = 0;

        @memset(self.diffMetricsN, 0);
        @memset(self.diffMetricsU, 0);
        @memset(self.diffMetricsUF, 0);
        @memset(self.dupArray, 0);
        @memset(self.lowest, 0);
        @memset(self.match, 0);
        @memset(self.filmd2v, 0);
        for (self.decimate) |*d| d.* = common.SENTINEL;
        for (self.decimate2) |*d| d.* = common.SENTINEL;
        for (self.dect) |*d| d.* = common.SENTINEL;
        for (self.dect2) |*d| d.* = common.SENTINEL;
    }

    /// Deep-copy data from another cycle of the same size
    pub fn copyFrom(self: *Cycle, other: *const Cycle) void {
        self.vtype = other.vtype;
        @memcpy(self.diffMetricsN, other.diffMetricsN);
        @memcpy(self.diffMetricsU, other.diffMetricsU);
        @memcpy(self.diffMetricsUF, other.diffMetricsUF);
        @memcpy(self.dupArray, other.dupArray);
        @memcpy(self.lowest, other.lowest);
        @memcpy(self.decimate, other.decimate);
        @memcpy(self.decimate2, other.decimate2);
        @memcpy(self.match, other.match);
        @memcpy(self.filmd2v, other.filmd2v);
        @memcpy(self.dect, other.dect);
        @memcpy(self.dect2, other.dect2);
        self.dupsSet = other.dupsSet;
        self.mSet = other.mSet;
        self.lowSet = other.lowSet;
        self.decSet = other.decSet;
        self.isfilmd2v = other.isfilmd2v;
        self.dupCount = other.dupCount;
        self.blend = other.blend;
    }
};
