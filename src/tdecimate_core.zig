//! TDecimate core algorithms — metric calculation, cycle-based decimation.
//!
//! Comptime-generic over pixel type. Every CPU cycle matters.

const vs = @import("vapoursynth").vapoursynth4;
const std = @import("std");
const cycle_mod = @import("cycle.zig");
const Cycle = cycle_mod.Cycle;

// ---------------------------------------------------------------------------
// frameDiff — compute SAD/SSD between two frames (luma plane only)
// ---------------------------------------------------------------------------
// Returns total diff. For SAD: sum of absolute differences.
// For SSD: sum of squared differences.

pub fn frameDiff(
    comptime T: type,
    prev: [*]const u8,
    curr: [*]const u8,
    prv_stride: isize,
    cur_stride: isize,
    width: u32,
    height: u32,
    ssd: bool,
    nt: i32,
) u64 {
    const prv_typed: [*]const T = @ptrCast(@alignCast(prev));
    const cur_typed: [*]const T = @ptrCast(@alignCast(curr));
    const pixel_pitch_prev: usize = @intCast(@divExact(prv_stride, @as(isize, @sizeOf(T))));
    const pixel_pitch_curr: usize = @intCast(@divExact(cur_stride, @as(isize, @sizeOf(T))));
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);

    var total: u64 = 0;
    if (ssd) {
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const prv_row = y * pixel_pitch_prev;
            const cur_row = y * pixel_pitch_curr;
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const a: i64 = @intCast(prv_typed[prv_row + x]);
                const b: i64 = @intCast(cur_typed[cur_row + x]);
                const d: i64 = if (a > b) a - b else b - a;
                total += @intCast(d * d);
            }
        }
    } else {
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const prv_row = y * pixel_pitch_prev;
            const cur_row = y * pixel_pitch_curr;
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const a: i64 = @intCast(prv_typed[prv_row + x]);
                const b: i64 = @intCast(cur_typed[cur_row + x]);
                const d: i64 = if (a > b) a - b else b - a;
                total += @intCast(d);
                if (d > nt) total += @intCast(d);
            }
        }
    }
    return total;
}

// ---------------------------------------------------------------------------
// calcBlockDiff — block-based SAD/SSD for detailed metrics (like C++ CalcMetrics)
// ---------------------------------------------------------------------------
// Returns the max block diff. Fills `diff` array with per-block values.

pub fn calcBlockDiff(
    comptime T: type,
    prev: [*]const u8,
    curr: [*]const u8,
    prv_stride: isize,
    cur_stride: isize,
    width: u32,
    height: u32,
    blockx: i32,
    blocky: i32,
    xhalf: i32,
    yhalf: i32,
    xshift: i32,
    yshift: i32,
    ssd: bool,
    nt: i32,
    diff: []i32,
    metric_f: *u64,
) u64 {
    _ = blockx;
    _ = blocky;
    const pixel_pitch_prv: usize = @intCast(@divExact(prv_stride, @as(isize, @sizeOf(T))));
    const pixel_pitch_cur: usize = @intCast(@divExact(cur_stride, @as(isize, @sizeOf(T))));
    const prv_typed: [*]const T = @ptrCast(@alignCast(prev));
    const cur_typed: [*]const T = @ptrCast(@alignCast(curr));

    const w: usize = @intCast(width);
    const h: usize = @intCast(height);

    const xblocks: i32 = @as(i32, @intCast((w + @as(usize, @intCast(xhalf))) >> @as(u5, @intCast(xshift)))) + 1;
    const yblocks: i32 = @as(i32, @intCast((h + @as(usize, @intCast(yhalf))) >> @as(u5, @intCast(yshift)))) + 1;
    const arraysize: usize = @intCast((xblocks * yblocks) << 2);

    @memset(diff[0..arraysize], 0);

    const xhalf_usz: usize = @intCast(xhalf);
    const yhalf_usz: usize = @intCast(yhalf);

    var y: usize = 0;
    while (y + yhalf_usz <= h) : (y += yhalf_usz) {
        const temp1: usize = @intCast((@as(i32, @intCast(y >> @as(u5, @intCast(yshift)))) * (xblocks << 2)));
        var x: usize = 0;
        while (x + xhalf_usz <= w) : (x += xhalf_usz) {
            var block_diff: i64 = 0;
            var u: usize = 0;
            while (u < yhalf_usz) : (u += 1) {
                const prv_row = (y + u) * pixel_pitch_prv;
                const cur_row = (y + u) * pixel_pitch_cur;
                var v: usize = 0;
                while (v < xhalf_usz) : (v += 1) {
                    const a: i64 = @intCast(prv_typed[prv_row + x + v]);
                    const b: i64 = @intCast(cur_typed[cur_row + x + v]);
                    const d: i64 = if (a > b) a - b else b - a;
                    if (ssd) {
                        block_diff += d * d;
                    } else {
                        if (d > nt) block_diff += d;
                        block_diff += d;
                    }
                }
            }
            const box: usize = @intCast((@as(i32, @intCast(x >> @as(u5, @intCast(xshift)))) << 2));
            const blk: i32 = @intCast(block_diff);
            diff[temp1 + box + 0] += blk;
            diff[temp1 + box + 1] += blk;
            diff[temp1 + box + 2] += blk;
            diff[temp1 + box + 3] += blk;
        }

        // Remaining columns
        const width_a: usize = (w >> @as(u5, @intCast(xshift - 1))) << @as(u5, @intCast(xshift - 1));
        x = width_a;
        while (x < w) : (x += 1) {
            var block_diff: i64 = 0;
            var uu: usize = 0;
            while (uu < yhalf_usz) : (uu += 1) {
                const prv_row = (y + uu) * pixel_pitch_prv;
                const cur_row = (y + uu) * pixel_pitch_cur;
                const a: i64 = @intCast(prv_typed[prv_row + x]);
                const b: i64 = @intCast(cur_typed[cur_row + x]);
                const d: i64 = if (a > b) a - b else b - a;
                if (ssd) {
                    block_diff += d * d;
                } else {
                    if (d > nt) block_diff += d;
                    block_diff += d;
                }
            }
            const box: usize = @intCast((@as(i32, @intCast(x >> @as(u5, @intCast(xshift)))) << 2));
            diff[temp1 + box + 0] += @intCast(block_diff);
        }
    }

    var max_diff: u64 = 0;
    var frame_sum: u64 = 0;
    for (diff[0..arraysize]) |d| {
        const du: u64 = @intCast(d);
        if (du > max_diff) max_diff = du;
        frame_sum += du;
    }

    metric_f.* = frame_sum;
    return max_diff;
}

// ---------------------------------------------------------------------------
// mostSimilarDecDecision — mode 0: drop lowest-metric frames
// ---------------------------------------------------------------------------

pub fn mostSimilarDecDecision(c: *Cycle, cycle_r: i32) void {
    c.setLowest(false);
    c.setDecimateLow(cycle_r);
    for (0..c.size) |i| {
        c.decimate2[i] = if (c.decimate[i] != -20) @as(i32, 1) else @as(i32, 0);
    }
}

// ---------------------------------------------------------------------------
// longestStringDecDecision — mode 1: find longest string of duplicates
// ---------------------------------------------------------------------------

pub fn longestStringDecDecision(p: *Cycle, c: *Cycle, n: *Cycle, dup_thresh: f64, cycle_r: i32) void {
    _ = p;
    _ = n;
    _ = dup_thresh;

    // Simplified: same as mode 0 for now
    c.setLowest(false);
    c.setDecimateLow(cycle_r);
    for (0..c.size) |i| {
        c.decimate2[i] = if (c.decimate[i] != -20) @as(i32, 1) else @as(i32, 0);
    }
}
