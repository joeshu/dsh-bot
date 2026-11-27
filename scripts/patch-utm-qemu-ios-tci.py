#!/usr/bin/env python3
"""Apply the pinned, minimal iOS TCI build changes to the UTM build helper."""

from pathlib import Path
import sys


def replace_once(source: str, old: str, new: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"Expected one upstream patch anchor, found {count}: {old[:100]!r}")
    return source.replace(old, new)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {Path(sys.argv[0]).name} <UTM-source-directory>")
    upstream = Path(sys.argv[1]).resolve()
    script = upstream / "scripts" / "build_dependencies.sh"
    if not script.is_file() or not (upstream / "patches" / "sources").is_file():
        raise SystemExit(f"Not a UTM source checkout: {upstream}")
    source = script.read_text()

    source = replace_once(
        source,
        """check_env () {
    command -v brew >/dev/null 2>&1 || { echo >&2 "${RED}Homebrew is required to be installed.${NC}"; exit 1; }
""",
        """check_env () {
    if [ -n "$MINIMAL_TCI" ]; then
        if [ -z "$SOURCE_HASH_LOCK" ] || [ ! -f "$SOURCE_HASH_LOCK" ]; then
            echo "Minimal TCI build requires SOURCE_HASH_LOCK" >&2
            exit 1
        fi
        for tool in python3 meson ninja bison flex glib-mkenums glib-compile-resources gdbus-codegen xcrun otool install_name_tool shasum; do
            command -v "$tool" >/dev/null 2>&1 || { echo >&2 "${RED}Required minimal-TCI build tool missing: $tool${NC}"; exit 1; }
        done
        BISON_VERSION="$(bison -V | head -1 | awk '{ print $NF }')"
        python3 -c 'import sys; v=tuple(map(int, sys.argv[1].split(".")[:2])); sys.exit(v < (2, 4))' "$BISON_VERSION" || { echo >&2 "${RED}'bison' >= 2.4 is required.${NC}"; exit 1; }
        return
    fi
    command -v brew >/dev/null 2>&1 || { echo >&2 "${RED}Homebrew is required to be installed.${NC}"; exit 1; }
""",
    )
    source = replace_once(
        source,
        """        mv "$FILE" "$TARGET"
    fi
    if [ -d "$DIR" ]; then
""",
        """        mv "$FILE" "$TARGET"
    fi
    if [ -n "$MINIMAL_TCI" ]; then
        EXPECTED_SHA="$(awk -v name="$FILE" '$2 == name {print $1}' "$SOURCE_HASH_LOCK")"
        if [ "${#EXPECTED_SHA}" -ne 64 ]; then
            echo "Missing SHA-256 entry for $FILE in $SOURCE_HASH_LOCK" >&2
            exit 1
        fi
        ACTUAL_SHA="$(shasum -a 256 "$TARGET" | awk '{print $1}')"
        if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
            echo "SHA-256 mismatch for $FILE: expected $EXPECTED_SHA, got $ACTUAL_SHA" >&2
            exit 1
        fi
    fi
    if [ -d "$DIR" ]; then
""",
    )
    source = replace_once(
        source,
        """download_all () {
    [ -d "$BUILD_DIR" ] || mkdir -p "$BUILD_DIR"
    download $PKG_CONFIG_SRC
""",
        """download_all () {
    [ -d "$BUILD_DIR" ] || mkdir -p "$BUILD_DIR"
    if [ -n "$MINIMAL_TCI" ]; then
        download $PKG_CONFIG_SRC
        download $FFI_SRC
        download $ICONV_SRC
        download $GLIB_SRC
        download $PIXMAN_SRC
        download $SLIRP_SRC
        download $QEMU_SRC
        return
    fi
    download $PKG_CONFIG_SRC
""",
    )
    source = replace_once(
        source,
        """build_qemu_dependencies () {
    build $FFI_SRC
""",
        """build_qemu_dependencies () {
    if [ -n "$MINIMAL_TCI" ]; then
        build $FFI_SRC
        build $ICONV_SRC
        meson_build $GLIB_SRC -Dtests=false -Ddtrace=disabled -Dnls=disabled -Dintrospection=disabled
        build $PIXMAN_SRC
        meson_darwin_build $SLIRP_SRC
        return
    fi
    build $FFI_SRC
""",
    )
    source = replace_once(
        source,
        """        if [ "$ARCH" == "arm64" ]; then
            TCI_BUILD_FLAGS="--enable-tcg-threaded-interpreter --target-list=aarch64-softmmu,i386-softmmu,ppc-softmmu,ppc64-softmmu,riscv64-softmmu,x86_64-softmmu,m68k-softmmu --extra-cflags=-Wno-unused-command-line-argument --extra-ldflags=-Wl,-no_deduplicate --extra-ldflags=-Wl,-random_uuid --extra-ldflags=-Wl,-no_compact_unwind"
""",
        """        if [ "$ARCH" == "arm64" ]; then
            if [ -n "$MINIMAL_TCI" ]; then
                HVF_FLAGS="--disable-hvf"
                TCI_BUILD_FLAGS="--enable-tcg-threaded-interpreter --target-list=aarch64-softmmu --extra-cflags=-Wno-unused-command-line-argument --extra-ldflags=-Wl,-no_deduplicate --extra-ldflags=-Wl,-random_uuid --extra-ldflags=-Wl,-no_compact_unwind"
            else
                TCI_BUILD_FLAGS="--enable-tcg-threaded-interpreter --target-list=aarch64-softmmu,i386-softmmu,ppc-softmmu,ppc64-softmmu,riscv64-softmmu,x86_64-softmmu,m68k-softmmu --extra-cflags=-Wno-unused-command-line-argument --extra-ldflags=-Wl,-no_deduplicate --extra-ldflags=-Wl,-random_uuid --extra-ldflags=-Wl,-no_compact_unwind"
            fi
""",
    )
    source = replace_once(
        source,
        """    QEMU_PLATFORM_BUILD_FLAGS="--enable-shared-lib --disable-cocoa --disable-sdl --disable-coreaudio --disable-slirp-smbd --enable-ucontext --with-coroutine=libucontext $HVF_FLAGS $TCI_BUILD_FLAGS"
""",
        """    QEMU_PLATFORM_BUILD_FLAGS="--enable-shared-lib --disable-cocoa --disable-sdl --disable-coreaudio --disable-slirp-smbd --enable-ucontext --with-coroutine=libucontext $HVF_FLAGS $TCI_BUILD_FLAGS"
    if [ -n "$MINIMAL_TCI" ]; then
        QEMU_PLATFORM_BUILD_FLAGS="$QEMU_PLATFORM_BUILD_FLAGS --enable-slirp --disable-docs --disable-gettext --disable-spice --disable-gtk --disable-vnc --disable-usb-redir --disable-opengl --disable-virglrenderer --disable-virtfs"
    fi
""",
    )
    source = replace_once(
        source,
        """build_qemu_dependencies
build $QEMU_DIR --cross-prefix="" $QEMU_PLATFORM_BUILD_FLAGS $QEMU_DEBUG_FLAGS
build_spice_client
build_vulkan_drivers
build_d3d_drivers
fixup_all
remove_shared_gst_plugins # another hack...
""",
        """build_qemu_dependencies
build $QEMU_DIR --cross-prefix="" $QEMU_PLATFORM_BUILD_FLAGS $QEMU_DEBUG_FLAGS
if [ -z "$MINIMAL_TCI" ]; then
    build_spice_client
    build_vulkan_drivers
    build_d3d_drivers
fi
fixup_all
if [ -z "$MINIMAL_TCI" ]; then
    remove_shared_gst_plugins # another hack...
fi
""",
    )

    script.write_text(source)
    print(f"Applied minimal iOS TCI build configuration to {script}")


if __name__ == "__main__":
    main()
