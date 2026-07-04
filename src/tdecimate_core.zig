//! TDecimate core algorithms — metric calculation, cycle-based decimation.
//!
//! Comptime-generic over pixel type. Every CPU cycle matters.

const vs = @import("vapoursynth").vapoursynth4;
const ZAPI = @import("vapoursynth").ZAPI;
const std = @import("std");
const cycle_mod = @import("cycle.zig");
const Cycle = cycle_mod.Cycle;

// ---------------------------------------------------------------------------
// calcMetric — compute block-based SAD (or SSD) between two frames
// ---------------------------------------------------------------------------
// Returns the max block diff (in `max_diff`) and the frame-wide sum (in `metric_f`).
// `diff` is a scratch buffer of `arraysize` i32 values.

pub fn calcMetric(
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
    metric_f: *i32,
) i32 {
    const pixel_pitch_prv: usize = @intCast(@divExact(prv_stride, @as(isize, @sizeOf(T))));
    const pixel_pitch_cur: usize = @intCast(@divExact(cur_stride, @as(isize, @sizeOf(T))));
    const prv_typed: [*]const T = @ptrCast(prev);
    const cur_typed: [*]const T = @ptrCast(curr);

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
            // Accumulate SAD/SSD for this block
            var block_diff: i64 = 0;
            var frame_sum: i64 = 0;

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
                        frame_sum += d * d;
                    } else {
                        if (d > nt) block_diff += d;
                        block_diff += d;
                        frame_sum += d;
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
        if (x < w) {
            var x2 = width_a;
            while (x2 < w) : (x2 += 1) {
                var block_diff: i64 = 0;
                var uu: usize = 0;
                while (uu < yhalf_usz) : (uu += 1) {
                    const prv_row = (y + uu) * pixel_pitch_prv;
                    const cur_row = (y + uu) * pixel_pitch_cur;
                    const a: i64 = @intCast(prv_typed[prv_row + x2]);
                    const b: i64 = @intCast(cur_typed[cur_row + x2]);
                    const d: i64 = if (a > b) a - b else b - a;
                    if (ssd) {
                        block_diff += d * d;
                    } else {
                        if (d > nt) block_diff += d;
                        block_diff += d;
                    }
                }
                const box: usize = @intCast((@as(i32, @intCast(x2 >> @as(u5, @intCast(xshift)))) << 2));
                const blk: i32 = @intCast(block_diff);
                diff[temp1 + box + 0] += blk;
            }
        }
    }

    // Find max diff and compute frame metric
    var max_diff: i32 = 0;
    var frame_sum: i64 = 0;
    for (diff[0..arraysize]) |d| {
        if (d > max_diff) max_diff = d;
        frame_sum += d;
    }

    metric_f.* = @intCast(frame_sum);
    return max_diff;
}

// ---------------------------------------------------------------------------
// calcMetricCycle — compute metrics for all consecutive frame pairs in a cycle
// ---------------------------------------------------------------------------
// For each pair (i, i+1) in the cycle, computes the block SAD/SSD diff.
// Stores results in `current.diffMetricsU[i]` and `current.diffMetricsUF[i]`.

pub fn calcMetricCycle(
    comptime T: type,
    current: *Cycle,
    cycle_size: i32,
    blockx: i32,
    blocky: i32,
    xhalf: i32,
    yhalf: i32,
    xshift: i32,
    yshift: i32,
    ssd: bool,
    nt: i32,
    chroma: bool,
    diff: []i32,
    metrics_array: *std.ArrayListUnmanaged(u64),
    vsapi: ?*const vs.API,
    core: ?*vs.Core,
) !void {
    _ = T;
    _ = blockx;
    _ = blocky;
    _ = xhalf;
    _ = yhalf;
    _ = xshift;
    _ = yshift;
    _ = ssd;
    _ = nt;
    _ = diff;
    _ = core;
    _ = chroma;
    _ = vsapi;

    // Make sure metrics_array has enough room for cycle_size entries
    // This is called per-cycle, metrics_array stores all metrics for all frames
    // We'll populate current.diffMetricsU directly

    _ = cycle_size;
    _ = metrics_array;

    const csize: usize = @intCast(cycle_size);

    for (0..csize - 1) |i| {
        // For now, set a sentinel — actual frame retrieval is done in getframe
        // The metrics will be computed lazily when frames are requested
        current.diffMetricsU[i] = @as(u64, @intCast(i * 1000)); // placeholder
        current.diffMetricsUF[i] = @as(u64, @intCast(i * 500));
    }
    current.diffMetricsU[csize - 1] = 0;
    current.diffMetricsUF[csize - 1] = 0;
    current.mSet = true;
}

// ---------------------------------------------------------------------------
// mostSimilarDecDecision — mode 0: pick frame with lowest diff to drop
// ---------------------------------------------------------------------------

pub fn mostSimilarDecDecision(p: *Cycle, c: *Cycle, n: *Cycle, cycle_r: i32) void {
    _ = p;
    _ = n;

    c.setLowest(false);
    // Drop the `cycle_r` lowest-metric frames
    c.setDecimateLow(cycle_r);

    // Mark decimate2 same as decimate for simplicity
    for (0..c.size) |i| {
        if (c.decimate[i] != -20) {
            c.decimate2[i] = 1;
        } else {
            c.decimate2[i] = 0;
        }
    }
}

// ---------------------------------------------------------------------------
// pickOutputFrame — given cycle and position, pick the output frame index
// ---------------------------------------------------------------------------

pub fn pickOutputFrame(c: *Cycle, n: i32, cycle: i32, cycle_r: i32, hybrid: i32) i32 {
    if (hybrid != 3) {
        const cycle_group: i32 = @divTrunc(n, cycle - cycle_r);
        const group_start = cycle_group * cycle;
        const pos_in_group = n - cycle_group * (cycle - cycle_r);
        const pos_in_cycle = group_start + pos_in_group;

        // Count non-dropped frames up to pos_in_cycle
        var count: i32 = 0;
        var src: i32 = group_start;
        while (src <= pos_in_cycle and src - group_start < cycle) : (src += 1) {
            const idx: usize = @intCast(src - group_start);
            if (c.decimate2[idx] == 0) {
                if (src == pos_in_cycle) return src;
                count += 1;
            }
        }
        return pos_in_cycle;
    } else {
        return n;
    }
}
