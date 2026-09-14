#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
deps="$PWD/build/local-deps"
runtime="$PWD/Resources/LocalRuntime"
mkdir -p "$deps/include/sherpa-onnx/c-api" "$runtime"
fetch() {
  local url="$1" destination="$2" digest="$3"
  if [[ -f "$destination" ]] && [[ "$(shasum -a 256 "$destination" | cut -d ' ' -f 1)" == "$digest" ]]; then return; fi
  curl --fail --location --silent --show-error --retry 2 "$url" -o "$destination.download"
  [[ "$(shasum -a 256 "$destination.download" | cut -d ' ' -f 1)" == "$digest" ]] || { echo 'Native runtime checksum mismatch.' >&2; exit 1; }
  mv "$destination.download" "$destination"
}
fetch 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-universal2-shared-no-tts-lib.tar.bz2' "$deps/sherpa.tar.bz2" 'bdcc7c266d355697584dd4efb9dc766e45e18e87cec1fc553002a32cfcfab9a7'
fetch 'https://github.com/ggml-org/llama.cpp/releases/download/b10955/llama-b10955-xcframework.zip' "$deps/llama.zip" '94e66a3ac732b792a8680dba8f9c3cf47494f00773d03792f7cf5da8aaf514bb'
fetch 'https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/sherpa-onnx/c-api/c-api.h' "$deps/include/sherpa-onnx/c-api/c-api.h" '2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce'
sherpa="$deps/sherpa-onnx-v1.13.8-osx-universal2-shared-no-tts-lib"
frameworks="$deps/llama/build-apple/llama.xcframework/macos-arm64_x86_64"
[[ -f "$sherpa/lib/libsherpa-onnx-c-api.dylib" ]] || tar -xjf "$deps/sherpa.tar.bz2" -C "$deps"
[[ -d "$frameworks/llama.framework" ]] || unzip -qo "$deps/llama.zip" -d "$deps/llama"
cp "$sherpa/lib/libsherpa-onnx-c-api.dylib" "$sherpa/lib/libonnxruntime.dylib" "$runtime/"
ditto "$frameworks/llama.framework" "$runtime/llama.framework"
xcrun clang++ -std=c++17 -fobjc-arc -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -I "$deps/include" -I "$frameworks/llama.framework/Headers" \
  -F "$frameworks" -framework Foundation -framework llama \
  -L "$sherpa/lib" -lsherpa-onnx-c-api -Wl,-rpath,@executable_path \
  Native/LocalInference.mm -o "$runtime/livecopilot-inference"
for binary in "$runtime/libonnxruntime.dylib" "$runtime/libsherpa-onnx-c-api.dylib" "$runtime/llama.framework" "$runtime/livecopilot-inference"; do
  codesign --force --sign - "$binary" >/dev/null 2>&1
done
echo 'Native local inference runtime ready (arm64 + x86_64).'
