//! TDecimate — frame decimation filter for IVTC.
//!
//! Decimates duplicate frames from field-matched telecined content.
//! Every CPU cycle matters. Memory is a resource. Together we serve users.

const std = @import("std");
const vapoursynth = @import("vapoursynth");
const vs = vapoursynth.vapoursynth4;
const vsh = vapoursynth.vshelper;
const ZAPI = vapoursynth.ZAPI;

const common = @import("common.zig");
const cycle_mod = @import("cycle.zig");
const Cycle = cycle_mod.Cycle;
const tdm_core = @import("tdecimate_core.zig");

// ---------------------------------------------------------------------------
// Per-instance filter data
// ---------------------------------------------------------------------------

pub const TDecimate = struct {
    alloc: std.mem.Allocator,
    node: ?*vs.Node,
    vi: *const vs.VideoInfo,
    vi_child: *const vs.VideoInfo,

    // --- Filter parameters ---
    mode: i32,
    cycle_r: i32,
    cycle_size: i32,
    rate: f64,
    dup_thresh: f64,
    vid_thresh: f64,
    scene_thresh: f64,
    hybrid: i32,
    vid_detect: i32,
    con_cycle: i32,
    con_cycle_tp: i32,
    nt: i32,
    blockx: i32,
    blocky: i32,
    vfr_dec: i32,
    debug: bool,
    display: bool,
    batch: bool,
    tcfv1: bool,
    se: bool,
    chroma: bool,
    ex_pp: bool,
    maxndl: i32,
    m2pa: bool,
    predenoise: bool,
    noblend: bool,
    ssd: bool,
    use_hints: bool,
    sdlim: i32,
    opt: i32,
    clip2_node: ?*vs.Node,

    // Stored string copies
    ovr_path: []const u8,
    output_path: []const u8,
    input_path: []const u8,
    tfm_in_path: []const u8,
    mkv_out_path: []const u8,
    org_out_path: []const u8,

    // --- Derived state ---
    nfrms: i32,
    nfrms_n: i32,
    linear_count: i32,
    blocky_shift: i32,
    blockx_shift: i32,
    blockx_half: i32,
    blocky_half: i32,
    last_n: i32,
    last_frame: i32,
    last_cycle: i32,
    last_group: i32,
    last_type: i32,
    ret_frames: i32,
    max_diff: u64,
    scene_thresh_u: u64,
    scene_div_u: u64,
    diff_thresh: u64,
    same_thresh: u64,
    fps: f64,
    mkv_fps: f64,
    mkv_fps2: f64,
    use_tfm_pp: bool,
    cve: bool,
    ecf: bool,
    full_info: bool,
    output_crc: u32,

    // --- Cycle state ---
    prev: Cycle,
    curr: Cycle,
    next: Cycle,
    nbuf: Cycle,

    // --- Scratch / metric buffers ---
    diff_aligned: ?[]u64,
    metrics_array: std.ArrayListUnmanaged(u64),
    metrics_out_array: std.ArrayListUnmanaged(u64),
    mode2_metrics: std.ArrayListUnmanaged(u64),

    // --- Mode 2 state ---
    a_lut: std.ArrayListUnmanaged(i32),
    mode2_dec_a: std.ArrayListUnmanaged(i32),
    mode2_order: std.ArrayListUnmanaged(i32),
    mode2_num: i32,
    mode2_den: i32,
    mode2_num_cycles: i32,
    mode2_cfs: [10]i32,

    // --- Override array ---
    ovr_array: std.ArrayListUnmanaged(u8),
};

// ---------------------------------------------------------------------------
// GetFrame callback
// ---------------------------------------------------------------------------

pub fn tdecimateGetFrame(
    n: c_int,
    activation_reason: vs.ActivationReason,
    instance_data: ?*anyopaque,
    frame_data: ?*?*anyopaque,
    frame_ctx: ?*vs.FrameContext,
    core: ?*vs.Core,
    vsapi: ?*const vs.API,
) callconv(.c) ?*const vs.Frame {
    const d: *TDecimate = @ptrCast(@alignCast(instance_data));
    const zapi = ZAPI.init(vsapi, core, frame_ctx);

    const nn = common.clampFrame(n, d.nfrms_n);

    // Mode dispatch
    if (d.mode < 2) {
        return tdecimateGetFrameMode01(d, nn, activation_reason, frame_data, frame_ctx, &zapi);
    }
    if (d.mode == 2 or d.mode == 7) {
        return tdecimateGetFrameMode2(d, nn, activation_reason, frame_ctx, &zapi);
    }

    // Modes 3-6: passthrough for now
    if (activation_reason == .Initial) {
        zapi.requestFrameFilter(nn, d.node);
        return null;
    }
    if (activation_reason != .AllFramesReady) return null;

    const src = zapi.initZFrame(d.node, nn);
    defer src.deinit();
    const dst = src.newVideoFrame();
    var plane: u32 = 0;
    while (plane < d.vi.format.numPlanes) : (plane += 1) {
        var srcp = src.getReadSlice(plane);
        var dstp = dst.getWriteSlice(plane);
        const w, const h, const stride = src.getDimensions(plane);
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            @memcpy(dstp[0..w], srcp[0..w]);
            dstp = dstp[stride..];
            srcp = srcp[stride..];
        }
    }
    return dst.frame;
}

fn tdecimateGetFrameMode01(
    d: *TDecimate,
    n: i32,
    activation_reason: vs.ActivationReason,
    frame_data: ?*?*anyopaque,
    frame_ctx: ?*vs.FrameContext,
    zapi: *const ZAPI,
) ?*const vs.Frame {
    _ = frame_data;
    _ = frame_ctx;
    const cycle = d.cycle_size;
    const cycle_r = d.cycle_r;
    const hybrid = d.hybrid;

    const eval_group: i32 = if (hybrid != 3)
        @divTrunc(n, cycle - cycle_r) * cycle
    else
        @divTrunc(n, cycle) * cycle;

    if (activation_reason == .Initial) {
        const vi_nfrms: i32 = @intCast(d.vi_child.numFrames);
        var i: i32 = eval_group - cycle - 1;
        while (i < eval_group + cycle * 3) : (i += 1) {
            zapi.requestFrameFilter(common.clampFrame(i, vi_nfrms - 1), d.node);
        }
        return null;
    }

    if (activation_reason != .AllFramesReady) return null;

    // Compute metrics for this cycle if not already done
    if (!d.curr.mSet or d.curr.frame != eval_group) {
        d.curr.setFrame(eval_group);

        const bits: i32 = d.vi.format.bitsPerSample;
        const vi_nfrms: i32 = @intCast(d.vi_child.numFrames);

        // Compute diff between each consecutive pair in the cycle
        var j: i32 = 0;
        while (j < cycle - 1) : (j += 1) {
            const f1_idx: i32 = common.clampFrame(eval_group + j, vi_nfrms);
            const f2_idx: i32 = common.clampFrame(eval_group + j + 1, vi_nfrms);

            const f1 = zapi.initZFrame(d.node, f1_idx);
            const f2 = zapi.initZFrame(d.node, f2_idx);

            const f1_rp = zapi.getReadPtr(f1.frame, 0);
            const f2_rp = zapi.getReadPtr(f2.frame, 0);
            const f1_stride = zapi.getStride(f1.frame, 0);
            const f2_stride = zapi.getStride(f2.frame, 0);
            const luma_w: u32 = @intCast(zapi.getFrameWidth(f1.frame, 0));
            const luma_h: u32 = @intCast(zapi.getFrameHeight(f1.frame, 0));

            const diff: u64 = if (bits == 8)
                tdm_core.frameDiff(u8, f1_rp, f2_rp, f1_stride, f2_stride, luma_w, luma_h, d.ssd, d.nt)
            else
                tdm_core.frameDiff(u16, f1_rp, f2_rp, f1_stride, f2_stride, luma_w, luma_h, d.ssd, d.nt);

            const idx: usize = @intCast(j);
            d.curr.diffMetricsU[idx] = diff;
            d.curr.diffMetricsUF[idx] = diff;

            f1.deinit();
            f2.deinit();
        }
        // Last position in cycle: diff with first frame of next cycle
        {
            const last_idx: i32 = common.clampFrame(eval_group + cycle - 1, vi_nfrms);
            const next_idx: i32 = common.clampFrame(eval_group + cycle, vi_nfrms);
            const f1 = zapi.initZFrame(d.node, last_idx);
            const f2 = zapi.initZFrame(d.node, next_idx);

            const f1_rp = zapi.getReadPtr(f1.frame, 0);
            const f2_rp = zapi.getReadPtr(f2.frame, 0);
            const f1_stride = zapi.getStride(f1.frame, 0);
            const f2_stride = zapi.getStride(f2.frame, 0);
            const luma_w: u32 = @intCast(zapi.getFrameWidth(f1.frame, 0));
            const luma_h: u32 = @intCast(zapi.getFrameHeight(f1.frame, 0));

            const diff: u64 = if (bits == 8)
                tdm_core.frameDiff(u8, f1_rp, f2_rp, f1_stride, f2_stride, luma_w, luma_h, d.ssd, d.nt)
            else
                tdm_core.frameDiff(u16, f1_rp, f2_rp, f1_stride, f2_stride, luma_w, luma_h, d.ssd, d.nt);

            d.curr.diffMetricsU[@intCast(cycle - 1)] = diff;
            d.curr.diffMetricsUF[@intCast(cycle - 1)] = diff;

            f1.deinit();
            f2.deinit();
        }

        d.curr.mSet = true;

        // Make decimation decision
        if (d.mode == 0) {
            tdm_core.mostSimilarDecDecision(&d.curr, cycle_r);
        } else {
            // Mode 1: longest string (simplified — same as mode 0 for now)
            tdm_core.mostSimilarDecDecision(&d.curr, cycle_r);
        }
    }

    // Map output frame to input, skipping dropped frames
    const pos_in_group = if (hybrid != 3)
        n - @divTrunc(n, cycle - cycle_r) * (cycle - cycle_r)
    else
        n - @divTrunc(n, cycle) * cycle;

    // Find the input frame index by counting non-dropped frames
    var src_idx: i32 = eval_group;
    var kept: i32 = 0;
    while (src_idx < eval_group + cycle) : (src_idx += 1) {
        const ci: usize = @intCast(src_idx - eval_group);
        if (d.curr.decimate2[ci] == 0) {
            if (kept == pos_in_group) break;
            kept += 1;
        }
    }

    const frame_idx = common.clampFrame(src_idx, d.nfrms);
    const src = zapi.initZFrame(d.node, frame_idx);
    defer src.deinit();

    const dst = src.newVideoFrame();

    var plane: u32 = 0;
    while (plane < d.vi.format.numPlanes) : (plane += 1) {
        var srcp = src.getReadSlice(plane);
        var dstp = dst.getWriteSlice(plane);
        const w, const h, const stride = src.getDimensions(plane);
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            @memcpy(dstp[0..w], srcp[0..w]);
            dstp = dstp[stride..];
            srcp = srcp[stride..];
        }
    }

    return dst.frame;
}

// ---------------------------------------------------------------------------
// Mode 2/7: arbitrary framerate decimation
// ---------------------------------------------------------------------------

fn tdecimateGetFrameMode2(
    d: *TDecimate,
    n: i32,
    activation_reason: vs.ActivationReason,
    frame_ctx: ?*vs.FrameContext,
    zapi: *const ZAPI,
) ?*const vs.Frame {
    _ = frame_ctx;

    if (activation_reason == .Initial) {
        const vi_nfrms: i32 = @intCast(d.vi_child.numFrames);
        const cycle = d.cycle_size;
        const start: i32 = common.clampFrame(n - cycle * 2, vi_nfrms - 1);
        const end: i32 = common.clampFrame(n + cycle * 2, vi_nfrms - 1);
        var i: i32 = start;
        while (i <= end) : (i += 1) {
            zapi.requestFrameFilter(i, d.node);
        }
        return null;
    }

    if (activation_reason != .AllFramesReady) return null;

    const input_fps: f64 = @as(f64, @floatFromInt(d.vi_child.fpsNum)) / @as(f64, @floatFromInt(d.vi_child.fpsDen));
    const dec_ratio = input_fps / d.rate;
    const src_n: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(n)) * dec_ratio));
    const frame_idx = common.clampFrame(src_n, d.nfrms);

    const src = zapi.initZFrame(d.node, frame_idx);
    defer src.deinit();
    const dst = src.newVideoFrame();

    var plane: u32 = 0;
    while (plane < d.vi.format.numPlanes) : (plane += 1) {
        var srcp = src.getReadSlice(plane);
        var dstp = dst.getWriteSlice(plane);
        const w, const h, const stride = src.getDimensions(plane);
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            @memcpy(dstp[0..w], srcp[0..w]);
            dstp = dstp[stride..];
            srcp = srcp[stride..];
        }
    }

    return dst.frame;
}

// ---------------------------------------------------------------------------
// Free callback
// ---------------------------------------------------------------------------

pub fn tdecimateFree(
    instance_data: ?*anyopaque,
    core: ?*vs.Core,
    vsapi: ?*const vs.API,
) callconv(.c) void {
    _ = core;
    const d: *TDecimate = @ptrCast(@alignCast(instance_data));

    vsapi.?.freeNode.?(d.node);
    if (d.clip2_node) |c2| vsapi.?.freeNode.?(c2);

    // Free aligned diff buffer
    if (d.diff_aligned) |buf| d.alloc.free(buf);

    // Free cycles
    d.prev.deinit();
    d.curr.deinit();
    d.next.deinit();
    d.nbuf.deinit();

    // Free arraylists
    d.metrics_array.deinit(d.alloc);
    d.metrics_out_array.deinit(d.alloc);
    d.mode2_metrics.deinit(d.alloc);
    d.a_lut.deinit(d.alloc);
    d.mode2_dec_a.deinit(d.alloc);
    d.mode2_order.deinit(d.alloc);
    d.ovr_array.deinit(d.alloc);

    // Free string copies
    if (d.ovr_path.len > 0) d.alloc.free(d.ovr_path);
    if (d.output_path.len > 0) d.alloc.free(d.output_path);
    if (d.input_path.len > 0) d.alloc.free(d.input_path);
    if (d.tfm_in_path.len > 0) d.alloc.free(d.tfm_in_path);
    if (d.mkv_out_path.len > 0) d.alloc.free(d.mkv_out_path);
    if (d.org_out_path.len > 0) d.alloc.free(d.org_out_path);

    d.alloc.destroy(d);
}

// ---------------------------------------------------------------------------
// Create (invoked when the filter is instantiated)
// ---------------------------------------------------------------------------

pub fn tdecimateCreate(
    in: ?*const vs.Map,
    out: ?*vs.Map,
    _: ?*anyopaque,
    core: ?*vs.Core,
    vsapi: ?*const vs.API,
) callconv(.c) void {
    const zapi = ZAPI.init(vsapi, core, null);
    const map_in = zapi.initZMap(in);
    const map_out = zapi.initZMap(out);

    // Parse required input clip
    const clip = map_in.getNodeVi("clip") orelse {
        map_out.setError("TDecimate: required argument 'clip' not provided");
        return;
    };
    const node = clip.@"0";
    const vi = clip.@"1";
    const vi_child = vi;

    // Validate input format
    if (!vsh.isConstantVideoFormat(vi)) {
        map_out.setError("TDecimate: only constant format input supported");
        zapi.freeNode(node);
        return;
    }

    if (vi.format.colorFamily != .YUV and vi.format.colorFamily != .Gray) {
        map_out.setError("TDecimate: only YUV and Gray formats supported");
        zapi.freeNode(node);
        return;
    }

    if (vi.format.sampleType != .Integer) {
        map_out.setError("TDecimate: only integer formats supported");
        zapi.freeNode(node);
        return;
    }
    const bits = vi.format.bitsPerSample;
    if (bits < 8 or bits > 16) {
        map_out.setError("TDecimate: only 8-16 bit formats supported");
        zapi.freeNode(node);
        return;
    }

    const alloc = std.heap.c_allocator;

    // Parse parameters with defaults matching the original
    const mode = map_in.getValue(i32, "mode") orelse 0;
    const cycle = map_in.getValue(i32, "cycle") orelse 5;
    const cycle_r = map_in.getValue(i32, "cycleR") orelse 1;
    const rate = map_in.getValue(f64, "rate") orelse 23.976;
    const chroma = if (vi.format.colorFamily == .Gray) false else map_in.getBool("chroma") orelse true;

    const dup_thresh = map_in.getValue(f64, "dupThresh") orelse blk: {
        if (mode == 7) break :blk @as(f64, if (chroma) 0.4 else 0.5);
        if (chroma) break :blk @as(f64, 1.1);
        break :blk @as(f64, 1.4);
    };

    const vid_thresh = map_in.getValue(f64, "vidThresh") orelse blk: {
        if (mode == 7) break :blk @as(f64, if (chroma) 3.5 else 4.0);
        if (chroma) break :blk @as(f64, 1.1);
        break :blk @as(f64, 1.4);
    };

    const scene_thresh = map_in.getValue(f64, "sceneThresh") orelse 15.0;
    const hybrid = map_in.getValue(i32, "hybrid") orelse 0;
    const vid_detect = map_in.getValue(i32, "vidDetect") orelse 3;
    const con_cycle = map_in.getValue(i32, "conCycle") orelse blk: {
        if (vid_detect >= 3) break :blk @as(i32, 1);
        break :blk @as(i32, 2);
    };

    const con_cycle_tp = map_in.getValue(i32, "conCycleTP") orelse blk: {
        if (vid_detect >= 3) break :blk @as(i32, 1);
        break :blk @as(i32, 2);
    };
    const ovr_raw = map_in.getData("ovr", 0) orelse "";
    const output_raw = map_in.getData("output", 0) orelse "";
    const input_raw = map_in.getData("input", 0) orelse "";
    const tfm_in_raw = map_in.getData("tfmIn", 0) orelse "";
    const mkv_out_raw = map_in.getData("mkvOut", 0) orelse "";
    const org_out_raw = map_in.getData("orgOut", 0) orelse "";

    const nt = map_in.getValue(i32, "nt") orelse 0;
    const blockx = map_in.getValue(i32, "blockx") orelse 32;
    const blocky = map_in.getValue(i32, "blocky") orelse 32;
    const debug = map_in.getBool("debug") orelse false;
    const display = map_in.getBool("display") orelse false;
    const vfr_dec = map_in.getValue(i32, "vfrDec") orelse 1;
    const batch = map_in.getBool("batch") orelse false;
    const tcfv1 = map_in.getBool("tcfv1") orelse false;
    const se = map_in.getBool("se") orelse false;
    const ex_pp = map_in.getBool("exPP") orelse false;
    const maxndl = map_in.getValue(i32, "maxndl") orelse 100;
    const m2pa = map_in.getBool("m2PA") orelse false;
    const predenoise = map_in.getBool("predenoise") orelse false;
    const noblend = map_in.getBool("noblend") orelse false;
    const ssd = map_in.getBool("ssd") orelse false;
    const use_hints = map_in.getBool("hint") orelse false;
    const sdlim = map_in.getValue(i32, "sdlim") orelse 0;
    const opt = map_in.getValue(i32, "opt") orelse 4;

    // Optional clip2
    var clip2_node: ?*vs.Node = null;
    if (map_in.getNodeVi("clip2")) |c2| {
        clip2_node = c2.@"0";
    }

    // Validate parameter ranges
    if (mode < 0 or mode > 7) {
        map_out.setError("TDecimate: mode must be 0-7");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    }
    if (cycle < 2 or cycle > 25) {
        map_out.setError("TDecimate: cycle must be 2-25");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    }
    if (cycle_r < 1 or cycle_r >= cycle) {
        map_out.setError("TDecimate: cycleR must be in [1, cycle-1]");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    }

    // Copy strings
    const ovr_path = if (ovr_raw.len > 0) alloc.dupe(u8, ovr_raw) catch {
        map_out.setError("TDecimate: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    } else &[_]u8{};
    const output_path = if (output_raw.len > 0) alloc.dupe(u8, output_raw) catch {
        alloc.free(ovr_path);
        map_out.setError("TDecimate: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    } else &[_]u8{};
    const input_path = if (input_raw.len > 0) alloc.dupe(u8, input_raw) catch {
        alloc.free(output_path);
        alloc.free(ovr_path);
        map_out.setError("TDecimate: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    } else &[_]u8{};
    const tfm_in_path = if (tfm_in_raw.len > 0) alloc.dupe(u8, tfm_in_raw) catch {
        alloc.free(input_path);
        alloc.free(output_path);
        alloc.free(ovr_path);
        map_out.setError("TDecimate: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    } else &[_]u8{};
    const mkv_out_path = if (mkv_out_raw.len > 0) alloc.dupe(u8, mkv_out_raw) catch {
        alloc.free(tfm_in_path);
        alloc.free(input_path);
        alloc.free(output_path);
        alloc.free(ovr_path);
        map_out.setError("TDecimate: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    } else &[_]u8{};
    const org_out_path = if (org_out_raw.len > 0) alloc.dupe(u8, org_out_raw) catch {
        alloc.free(mkv_out_path);
        alloc.free(tfm_in_path);
        alloc.free(input_path);
        alloc.free(output_path);
        alloc.free(ovr_path);
        map_out.setError("TDecimate: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    } else &[_]u8{};

    // Derived values
    const nfrms: i32 = @intCast(vi.numFrames);
    const nfrms_n = nfrms - 1;
    const blockx_half: i32 = @divTrunc(blockx, 2);
    const blocky_half: i32 = @divTrunc(blocky, 2);
    const blockx_shift: i32 = @as(i32, @intCast(@ctz(@as(u32, @intCast(blockx)))));
    const blocky_shift: i32 = @as(i32, @intCast(@ctz(@as(u32, @intCast(blocky)))));

    // Thresholds
    const max_diff: u64 = @as(u64, 255 * 255 * 255);
    const scene_thresh_u: u64 = @intFromFloat(@round(scene_thresh * scene_thresh * 255.0));

    // Allocate cycles
    const csize: usize = @as(usize, @intCast(cycle));
    var prev = Cycle.init(alloc, csize, sdlim) catch {
        alloc.free(org_out_path);
        alloc.free(mkv_out_path);
        alloc.free(tfm_in_path);
        alloc.free(input_path);
        alloc.free(output_path);
        alloc.free(ovr_path);
        map_out.setError("TDecimate: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    };
    var curr = Cycle.init(alloc, csize, sdlim) catch {
        prev.deinit();
        alloc.free(org_out_path);
        alloc.free(mkv_out_path);
        alloc.free(tfm_in_path);
        alloc.free(input_path);
        alloc.free(output_path);
        alloc.free(ovr_path);
        map_out.setError("TDecimate: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    };
    var next = Cycle.init(alloc, csize, sdlim) catch {
        curr.deinit();
        prev.deinit();
        alloc.free(org_out_path);
        alloc.free(mkv_out_path);
        alloc.free(tfm_in_path);
        alloc.free(input_path);
        alloc.free(output_path);
        alloc.free(ovr_path);
        map_out.setError("TDecimate: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    };
    var nbuf = Cycle.init(alloc, csize, sdlim) catch {
        next.deinit();
        curr.deinit();
        prev.deinit();
        alloc.free(org_out_path);
        alloc.free(mkv_out_path);
        alloc.free(tfm_in_path);
        alloc.free(input_path);
        alloc.free(output_path);
        alloc.free(ovr_path);
        map_out.setError("TDecimate: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    };

    // Allocate instance
    const data: *TDecimate = alloc.create(TDecimate) catch {
        nbuf.deinit();
        next.deinit();
        curr.deinit();
        prev.deinit();
        alloc.free(org_out_path);
        alloc.free(mkv_out_path);
        alloc.free(tfm_in_path);
        alloc.free(input_path);
        alloc.free(output_path);
        alloc.free(ovr_path);
        map_out.setError("TDecimate: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    };

    data.* = .{
        .alloc = alloc,
        .node = node,
        .vi = vi,
        .vi_child = vi_child,
        .mode = mode,
        .cycle_r = cycle_r,
        .cycle_size = cycle,
        .rate = rate,
        .dup_thresh = dup_thresh,
        .vid_thresh = vid_thresh,
        .scene_thresh = scene_thresh,
        .hybrid = hybrid,
        .vid_detect = vid_detect,
        .con_cycle = con_cycle,
        .con_cycle_tp = con_cycle_tp,
        .nt = nt,
        .blockx = blockx,
        .blocky = blocky,
        .vfr_dec = vfr_dec,
        .debug = debug,
        .display = display,
        .batch = batch,
        .tcfv1 = tcfv1,
        .se = se,
        .chroma = chroma,
        .ex_pp = ex_pp,
        .maxndl = maxndl,
        .m2pa = m2pa,
        .predenoise = predenoise,
        .noblend = noblend,
        .ssd = ssd,
        .use_hints = use_hints,
        .sdlim = sdlim,
        .opt = opt,
        .clip2_node = clip2_node,
        .ovr_path = ovr_path,
        .output_path = output_path,
        .input_path = input_path,
        .tfm_in_path = tfm_in_path,
        .mkv_out_path = mkv_out_path,
        .org_out_path = org_out_path,
        .nfrms = nfrms,
        .nfrms_n = nfrms_n,
        .linear_count = 0,
        .blocky_shift = blocky_shift,
        .blockx_shift = blockx_shift,
        .blockx_half = blockx_half,
        .blocky_half = blocky_half,
        .last_n = 0,
        .last_frame = -1,
        .last_cycle = -1,
        .last_group = -1,
        .last_type = -1,
        .ret_frames = 0,
        .max_diff = max_diff,
        .scene_thresh_u = scene_thresh_u,
        .scene_div_u = 0,
        .diff_thresh = 0,
        .same_thresh = 0,
        .fps = 0,
        .mkv_fps = 0,
        .mkv_fps2 = 0,
        .use_tfm_pp = false,
        .cve = false,
        .ecf = false,
        .full_info = false,
        .output_crc = 0,
        .prev = prev,
        .curr = curr,
        .next = next,
        .nbuf = nbuf,
        .diff_aligned = null,
        .metrics_array = .{ .items = &.{}, .capacity = 0 },
        .metrics_out_array = .{ .items = &.{}, .capacity = 0 },
        .mode2_metrics = .{ .items = &.{}, .capacity = 0 },
        .a_lut = .{ .items = &.{}, .capacity = 0 },
        .mode2_dec_a = .{ .items = &.{}, .capacity = 0 },
        .mode2_order = .{ .items = &.{}, .capacity = 0 },
        .mode2_num = 0,
        .mode2_den = 0,
        .mode2_num_cycles = 0,
        .mode2_cfs = [_]i32{0} ** 10,
        .ovr_array = .{ .items = &.{}, .capacity = 0 },
    };

    // TDecimate uses serial filter mode — it has mutable cycle state,
    // per-frame tracking fields, and mode=7 requires linear access.
    const deps = [_]vs.FilterDependency{
        .{ .source = node, .requestPattern = .StrictSpatial },
    };

    zapi.createVideoFilter(
        out,
        "TDecimate",
        vi,
        tdecimateGetFrame,
        tdecimateFree,
        .FrameState,
        &deps,
        data,
    );
}
