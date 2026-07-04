//! TFMPP — post-processing filter for TFM combed frames.
//!
//! Applied after TFM when PP > 1. Deinterlaces combed frames.
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

pub const TFMPP = struct {
    alloc: std.mem.Allocator,
    node: ?*vs.Node,
    vi: *const vs.VideoInfo,

    pp: i32,
    mthresh: i32,
    display: bool,
    clip2_node: ?*vs.Node,
    use_hints: bool,
    opt: i32,

    ovr_path: []const u8,

    // --- Override array ---
    ovr_array: std.ArrayListUnmanaged(u8),
};

// ---------------------------------------------------------------------------
// GetFrame callback
// ---------------------------------------------------------------------------

pub fn tfmppGetFrame(
    n: c_int,
    activation_reason: vs.ActivationReason,
    instance_data: ?*anyopaque,
    frame_data: ?*?*anyopaque,
    frame_ctx: ?*vs.FrameContext,
    core: ?*vs.Core,
    vsapi: ?*const vs.API,
) callconv(.c) ?*const vs.Frame {
    _ = frame_data;
    const d: *TFMPP = @ptrCast(@alignCast(instance_data));
    const zapi = ZAPI.init(vsapi, core, frame_ctx);

    if (activation_reason == .Initial) {
        zapi.requestFrameFilter(n, d.node);
        if (d.clip2_node) |c2| {
            zapi.requestFrameFilter(n, c2);
        }
        return null;
    }

    if (activation_reason != .AllFramesReady) {
        return null;
    }

    // TODO: full post-processing logic
    // For now, skeleton passthrough
    const src = zapi.initZFrame(d.node, n);
    defer src.deinit();

    var dst = src.newVideoFrame();

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

pub fn tfmppFree(
    instance_data: ?*anyopaque,
    core: ?*vs.Core,
    vsapi: ?*const vs.API,
) callconv(.c) void {
    _ = core;
    const d: *TFMPP = @ptrCast(@alignCast(instance_data));

    vsapi.?.freeNode.?(d.node);
    if (d.clip2_node) |c2| vsapi.?.freeNode.?(c2);

    d.ovr_array.deinit(d.alloc);

    if (d.ovr_path.len > 0) d.alloc.free(d.ovr_path);

    d.alloc.destroy(d);
}

// ---------------------------------------------------------------------------
// Create
// ---------------------------------------------------------------------------

pub fn tfmppCreate(
    in: ?*const vs.Map,
    out: ?*vs.Map,
    _: ?*anyopaque,
    core: ?*vs.Core,
    vsapi: ?*const vs.API,
) callconv(.c) void {
    const zapi = ZAPI.init(vsapi, core, null);
    const map_in = zapi.initZMap(in);
    const map_out = zapi.initZMap(out);

    const clip = map_in.getNodeVi("clip") orelse {
        map_out.setError("TFMPP: required argument 'clip' not provided");
        return;
    };
    const node = clip.@"0";
    const vi = clip.@"1";

    if (!vsh.isConstantVideoFormat(vi)) {
        map_out.setError("TFMPP: only constant format input supported");
        zapi.freeNode(node);
        return;
    }

    if (vi.format.colorFamily != .YUV and vi.format.colorFamily != .Gray) {
        map_out.setError("TFMPP: only YUV and Gray formats supported");
        zapi.freeNode(node);
        return;
    }

    if (vi.format.sampleType != .Integer) {
        map_out.setError("TFMPP: only integer formats supported");
        zapi.freeNode(node);
        return;
    }
    const bits = vi.format.bitsPerSample;
    if (bits < 8 or bits > 16) {
        map_out.setError("TFMPP: only 8-16 bit formats supported");
        zapi.freeNode(node);
        return;
    }

    const alloc = std.heap.c_allocator;

    const pp = map_in.getValue(i32, "PP") orelse 6;
    const mthresh = map_in.getValue(i32, "mthresh") orelse 5;
    const display = map_in.getBool("display") orelse false;
    const use_hints = map_in.getBool("hint") orelse true;
    const opt = map_in.getValue(i32, "opt") orelse 4;

    const ovr_raw = map_in.getData("ovr", 0) orelse "";

    var clip2_node: ?*vs.Node = null;
    if (map_in.getNodeVi("clip2")) |c2| {
        clip2_node = c2.@"0";
    }

    if (pp < 2 or pp > 7) {
        map_out.setError("TFMPP: PP must be 2-7");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    }

    const ovr_path = if (ovr_raw.len > 0) alloc.dupe(u8, ovr_raw) catch {
        map_out.setError("TFMPP: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    } else &[_]u8{};

    const data: *TFMPP = alloc.create(TFMPP) catch {
        alloc.free(ovr_path);
        map_out.setError("TFMPP: allocation failed");
        zapi.freeNode(node);
        if (clip2_node) |c2| zapi.freeNode(c2);
        return;
    };

    data.* = .{
        .alloc = alloc,
        .node = node,
        .vi = vi,
        .pp = pp,
        .mthresh = mthresh,
        .display = display,
        .clip2_node = clip2_node,
        .use_hints = use_hints,
        .opt = opt,
        .ovr_path = ovr_path,
        .ovr_array = .{ .items = &.{}, .capacity = 0 },
    };

    const deps = [_]vs.FilterDependency{
        .{ .source = node, .requestPattern = .StrictSpatial },
    };

    zapi.createVideoFilter(
        out,
        "TFMPP",
        vi,
        tfmppGetFrame,
        tfmppFree,
        .ParallelRequests,
        &deps,
        data,
    );
}
