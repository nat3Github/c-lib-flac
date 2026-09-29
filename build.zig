const std = @import("std");

// ponytail: libFLAC only (no libFLAC++, programs, examples). Ogg FLAC enabled.
// x86 intrinsics keep upstream's runtime dispatch (cpuid + __attribute__((target))), so every
// x86 build gets all SSE/AVX2/FMA paths and picks at runtime; aarch64 always has NEON.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libc_include = b.option(std.Build.LazyPath, "libc_include", "Build without libc against these headers; the consumer provides the symbols");
    const t = target.result;
    const threads = b.option(bool, "threads", "Encoder multithreading via pthreads (not on windows)") orelse true;

    const ogg = b.dependency("ogg", .{ .target = target, .optimize = optimize, .libc_include = libc_include }).artifact("ogg");

    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = libc_include == null });
    if (libc_include) |p| mod.addIncludePath(p); // -I: must win over the macOS SDK headers zig always adds
    // Without libc the Windows file code (windows.h, io.h, _wfopen) cannot build; the consumer's
    // libc has no files anyway, so take the POSIX paths (they call its failing stubs).
    const no_win32: []const []const u8 = if (libc_include != null and target.result.os.tag == .windows)
        &.{ "-U_WIN32", "-UWIN32", "-U__WIN32__", "-U__MINGW32__" } // not _WIN64: used to detect LLP64
    else
        &.{};
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("src/libFLAC/include"));
    mod.linkLibrary(ogg);

    mod.addCMacro("PACKAGE_VERSION", "\"1.5.0\"");
    mod.addCMacro("FLAC__HAS_OGG", "1");
    // ponytail: FLAC__NO_DLL is a PUBLIC define upstream; C consumers on windows must set it too.
    mod.addCMacro("FLAC__NO_DLL", "1");
    mod.addCMacro("ENABLE_64_BIT_WORDS", "1");
    mod.addCMacro("CPU_IS_BIG_ENDIAN", if (t.cpu.arch.endian() == .big) "1" else "0");
    mod.addCMacro("WORDS_BIGENDIAN", if (t.cpu.arch.endian() == .big) "1" else "0");
    mod.addCMacro("HAVE_LROUND", "1");
    mod.addCMacro("HAVE_BSWAP16", "1");
    mod.addCMacro("HAVE_BSWAP32", "1");
    mod.addCMacro("HAVE_STDINT_H", "1");
    mod.addCMacro("HAVE_INTTYPES_H", "1");
    mod.addCMacro("HAVE_FSEEKO", "1");
    mod.addCMacro("_FILE_OFFSET_BITS", "64");
    // ponytail: encoder multithreading via pthreads, not on windows (set_num_threads reports
    // NOT_COMPILED_WITH_MULTITHREADING_ENABLED there); add winpthreads/C11 threads if needed.
    if (threads and t.os.tag != .windows) mod.addCMacro("HAVE_PTHREAD", "1");

    var files: std.ArrayList([]const u8) = .empty;
    files.appendSlice(b.allocator, &flac_sources) catch @panic("OOM");
    if (t.os.tag == .windows and libc_include == null) files.append(b.allocator, "src/share/win_utf8_io/win_utf8_io.c") catch @panic("OOM");

    switch (t.cpu.arch) {
        .x86, .x86_64 => {
            mod.addCMacro("FLAC__HAS_X86INTRIN", "1");
            mod.addCMacro("FLAC__USE_AVX", "1");
            mod.addCMacro("FLAC__ALIGN_MALLOC_DATA", "1");
            mod.addCMacro("HAVE_CPUID_H", "1");
            files.appendSlice(b.allocator, &x86_sources) catch @panic("OOM");
        },
        .aarch64 => if (std.Target.aarch64.featureSetHas(t.cpu.features, .neon)) {
            mod.addCMacro("FLAC__CPU_ARM64", "1");
            mod.addCMacro("FLAC__HAS_NEONINTRIN", "1");
            mod.addCMacro("FLAC__HAS_A64NEONINTRIN", "1");
            files.append(b.allocator, "src/libFLAC/lpc_intrin_neon.c") catch @panic("OOM");
        },
        else => {},
    }

    mod.addCSourceFiles(.{
        .files = files.items,
        .flags = std.mem.concat(b.allocator, []const u8, &.{
            &.{ "-fassociative-math", "-fno-signed-zeros", "-fno-trapping-math", "-freciprocal-math" },
            // Damaged input overflows the predictor arithmetic (e.g. FLAC__fixed_restore_signal)
            // before the frame CRC rejects it; wrap like upstream silently assumes. Valid streams
            // never overflow, so decoded audio is unchanged.
            &.{"-fwrapv"},
            no_win32,
        }) catch @panic("OOM"),
    });

    const lib = b.addLibrary(.{ .name = "FLAC", .root_module = mod });
    for ([_][]const u8{ "all.h", "assert.h", "callback.h", "export.h", "format.h", "metadata.h", "ordinals.h", "stream_decoder.h", "stream_encoder.h" }) |h|
        lib.installHeader(b.path(b.fmt("include/FLAC/{s}", .{h})), b.fmt("FLAC/{s}", .{h}));
    lib.installLibraryHeaders(ogg);
    b.installArtifact(lib);
}

const flac_sources = [_][]const u8{
    "src/libFLAC/bitmath.c",
    "src/libFLAC/bitreader.c",
    "src/libFLAC/bitwriter.c",
    "src/libFLAC/cpu.c",
    "src/libFLAC/crc.c",
    "src/libFLAC/fixed.c",
    "src/libFLAC/float.c",
    "src/libFLAC/format.c",
    "src/libFLAC/lpc.c",
    "src/libFLAC/md5.c",
    "src/libFLAC/memory.c",
    "src/libFLAC/metadata_iterators.c",
    "src/libFLAC/metadata_object.c",
    "src/libFLAC/stream_decoder.c",
    "src/libFLAC/stream_encoder.c",
    "src/libFLAC/stream_encoder_framing.c",
    "src/libFLAC/window.c",
    "src/libFLAC/ogg_decoder_aspect.c",
    "src/libFLAC/ogg_encoder_aspect.c",
    "src/libFLAC/ogg_helper.c",
    "src/libFLAC/ogg_mapping.c",
};

const x86_sources = [_][]const u8{
    "src/libFLAC/fixed_intrin_sse2.c",
    "src/libFLAC/fixed_intrin_ssse3.c",
    "src/libFLAC/fixed_intrin_sse42.c",
    "src/libFLAC/fixed_intrin_avx2.c",
    "src/libFLAC/lpc_intrin_sse2.c",
    "src/libFLAC/lpc_intrin_sse41.c",
    "src/libFLAC/lpc_intrin_avx2.c",
    "src/libFLAC/lpc_intrin_fma.c",
    "src/libFLAC/stream_encoder_intrin_sse2.c",
    "src/libFLAC/stream_encoder_intrin_ssse3.c",
    "src/libFLAC/stream_encoder_intrin_avx2.c",
};
