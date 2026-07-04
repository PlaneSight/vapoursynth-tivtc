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

    // --- Cached frames ---
    map: ?*vs.Frame,
    cmask: ?*vs.Frame,
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

    if (activation_reason == .Initial) {
        const n0 = common.clampFrame(n - 1, d.nfrms);
        const n1 = common.clampFrame(n, d.nfrms);
        const n2 = common.clampFrame(n + 1, d.nfrms);
        zapi.requestFrameFilter(n0, d.node);
        zapi.requestFrameFilter(n1, d.node);
        zapi.requestFrameFilter(n2, d.node);
        return null;
    }

    if (activation_reason != .AllFramesReady) {
        return null;
    }

    // TODO: full field matching logic
    // For now, pass through as a skeleton
    const src = zapi.initZFrame(d.node, n);
    defer src.deinit();

    var dst = src.newVideoFrame();

    // Passthrough placeholder — copy source to destination
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

    // Write frame properties (TODO: putFrameProperties)
    _ = &d.vi; // suppress unused warning while skeleton is incomplete

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

    if (vi.format.bitsPerSample != 8) {
        map_out.setError("TFM: only 8-bit input supported currently");
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
        .diffmax_sc = 0,
        .map = null,
        .cmask = null,
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
