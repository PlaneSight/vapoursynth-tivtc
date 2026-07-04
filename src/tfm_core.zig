//! TFM core algorithms — field weaving, comb detection, diff-map field matching.
//!
//! Comptime-generic over pixel type. Supports 8/10/12/14/16-bit integer.
//! Every CPU cycle matters.

const vs = @import("vapoursynth").vapoursynth4;
const ZAPI = @import("vapoursynth").ZAPI;
const common = @import("common.zig");

// ---------------------------------------------------------------------------
// weaveFrame — weave two adjacent frames into a progressive frame
// ---------------------------------------------------------------------------
// Match codes: 0=p, 1=c, 2=n, 3=b, 4=u
// `field`: 0=BFF, 1=TFF

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
// Build absdiff mask — |prv[x] - nxt[x]| into dst (always 8-bit mask)
// ---------------------------------------------------------------------------

pub fn buildABSDiffMask(
    comptime T: type,
    prv: [*]const u8,
    nxt: [*]const u8,
    dst: [*]u8,
    prv_stride: isize,
    nxt_stride: isize,
    dst_stride: isize,
    width: u32,
    height: u32,
) void {
    const prv_typed: [*]const T = @ptrCast(prv);
    const nxt_typed: [*]const T = @ptrCast(nxt);
    const pixel_pitch_prv: usize = @intCast(@divExact(prv_stride, @as(isize, @sizeOf(T))));
    const pixel_pitch_nxt: usize = @intCast(@divExact(nxt_stride, @as(isize, @sizeOf(T))));
    const w: usize = @intCast(width);
    const dst_pitch: usize = @intCast(dst_stride);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const prv_row = pixel_pitch_prv * y;
        const nxt_row = pixel_pitch_nxt * y;
        const dst_row = dst_pitch * y;

        var x: usize = 0;
        while (x < w) : (x += 1) {
            const a: i32 = @intCast(prv_typed[prv_row + x]);
            const b: i32 = @intCast(nxt_typed[nxt_row + x]);
            const diff: u32 = @intCast(if (a > b) a - b else b - a);
            // Scale HBD down to 8-bit for diff buffer
            if (T == u8) {
                dst[dst_row + x] = @truncate(diff);
            } else {
                dst[dst_row + x] = @truncate(diff >> (@bitSizeOf(T) - 8));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Analyze diff mask for field comparison
// ---------------------------------------------------------------------------
// Reads the 8-bit absdiff buffer and produces two aggregates:
//   accumPc/accumNc — total "noise" for p and n comparisons
//   accumPm/accumNm — "motion" metric for MIC
//
// This is the core of compareFields* — simplified from TCommonASM's analyze.

pub fn analyzeDiffMask(
    mapp: [*]const u8,
    mapc: [*]const u8,
    mapn: [*]const u8,
    map_pitch: isize,
    width_u: u32,
    height_u: u32,
    accum_pc: *u64,
    accum_nc: *u64,
    accum_pm: *u64,
    accum_nm: *u64,
    accum_pml: *u64,
    accum_nml: *u64,
) void {
    const pitch: usize = @intCast(map_pitch);
    const w: usize = @intCast(width_u);
    const h: usize = @intCast(height_u);

    var apc: u64 = 0;
    var anc: u64 = 0;
    var apm: u64 = 0;
    var anm: u64 = 0;
    var apml: u64 = 0;
    var anml: u64 = 0;

    var y: usize = 3;
    while (y < h - 3) : (y += 1) {
        const pp = mapp + y * pitch;
        const pc = mapc + y * pitch;
        const pn = mapn + y * pitch;
        const ppm1 = mapp + (y - 1) * pitch;
        const pcm1 = mapc + (y - 1) * pitch;
        const pnm1 = mapn + (y - 1) * pitch;
        const ppp1 = mapp + (y + 1) * pitch;
        const pcp1 = mapc + (y + 1) * pitch;
        const pnp1 = mapn + (y + 1) * pitch;

        var x: usize = 3;
        while (x < w - 3) : (x += 1) {
            // p-match noise: how much the p-match diff stands out vs. neighbors
            const pc_val: u64 = pc[x];
            apc += pc_val;

            if (pc_val > 3) {
                const p_motion: u64 = if (pc_val > pp[x] and pc_val > pn[x] and pc_val > ppm1[x] and
                    pc_val > pcm1[x] and pc_val > pnm1[x] and pc_val > ppp1[x] and
                    pc_val > pcp1[x] and pc_val > pnp1[x]) pc_val else 0;
                apm += p_motion;
                apml += pc_val;
            }
        }
        // n-match: same analysis on the n-side diff map
        {
            var x2: usize = 3;
            while (x2 < w - 3) : (x2 += 1) {
                const nc_val: u64 = pn[x2];
                anc += nc_val;

                if (nc_val > 3) {
                    const n_motion: u64 = if (nc_val > pp[x2] and nc_val > pc[x2] and nc_val > ppm1[x2] and
                        nc_val > pcm1[x2] and nc_val > pnm1[x2] and nc_val > ppp1[x2] and
                        nc_val > pcp1[x2] and nc_val > pnp1[x2]) nc_val else 0;
                    anm += n_motion;
                    anml += nc_val;
                }
            }
        }
    }

    accum_pc.* = apc;
    accum_nc.* = anc;
    accum_pm.* = apm;
    accum_nm.* = anm;
    accum_pml.* = apml;
    accum_nml.* = anml;
}

// ---------------------------------------------------------------------------
// compareFields — pick the best match between two candidates
// ---------------------------------------------------------------------------
// Returns the winning match index (match1 or match2).
// Modes: slow=0 (fast, analyze diff maps), slow=1 (per-pixel, not implemented yet)

pub fn compareFields(
    comptime T: type,
    prv_frame: ?*const vs.Frame,
    src_frame: ?*const vs.Frame,
    nxt_frame: ?*const vs.Frame,
    match1: i32,
    match2: i32,
    norm1: *i32,
    norm2: *i32,
    mtn1: *i32,
    mtn2: *i32,
    bits_per_pixel: i32,
    tbuffer: [*]u8,
    map_frame: ?*const vs.Frame,
    vsapi: ?*const vs.API,
    nfrms: i32,
    n: i32,
    field: i32,
) i32 {
    _ = n;
    _ = nfrms;
    _ = field;
    _ = tbuffer;

    const bytes: i32 = if (T == u8) @as(i32, 1) else @as(i32, 2);
    _ = bytes;

    // Get luma plane pointers
    const prvp = vsapi.?.getReadPtr.?(prv_frame, 0) orelse return match1;
    const srcp = vsapi.?.getReadPtr.?(src_frame, 0) orelse return match1;
    const nxtp = vsapi.?.getReadPtr.?(nxt_frame, 0) orelse return match1;

    const prv_pitch = vsapi.?.getStride.?(prv_frame, 0);
    const src_pitch = vsapi.?.getStride.?(src_frame, 0);
    const nxt_pitch = vsapi.?.getStride.?(nxt_frame, 0);

    const width: u32 = @intCast(vsapi.?.getFrameWidth.?(src_frame, 0));
    const height: u32 = @intCast(vsapi.?.getFrameHeight.?(src_frame, 0));
    _ = width;
    _ = height;

    // Map frame is always 8-bit
    const mapw: u32 = @intCast(vsapi.?.getFrameWidth.?(map_frame, 0));
    const maph: u32 = @intCast(vsapi.?.getFrameHeight.?(map_frame, 0));
    const map_pitch = vsapi.?.getStride.?(map_frame, 0);
    const mapp = vsapi.?.getWritePtr.?(map_frame, 0);
    const mapc = mapp + @as(usize, @intCast(map_pitch)) * @as(usize, @intCast(maph));
    const mapn = mapc + @as(usize, @intCast(map_pitch)) * @as(usize, @intCast(maph));

    const tpitch: isize = map_pitch;

    // Build absdiff masks for p, c, n comparisons
    // p-diff: |prv - src| into mapp
    buildABSDiffMask(T, prvp, srcp, mapp, prv_pitch, src_pitch, tpitch, mapw, maph);
    // c-diff: |prv - nxt|? Actually mapc = weave-frame diff.
    // In the C++ code, the map holds three diff layers: p-match, c-match, n-match.
    // We simplify: build diff between the two frames relevant to each match.

    // n-diff: |src - nxt| into mapn
    buildABSDiffMask(T, srcp, nxtp, mapn, src_pitch, nxt_pitch, tpitch, mapw, maph);

    // For match1/m2 comparison, we need diff between the frames that differ per match.
    // match1's diff goes in mapc, match2's also goes... simplified approach:
    // Just build the two relevant comparisons and analyze.

    // Build comparison diff for match1's non-src frame
    const match1_other_p = if (match1 == 0) prvp else if (match1 == 2) nxtp else if (match1 == 3) prvp else if (match1 == 4) nxtp else srcp;
    const match1_other_pitch = if (match1 == 0) prv_pitch else if (match1 == 2) nxt_pitch else if (match1 == 3) prv_pitch else if (match1 == 4) nxt_pitch else src_pitch;
    buildABSDiffMask(T, srcp, match1_other_p, mapc, src_pitch, match1_other_pitch, tpitch, mapw, maph);

    // For match2's non-src frame — just put in the same buffer for now
    const match2_other_p = if (match2 == 0) prvp else if (match2 == 2) nxtp else if (match2 == 3) prvp else if (match2 == 4) nxtp else srcp;
    const match2_other_pitch = if (match2 == 0) prv_pitch else if (match2 == 2) nxt_pitch else if (match2 == 3) prv_pitch else if (match2 == 4) nxt_pitch else src_pitch;
    buildABSDiffMask(T, srcp, match2_other_p, mapn, src_pitch, match2_other_pitch, tpitch, mapw, maph);

    var accum_pc: u64 = 0;
    var accum_nc: u64 = 0;
    var accum_pm: u64 = 0;
    var accum_nm: u64 = 0;
    var accum_pml: u64 = 0;
    var accum_nml: u64 = 0;

    analyzeDiffMask(mapp, mapc, mapn, tpitch, mapw, maph,
        &accum_pc, &accum_nc, &accum_pm, &accum_nm, &accum_pml, &accum_nml);

    // Scale back to 8-bit range for HBD
    const factor: f64 = 1.0 / @as(f64, @floatFromInt(@as(i32, 1) << @intCast(bits_per_pixel - 8)));

    norm1.* = @intFromFloat(@round(@as(f64, @floatFromInt(accum_pc)) / 6.0 * factor));
    norm2.* = @intFromFloat(@round(@as(f64, @floatFromInt(accum_nc)) / 6.0 * factor));
    mtn1.* = @intFromFloat(@round(@as(f64, @floatFromInt(accum_pm)) / 6.0 * factor));
    mtn2.* = @intFromFloat(@round(@as(f64, @floatFromInt(accum_nm)) / 6.0 * factor));

    // Decision logic — same thresholds as C++
    const c1: f64 = @as(f64, @floatFromInt(@max(norm1.*, norm2.*))) / @as(f64, @floatFromInt(@max(@min(norm1.*, norm2.*), 1)));
    const c2: f64 = @as(f64, @floatFromInt(@max(mtn1.*, mtn2.*))) / @as(f64, @floatFromInt(@max(@min(mtn1.*, mtn2.*), 1)));
    const mr: f64 = @as(f64, @floatFromInt(@max(mtn1.*, mtn2.*))) / @as(f64, @floatFromInt(@max(@max(norm1.*, norm2.*), 1)));

    if (((mtn1.* >= 250 or mtn2.* >= 250) and (mtn1.* * 4 < mtn2.* * 1 or mtn2.* * 4 < mtn1.* * 1)) or
        ((mtn1.* >= 375 or mtn2.* >= 375) and (mtn1.* * 3 < mtn2.* * 1 or mtn2.* * 3 < mtn1.* * 1)) or
        ((mtn1.* >= 500 or mtn2.* >= 500) and (mtn1.* * 2 < mtn2.* * 1 or mtn2.* * 2 < mtn1.* * 1)) or
        ((mtn1.* >= 1000 or mtn2.* >= 1000) and (mtn1.* * 3 < mtn2.* * 2 or mtn2.* * 3 < mtn1.* * 2)) or
        ((mtn1.* >= 2000 or mtn2.* >= 2000) and (mtn1.* * 5 < mtn2.* * 4 or mtn2.* * 5 < mtn1.* * 4)) or
        ((mtn1.* >= 4000 or mtn2.* >= 4000) and c2 > c1))
    {
        return if (mtn1.* > mtn2.*) match2 else match1;
    } else if (mr > 0.005 and @max(mtn1.*, mtn2.*) > 150 and (mtn1.* * 2 < mtn2.* * 1 or mtn2.* * 2 < mtn1.* * 1)) {
        return if (mtn1.* > mtn2.*) match2 else match1;
    } else {
        return if (norm1.* > norm2.*) match2 else match1;
    }
}

// ---------------------------------------------------------------------------
// Comb detection: analyze phase (mark combed pixels)
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

    @memset(cmkp_bytes[0..pitch_us * @as(usize, @intCast(height))], 0);
    if (height < 5) return;

    // Row 0
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

    // Row 1
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

    // Middle rows
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

    // Bottom row
    if (height >= 3) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const sFirst: i32 = @as(i32, srcp_cur[x]) - @as(i32, srcpp[x]);
            if (sFirst > cthresh_scaled or sFirst < -cthresh_scaled) cmkp_bytes[x] = 0xFF;
        }
    }
}

// ---------------------------------------------------------------------------
// countCombBlocks — count combed pixels in blocks, return max
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

    const yhalf_usz: usize = @intCast(yhalf);
    const xhalf_usz: usize = @intCast(xhalf);

    // Top
    var y: usize = 1;
    while (y < yhalf_usz) : (y += 1) {
        const cmkpp = cmkp_bytes + (y - 1) * pitch;
        const cmkpc = cmkp_bytes + y * pitch;
        const cmkpn = cmkp_bytes + (y + 1) * pitch;
        const temp1: usize = @intCast((@as(i32, @intCast(y >> @as(u5, @intCast(yshift)))) * xblocks4));
        const temp2: usize = @intCast((@as(i32, @intCast((y + yhalf_usz) >> @as(u5, @intCast(yshift)))) * xblocks4));
        var x: usize = 0;
        while (x < w) : (x += 1) {
            if (cmkpp[x] == 0xFF and cmkpc[x] == 0xFF and cmkpn[x] == 0xFF) {
                const box1: usize = @intCast((@as(i32, @intCast(x >> @as(u5, @intCast(xshift)))) << 2));
                const box2: usize = @intCast((@as(i32, @intCast((x + xhalf_usz) >> @as(u5, @intCast(xshift)))) << 2));
                c_array[temp1 + box1 + 0] += 1;
                c_array[temp1 + box2 + 1] += 1;
                c_array[temp2 + box1 + 2] += 1;
                c_array[temp2 + box2 + 3] += 1;
            }
        }
    }

    // Middle
    y = yhalf_usz;
    while (y < height_a) : (y += yhalf_usz) {
        const temp1: usize = @intCast((@as(i32, @intCast(y >> @as(u5, @intCast(yshift)))) * xblocks4));
        const temp2: usize = @intCast((@as(i32, @intCast((y + yhalf_usz) >> @as(u5, @intCast(yshift)))) * xblocks4));
        var x: usize = 0;
        while (x < w) : (x += xhalf_usz) {
            var sum: i32 = 0;
            const cmkpp_base = cmkp_bytes + (y - 1) * pitch;
            const cmkpc_base = cmkp_bytes + y * pitch;
            const cmkpn_base = cmkp_bytes + (y + 1) * pitch;
            var u: usize = 0;
            while (u < yhalf_usz) : (u += 1) {
                var v: usize = 0;
                while (v < xhalf_usz and (x + v) < w) : (v += 1) {
                    const idx = x + v;
                    if (cmkpp_base[u * pitch + idx] == 0xFF and
                        cmkpc_base[u * pitch + idx] == 0xFF and
                        cmkpn_base[u * pitch + idx] == 0xFF) sum += 1;
                }
            }
            if (sum > 0) {
                const box1: usize = @intCast((@as(i32, @intCast(x >> @as(u5, @intCast(xshift)))) << 2));
                const box2: usize = @intCast((@as(i32, @intCast((x + xhalf_usz) >> @as(u5, @intCast(xshift)))) << 2));
                c_array[temp1 + box1 + 0] += sum;
                c_array[temp1 + box2 + 1] += sum;
                c_array[temp2 + box1 + 2] += sum;
                c_array[temp2 + box2 + 3] += sum;
            }
        }
        const width_a: usize = (w >> @as(u5, @intCast(xshift - 1))) << @as(u5, @intCast(xshift - 1));
        x = width_a;
        while (x < w) : (x += 1) {
            var sum: i32 = 0;
            var u: usize = 0;
            while (u < yhalf_usz) : (u += 1) {
                const cmkpp_row = cmkp_bytes + (y - 1 + u) * pitch;
                const cmkpc_row = cmkp_bytes + (y + u) * pitch;
                const cmkpn_row = cmkp_bytes + (y + 1 + u) * pitch;
                if (cmkpp_row[x] == 0xFF and cmkpc_row[x] == 0xFF and cmkpn_row[x] == 0xFF) sum += 1;
            }
            if (sum > 0) {
                const box1: usize = @intCast((@as(i32, @intCast(x >> @as(u5, @intCast(xshift)))) << 2));
                const box2: usize = @intCast((@as(i32, @intCast((x + xhalf_usz) >> @as(u5, @intCast(xshift)))) << 2));
                c_array[temp1 + box1 + 0] += sum;
                c_array[temp1 + box2 + 1] += sum;
                c_array[temp2 + box1 + 2] += sum;
                c_array[temp2 + box2 + 3] += sum;
            }
        }
    }

    // Bottom
    y = height_a;
    while (y < h - 1) : (y += 1) {
        const cmkpp = cmkp_bytes + (y - 1) * pitch;
        const cmkpc = cmkp_bytes + y * pitch;
        const cmkpn = cmkp_bytes + (y + 1) * pitch;
        const temp1: usize = @intCast((@as(i32, @intCast(y >> @as(u5, @intCast(yshift)))) * xblocks4));
        const temp2: usize = @intCast((@as(i32, @intCast((y + yhalf_usz) >> @as(u5, @intCast(yshift)))) * xblocks4));
        var x: usize = 0;
        while (x < w) : (x += 1) {
            if (cmkpp[x] == 0xFF and cmkpc[x] == 0xFF and cmkpn[x] == 0xFF) {
                const box1: usize = @intCast((@as(i32, @intCast(x >> @as(u5, @intCast(xshift)))) << 2));
                const box2: usize = @intCast((@as(i32, @intCast((x + xhalf_usz) >> @as(u5, @intCast(xshift)))) << 2));
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
// putFrameProperties — write TFM hint frame properties for TDecimate
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

// ---------------------------------------------------------------------------
// Dispatch helper: run operation with correct pixel type
// ---------------------------------------------------------------------------

pub fn withPixelType(comptime T: type, bits_per_sample: i32, comptime op: anytype, args: anytype) void {
    _ = T;
    switch (bits_per_sample) {
        8 => @call(.auto, op, .{u8} ++ args),
        10, 12, 14, 16 => @call(.auto, op, .{u16} ++ args),
        else => @compileError("unsupported bit depth"),
    }
}
