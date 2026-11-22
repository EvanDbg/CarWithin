#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d /private/tmp/carwithin-network.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="$work_dir/clang-cache"
xcrun clang -c "$project_root/Sources/CTDSCarKitCrypto/TDSCarKitCrypto.c" \
  -I "$project_root/Sources/CTDSCarKitCrypto/include" -o "$work_dir/crypto.o"
xcrun swiftc -O -parse-as-library -swift-version 5 \
  -module-cache-path "$work_dir/swift-cache" \
  -import-objc-header "$project_root/Sources/CTDSCarKitCrypto/include/TDSCarKitCrypto.h" \
  "$project_root"/Sources/TDSCarKitCore/*.swift \
  "$project_root"/Sources/TDSCarKitCore/Vendor/BigInt/*.swift \
  "$project_root/App/MediaSockets.swift" "$project_root/App/CarPlayAudio.swift" \
  "$project_root/Tools/LocalNetworkSmoke.swift" "$work_dir/crypto.o" -o "$work_dir/network-test"
"$work_dir/network-test"
