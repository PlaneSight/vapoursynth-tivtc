//! TIVTC — field matching and decimation for VapourSynth, Zig port.
//!
//! Registers TFM (field matching), TDecimate (decimation), and TFMPP
//! (post-processing) filters. High-performance, portable implementation
//! using ZAPI bindings. Every CPU cycle matters.
//!
//! Ported from tritical's TIVTC / pinterf's VapourSynth port.

const std = @import("std");
const vapoursynth = @import("vapoursynth");
const zon = @import("zon");

const vs = vapoursynth.vapoursynth4;
const ZAPI = vapoursynth.ZAPI;

const common = @import("common.zig");
const tfm = @import("tfm.zig");
const tdecimate = @import("tdecimate.zig");
const tfmpp = @import("tfmpp.zig");

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------

export fn VapourSynthPluginInit2(
    plugin: *vs.Plugin,
    vspapi: *const vs.PLUGINAPI,
) void {
    ZAPI.Plugin.config(
        common.PLUGIN_ID,
        common.PLUGIN_NAMESPACE,
        common.PLUGIN_NAME,
        zon.version,
        plugin,
        vspapi,
    );

    // TFM — field matching
    ZAPI.Plugin.function(
        "TFM",
        // Required
        "clip:vnode;" ++
        // Optional ints
        "order:int:opt;field:int:opt;mode:int:opt;PP:int:opt;" ++
        "slow:int:opt;mChroma:int:opt;cNum:int:opt;cthresh:int:opt;" ++
        "MI:int:opt;chroma:int:opt;blockx:int:opt;blocky:int:opt;" ++
        "y0:int:opt;y1:int:opt;ovrDefault:int:opt;flags:int:opt;" ++
        "micout:int:opt;micmatching:int:opt;" ++
        "hint:int:opt;metric:int:opt;batch:int:opt;" ++
        "ubsco:int:opt;mmsco:int:opt;opt:int:opt;" ++
        "display:int:opt;debug:int:opt;" ++
        // Optional floats
        "scthresh:float:opt;" ++
        // Optional data strings
        "ovr:data:opt;input:data:opt;output:data:opt;" ++
        "outputC:data:opt;d2v:data:opt;trimIn:data:opt;" ++
        // Optional clip2
        "clip2:vnode:opt;",
        "clip:vnode;",
        tfm.tfmCreate,
        plugin,
        vspapi,
    );

    // TDecimate — frame decimation
    ZAPI.Plugin.function(
        "TDecimate",
        // Required
        "clip:vnode;" ++
        // Optional ints
        "mode:int:opt;cycleR:int:opt;cycle:int:opt;" ++
        "hybrid:int:opt;vidDetect:int:opt;conCycle:int:opt;" ++
        "conCycleTP:int:opt;nt:int:opt;blockx:int:opt;blocky:int:opt;" ++
        "vfrDec:int:opt;maxndl:int:opt;sdlim:int:opt;opt:int:opt;" ++
        "debug:int:opt;display:int:opt;batch:int:opt;" ++
        "tcfv1:int:opt;se:int:opt;chroma:int:opt;" ++
        "exPP:int:opt;m2PA:int:opt;predenoise:int:opt;" ++
        "noblend:int:opt;ssd:int:opt;hint:int:opt;" ++
        // Optional floats
        "rate:float:opt;dupThresh:float:opt;vidThresh:float:opt;" ++
        "sceneThresh:float:opt;" ++
        // Optional data strings
        "ovr:data:opt;output:data:opt;input:data:opt;" ++
        "tfmIn:data:opt;mkvOut:data:opt;orgOut:data:opt;" ++
        // Optional clip2
        "clip2:vnode:opt;",
        "clip:vnode;",
        tdecimate.tdecimateCreate,
        plugin,
        vspapi,
    );

    // TFMPP — post-processing for TFM
    ZAPI.Plugin.function(
        "TFMPP",
        "clip:vnode;" ++
        "PP:int:opt;mthresh:int:opt;hint:int:opt;opt:int:opt;" ++
        "display:int:opt;" ++
        "ovr:data:opt;" ++
        "clip2:vnode:opt;",
        "clip:vnode;",
        tfmpp.tfmppCreate,
        plugin,
        vspapi,
    );
}
