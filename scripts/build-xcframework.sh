#!/usr/bin/env bash

set -e # immediately terminate script on any failure conditions
set -x # echo script commands for easier debugging

THIS_SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
# ^^ provides an absolutely local path to where the script is being invoked,
# which lets us target further build commands specific to a directory
# srtucture.
# example: /Users/heckj/src/y-uniffi/scripts
pushd "$THIS_SCRIPT_DIR/../lib"

PACKAGE_NAME="yniffi"
LIB_NAME="libuniffi_yniffi.a"

# *IMPORTANT*: When changing this value, change them in `swift/pkg/YNative.h` and `swift/pkg/Info.plist` as well
FRAMEWORK_NAME="yniffiFFI"

SWIFT_FOLDER="swift"
BUILD_FOLDER="target"

XCFRAMEWORK_FOLDER="${FRAMEWORK_NAME}.xcframework"

# currently macabi/Catalyst target has no prebuild rust-std library hence we use `-Z build-std`
# how to build-std: https://doc.rust-lang.org/nightly/cargo/reference/unstable.html#build-std
# list of targets with prebuild rust-std https://doc.rust-lang.org/nightly/rustc/platform-support.html

# The specific issue with an earlier nightly version and linking into an
# XCFramework appears to be resolved with latest versions of +nightly toolchain
# (as of 10/10/23), but leaving it open to float seems less useful than
# moving the pinning forward, since Catalyst support (target macabi) still
# requires an active, nightly toolchain.
RUST_NIGHTLY="nightly-2024-05-23"

echo "Install nightly and rust-src for Catalyst"
rustup toolchain install ${RUST_NIGHTLY}
rustup component add rust-src --toolchain ${RUST_NIGHTLY}
rustup update
rustup default ${RUST_NIGHTLY}

echo "▸ Install toolchains"
rustup target add x86_64-apple-ios # iOS Simulator (Intel)
rustup target add aarch64-apple-ios-sim # iOS Simulator (M1)
rustup target add aarch64-apple-ios # iOS Device
rustup target add aarch64-apple-darwin # macOS ARM/M1
rustup target add x86_64-apple-darwin # macOS Intel/x86

echo "▸ Clean state"
rm -rf "${BUILD_FOLDER}"
rm -rf "${XCFRAMEWORK_FOLDER}"

mkdir -p "${SWIFT_FOLDER}/scaffold"
echo "▸ Generate Swift Scaffolding Code"
cargo run --manifest-path "./Cargo.toml"  \
    --features=uniffi/cli \
    --bin uniffi-bindgen generate \
    "./src/yniffi.udl" \
    --language swift \
    --out-dir "${SWIFT_FOLDER}/scaffold"

echo "▸ Building for x86_64-apple-ios"
CFLAGS_x86_64_apple_ios="-target x86_64-apple-ios" \
cargo build --target x86_64-apple-ios --package "${PACKAGE_NAME}" --locked --release

echo "▸ Building for aarch64-apple-ios-sim"
CFLAGS_aarch64_apple_ios="-target aarch64-apple-ios-sim" \
cargo build --target aarch64-apple-ios-sim --package "${PACKAGE_NAME}" --locked --release

echo "▸ Building for aarch64-apple-ios"
CFLAGS_aarch64_apple_ios="-target aarch64-apple-ios" \
cargo build --target aarch64-apple-ios --package "${PACKAGE_NAME}" --locked --release

echo "▸ Building for aarch64-apple-darwin"
CFLAGS_aarch64_apple_darwin="-target aarch64-apple-darwin" \
cargo build --target aarch64-apple-darwin --package "${PACKAGE_NAME}" --locked --release

echo "▸ Building for x86_64-apple-darwin"
CFLAGS_x86_64_apple_darwin="-target x86_64-apple-darwin" \
cargo build --target x86_64-apple-darwin --package "${PACKAGE_NAME}" --locked --release

echo "▸ Building for aarch64-apple-ios-macabi"
cargo "+${RUST_NIGHTLY}" build -Zbuild-std=std --target aarch64-apple-ios-macabi --package "${PACKAGE_NAME}" --locked --release

echo "▸ Building for x86_64-apple-ios-macabi"
cargo "+${RUST_NIGHTLY}" build -Zbuild-std=std --target x86_64-apple-ios-macabi --package "${PACKAGE_NAME}" --locked --release

echo "▸ Consolidating the headers and modulemaps for XCFramework generation"
mkdir -p "${BUILD_FOLDER}/includes/yniffiFFI"
cp "${SWIFT_FOLDER}/scaffold/yniffiFFI.h" "${BUILD_FOLDER}/includes/yniffiFFI/yniffiFFI.h"
cp "${SWIFT_FOLDER}/scaffold/yniffiFFI.modulemap" "${BUILD_FOLDER}/includes/yniffiFFI/module.modulemap"

mkdir -p "${BUILD_FOLDER}/ios-simulator/release"
echo "▸ Lipo (merge) x86 and arm simulator static libraries into a fat static binary"
lipo -create  \
    "./${BUILD_FOLDER}/x86_64-apple-ios/release/${LIB_NAME}" \
    "./${BUILD_FOLDER}/aarch64-apple-ios-sim/release/${LIB_NAME}" \
    -output "${BUILD_FOLDER}/ios-simulator/release/${LIB_NAME}"

mkdir -p "${BUILD_FOLDER}/apple-darwin/release"
echo "▸ Lipo (merge) x86 and arm macOS static libraries into a fat static binary"
lipo -create  \
    "./${BUILD_FOLDER}/x86_64-apple-darwin/release/${LIB_NAME}" \
    "./${BUILD_FOLDER}/aarch64-apple-darwin/release/${LIB_NAME}" \
    -output "${BUILD_FOLDER}/apple-darwin/release/${LIB_NAME}"

echo "▸ Lipo (merge) x86 and arm macOS Catalyst static libraries into a fat static binary"
mkdir -p "${BUILD_FOLDER}/apple-macabi/release"
lipo -create  \
    "${BUILD_FOLDER}/x86_64-apple-ios-macabi/release/${LIB_NAME}" \
    "${BUILD_FOLDER}/aarch64-apple-ios-macabi/release/${LIB_NAME}" \
    -output "${BUILD_FOLDER}/apple-macabi/release/${LIB_NAME}"

# what docs there are:
# xcodebuild -create-xcframework -help
# https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle

xcodebuild -create-xcframework \
    -library "./$BUILD_FOLDER/aarch64-apple-ios/release/$LIB_NAME" \
    -headers "./${BUILD_FOLDER}/includes" \
    -library "./${BUILD_FOLDER}/ios-simulator/release/${LIB_NAME}" \
    -headers "./${BUILD_FOLDER}/includes" \
    -library "./${BUILD_FOLDER}/apple-darwin/release/${LIB_NAME}" \
    -headers "./${BUILD_FOLDER}/includes" \
    -library "./$BUILD_FOLDER/apple-macabi/release/$LIB_NAME" \
    -headers "./${BUILD_FOLDER}/includes" \
    -output "./${XCFRAMEWORK_FOLDER}"

# echo "▸ Compress xcframework"
ditto -c -k --sequesterRsrc --keepParent "$XCFRAMEWORK_FOLDER" "$XCFRAMEWORK_FOLDER.zip"

# echo "▸ Compute checksum"
openssl dgst -sha256 "$XCFRAMEWORK_FOLDER.zip"
