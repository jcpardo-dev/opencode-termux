#!/usr/bin/env bash
# Build libopentui.so for Android aarch64
#
# Usage: ./scripts/build-opentui.sh
#
# OpenCode's TUI renderer (@opentui/core) uses a native Zig library.
# The upstream build targets aarch64-linux (musl), which fails on Android
# because getauxval cannot be resolved. We build for aarch64-linux-android.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# OpenTUI 0.5.17 requires Zig 0.16.0 (specified in packages/native/build.zig.zon).
# Bun requires Zig 0.15.2. Use Zig 0.16.0 for OpenTUI.
if [ -n "${OPENTUI_ZIG_BIN:-}" ] && [ -x "$OPENTUI_ZIG_BIN" ]; then
    ZIG_BIN="$OPENTUI_ZIG_BIN"
elif [ -x "${WORK_DIR:-}/zig-0.16.0/zig" ]; then
    ZIG_BIN="${WORK_DIR}/zig-0.16.0/zig"
else
    ZIG_016_DIR="${WORK_DIR:-/tmp}/zig-0.16.0"
    if [ ! -x "$ZIG_016_DIR/zig" ]; then
        echo ">>> Installing Zig 0.16.0 for OpenTUI..."
        mkdir -p "$ZIG_016_DIR"
        curl -sSL "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz" | tar -xJ -C "$ZIG_016_DIR" --strip-components=1
    fi
    ZIG_BIN="$ZIG_016_DIR/zig"
fi

# Pin opentui to the exact version that OpenCode depends on.
# This commit corresponds to @opentui/core v0.5.17 (dereferenced tag).
OPENTUI_COMMIT="6f0efd3330978d696b42db3d7d95d2042008312b"

echo "=== Building libopentui.so for Android aarch64 ==="

# Clone opentui if needed
if [ ! -d "$OPENTUI_SRC/.git" ]; then
    echo ">>> Cloning opentui (commit $OPENTUI_COMMIT)..."
    git clone https://github.com/anomalyco/opentui.git "$OPENTUI_SRC"
    cd "$OPENTUI_SRC"
    git checkout "$OPENTUI_COMMIT"
else
    echo ">>> opentui source exists at $OPENTUI_SRC"
    # Ensure we are on the pinned commit
    cd "$OPENTUI_SRC"
    CURRENT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    if [ "$CURRENT" != "$OPENTUI_COMMIT" ]; then
        echo "    Resetting to pinned commit $OPENTUI_COMMIT (was $CURRENT)..."
        git fetch origin 2>/dev/null || true
        git checkout --force "$OPENTUI_COMMIT"
    fi
    git reset --hard "$OPENTUI_COMMIT" >/dev/null
fi

OPENTUI_PATCH="$REPO_ROOT/patches/opentui/android-libc-link.patch"
if [ -f "$OPENTUI_PATCH" ] && [ "${OPENTUI_SKIP_PATCH:-}" != "1" ]; then
    echo ">>> Checking opentui Android patch..."
    cd "$OPENTUI_SRC"
    if git apply --check "$OPENTUI_PATCH" 2>/dev/null; then
        git apply "$OPENTUI_PATCH"
        echo "    Patch applied successfully"
    elif git apply --check --reverse "$OPENTUI_PATCH" 2>/dev/null; then
        echo "    Patch already applied, skipping"
    else
        echo "    Notice: git patch does not apply (using packages/native layout), proceeding with runtime hooks"
    fi
else
    echo ">>> Skipping opentui Android patch"
fi

if [ -f "$OPENTUI_SRC/packages/native/build.zig" ]; then
    OPENTUI_ZIG_DIR="$OPENTUI_SRC/packages/native"
else
    OPENTUI_ZIG_DIR="$OPENTUI_SRC/packages/core/src/zig"
fi

if [ ! -f "$OPENTUI_ZIG_DIR/build.zig" ]; then
    echo "ERROR: build.zig not found at $OPENTUI_ZIG_DIR"
    exit 1
fi

# Prepare Zig dependencies archive (uucode, ghostty, yoga)
if [ -f "$OPENTUI_ZIG_DIR/scripts/prepare-zig-deps.sh" ]; then
    echo ">>> Preparing Zig dependencies (prepare-zig-deps.sh)..."
    sh "$OPENTUI_ZIG_DIR/scripts/prepare-zig-deps.sh"
elif [ -f "$OPENTUI_ZIG_DIR/src/vendor/zig-deps.tar.gz" ] && [ ! -d "$OPENTUI_ZIG_DIR/zig-deps" ]; then
    echo ">>> Extracting zig-deps.tar.gz..."
    mkdir -p "$OPENTUI_ZIG_DIR/zig-deps"
    tar -xzf "$OPENTUI_ZIG_DIR/src/vendor/zig-deps.tar.gz" -C "$OPENTUI_ZIG_DIR/zig-deps"
fi

if [ "${OPENTUI_SKIP_ANDROID_RUNTIME_PATCH:-}" != "1" ]; then
    echo ">>> Patching opentui Android runtime paths..."
    python3 - "$OPENTUI_ZIG_DIR" <<'PY'
import sys
from pathlib import Path

zig_dir = Path(sys.argv[1])
if (zig_dir / "src" / "lib.zig").exists():
    lib_zig = zig_dir / "src" / "lib.zig"
    span_feed_zig = zig_dir / "src" / "native-span-feed.zig"
    yoga_zig = zig_dir / "src" / "yoga.zig"
else:
    lib_zig = zig_dir / "lib.zig"
    span_feed_zig = zig_dir / "native-span-feed.zig"
    yoga_zig = zig_dir / "yoga.zig"


def replace_export_body(text: str, signature: str, body: str) -> str:
    start = text.find(signature)
    if start == -1:
        print(f"    Notice: signature not found: {signature[:50]}...")
        return text
    brace = text.find("{", start + len(signature))
    if brace == -1:
        print(f"    Notice: body not found for: {signature[:50]}...")
        return text
    depth = 0
    end = brace
    while end < len(text):
        char = text[end]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end += 1
                break
        end += 1
    return text[:brace] + "{\n" + body.rstrip() + "\n}" + text[end:]


lib_text = lib_zig.read_text()
audio_bodies = {
    "export fn createAudioEngine(options_ptr: ?*const native_audio.CreateOptions) NativeHandle": """    _ = options_ptr;
    return INVALID_HANDLE;""",
    "export fn audioRefreshPlaybackDevices(engine_handle: NativeHandle) i32": """    _ = engine_handle;
    return native_audio.Status.err_invalid;""",
    "export fn audioGetPlaybackDeviceCount(engine_handle: NativeHandle) u32": """    _ = engine_handle;
    return 0;""",
    "export fn audioGetPlaybackDeviceName(engine_handle: NativeHandle, index: u32, out_ptr: [*]u8, max_len: u32) u32": """    _ = engine_handle;
    _ = index;
    _ = out_ptr;
    _ = max_len;
    return 0;""",
    "export fn audioIsPlaybackDeviceDefault(engine_handle: NativeHandle, index: u32) bool": """    _ = engine_handle;
    _ = index;
    return false;""",
    "export fn audioSelectPlaybackDevice(engine_handle: NativeHandle, index: u32) i32": """    _ = engine_handle;
    _ = index;
    return native_audio.Status.err_invalid;""",
    "export fn audioClearPlaybackDeviceSelection(engine_handle: NativeHandle) void": """    _ = engine_handle;""",
    "export fn audioStart(engine_handle: NativeHandle, options_ptr: ?*const native_audio.StartOptions) i32": """    _ = engine_handle;
    _ = options_ptr;
    return native_audio.Status.err_invalid;""",
    "export fn audioStartMixer(engine_handle: NativeHandle) i32": """    _ = engine_handle;
    return native_audio.Status.err_invalid;""",
    "export fn audioStop(engine_handle: NativeHandle) i32": """    _ = engine_handle;
    return native_audio.Status.err_invalid;""",
    "export fn audioLoad(engine_handle: NativeHandle, data_ptr: ?[*]const u8, data_len: u32, out_sound_id: ?*u32) i32": """    _ = engine_handle;
    _ = data_ptr;
    _ = data_len;
    _ = out_sound_id;
    return native_audio.Status.err_invalid;""",
    "export fn audioUnload(engine_handle: NativeHandle, sound_id: u32) i32": """    _ = engine_handle;
    _ = sound_id;
    return native_audio.Status.err_invalid;""",
    "export fn audioPlay(engine_handle: NativeHandle, sound_id: u32, options_ptr: ?*const native_audio.VoiceOptions, out_voice_id: ?*u32) i32": """    _ = engine_handle;
    _ = sound_id;
    _ = options_ptr;
    _ = out_voice_id;
    return native_audio.Status.err_invalid;""",
    "export fn audioStopVoice(engine_handle: NativeHandle, voice_id: u32) i32": """    _ = engine_handle;
    _ = voice_id;
    return native_audio.Status.err_invalid;""",
    "export fn audioSetVoiceGroup(engine_handle: NativeHandle, voice_id: u32, group_id: u32) i32": """    _ = engine_handle;
    _ = voice_id;
    _ = group_id;
    return native_audio.Status.err_invalid;""",
    "export fn audioCreateGroup(engine_handle: NativeHandle, name_ptr: ?[*]const u8, name_len: u32, out_group_id: ?*u32) i32": """    _ = engine_handle;
    _ = name_ptr;
    _ = name_len;
    _ = out_group_id;
    return native_audio.Status.err_invalid;""",
    "export fn audioSetGroupVolume(engine_handle: NativeHandle, group_id: u32, volume: f32) i32": """    _ = engine_handle;
    _ = group_id;
    _ = volume;
    return native_audio.Status.err_invalid;""",
    "export fn audioSetMasterVolume(engine_handle: NativeHandle, volume: f32) i32": """    _ = engine_handle;
    _ = volume;
    return native_audio.Status.err_invalid;""",
    "export fn audioMixToBuffer(engine_handle: NativeHandle, out_ptr: ?[*]f32, frame_count: u32, channels: u8) i32": """    _ = engine_handle;
    _ = out_ptr;
    _ = frame_count;
    _ = channels;
    return native_audio.Status.err_invalid;""",
    "export fn audioEnableTap(engine_handle: NativeHandle, enabled: u8, capacity_frames: u32) i32": """    _ = engine_handle;
    _ = enabled;
    _ = capacity_frames;
    return native_audio.Status.err_invalid;""",
    "export fn audioReadTap(engine_handle: NativeHandle, out_ptr: ?[*]f32, frame_count: u32, channels: u8, out_frames_read: ?*u32) i32": """    _ = engine_handle;
    _ = out_ptr;
    _ = frame_count;
    _ = channels;
    _ = out_frames_read;
    return native_audio.Status.err_invalid;""",
    "export fn audioGetStats(engine_handle: NativeHandle, out_stats: ?*native_audio.Stats) i32": """    _ = engine_handle;
    _ = out_stats;
    return native_audio.Status.err_invalid;""",
}
for signature, body in audio_bodies.items():
    lib_text = replace_export_body(lib_text, signature, body)
lib_zig.write_text(lib_text)

span_text = span_feed_zig.read_text()
span_text = span_text.replace("        errdefer stream.destroy();", "        errdefer allocator.destroy(stream);")
span_text = replace_export_body(
    span_text,
    "pub export fn destroyNativeSpanFeed(stream: ?*Stream) void",
    "    _ = stream;",
)
span_feed_zig.write_text(span_text)

yoga_text = yoga_zig.read_text()
yoga_text = yoga_text.replace(
    "const callback_allocator = std.heap.c_allocator;",
    "const callback_allocator = std.heap.page_allocator;",
)
yoga_zig.write_text(yoga_text)

# Patch build.zig for Android compatibility:
# 1. Disable pthread/dl on Android (provided by libc.so)
# 2. Link Android NDK libc and libc++_shared
build_zig = zig_dir / "build.zig"
bz = build_zig.read_text()

old_audio = '''        .linux => {
            module.linkSystemLibrary("dl", .{});
            module.linkSystemLibrary("pthread", .{});
            module.linkSystemLibrary("m", .{});
        },'''
new_audio = '''        .linux => {
            if (target.result.abi != .android and target.result.abi != .androideabi) {
                module.linkSystemLibrary("dl", .{});
                module.linkSystemLibrary("pthread", .{});
            }
            module.linkSystemLibrary("m", .{});
        },'''
if old_audio in bz:
    bz = bz.replace(old_audio, new_audio)
    print(">>> build.zig: patched addNativeAudioDependencies (skipped pthread/dl on Android)")

old_translate = 'module.addImport("yoga", yoga_translate.createModule());'
new_translate = '''module.addImport("yoga", yoga_translate.createModule());

    if (target.result.os.tag == .linux and (target.result.abi == .android or target.result.abi == .androideabi)) {
        const ndk_home = if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |p| p else "/opt/android-ndk";
        const sysroot = std.fmt.allocPrint(b.allocator, "{s}/toolchains/llvm/prebuilt/linux-x86_64/sysroot", .{ndk_home}) catch unreachable;
        const inc1 = std.fmt.allocPrint(b.allocator, "{s}/usr/include", .{sysroot}) catch unreachable;
        const inc2 = std.fmt.allocPrint(b.allocator, "{s}/usr/include/aarch64-linux-android", .{sysroot}) catch unreachable;
        const inc_cxx = std.fmt.allocPrint(b.allocator, "{s}/usr/include/c++/v1", .{sysroot}) catch unreachable;
        miniaudio_translate.addSystemIncludePath(.{ .cwd_relative = inc1 });
        miniaudio_translate.addSystemIncludePath(.{ .cwd_relative = inc2 });
        yoga_translate.addSystemIncludePath(.{ .cwd_relative = inc1 });
        yoga_translate.addSystemIncludePath(.{ .cwd_relative = inc2 });
        yoga_translate.addSystemIncludePath(.{ .cwd_relative = inc_cxx });
        module.addSystemIncludePath(.{ .cwd_relative = inc1 });
        module.addSystemIncludePath(.{ .cwd_relative = inc2 });
        module.addSystemIncludePath(.{ .cwd_relative = inc_cxx });
    }'''
if old_translate in bz:
    bz = bz.replace(old_translate, new_translate, 1)
    print(">>> build.zig: added Android NDK system include paths for translate-c and module")

old_target = 'addYogaDependencies(b, module);'
new_target = '''addYogaDependencies(b, module);

    if (target.result.os.tag == .linux and (target.result.abi == .android or target.result.abi == .androideabi)) {
        module.link_libcpp = false;
        const ndk_home = if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |p| p else "/opt/android-ndk";
        const ndk_lib_dir = std.fmt.allocPrint(
            b.allocator,
            "{s}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/24",
            .{ndk_home},
        ) catch unreachable;
        module.addLibraryPath(.{ .cwd_relative = ndk_lib_dir });
        const ndk_cxx_dir = std.fmt.allocPrint(
            b.allocator,
            "{s}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android",
            .{ndk_home},
        ) catch unreachable;
        module.addLibraryPath(.{ .cwd_relative = ndk_cxx_dir });
        module.linkSystemLibrary("c", .{});
        module.linkSystemLibrary("c++_shared", .{});
    }'''
if old_target in bz:
    bz = bz.replace(old_target, new_target, 1)
    print(">>> build.zig: added Android NDK libc and libc++_shared linking in buildTarget")

if ".link_libc = true" not in bz and "module.link_libc = true" not in bz:
    old = ".optimize = optimize,\n    });"
    new = ".optimize = optimize,\n        .link_libc = true,\n    });"
    if old in bz:
        bz = bz.replace(old, new, 1)
        print(">>> build.zig: set .link_libc = true")
    else:
        print(">>> build.zig: note: default libc linking used")
build_zig.write_text(bz)
PY
fi

echo ">>> Building with Zig (target: aarch64-linux-android)..."
cd "$OPENTUI_ZIG_DIR"

# Zig 0.15.2 does not ship prebuilt Bionic libc. Provide a libc.txt that
# points at the NDK sysroot, then pass it via --libc. See ziglang/zig#23906.
NDK_HOME="${ANDROID_NDK_HOME:-/opt/android-ndk}"
NDK_SYSROOT="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
API_LEVEL="${ANDROID_API:-29}"
if [ ! -d "$NDK_SYSROOT/usr/lib/aarch64-linux-android/$API_LEVEL" ]; then
  AVAIL=$(ls "$NDK_SYSROOT/usr/lib/aarch64-linux-android/" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1)
  [ -n "$AVAIL" ] && API_LEVEL="$AVAIL"
fi
LIBC_TXT="$OPENTUI_ZIG_DIR/libc-android.txt"
{
  echo "include_dir=$NDK_SYSROOT/usr/include"
  echo "sys_include_dir=$NDK_SYSROOT/usr/include/aarch64-linux-android"
  echo "crt_dir=$NDK_SYSROOT/usr/lib/aarch64-linux-android/$API_LEVEL"
  echo "msvc_lib_dir="
  echo "kernel32_lib_dir="
  echo "gcc_dir="
} > "$LIBC_TXT"
echo ">>> Generated libc.txt for API $API_LEVEL:"
cat "$LIBC_TXT"

BUILD_ARGS=(-Doptimize=ReleaseFast --libc "$LIBC_TXT" --prefix .)
if grep -q "library-target" "$OPENTUI_ZIG_DIR/build.zig"; then
    BUILD_ARGS+=("-Dlibrary-target=aarch64-linux-android")
else
    BUILD_ARGS+=("-Dtarget=aarch64-linux-android")
fi

"$ZIG_BIN" build "${BUILD_ARGS[@]}" 2>&1

LIBOPENTUI=""
for candidate in \
    "$OPENTUI_ZIG_DIR/../lib/aarch64-linux-android/libopentui.so" \
    "$OPENTUI_ZIG_DIR/lib/aarch64-linux-android/libopentui.so" \
    "$OPENTUI_SRC/packages/core/src/lib/aarch64-linux-android/libopentui.so" \
    "$OPENTUI_SRC/packages/native/lib/aarch64-linux-android/libopentui.so" \
    "$OPENTUI_SRC/packages/lib/aarch64-linux-android/libopentui.so"
do
    if [ -f "$candidate" ]; then
        LIBOPENTUI="$candidate"
        break
    fi
done
if [ -z "$LIBOPENTUI" ]; then
    LIBOPENTUI=$(find "$OPENTUI_SRC" -name "libopentui.so" -type f 2>/dev/null | head -1)
fi

if [ -z "$LIBOPENTUI" ] || [ ! -f "$LIBOPENTUI" ]; then
    echo "ERROR: libopentui.so not found under $OPENTUI_SRC"
    find "$OPENTUI_SRC" -name "libopentui.so" -type f 2>/dev/null || true
    exit 1
fi

echo ""
echo "=== libopentui.so build complete ==="
echo "Output: $LIBOPENTUI"
echo "Size: $(du -h "$LIBOPENTUI" | cut -f1)"
file "$LIBOPENTUI"

# Show dynamic section for debugging. Android builds must include
# NEEDED: libc.so so dlopen() can resolve symbols such as getauxval.
echo ">>> Dynamic section of libopentui.so:"
readelf -d "$LIBOPENTUI" 2>/dev/null | grep -E "NEEDED|FLAGS|SONAME" || echo "    (no dynamic dependencies)"
if ! readelf -d "$LIBOPENTUI" 2>/dev/null | grep -q 'Shared library: \[libc\.so\]'; then
    echo ">>> Adding missing NEEDED: libc.so with patchelf..."
    if ! command -v patchelf >/dev/null 2>&1; then
        echo "ERROR: libopentui.so is missing NEEDED: libc.so and patchelf is unavailable"
        exit 1
    fi
    patchelf --add-needed libc.so "$LIBOPENTUI"
    readelf -d "$LIBOPENTUI" 2>/dev/null | grep -E "NEEDED|FLAGS|SONAME" || true
    if ! readelf -d "$LIBOPENTUI" 2>/dev/null | grep -q 'Shared library: \[libc\.so\]'; then
        echo "ERROR: failed to add NEEDED: libc.so"
        exit 1
    fi
fi

mkdir -p "$DIST_DIR" 2>/dev/null || true
cp "$LIBOPENTUI" "$DIST_DIR/libopentui.so"
echo ">>> Staged libopentui.so to $DIST_DIR/libopentui.so"
