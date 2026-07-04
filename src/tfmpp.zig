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

    if (activation_reason != .AllFramesReady) return null;

    const src = zapi.initZFrame(d.node, n);
    defer src.deinit();

    // Check if this frame is combed from TFM hints
    const src_props = zapi.vsapi.getFramePropertiesRO.?(src.frame);
    var err: vs.MapPropertyError = .Unset;
    const combed_val = zapi.vsapi.mapGetInt.?(src_props, common.PROP_COMBED, 0, &err);
    const is_combed = (err == .Success) and (combed_val != 0);

    if (!is_combed) {
        // Passthrough: copy source to destination
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

    // Deinterlace combed frame with cubic interpolation
    const dst = src.newVideoFrame();
    const bytes: u32 = @intCast(d.vi.format.bytesPerSample);
    const np = d.vi.format.numPlanes;

    var plane: u32 = 0;
    while (plane < np) : (plane += 1) {
        const src_rp = zapi.getReadPtr(src.frame, @intCast(plane));
        const src_stride = zapi.getStride(src.frame, @intCast(plane));
        const dst_wp = zapi.getWritePtr(dst.frame, @intCast(plane));
        const dst_stride = zapi.getStride(dst.frame, @intCast(plane));
        const w = zapi.getFrameWidth(dst.frame, @intCast(plane));
        const h = zapi.getFrameHeight(dst.frame, @intCast(plane));
        const row_bytes: usize = @intCast(@as(u32, @intCast(w)) * bytes);

        const stride_u: isize = @intCast(src_stride);
        _ = stride_u;
        const src_u8: [*]const u8 = @ptrCast(src_rp);
        const dst_u8: [*]u8 = @ptrCast(dst_wp);

        // Cubic deinterlace: for each field line, interpolate from 4 neighbors
        // Weights: [-1/8, 5/8, 5/8, -1/8] → simplified to [1, 4, 4, 1]/8 for integer math
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const dst_row: usize = @intCast(y * dst_stride);
            const y0 = if (y >= 3) y - 3 else if (y >= 1) y - 1 else y;
            const y1 = if (y >= 2) y - 2 else if (y >= 1) y - 1 else y;
            const y2 = if (y + 1 < h) y + 1 else y;
            const y3 = if (y + 2 < h) y + 2 else if (y + 1 < h) y + 1 else y;

            if (y & 1 == 0) {
                // Even line: keep original
                @memcpy(dst_u8[dst_row..][0..row_bytes], src_u8[dst_row..][0..row_bytes]);
            } else {
                // Odd line: interpolate from neighboring even lines
                const r0: usize = @intCast(y0 * src_stride);
                const r1: usize = @intCast(y1 * src_stride);
                const r2: usize = @intCast(y2 * src_stride);
                const r3: usize = @intCast(y3 * src_stride);

                if (bytes == 1) {
                    var x: u32 = 0;
                    while (x < w) : (x += 1) {
                        const v0: i32 = @intCast(src_u8[r0 + x]);
                        const v1: i32 = @intCast(src_u8[r1 + x]);
                        const v2: i32 = @intCast(src_u8[r2 + x]);
                        const v3: i32 = @intCast(src_u8[r3 + x]);
                        // Cubic: (-v0 + 5*v1 + 5*v2 - v3) / 8
                        const val: i32 = @divTrunc(-v0 + 5 * v1 + 5 * v2 - v3, 8);
                        dst_u8[dst_row + x] = @intCast(@max(0, @min(255, val)));
                    }
                } else {
                    const src_u16: [*]const u16 = @ptrCast(@alignCast(src_rp));
                    const dst_u16: [*]u16 = @ptrCast(@alignCast(dst_wp));
                    const max_val: i32 = (@as(i32, 1) << @intCast(d.vi.format.bitsPerSample)) - 1;
                    const w_u16: u32 = @intCast(w);
                    const r0_16: usize = @intCast(y0 * @divExact(src_stride, 2));
                    const r1_16: usize = @intCast(y1 * @divExact(src_stride, 2));
                    const r2_16: usize = @intCast(y2 * @divExact(src_stride, 2));
                    const r3_16: usize = @intCast(y3 * @divExact(src_stride, 2));
                    const dst_row_16: usize = @intCast(y * @divExact(dst_stride, 2));

                    var x: u32 = 0;
                    while (x < w_u16) : (x += 1) {
                        const v0: i32 = @intCast(src_u16[r0_16 + x]);
                        const v1: i32 = @intCast(src_u16[r1_16 + x]);
                        const v2: i32 = @intCast(src_u16[r2_16 + x]);
                        const v3: i32 = @intCast(src_u16[r3_16 + x]);
                        const val: i32 = @divTrunc(-v0 + 5 * v1 + 5 * v2 - v3, 8);
                        dst_u16[dst_row_16 + x] = @intCast(@max(0, @min(max_val, val)));
                    }
                }
            }
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
