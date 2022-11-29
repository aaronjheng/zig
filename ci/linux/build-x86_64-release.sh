#!/bin/sh

# Requires cmake ninja-build

set -x
set -e

ARCH="$(uname -m)"
TARGET="$ARCH-linux-musl"
MCPU="baseline"
CACHE_BASENAME="zig+llvm+lld+clang-$TARGET-0.11.0-dev.256+271cc52a1"
PREFIX="$HOME/deps/$CACHE_BASENAME"
ZIG="$PREFIX/bin/zig" 

export PATH="$HOME/deps/wasmtime-v2.0.2-$ARCH-linux:$HOME/deps/qemu-linux-x86_64-6.1.0.1/bin:$PATH"

# Make the `zig version` number consistent.
# This will affect the cmake command below.
git config core.abbrev 9
git fetch --unshallow || true
git fetch --tags

export CC="$ZIG cc -target $TARGET -mcpu=$MCPU"
export CXX="$ZIG c++ -target $TARGET -mcpu=$MCPU"

rm -rf build-release
mkdir build-release
cd build-release
echo "::group:: Build Zig"
cmake .. \
  -DCMAKE_INSTALL_PREFIX="stage3-release" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DZIG_TARGET_TRIPLE="$TARGET" \
  -DZIG_TARGET_MCPU="$MCPU" \
  -DZIG_STATIC=ON \
  -GNinja

# Now cmake will use zig as the C/C++ compiler. We reset the environment variables
# so that installation and testing do not get affected by them.
unset CC
unset CXX

ninja install
echo "::endgroup::"

echo "Looking for non-conforming code formatting..."
stage3-release/bin/zig fmt --check .. \
  --exclude ../test/cases/ \
  --exclude ../build-debug \
  --exclude ../build-release

# simultaneously test building self-hosted without LLVM and with 32-bit arm
echo "::group:: zig build arm32"
stage3-release/bin/zig build -Dtarget=arm-linux-musleabihf
echo "::endgroup::"

echo "::group:: zig build test docs"
stage3-release/bin/zig build test docs \
  -fqemu \
  -fwasmtime \
  -Dstatic-llvm \
  -Dtarget=native-native-musl \
  --search-prefix "$PREFIX" \
  --zig-lib-dir "$(pwd)/../lib"
echo "::endgroup::"

# Look for HTML errors.
tidy --drop-empty-elements no -qe ../zig-cache/langref.html

# Produce the experimental std lib documentation.
stage3-release/bin/zig test ../lib/std/std.zig -femit-docs -fno-emit-bin --zig-lib-dir ../lib

echo "::group:: zig build stage4"
stage3-release/bin/zig build \
  --prefix stage4-release \
  -Denable-llvm \
  -Denable-stage1 \
  -Dno-lib \
  -Drelease \
  -Dstrip \
  -Dtarget=$TARGET \
  -Duse-zig-libcxx \
  -Dversion-string="$(stage3-release/bin/zig version)"
echo "::endgroup::"

# diff returns an error code if the files differ.
echo "If the following command fails, it means nondeterminism has been"
echo "introduced, making stage3 and stage4 no longer byte-for-byte identical."
diff stage3-release/bin/zig stage4-release/bin/zig