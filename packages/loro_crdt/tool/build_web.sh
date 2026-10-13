#!/usr/bin/env bash
# Builds the web (wasm) version of the native library for wasm_ffi:
#   lib/src/web/loro_crdt_ffi.js    Emscripten glue (MODULARIZE factory)
#   lib/src/web/loro_crdt_ffi.wasm  the module itself
#
# Requires rustup and the Emscripten SDK. EMSDK may point at an emsdk
# checkout; ~/emsdk is used otherwise.
set -euo pipefail

cd "$(dirname "$0")/.."
PKG_DIR=$(pwd)
OUT_DIR="$PKG_DIR/lib/src/web"
TARGET=wasm32-unknown-emscripten

if ! command -v emcc >/dev/null 2>&1; then
  EMSDK_DIR=${EMSDK:-$HOME/emsdk}
  if [[ ! -f "$EMSDK_DIR/emsdk_env.sh" ]]; then
    echo "emcc not found. Install the Emscripten SDK (https://emscripten.org/docs/getting_started/downloads.html) or set EMSDK." >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  source "$EMSDK_DIR/emsdk_env.sh" >/dev/null
fi

TOOLCHAIN=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' native/rust-toolchain.toml)
rustup target add --toolchain "$TOOLCHAIN" "$TARGET" >/dev/null

# Only the static library is needed; emcc links it below. Rust's emscripten
# std unwinds with Emscripten's JS-based exceptions, so the final link enables
# exception catching (Rust panics become catchable LoroExceptions).
CARGO_PROFILE_RELEASE_OPT_LEVEL=s \
  rustup run "$TOOLCHAIN" cargo rustc \
    --release \
    --lib \
    --crate-type staticlib \
    --manifest-path native/Cargo.toml \
    --target "$TARGET" \
    --target-dir native/target/web

mkdir -p "$OUT_DIR"
emcc "native/target/web/$TARGET/release/libloro_crdt_ffi.a" \
  native/web/emscripten_shims.c \
  -o "$OUT_DIR/loro_crdt_ffi.js" \
  -Oz \
  --no-entry \
  -sDEFAULT_TO_CXX \
  -sDISABLE_EXCEPTION_CATCHING=0 \
  -sMODULARIZE=1 \
  -sEXPORT_NAME=loro_crdt_ffi \
  -sALLOW_MEMORY_GROWTH=1 \
  -sEXPORTED_RUNTIME_METHODS=HEAPU8 \
  -sEXPORTED_FUNCTIONS=@native/exports.txt

ls -l "$OUT_DIR"
