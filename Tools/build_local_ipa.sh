#!/bin/bash
# Build a public, unsigned IPA. Accessory identities are deliberately excluded.
set -euo pipefail
umask 077

project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_directory="${1:-$project_root/build/local-ipa}"
bundle_identifier="${TDS_LOCAL_BUNDLE_IDENTIFIER:-com.evandbg.carwithin.local}"

if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'This build requires macOS and Xcode; Linux cannot build the iOS target.' >&2
  exit 1
fi
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  printf '%s\n' 'An iPhoneOS SDK is required. Select a full Xcode installation first.' >&2
  exit 1
fi
if [[ ! "$bundle_identifier" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  printf '%s\n' 'TDS_LOCAL_BUNDLE_IDENTIFIER must be a reverse-DNS bundle identifier.' >&2
  exit 1
fi

# Never read, display, or bundle local credential staging files in this public build.
python3 "$project_root/Tools/verify_local_ipa.py" --check-source "$project_root"

mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
temporary_parent="${TDS_LOCAL_BUILD_TMP:-${TMPDIR:-/tmp}}"
build_work_directory="$(mktemp -d "$temporary_parent/carwithin-local.XXXXXX")"
trap 'rm -rf "$build_work_directory"' EXIT

xcodebuild \
  -project "$project_root/TDSCarKit.xcodeproj" \
  -scheme TDSCarKit \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_work_directory/DerivedData" \
  -resultBundlePath "$build_work_directory/Build.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  'CODE_SIGN_IDENTITY=' \
  'DEVELOPMENT_TEAM=' \
  "PRODUCT_BUNDLE_IDENTIFIER=$bundle_identifier" \
  build

app_path="$build_work_directory/DerivedData/Build/Products/Release-iphoneos/TDSCarKit.app"
if [[ ! -d "$app_path" ]]; then
  printf '%s\n' 'The expected iOS application bundle was not produced.' >&2
  exit 1
fi

mkdir -p "$build_work_directory/package/Payload"
/usr/bin/ditto "$app_path" "$build_work_directory/package/Payload/TDSCarKit.app"
ipa_path="$build_work_directory/CarWithin-Local-unsigned.ipa"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent --norsrc \
  "$build_work_directory/package/Payload" "$ipa_path"

source_commit="$(git -C "$project_root" rev-parse HEAD)"
xcode_version="$(xcodebuild -version)"
verification_arguments=(
  --ipa "$ipa_path"
  --bundle-id "$bundle_identifier"
  --display-name 'CarWithin Local'
  --commit "$source_commit"
  --xcode "$xcode_version"
  --metadata "$build_work_directory/build-info.json"
)
if [[ -n "$(git -C "$project_root" status --porcelain --untracked-files=all)" ]]; then
  verification_arguments+=(--dirty-source)
fi
python3 "$project_root/Tools/verify_local_ipa.py" "${verification_arguments[@]}"

# Only verified deliverables are copied to the upload directory.
mv "$ipa_path" "$output_directory/CarWithin-Local-unsigned.ipa"
mv "$build_work_directory/build-info.json" "$output_directory/build-info.json"
(
  cd "$output_directory"
  shasum -a 256 CarWithin-Local-unsigned.ipa > SHA256SUMS
)
printf 'Verified unsigned IPA: %s\n' "$output_directory/CarWithin-Local-unsigned.ipa"
printf '%s\n' 'Accessory authentication and physical-iPhone testing are still required.'
