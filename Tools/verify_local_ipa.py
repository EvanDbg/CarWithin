#!/usr/bin/env python3
"""Validate the public IPA without reading or printing credential file contents."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import sys
import zipfile


CREDENTIAL_SUFFIXES = {
    ".cer", ".crt", ".der", ".key", ".p7b", ".p7c", ".p8", ".pk8",
    ".p12", ".pfx", ".pem", ".x963", ".mobileprovision", ".provisionprofile",
}
CREDENTIAL_DIRECTORIES = {"bundledidentity", "identityimport", "mfi", "offline-mfi"}
MACH_O_MAGICS = {
    b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",  # 64-bit Mach-O
    b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",  # 32-bit Mach-O
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",  # universal Mach-O
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",  # universal Mach-O 64
}


class VerificationError(ValueError):
    pass


def check_source(root: Path) -> None:
    """Reject credential staging before Xcode can copy it into any build output."""
    locations = (
        root / "App" / "BundledIdentity",
        root / ".local",
        root / "IdentityImport",
        root / "mfi",
        root / "offline-mfi",
    )
    for location in locations:
        if location.is_symlink():
            raise VerificationError("A credential staging path is a symbolic link; public build refused.")
        if location.exists() and any(path.is_file() or path.is_symlink() for path in location.rglob("*")):
            raise VerificationError("Local accessory credential staging is present; public build refused.")


def inspect_ipa(path: Path, bundle_id: str, display_name: str) -> dict:
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)):
            raise VerificationError("The IPA contains duplicate ZIP entries.")
        for entry in entries:
            member = PurePosixPath(entry.filename)
            if member.is_absolute() or ".." in member.parts or "\\" in entry.filename:
                raise VerificationError("The IPA contains an invalid archive path.")
            parts = {part.casefold() for part in member.parts}
            if member.suffix.casefold() in CREDENTIAL_SUFFIXES or parts & CREDENTIAL_DIRECTORIES:
                raise VerificationError("The IPA contains a credential file or staging directory; upload refused.")
            if "_codesignature" in parts or member.name.casefold() == "embedded.mobileprovision":
                raise VerificationError("The public IPA must not contain Apple signing or provisioning files.")

        plists = [name for name in names if len(PurePosixPath(name).parts) == 3
                  and PurePosixPath(name).parts[0] == "Payload"
                  and PurePosixPath(name).parts[1].endswith(".app")
                  and PurePosixPath(name).name == "Info.plist"]
        if len(plists) != 1:
            raise VerificationError("Expected exactly one application Info.plist under Payload.")
        info_entry = archive.getinfo(plists[0])
        if info_entry.file_size > 1_048_576:
            raise VerificationError("The application Info.plist is unexpectedly large.")
        info = plistlib.loads(archive.read(plists[0]))
        if info.get("CFBundleIdentifier") != bundle_id:
            raise VerificationError("The IPA bundle identifier does not match the local edition.")
        if info.get("CFBundleDisplayName") != display_name:
            raise VerificationError("The IPA display name does not match the local edition.")
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise VerificationError("Expected a physical-iPhone build, not a simulator or Catalyst bundle.")

        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable or PurePosixPath(executable).name != executable:
            raise VerificationError("The app executable name is invalid.")
        executable_path = str(PurePosixPath(plists[0]).parent / executable)
        with archive.open(executable_path) as binary:
            if binary.read(4) not in MACH_O_MAGICS:
                raise VerificationError("The application does not contain a Mach-O executable.")

        return {
            "bundle_identifier": info["CFBundleIdentifier"],
            "display_name": info["CFBundleDisplayName"],
            "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"),
            "minimum_ios": info.get("MinimumOSVersion"),
            "platform": "iPhoneOS",
            "archive_entries": len(entries),
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check-source", type=Path)
    mode.add_argument("--ipa", type=Path)
    parser.add_argument("--bundle-id", default="com.evandbg.carwithin.local")
    parser.add_argument("--display-name", default="CarWithin Local")
    parser.add_argument("--commit", default="unknown")
    parser.add_argument("--dirty-source", action="store_true")
    parser.add_argument("--xcode", default="unknown")
    parser.add_argument("--metadata", type=Path)
    args = parser.parse_args()

    try:
        if args.check_source:
            check_source(args.check_source)
            print("Public-build input check passed: no staged accessory credentials.")
            return 0
        report = inspect_ipa(args.ipa, args.bundle_id, args.display_name)
        digest = hashlib.sha256()
        with args.ipa.open("rb") as ipa_file:
            for chunk in iter(lambda: ipa_file.read(1024 * 1024), b""):
                digest.update(chunk)
        report.update({
            "schema_version": 1,
            "source_commit": args.commit,
            "source_tree_dirty": args.dirty_source,
            "built_at_utc": datetime.now(timezone.utc).isoformat(),
            "xcode": args.xcode,
            "ipa_sha256": digest.hexdigest(),
            "apple_code_signing": "disabled",
            "accessory_identity": "not_bundled",
            "physical_iphone_validation": "not_performed_by_ci",
            "verification": "archive_structure_and_known_credential_paths",
        })
        if args.metadata:
            args.metadata.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("IPA verified: local-edition metadata, iPhoneOS executable, no credential or signing files.")
        return 0
    except (VerificationError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        if isinstance(error, VerificationError):
            print(f"Verification failed: {error}", file=sys.stderr)
        else:
            # Do not print file contents or exception payloads from an unexpected archive.
            print(f"Verification failed ({type(error).__name__}); no IPA will be uploaded.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
