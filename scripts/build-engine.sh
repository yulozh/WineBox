#!/bin/bash
# 构建 YuixServer 内置 Linux 引擎（OpenMinis/ish-arm64 @ 89269e6，GPLv2）
#
# 产物：engine/build/libish.a、libish_emu.a、libfakefs.a（iOS arm64 静态库）
# 用法：在 macOS（本机或 GitHub Actions macos-15）上执行
#   brew install meson ninja llvm
#   ./scripts/build-engine.sh
#
# 原理：与上游 iSH Xcode 工程的 xcode-meson.sh 完全一致 ——
#   用 SDKROOT=iphoneos 的环境运行 meson，使 clang 以 iOS arm64 为目标，
#   meson cross-file 关闭 exe_wrapper（纯交叉编译，只产静态库）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine"
BUILD="$ENGINE/build"

# ---- 依赖检查 ----
for tool in meson ninja clang python3; do
    command -v "$tool" >/dev/null || { echo "缺少 $tool，请先: brew install meson ninja llvm"; exit 1; }
done

# ---- iOS 交叉编译环境（模拟 Xcode 的构建环境）----
export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
export IPHONEOS_DEPLOYMENT_TARGET=16.0
# brew llvm 优先：vdso 需要带 lld 的 clang（-target aarch64-linux-gnu -fuse-ld=lld）
for P in /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin; do
    [ -d "$P" ] && export PATH="$P:$PATH"
done
echo "SDKROOT=$SDKROOT"
echo "clang:  $(command -v clang)"

mkdir -p "$BUILD"
CROSS="$BUILD/cross-ios-arm64.txt"
cat > "$CROSS" <<EOF
[binaries]
c = 'clang'
ar = 'ar'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-arch', 'arm64', '-miphoneos-version-min=16.0']
c_link_args = ['-arch', 'arm64']

[properties]
needs_exe_wrapper = true
EOF

# ---- meson 配置（arm64 guest + ish 内核 + asbestos 引擎，日志走 nslog）----
cd "$ENGINE"
meson setup build --cross-file "$CROSS" \
    -Dguest_arch=arm64 \
    -Dkernel=ish \
    -Dengine=asbestos \
    -Dlog_handler=nslog \
    -Dbuildtype=debugoptimized \
    --reconfigure 2>/dev/null || \
meson setup build --cross-file "$CROSS" \
    -Dguest_arch=arm64 \
    -Dkernel=ish \
    -Dengine=asbestos \
    -Dlog_handler=nslog \
    -Dbuildtype=debugoptimized

# ---- 只构建三个静态库（fakefsify/libarchive 等工具不需要）----
ninja -C build libish.a libish_emu.a libfakefs.a

echo ""
echo "✓ 引擎构建完成："
ls -la "$BUILD"/libish.a "$BUILD"/libish_emu.a "$BUILD"/libfakefs.a
