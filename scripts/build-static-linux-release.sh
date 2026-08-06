#!/usr/bin/env bash

# Build and audit the native static Linux release binaries.
#
# Usage:
#   ./scripts/build-static-linux-release.sh [x86_64|aarch64]
#
# The GitHub release probe invokes this script too, so local and CI builds use
# the same Zig, OpenSSL, native dependency, linker, and ELF audit logic.

set -euo pipefail

readonly ZIG_VERSION="${ZIG_VERSION:-0.15.2}"
readonly OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.7}"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
requested_arch="${1:-$(uname -m)}"
host_arch="$(uname -m)"

case "$requested_arch" in
    x86_64)
        rust_target=x86_64-unknown-linux-musl
        zig_target=x86_64-linux-musl
        openssl_target=linux-x86_64
        arch_flags=()
        ;;
    aarch64|arm64)
        requested_arch=aarch64
        rust_target=aarch64-unknown-linux-musl
        zig_target=aarch64-linux-musl
        openssl_target=linux-aarch64
        arch_flags=(-mno-outline-atomics)
        ;;
    *)
        echo "error: unsupported target architecture: $requested_arch" >&2
        exit 1
        ;;
esac

case "$host_arch" in
    x86_64) zig_host_arch=x86_64 ;;
    aarch64|arm64) zig_host_arch=aarch64 ;;
    *)
        echo "error: unsupported host architecture: $host_arch" >&2
        exit 1
        ;;
esac

required_commands=(
    cargo
    clang
    cmake
    curl
    file
    make
    ninja
    perl
    pkg-config
    protoc
    readelf
    rustc
    rustup
    sed
    tar
)
for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "error: required command is missing: $command_name" >&2
        exit 1
    fi
done

if ! rustup target list --installed | grep -Fxq "$rust_target"; then
    echo "error: Rust target $rust_target is not installed" >&2
    echo "install it with: rustup target add $rust_target" >&2
    exit 1
fi

work_dir="$(mktemp -d -t agentenv-static-release.XXXXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

zig_archive="zig-${zig_host_arch}-linux-$ZIG_VERSION.tar.xz"
zig_dir="$work_dir/zig-$ZIG_VERSION"
echo "Downloading Zig $ZIG_VERSION for $zig_host_arch..."
curl -fsSL --retry 5 \
    "https://ziglang.org/download/$ZIG_VERSION/$zig_archive" \
    -o "$work_dir/$zig_archive"
mkdir -p "$zig_dir"
tar -xJf "$work_dir/$zig_archive" -C "$zig_dir" --strip-components=1
zig="$zig_dir/zig"

toolchain_dir="$work_dir/toolchain"
mkdir -p "$toolchain_dir"

write_compiler_wrapper() {
    local output=$1
    local mode=$2
    local flags=${arch_flags[*]:-}
    local compiler_template
    compiler_template='#!/usr/bin/env bash
set -euo pipefail
args=()
skip_next=false
for arg in "$@"; do
    if $skip_next; then
        skip_next=false
        continue
    fi
    case "$arg" in
        --target=*) continue ;;
        --target) skip_next=true; continue ;;
        *) args+=("$arg") ;;
    esac
done
exec "ZIG_PATH" COMPILER_MODE -target ZIG_TARGET ARCH_FLAGS "${args[@]}"
'
    printf '%s' "$compiler_template" > "$output"
    sed -i "s|ZIG_PATH|$zig|g; s|COMPILER_MODE|$mode|g; s|ZIG_TARGET|$zig_target|g; s|ARCH_FLAGS|$flags|g" "$output"
    chmod +x "$output"
}

write_compiler_wrapper "$toolchain_dir/musl-cc" cc
write_compiler_wrapper "$toolchain_dir/musl-cxx" c++

for tool_name in ar ranlib; do
    tool_wrapper="$toolchain_dir/musl-$tool_name"
    printf '#!/bin/sh\nexec "%s" %s "$@"\n' "$zig" "$tool_name" > "$tool_wrapper"
    chmod +x "$tool_wrapper"
done

linker_template='#!/usr/bin/env bash
set -euo pipefail
args=()
skip_next=false
for arg in "$@"; do
    if $skip_next; then
        skip_next=false
        continue
    fi
    case "$arg" in
        --target=*) continue ;;
        --target) skip_next=true; continue ;;
        */self-contained/*crt*.o) continue ;;
        -lstdc++) args+=("-lc++") ;;
        *) args+=("$arg") ;;
    esac
done
exec "ZIG_PATH" c++ -target ZIG_TARGET ARCH_FLAGS "${args[@]}"
'
printf '%s' "$linker_template" > "$toolchain_dir/musl-linker"
sed -i "s|ZIG_PATH|$zig|g; s|ZIG_TARGET|$zig_target|g; s|ARCH_FLAGS|${arch_flags[*]:-}|g" \
    "$toolchain_dir/musl-linker"
chmod +x "$toolchain_dir/musl-linker"

target_env_key="${rust_target//-/_}"
target_key="${rust_target^^}"
target_key="${target_key//-/_}"
export "CC_${target_env_key}=$toolchain_dir/musl-cc"
export "CXX_${target_env_key}=$toolchain_dir/musl-cxx"
export "AR_${target_env_key}=$toolchain_dir/musl-ar"
export "CARGO_TARGET_${target_key}_LINKER=$toolchain_dir/musl-linker"

echo "Probing the Zig musl C++ toolchain..."
printf '%s\n' \
    '#include <locale>' \
    '#include <random>' \
    '#include <string>' \
    'int main() { std::random_device r; std::locale l; std::string s = "musl"; return s.size() == 4 ? 0 : 1; }' \
    > "$work_dir/probe.cc"
"$toolchain_dir/musl-cxx" -static "$work_dir/probe.cc" -o "$work_dir/probe-cxx"

openssl_source_dir="$work_dir/openssl-$OPENSSL_VERSION"
openssl_install_dir="$work_dir/openssl-musl-$requested_arch"
openssl_archive="$work_dir/openssl-$OPENSSL_VERSION.tar.gz"
echo "Building static OpenSSL $OPENSSL_VERSION..."
curl -fsSL --retry 5 \
    "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" \
    -o "$openssl_archive"
tar -xzf "$openssl_archive" -C "$work_dir"

(
    cd "$openssl_source_dir"
    CC="$toolchain_dir/musl-cc" \
        AR="$toolchain_dir/musl-ar" \
        RANLIB="$toolchain_dir/musl-ranlib" \
        ./Configure \
        "$openssl_target" \
        no-shared \
        no-tests \
        no-module \
        --prefix="$openssl_install_dir" \
        --libdir=lib \
        "${arch_flags[@]}"
    make -j"$(nproc)" build_libs
    mkdir -p "$openssl_install_dir/include" "$openssl_install_dir/lib"
    cp -a include/openssl "$openssl_install_dir/include/"
    cp -a libcrypto.a libssl.a "$openssl_install_dir/lib/"
)

export OPENSSL_STATIC=1
export OPENSSL_DIR="$openssl_install_dir"
export OPENSSL_LIB_DIR="$openssl_install_dir/lib"
export OPENSSL_INCLUDE_DIR="$openssl_install_dir/include"
export PKG_CONFIG_ALLOW_CROSS=1

cd "$repo_dir"
echo "Building AgentENV static Linux binaries for $rust_target..."
cargo build --release --locked --target "$rust_target" -p aenv
cargo build --release --locked --target "$rust_target" \
    -p uvm-ublk-daemon --bin uvm-ublk-daemon
cargo build --release --locked --target "$rust_target" \
    -p agentenv --bin server

target_dir="$repo_dir/target/$rust_target/release"
binaries=(
    "$target_dir/aenv"
    "$target_dir/server"
    "$target_dir/uvm-ublk-daemon"
)

echo "Auditing static ELF outputs..."
for binary in "${binaries[@]}"; do
    test -x "$binary"
    file "$binary"
    if readelf -l "$binary" | grep -q INTERP; then
        echo "error: $binary contains an ELF interpreter" >&2
        exit 1
    fi
    if readelf -d "$binary" 2>&1 | grep -q NEEDED; then
        echo "error: $binary contains dynamic dependencies" >&2
        readelf -d "$binary" >&2
        exit 1
    fi
done

echo "Static Linux release build passed for $requested_arch."
