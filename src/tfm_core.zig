//! TFM core algorithms — field weaving, comb detection, diff maps.
//!
//! Portable, comptime-generic over pixel type. Every CPU cycle matters.

const vs = @import("vapoursynth").vapoursynth4;
const ZAPI = @import("vapoursynth").ZAPI;
const common = @import("common.zig");

// ---------------------------------------------------------------------------
// weaveFrame — weave two adjacent frames into a progressive frame
// ---------------------------------------------------------------------------
// Match codes (same as C++ createWeaveFrame):
//   0=p (even rows from src, odd from prv)
//   1=c (direct copy src)
//   2=n (even from src, odd from nxt)
//   3=b (odd from src, even from prv)
//   4=u (odd from src, even from nxt)
// `field`: 0=BFF, 1=TFF. Row offset pattern: src_off=(1-field)*stride, other_off=field*stride

pub fn weaveFrame(
    comptime T: type,
    dst_plane: [*]u8,
    src_plane: [*]const u8,
    prv_plane: [*]const u8,
    nxt_plane: [*]const u8,
    dst_stride: isize,
    width: u32,
    height: u32,
    match: i32,
    field: i32,
    bytes_per_sample: u32,
) void {
    _ = T;
    const row_bytes: usize = @intCast(width * bytes_per_sample);
    const stride_us: usize = @intCast(dst_stride);
    const src_off: usize = @intCast((1 - field) * dst_stride);
    const other_off: usize = @intCast(field * dst_stride);

    switch (match) {
        0 => { // p: even from src, odd from prv
            var y: u32 = 0;
            while (y < height) : (y += 2) {
                const dst_row = y * stride_us;
                @memcpy(dst_plane[dst_row + src_off ..][0..row_bytes], src_plane[dst_row + src_off ..][0..row_bytes]);
                @memcpy(dst_plane[dst_row + other_off ..][0..row_bytes], prv_plane[dst_row + other_off ..][0..row_bytes]);
            }
        },
        1 => { // c: direct copy
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                const dst_row = y * stride_us;
                @memcpy(dst_plane[dst_row..][0..row_bytes], src_plane[dst_row..][0..row_bytes]);
            }
        },
        2 => { // n: even from src, odd from nxt
            var y: u32 = 0;
            while (y < height) : (y += 2) {
                const dst_row = y * stride_us;
                @memcpy(dst_plane[dst_row + src_off ..][0..row_bytes], src_plane[dst_row + src_off ..][0..row_bytes]);
                @memcpy(dst_plane[dst_row + other_off ..][0..row_bytes], nxt_plane[dst_row + other_off ..][0..row_bytes]);
            }
        },
        3 => { // b: odd from src, even from prv
            var y: u32 = 0;
            while (y < height) : (y += 2) {
                const dst_row = y * stride_us;
                @memcpy(dst_plane[dst_row + other_off ..][0..row_bytes], src_plane[dst_row + other_off ..][0..row_bytes]);
                @memcpy(dst_plane[dst_row + src_off ..][0..row_bytes], prv_plane[dst_row + src_off ..][0..row_bytes]);
            }
        },
        4 => { // u: odd from src, even from nxt
            var y: u32 = 0;
            while (y < height) : (y += 2) {
                const dst_row = y * stride_us;
                @memcpy(dst_plane[dst_row + other_off ..][0..row_bytes], src_plane[dst_row + other_off ..][0..row_bytes]);
                @memcpy(dst_plane[dst_row + src_off ..][0..row_bytes], nxt_plane[dst_row + src_off ..][0..row_bytes]);
            }
        },
        else => {
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                const dst_row = y * stride_us;
                @memcpy(dst_plane[dst_row..][0..row_bytes], src_plane[dst_row..][0..row_bytes]);
            }
        },
    }
}

// ---------------------------------------------------------------------------
// buildABSDiffMask8 — absolute difference between two 8-bit frame rows
// ---------------------------------------------------------------------------

pub fn buildABSDiffMask8(
    prv: [*]const u8,
    nxt: [*]const u8,
    dst: [*]u8,
    prv_stride: isize,
    nxt_stride: isize,
    dst_stride: isize,
    width: u32,
    height: u32,
) void {
    const w = @as(usize, @intCast(width));
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const prv_row = @as(usize, @intCast(prv_stride)) * y;
        const nxt_row = @as(usize, @intCast(nxt_stride)) * y;
        const dst_row = @as(usize, @intCast(dst_stride)) * y;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const a = prv[prv_row + x];
            const b = nxt[nxt_row + x];
            dst[dst_row + x] = if (a > b) a - b else b - a;
        }
    }
}

// ---------------------------------------------------------------------------
// analyzeCombMask — mark combed pixels into a cmask frame (metric=0)
// ---------------------------------------------------------------------------

pub fn analyzeCombMask(
    comptime T: type,
    srcp: [*]const u8,
    cmkp: [*]u8,
    width: u32,
    height: u32,
    src_pitch: isize,
    cmk_pitch: isize,
    cthresh_scaled: i32,
) void {
    const pixel_pitch: usize = @intCast(@divExact(src_pitch, @as(isize, @sizeOf(T))));
    const cthresh6 = cthresh_scaled * 6;

    const pitch_us: usize = @intCast(cmk_pitch);
    var cmkp_bytes: [*]u8 = @ptrCast(cmkp);
    const srcp_typed: [*]const T = @ptrCast(srcp);

    var srcppp: [*]const T = srcp_typed;
    var srcpp: [*]const T = srcp_typed;
    var srcp_cur: [*]const T = srcp_typed;
    var srcpn: [*]const T = srcp_typed;
    var srcpnn: [*]const T = srcp_typed;

    const w: usize = @intCast(width);

    // Zero cmask
    @memset(cmkp_bytes[0..@as(usize, @intCast(cmk_pitch)) * @as(usize, @intCast(height))], 0);
    if (height < 5) return;

    // Row 0: compare row 0 vs row 1 only
    srcpn = srcp_cur + pixel_pitch;
    {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const sFirst: i32 = @as(i32, srcp_cur[x]) - @as(i32, srcpn[x]);
            if (sFirst > cthresh_scaled or sFirst < -cthresh_scaled) cmkp_bytes[x] = 0xFF;
        }
        srcppp += pixel_pitch;
        srcpp += pixel_pitch;
        srcp_cur += pixel_pitch;
        srcpn += pixel_pitch;
        cmkp_bytes += pitch_us;
    }

    // Row 1: compare with prev and next
    srcpnn = srcpn + pixel_pitch;
    {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const sFirst: i32 = @as(i32, srcp_cur[x]) - @as(i32, srcpp[x]);
            const sSecond: i32 = @as(i32, srcp_cur[x]) - @as(i32, srcpn[x]);
            if ((sFirst > cthresh_scaled and sSecond > cthresh_scaled) or
                (sFirst < -cthresh_scaled and sSecond < -cthresh_scaled))
            {
                if (@abs(@as(i32, srcppp[x]) + (@as(i32, srcp_cur[x]) << 2) + @as(i32, srcppp[x]) -
                    (3 * (@as(i32, srcpp[x]) + @as(i32, srcpn[x])))) > cthresh6)
                    cmkp_bytes[x] = 0xFF;
            }
        }
        srcppp += pixel_pitch;
        srcpp += pixel_pitch;
        srcp_cur += pixel_pitch;
        srcpn += pixel_pitch;
        srcpnn += pixel_pitch;
        cmkp_bytes += pitch_us;
    }

    // Middle rows: general 5-line comb detection
    const mid_rows = height - 4;
    var r: u32 = 0;
    while (r < mid_rows) : (r += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const sFirst: i32 = @as(i32, srcp_cur[x]) - @as(i32, srcpp[x]);
            const sSecond: i32 = @as(i32, srcp_cur[x]) - @as(i32, srcpn[x]);
            if ((sFirst > cthresh_scaled and sSecond > cthresh_scaled) or
                (sFirst < -cthresh_scaled and sSecond < -cthresh_scaled))
            {
                const v = @as(i32, srcppp[x]) + (@as(i32, srcp_cur[x]) << 2) + @as(i32, srcpnn[x]) -
                    (3 * (@as(i32, srcpp[x]) + @as(i32, srcpn[x])));
                if (@abs(v) > cthresh6) cmkp_bytes[x] = 0xFF;
            }
        }
        srcppp += pixel_pitch;
        srcpp += pixel_pitch;
        srcp_cur += pixel_pitch;
        srcpn += pixel_pitch;
        srcpnn += pixel_pitch;
        cmkp_bytes += pitch_us;
    }

    // Row (height-2)
    if (height >= 4) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const sFirst: i32 = @as(i32, srcp_cur[x]) - @as(i32, srcpp[x]);
            const sSecond: i32 = @as(i32, srcp_cur[x]) - @as(i32, srcpn[x]);
            if ((sFirst > cthresh_scaled and sSecond > cthresh_scaled) or
                (sFirst < -cthresh_scaled and sSecond < -cthresh_scaled))
            {
                if (@abs(@as(i32, srcppp[x]) + (@as(i32, srcp_cur[x]) << 2) + @as(i32, srcppp[x]) -
                    (3 * (@as(i32, srcpp[x]) + @as(i32, srcpn[x])))) > cthresh6)
                    cmkp_bytes[x] = 0xFF;
            }
        }
        srcppp += pixel_pitch;
        srcpp += pixel_pitch;
        srcp_cur += pixel_pitch;
        srcpn += pixel_pitch;
        cmkp_bytes += pitch_us;
    }

    // Bottom row (height-1)
    if (height >= 3) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const sFirst: i32 = @as(i32, srcp_cur[x]) - @as(i32, srcpp[x]);
            if (sFirst > cthresh_scaled or sFirst < -cthresh_scaled) cmkp_bytes[x] = 0xFF;
        }
    }
}

// ---------------------------------------------------------------------------
// countCombBlocks — count combed pixels in blocks, find max
// ---------------------------------------------------------------------------

pub const CombResult = struct {
    combed: bool,
    block_n: i32,
    mic_value: i32,
};

pub fn countCombBlocks(
    cmkp: [*]const u8,
    cmk_pitch: isize,
    c_array: []i32,
    width: u32,
    height: u32,
    xhalf: i32,
    yhalf: i32,
    xshift: i32,
    yshift: i32,
    mi: i32,
) CombResult {
    const cmkp_bytes: [*]const u8 = @ptrCast(cmkp);
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pitch: usize = @intCast(cmk_pitch);

    const xblocks: i32 = @as(i32, @intCast((w + @as(usize, @intCast(xhalf))) >> @as(u5, @intCast(xshift)))) + 1;
    const xblocks4: i32 = xblocks << 2;
    const yblocks: i32 = @as(i32, @intCast((h + @as(usize, @intCast(yhalf))) >> @as(u5, @intCast(yshift)))) + 1;
    const arraysize: usize = @intCast((xblocks * yblocks) << 2);

    @memset(c_array[0..arraysize], 0);

    const height_a: usize = if (((h >> @as(u5, @intCast(yshift - 1))) << @as(u5, @intCast(yshift - 1))) == h)
        h - @as(usize, @intCast(yhalf))
    else
        (h >> @as(u5, @intCast(yshift - 1))) << @as(u5, @intCast(yshift - 1));

    const yhalf_usize: usize = @intCast(yhalf);
    const xhalf_usize: usize = @intCast(xhalf);

    // Top boundary
    var y: usize = 1;
    while (y < yhalf_usize) : (y += 1) {
        const cmkpp = cmkp_bytes + (y - 1) * pitch;
        const cmkpc = cmkp_bytes + y * pitch;
        const cmkpn = cmkp_bytes + (y + 1) * pitch;
        const temp1: usize = @intCast((@as(i32, @intCast(y >> @as(u5, @intCast(yshift)))) * xblocks4));
        const temp2: usize = @intCast((@as(i32, @intCast((y + yhalf_usize) >> @as(u5, @intCast(yshift)))) * xblocks4));
        var x: usize = 0;
        while (x < w) : (x += 1) {
            if (cmkpp[x] == 0xFF and cmkpc[x] == 0xFF and cmkpn[x] == 0xFF) {
                const box1: usize = @intCast((x >> @as(u5, @intCast(xshift))) << 2);
                const box2: usize = @intCast(((x + xhalf_usize) >> @as(u5, @intCast(xshift))) << 2);
                c_array[temp1 + box1 + 0] += 1;
                c_array[temp1 + box2 + 1] += 1;
                c_array[temp2 + box1 + 2] += 1;
                c_array[temp2 + box2 + 3] += 1;
            }
        }
    }

    // Middle: block-based
    y = yhalf_usize;
    while (y < height_a) : (y += yhalf_usize) {
        const temp1: usize = @intCast((@as(i32, @intCast(y >> @as(u5, @intCast(yshift)))) * xblocks4));
        const temp2: usize = @intCast((@as(i32, @intCast((y + yhalf_usize) >> @as(u5, @intCast(yshift)))) * xblocks4));
        var x: usize = 0;
        while (x < w) : (x += xhalf_usize) {
            var sum: i32 = 0;
            const cmkpp_base = cmkp_bytes + (y - 1) * pitch;
            const cmkpc_base = cmkp_bytes + y * pitch;
            const cmkpn_base = cmkp_bytes + (y + 1) * pitch;
            var u: usize = 0;
            while (u < yhalf_usize) : (u += 1) {
                var v: usize = 0;
                while (v < xhalf_usize and (x + v) < w) : (v += 1) {
                    const idx = x + v;
                    if (cmkpp_base[u * pitch + idx] == 0xFF and
                        cmkpc_base[u * pitch + idx] == 0xFF and
                        cmkpn_base[u * pitch + idx] == 0xFF) sum += 1;
                }
            }
            if (sum > 0) {
                const box1: usize = @intCast((x >> @as(u5, @intCast(xshift))) << 2);
                const box2: usize = @intCast(((x + xhalf_usize) >> @as(u5, @intCast(xshift))) << 2);
                c_array[temp1 + box1 + 0] += sum;
                c_array[temp1 + box2 + 1] += sum;
                c_array[temp2 + box1 + 2] += sum;
                c_array[temp2 + box2 + 3] += sum;
            }
        }
        // Remainder past aligned width
        const width_a: usize = (w >> @as(u5, @intCast(xshift - 1))) << @as(u5, @intCast(xshift - 1));
        x = width_a;
        while (x < w) : (x += 1) {
            var sum: i32 = 0;
            var u: usize = 0;
            while (u < yhalf_usize) : (u += 1) {
                const cmkpp_row = cmkp_bytes + (y - 1 + u) * pitch;
                const cmkpc_row = cmkp_bytes + (y + u) * pitch;
                const cmkpn_row = cmkp_bytes + (y + 1 + u) * pitch;
                if (cmkpp_row[x] == 0xFF and cmkpc_row[x] == 0xFF and cmkpn_row[x] == 0xFF) sum += 1;
            }
            if (sum > 0) {
                const box1: usize = @intCast((x >> @as(u5, @intCast(xshift))) << 2);
                const box2: usize = @intCast(((x + xhalf_usize) >> @as(u5, @intCast(xshift))) << 2);
                c_array[temp1 + box1 + 0] += sum;
                c_array[temp1 + box2 + 1] += sum;
                c_array[temp2 + box1 + 2] += sum;
                c_array[temp2 + box2 + 3] += sum;
            }
        }
    }

    // Bottom boundary
    y = height_a;
    while (y < h - 1) : (y += 1) {
        const cmkpp = cmkp_bytes + (y - 1) * pitch;
        const cmkpc = cmkp_bytes + y * pitch;
        const cmkpn = cmkp_bytes + (y + 1) * pitch;
        const temp1: usize = @intCast((@as(i32, @intCast(y >> @as(u5, @intCast(yshift)))) * xblocks4));
        const temp2: usize = @intCast((@as(i32, @intCast((y + yhalf_usize) >> @as(u5, @intCast(yshift)))) * xblocks4));
        var x: usize = 0;
        while (x < w) : (x += 1) {
            if (cmkpp[x] == 0xFF and cmkpc[x] == 0xFF and cmkpn[x] == 0xFF) {
                const box1: usize = @intCast((x >> @as(u5, @intCast(xshift))) << 2);
                const box2: usize = @intCast(((x + xhalf_usize) >> @as(u5, @intCast(xshift))) << 2);
                c_array[temp1 + box1 + 0] += 1;
                c_array[temp1 + box2 + 1] += 1;
                c_array[temp2 + box1 + 2] += 1;
                c_array[temp2 + box2 + 3] += 1;
            }
        }
    }

    var max_val: i32 = -20;
    var max_idx: i32 = -20;
    for (c_array[0..arraysize], 0..) |val, i| {
        if (val > max_val) {
            max_val = val;
            max_idx = @intCast(i);
        }
    }

    return .{ .combed = max_val > mi, .block_n = max_idx, .mic_value = max_val };
}

// ---------------------------------------------------------------------------
// putFrameProperties — write TFM hint frame properties
// ---------------------------------------------------------------------------

pub fn putFrameProperties(
    zapi: *const ZAPI,
    dst: ?*vs.Frame,
    match: i32,
    combed: i32,
    d2vfilm: bool,
    mics: [5]i32,
    field: i32,
    pp: i32,
) void {
    const props = zapi.getFramePropertiesRW(dst) orelse return;
    _ = zapi.vsapi.mapSetInt.?(props, common.PROP_TFM_MATCH, @intCast(match), .Replace);
    _ = zapi.vsapi.mapSetInt.?(props, common.PROP_COMBED, @intCast(if (combed > 1) @as(i32, 1) else @as(i32, 0)), .Replace);
    _ = zapi.vsapi.mapSetInt.?(props, common.PROP_TFM_D2VFILM, @intCast(if (d2vfilm) @as(i32, 1) else @as(i32, 0)), .Replace);
    _ = zapi.vsapi.mapSetInt.?(props, common.PROP_TFM_FIELD, @intCast(field), .Replace);
    _ = zapi.vsapi.mapSetInt.?(props, common.PROP_TFM_PP, @intCast(pp), .Replace);
    for (mics, 0..) |m, i| {
        _ = zapi.vsapi.mapSetInt.?(props, common.PROP_TFM_MICS, @intCast(m), if (i == 0) .Replace else .Append);
    }
}
