//! TFM — field matching filter for IVTC.
//!
//! Matches fields from a telecined source to reconstruct progressive frames.
//! Every CPU cycle matters. Memory is a resource. Together we serve users.

const std = @import("std");
const vapoursynth = @import("vapoursynth");
const vs = vapoursynth.vapoursynth4;
const vsh = vapoursynth.vshelper;
const ZAPI = vapoursynth.ZAPI;

const common = @import("common.zig");
const tfm_core = @import("tfm_core.zig");

// ---------------------------------------------------------------------------
// Per-instance filter data
// ---------------------------------------------------------------------------

pub const TFM = struct {
    alloc: std.mem.Allocator,
    node: ?*vs.Node,
    vi: *const vs.VideoInfo,

    // --- Filter parameters ---
    order: i32, // -1 = auto
    field: i32, // -1 = auto
    mode: i32,
    pp: i32,
    slow: i32,
    m_chroma: bool,
    c_num: i32,
    cthresh: i32,
    mi: i32,
    chroma: bool,
    blockx: i32,
    blocky: i32,
    y0: i32,
    y1: i32,
    d2v: []const u8,
    ovr_default: i32,
    flags: i32,
    scthresh: f64,
    micout: i32,
    micmatching: i32,
    trim_in: []const u8,
    use_hints: bool,
    metric: i32,
    batch: bool,
    ubsco: bool,
    mmsco: bool,
    opt: i32,
    display: bool,
    debug: bool,

    // Stored original values (may be modified per-frame by overrides)
    order_orig: i32,
    field_orig: i32,
    mode_orig: i32,
    pp_orig: i32,
    mi_orig: i32,

    // --- Derived state ---
    nfrms: i32,
    xhalf: i32,
    yhalf: i32,
    xshift: i32,
    yshift: i32,
    vid_count: i32,
    field_ovr: i32,
    mode7_field: i32,

    // --- File paths (copies needed, ZAPI getData pointers are transient) ---
    ovr_path: []const u8,
    input_path: []const u8,
    output_path: []const u8,
    output_c_path: []const u8,

    // --- Scratch buffers ---
    /// Aligned diff buffer for field comparison
    tbuffer: ?[]u8,
    tpitch_y: isize,
    tpitch_uv: isize,

    /// Comb detection scratch (i32 array, aligned)
    c_array: ?[]i32,

    /// 8-bit map/cmask frames for comb detection
    map: ?*vs.Frame,
    cmask: ?*vs.Frame,
    map_vi: vs.VideoInfo, // 8-bit version of vi
    cmask_vi: vs.VideoInfo,
    c_array_size: usize,

    // --- Override / output arrays ---
    ovr_array: std.ArrayListUnmanaged(u8),
    out_array: std.ArrayListUnmanaged(u8),
    d2vfilm_array: std.ArrayListUnmanaged(u8),
    trim_array: std.ArrayListUnmanaged(bool),

    /// MIC output arrays
    mout_array: std.ArrayListUnmanaged(i32),
    mout_array_e: std.ArrayListUnmanaged(i32),

    /// Last match tracking (serial filter — mutable per-frame)
    last_match: MatchTrack,
    sc_last: SceneChangeTrack,

    /// CRC for output file
    output_crc: u32,
    diffmax_sc: u64,

    // --- Override / output arrays ---
};

pub const MatchTrack = struct {
    frame: i32,
    match: i32,
    field: i32,
    combed: i32,
};

pub const SceneChangeTrack = struct {
    frame: i32,
    diff: u64,
    sc: bool,
};

// ---------------------------------------------------------------------------
// GetFrame callback
// ---------------------------------------------------------------------------

pub fn tfmGetFrame(
    n: c_int,
    activation_reason: vs.ActivationReason,
    instance_data: ?*anyopaque,
    frame_data: ?*?*anyopaque,
    frame_ctx: ?*vs.FrameContext,
    core: ?*vs.Core,
    vsapi: ?*const vs.API,
) callconv(.c) ?*const vs.Frame {
    _ = frame_data;
    const d: *TFM = @ptrCast(@alignCast(instance_data));
    const zapi = ZAPI.init(vsapi, core, frame_ctx);

    const nn = common.clampFrame(n, d.nfrms);

    if (activation_reason == .Initial) {
        zapi.requestFrameFilter(common.clampFrame(nn - 1, d.nfrms), d.node);
        zapi.requestFrameFilter(nn, d.node);
        zapi.requestFrameFilter(common.clampFrame(nn + 1, d.nfrms), d.node);
        return null;
    }

    if (activation_reason != .AllFramesReady) return null;

    // Get the three frames for field matching
    const prv_frame = zapi.initZFrame(d.node, common.clampFrame(nn - 1, d.nfrms));
    const src_frame = zapi.initZFrame(d.node, nn);
    const nxt_frame = zapi.initZFrame(d.node, common.clampFrame(nn + 1, d.nfrms));
    defer prv_frame.deinit();
    defer src_frame.deinit();
    defer nxt_frame.deinit();

    // Determine field order
    var order: i32 = d.order_orig;
    var field: i32 = d.field_orig;
    if (order == -1) {
        const src_props = zapi.vsapi.getFramePropertiesRO.?(src_frame.frame);
        var err: vs.MapPropertyError = .Unset;
        const field_based = zapi.vsapi.mapGetInt.?(src_props, "_FieldBased", 0, &err);
        if (err == .Success) {
            // _FieldBased: 0=Progressive, 1=BFF, 2=TFF; treat progressive as TFF
            order = if (field_based == 1) @as(i32, 0) else @as(i32, 1);
        } else {
            order = 1;
        }
    }
    if (field == -1) field = order;

    // Allocate destination frame
    const dst = src_frame.newVideoFrame();

    const bytes_per_sample: u32 = @intCast(d.vi.format.bytesPerSample);
    const np = d.vi.format.numPlanes;

    // --- Field matching logic ---
    // For mode=1: try match=c (1), fall back to p(0)/n(2) if combed
    const frstT: i32 = if ((field ^ order) != 0) 2 else 0;
    const scndT: i32 = if (field ^ order != 0) 3 else 2;
    _ = frstT;
    _ = scndT; // TODO: use in full field comparison

    const fmatch: i32 = 1; // default: match c
    var combed: i32 = 0;
    var blockN: [5]i32 = [_]i32{common.SENTINEL} ** 5;
    var mics: [5]i32 = [_]i32{common.SENTINEL} ** 5;
    const d2vfilm = false;
    

    // Try field matching: weave with match=c, check combing
    // If combed, try frstT (p or n depending on field/order)
    {
        var plane_i: u32 = 0;
        while (plane_i < np) : (plane_i += 1) {
            const dst_rwp = zapi.getWritePtr(dst.frame, @intCast(plane_i));
            const src_rop = zapi.getReadPtr(src_frame.frame, @intCast(plane_i));
            const prv_rop = zapi.getReadPtr(prv_frame.frame, @intCast(plane_i));
            const nxt_rop = zapi.getReadPtr(nxt_frame.frame, @intCast(plane_i));
            const dst_str = zapi.getStride(dst.frame, @intCast(plane_i));
            const w = zapi.getFrameWidth(dst.frame, @intCast(plane_i));
            const h = zapi.getFrameHeight(dst.frame, @intCast(plane_i));

            tfm_core.weaveFrame(u8, dst_rwp, src_rop, prv_rop, nxt_rop,
                dst_str, @intCast(w), @intCast(h), fmatch, field, bytes_per_sample);
        }
    }

    // Comb detection on the woven frame
    if (d.pp > 0 or d.mode > 0) {
        combed = 0;
        if (d.cmask) |cmf| {
            // Analyze comb mask on the dst frame
            {
                var plane_i: u32 = 0;
                while (plane_i < np and (plane_i < 1 or d.chroma)) : (plane_i += 1) {
                    const src_rop = zapi.getReadPtr(dst.frame, @intCast(plane_i));
                    const cmk_rwp = zapi.getWritePtr(cmf, @intCast(plane_i));
                    const src_pitch = zapi.getStride(dst.frame, @intCast(plane_i));
                    const cmk_pitch = zapi.getStride(cmf, @intCast(plane_i));
                    const w = zapi.getFrameWidth(dst.frame, @intCast(plane_i));
                    const h = zapi.getFrameHeight(dst.frame, @intCast(plane_i));
                    const cthresh_scaled = d.cthresh;

                    if (bytes_per_sample == 1) {
                        tfm_core.analyzeCombMask(u8, src_rop, cmk_rwp, @intCast(w), @intCast(h), src_pitch, cmk_pitch, cthresh_scaled);
                    }
                }
            }

            // Apply y0/y1 exclusion band
            if (d.y0 != 0 or d.y1 != 0) {
                var plane_i: u32 = 0;
                while (plane_i < np) : (plane_i += 1) {
                    var y0_plane: u32 = @intCast(d.y0);
                    var y1_plane: u32 = @intCast(d.y1);
                    if (plane_i > 0 and d.vi.format.subSamplingH > 0) {
                        y0_plane >>= @intCast(d.vi.format.subSamplingH);
                        y1_plane >>= @intCast(d.vi.format.subSamplingH);
                    }
                    const h = zapi.getFrameHeight(cmf, @intCast(plane_i));
                    if (@as(i32, @intCast(y1_plane)) > h) y1_plane = @intCast(h);
                    const cmk_pitch = zapi.getStride(cmf, @intCast(plane_i));
                    const cmkp = zapi.getWritePtr(cmf, @intCast(plane_i));
                    const row_len: usize = @intCast(cmk_pitch);
                    var yr: u32 = y0_plane;
                    while (yr < y1_plane) : (yr += 1) {
                        @memset(cmkp[@as(usize, @intCast(yr)) * row_len ..][0..row_len], 0);
                    }
                }
            }

            // Count comb blocks
            if (d.c_array) |ca| {
                const cmkp = zapi.getWritePtr(cmf, 0);
                const cmk_pitch = zapi.getStride(cmf, 0);
                const w = zapi.getFrameWidth(cmf, 0);
                const h = zapi.getFrameHeight(cmf, 0);
                const result = tfm_core.countCombBlocks(cmkp, cmk_pitch, ca, @intCast(w), @intCast(h),
                    d.xhalf, d.yhalf, d.xshift, d.yshift, d.mi);
                mics[@intCast(fmatch)] = result.mic_value;
                blockN[@intCast(fmatch)] = result.block_n;
                if (result.combed) combed = 2;
            }
        }
    }

    // Write frame properties (hints for TDecimate)
    if (d.use_hints) {
        tfm_core.putFrameProperties(&zapi, dst.frame, fmatch, combed, d2vfilm, mics, field, d.pp);
    }

    // Update tracking state
    d.last_match = .{ .frame = nn, .match = fmatch, .field = field, .combed = combed };

    return dst.frame;
}

// ---------------------------------------------------------------------------
// Free callback
// ---------------------------------------------------------------------------

pub fn tfmFree(
    instance_data: ?*anyopaque,
    core: ?*vs.Core,
    vsapi: ?*const vs.API,
) callconv(.c) void {
    _ = core;
    const d: *TFM = @ptrCast(@alignCast(instance_data));

    vsapi.?.freeNode.?(d.node);

    // Free scratch buffer
    if (d.tbuffer) |buf| {
        d.alloc.free(buf);
    }

    // Free frame caches
    if (d.map) |f| vsapi.?.freeFrame.?(f);
    if (d.cmask) |f| vsapi.?.freeFrame.?(f);

    // Free comb detection scratch buffer
    if (d.c_array) |ca| d.alloc.free(ca);

    // Free arraylists
    d.ovr_array.deinit(d.alloc);
    d.out_array.deinit(d.alloc);
    d.d2vfilm_array.deinit(d.alloc);
    d.trim_array.deinit(d.alloc);
    d.mout_array.deinit(d.alloc);
    d.mout_array_e.deinit(d.alloc);

    // Free string copies
    if (d.ovr_path.len > 0) d.alloc.free(d.ovr_path);
    if (d.input_path.len > 0) d.alloc.free(d.input_path);
    if (d.output_path.len > 0) d.alloc.free(d.output_path);
    if (d.output_c_path.len > 0) d.alloc.free(d.output_c_path);

    d.alloc.destroy(d);
}

// ---------------------------------------------------------------------------
// Create (invoked when the filter is instantiated)
// ---------------------------------------------------------------------------

pub fn tfmCreate(
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
        map_out.setError("TFM: required argument 'clip' not provided");
        return;
    };
    const node = clip.@"0";
    const vi = clip.@"1";

    // Validate input format (8-bit planar YUV only for now)
    if (!vsh.isConstantVideoFormat(vi)) {
        map_out.setError("TFM: only constant format input supported");
        zapi.freeNode(node);
        return;
    }

    if (vi.format.colorFamily != .YUV and vi.format.colorFamily != .Gray) {
        map_out.setError("TFM: only YUV and Gray formats supported");
        zapi.freeNode(node);
        return;
    }

    if (vi.format.sampleType != .Integer) {
        map_out.setError("TFM: only integer formats supported");
        zapi.freeNode(node);
        return;
    }

    const bits = vi.format.bitsPerSample;
    if (bits < 8 or bits > 16) {
        map_out.setError("TFM: only 8-16 bit formats supported");
        zapi.freeNode(node);
        return;
    }
    if (!(bits == 8 or bits == 10 or bits == 12 or bits == 14 or bits == 16)) {
        map_out.setError("TFM: only standard bit depths (8/10/12/14/16) supported");
        zapi.freeNode(node);
        return;
    }
    if (vi.width & 1 != 0 or vi.height & 1 != 0) {
        map_out.setError("TFM: width and height must be divisible by 2");
        zapi.freeNode(node);
        return;
    }
    if (vi.height < 6 or vi.width < 64) {
        map_out.setError("TFM: frame dimensions too small");
        zapi.freeNode(node);
        return;
    }

    // Parse parameters with defaults matching the original C++ code
    const alloc = std.heap.c_allocator;

    const order = map_in.getValue(i32, "order") orelse -1;
    const field = map_in.getValue(i32, "field") orelse -1;
    const mode = map_in.getValue(i32, "mode") orelse 1;
    const pp = map_in.getValue(i32, "PP") orelse 6;
    const slow = map_in.getValue(i32, "slow") orelse 1;
    const m_chroma = map_in.getBool("mChroma") orelse true;
    const c_num = map_in.getValue(i32, "cNum") orelse 15;
    const cthresh = map_in.getValue(i32, "cthresh") orelse 9;
    const mi = map_in.getValue(i32, "MI") orelse 80;
    const chroma = map_in.getBool("chroma") orelse false;
    const blockx = map_in.getValue(i32, "blockx") orelse 16;
    const blocky = map_in.getValue(i32, "blocky") orelse 16;
    const y0 = map_in.getValue(i32, "y0") orelse 0;
    const y1 = map_in.getValue(i32, "y1") orelse 0;

    const d2v_raw = map_in.getData("d2v", 0) orelse "";
    const ovr_raw = map_in.getData("ovr", 0) orelse "";
    const input_raw = map_in.getData("input", 0) orelse "";
    const output_raw = map_in.getData("output", 0) orelse "";
    const outputC_raw = map_in.getData("outputC", 0) orelse "";
    const trimIn_raw = map_in.getData("trimIn", 0) orelse "";

    const ovr_default = map_in.getValue(i32, "ovrDefault") orelse 0;
    const flags = map_in.getValue(i32, "flags") orelse 4;
    const scthresh = map_in.getValue(f64, "scthresh") orelse 12.0;
    const micout = map_in.getValue(i32, "micout") orelse 0;
    const micmatching = map_in.getValue(i32, "micmatching") orelse 1;
    const display = map_in.getBool("display") orelse false;
    const debug = map_in.getBool("debug") orelse false;
    const use_hints = map_in.getBool("hint") orelse true;
    const metric = map_in.getValue(i32, "metric") orelse 0;
    const batch = map_in.getBool("batch") orelse false;
    const ubsco = map_in.getBool("ubsco") orelse true;
    const mmsco = map_in.getBool("mmsco") orelse true;
    const opt = map_in.getValue(i32, "opt") orelse 4;

    // Validate parameter ranges
    if (order != -1 and order != 0 and order != 1) {
        map_out.setError("TFM: order must be -1 (auto), 0 (BFF), or 1 (TFF)");
        zapi.freeNode(node);
        return;
    }
    if (field != -1 and field != 0 and field != 1) {
        map_out.setError("TFM: field must be -1 (auto), 0 (bottom), or 1 (top)");
        zapi.freeNode(node);
        return;
    }
    if (mode < 0 or mode > 7) {
        map_out.setError("TFM: mode must be 0-7");
        zapi.freeNode(node);
        return;
    }
    if (pp < 0 or pp > 7) {
        map_out.setError("TFM: PP must be 0-7");
        zapi.freeNode(node);
        return;
    }

    // Copy strings (ZAPI data pointers are transient)
    const ovr_path = if (ovr_raw.len > 0) alloc.dupe(u8, ovr_raw) catch {
        map_out.setError("TFM: allocation failed");
        zapi.freeNode(node);
        return;
    } else &[_]u8{};

    const input_path = if (input_raw.len > 0) alloc.dupe(u8, input_raw) catch {
        alloc.free(ovr_path);
        map_out.setError("TFM: allocation failed");
        zapi.freeNode(node);
        return;
    } else &[_]u8{};

    const output_path = if (output_raw.len > 0) alloc.dupe(u8, output_raw) catch {
        alloc.free(input_path);
        alloc.free(ovr_path);
        map_out.setError("TFM: allocation failed");
        zapi.freeNode(node);
        return;
    } else &[_]u8{};

    const output_c_path = if (outputC_raw.len > 0) alloc.dupe(u8, outputC_raw) catch {
        alloc.free(output_path);
        alloc.free(input_path);
        alloc.free(ovr_path);
        map_out.setError("TFM: allocation failed");
        zapi.freeNode(node);
        return;
    } else &[_]u8{};

    // Derived values
    const nfrms: i32 = @intCast(vi.numFrames);
    const xhalf: i32 = @divTrunc(blockx, 2);
    const yhalf: i32 = @divTrunc(blocky, 2);
    const xshift: i32 = @as(i32, @intCast(@ctz(@as(u32, @intCast(blockx)))));
    const yshift: i32 = @as(i32, @intCast(@ctz(@as(u32, @intCast(blocky)))));

    // Allocate instance data
    const data: *TFM = alloc.create(TFM) catch {
        alloc.free(output_c_path);
        alloc.free(output_path);
        alloc.free(input_path);
        alloc.free(ovr_path);
        map_out.setError("TFM: allocation failed");
        zapi.freeNode(node);
        return;
    };

    // Allocate scratch buffers for comb detection
    var c_array: ?[]i32 = null;
    var cmask_frame: ?*vs.Frame = null;
    var c_array_size: usize = 0;

    if (mode == 1 or mode == 2 or mode == 3 or mode == 5 or mode == 6 or mode == 7 or
        pp > 0 or micout > 0 or micmatching > 0)
    {
        const xblocks: i32 = @as(i32, @intCast(((@as(usize, @intCast(vi.width)) + @as(usize, @intCast(xhalf))) >> @as(u5, @intCast(xshift))))) + 1;
        const yblocks: i32 = @as(i32, @intCast(((@as(usize, @intCast(vi.height)) + @as(usize, @intCast(yhalf))) >> @as(u5, @intCast(yshift))))) + 1;
        c_array_size = @as(usize, @intCast((xblocks * yblocks) << 2));
        c_array = alloc.alloc(i32, c_array_size) catch {
            alloc.destroy(data);
            alloc.free(output_c_path);
            alloc.free(output_path);
            alloc.free(input_path);
            alloc.free(ovr_path);
            map_out.setError("TFM: allocation failed (cArray)");
            zapi.freeNode(node);
            return;
        };

        // Create 8-bit cmask frame for comb detection
        cmask_frame = zapi.newVideoFrame(&vi.format, vi.width, vi.height, null);
        if (cmask_frame == null) {
            alloc.free(c_array.?);
            alloc.destroy(data);
            alloc.free(output_c_path);
            alloc.free(output_path);
            alloc.free(input_path);
            alloc.free(ovr_path);
            map_out.setError("TFM: allocation failed (cmask)");
            zapi.freeNode(node);
            return;
        }
    }

    // Allocate 8-bit map frame for field comparison (3x height for three diff layers)
    var map_frame: ?*vs.Frame = null;
    {
        const map_height: i32 = @intCast(vi.height * 3);
        map_frame = zapi.newVideoFrame(&vi.format, vi.width, map_height, null);
        if (map_frame == null) {
            if (c_array) |ca| alloc.free(ca);
            if (cmask_frame) |cf| zapi.freeFrame(cf);
            alloc.destroy(data);
            alloc.free(output_c_path);
            alloc.free(output_path);
            alloc.free(input_path);
            alloc.free(ovr_path);
            map_out.setError("TFM: allocation failed (map)");
            zapi.freeNode(node);
            return;
        }
    }

    // Compute scene-change threshold (matches C++ constructor)
    const mod16_width: u64 = @intCast((@as(usize, @intCast(vi.width)) >> 4) << 4);
    const h_u64: u64 = @intCast(vi.height);
    const diffmax_sc: u64 = @intFromFloat(@round(@as(f64, @floatFromInt(mod16_width * h_u64 * (235 - 16))) * scthresh * 0.5 / 100.0));

    data.* = .{
        .alloc = alloc,
        .node = node,
        .vi = vi,
        .order = order,
        .field = field,
        .mode = mode,
        .pp = pp,
        .slow = slow,
        .m_chroma = m_chroma,
        .c_num = c_num,
        .cthresh = cthresh,
        .mi = mi,
        .chroma = chroma,
        .blockx = blockx,
        .blocky = blocky,
        .y0 = y0,
        .y1 = y1,
        .d2v = d2v_raw,
        .ovr_default = ovr_default,
        .flags = flags,
        .scthresh = scthresh,
        .micout = micout,
        .micmatching = micmatching,
        .trim_in = trimIn_raw,
        .use_hints = use_hints,
        .metric = metric,
        .batch = batch,
        .ubsco = ubsco,
        .mmsco = mmsco,
        .opt = opt,
        .display = display,
        .debug = debug,
        .order_orig = order,
        .field_orig = field,
        .mode_orig = mode,
        .pp_orig = pp,
        .mi_orig = mi,
        .nfrms = nfrms,
        .xhalf = xhalf,
        .yhalf = yhalf,
        .xshift = xshift,
        .yshift = yshift,
        .vid_count = 0,
        .field_ovr = 0,
        .mode7_field = 0,
        .ovr_path = ovr_path,
        .input_path = input_path,
        .output_path = output_path,
        .output_c_path = output_c_path,
        .tbuffer = null,
        .tpitch_y = 0,
        .tpitch_uv = 0,
        .ovr_array = .{ .items = &.{}, .capacity = 0 },
        .out_array = .{ .items = &.{}, .capacity = 0 },
        .d2vfilm_array = .{ .items = &.{}, .capacity = 0 },
        .trim_array = .{ .items = &.{}, .capacity = 0 },
        .mout_array = .{ .items = &.{}, .capacity = 0 },
        .mout_array_e = .{ .items = &.{}, .capacity = 0 },
        .last_match = .{ .frame = -20, .match = -20, .field = -20, .combed = -20 },
        .sc_last = .{ .frame = -20, .diff = 0, .sc = false },
        .output_crc = 0,
        .diffmax_sc = diffmax_sc,
        .map = map_frame,
        .cmask = cmask_frame,
        .map_vi = vi.*,
        .cmask_vi = vi.*,
        .c_array = c_array,
        .c_array_size = c_array_size,
    };

    // TFM uses serial filter mode — shared scratch buffers and mutable
    // tracking state (lastMatch, scLast) are not thread-safe
    const deps = [_]vs.FilterDependency{
        .{ .source = node, .requestPattern = .StrictSpatial },
    };

    // TODO: support display mode (std.FrameEval + text.Text)
    // TODO: support PP > 1 (chain TFMPP)
    // TODO: support clip2 for post-processing
    // TODO: support mode=7 linear access

    zapi.createVideoFilter(
        out,
        "TFM",
        vi,
        tfmGetFrame,
        tfmFree,
        .FrameState,
        &deps,
        data,
    );
}
