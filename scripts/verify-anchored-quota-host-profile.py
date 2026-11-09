#!/usr/bin/env python3
"""Read-only verification for legacy embedded profiles and external-JSON profiles."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import sys
from pathlib import Path
from typing import Any

TARGET_BUNDLE_ID = "com.openai.codex"
SCHEMA_VERSION = 1
MAX_CONFIG_BYTES = 65_536
ROOT_KEYS = {"schemaVersion", "profiles"}
PROFILE_KEYS = {"bundleIdentifier", "buildVersion", "shortVersion", "infoPlistSHA256"}
BUILD_PATTERN = re.compile(r"^[0-9]{1,64}$")
SHORT_VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){0,7}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
LEGACY_PROFILE_KEYS = (
    "QuotaHostProfileBundleIdentifier",
    "QuotaHostProfileBuildVersion",
    "QuotaHostProfileShortVersion",
    "QuotaHostProfileInfoPlistSHA256",
)


class VerificationError(ValueError):
    pass


def read_plist(path: Path) -> tuple[dict[str, Any], bytes]:
    raw = path.read_bytes()
    value = plistlib.loads(raw)
    if not isinstance(value, dict):
        raise VerificationError(f"Expected a plist dictionary: {path}")
    return value, raw


def source_string(source: str, name: str) -> str:
    matches = re.findall(rf'\bstatic\s+let\s+{re.escape(name)}\s*=\s*"([^"]+)"', source)
    if not matches:
        raise VerificationError(f"Missing Swift profile constant: {name}")
    # hostBundleIdentifier appears in test and production branches; production is last.
    return matches[-1]


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise VerificationError(f"Duplicate JSON field: {key}")
        result[key] = value
    return result


def decode_configuration(data: bytes) -> list[dict[str, str]]:
    if not data:
        raise VerificationError("Configuration is empty")
    if len(data) > MAX_CONFIG_BYTES:
        raise VerificationError("Configuration exceeds 64 KiB")
    try:
        document = json.loads(data.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError("Configuration is not valid UTF-8 JSON") from error
    if not isinstance(document, dict) or set(document) != ROOT_KEYS:
        raise VerificationError("Configuration must contain only schemaVersion and profiles")
    if type(document["schemaVersion"]) is not int or document["schemaVersion"] != SCHEMA_VERSION:
        raise VerificationError("Unsupported schemaVersion")
    profiles = document["profiles"]
    if not isinstance(profiles, list) or not profiles:
        raise VerificationError("profiles must be a nonempty array")
    seen: set[tuple[str, str, str]] = set()
    result: list[dict[str, str]] = []
    for index, profile in enumerate(profiles):
        if not isinstance(profile, dict) or set(profile) != PROFILE_KEYS:
            raise VerificationError(f"profiles[{index}] has incomplete or unknown fields")
        if any(not isinstance(profile[field], str) for field in PROFILE_KEYS):
            raise VerificationError(f"profiles[{index}] identity fields must be strings")
        if profile["bundleIdentifier"] != TARGET_BUNDLE_ID:
            raise VerificationError(f"profiles[{index}] has an unsupported bundle ID")
        if not BUILD_PATTERN.fullmatch(profile["buildVersion"]):
            raise VerificationError(f"profiles[{index}] buildVersion is malformed")
        if len(profile["shortVersion"].encode("utf-8")) > 128 or not SHORT_VERSION_PATTERN.fullmatch(profile["shortVersion"]):
            raise VerificationError(f"profiles[{index}] shortVersion is malformed")
        if not SHA256_PATTERN.fullmatch(profile["infoPlistSHA256"]):
            raise VerificationError(f"profiles[{index}] infoPlistSHA256 is malformed")
        identity_key = (profile["bundleIdentifier"], profile["buildVersion"], profile["shortVersion"])
        if identity_key in seen:
            raise VerificationError(f"profiles[{index}] is a duplicate or ambiguous version entry")
        seen.add(identity_key)
        result.append(profile)
    return result


def read_config_file(path: Path) -> list[dict[str, str]]:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise VerificationError(f"Configuration is not a regular file: {path}")
    if metadata.st_size > MAX_CONFIG_BYTES:
        raise VerificationError("Configuration exceeds 64 KiB")
    return decode_configuration(path.read_bytes())


def load_new_protocol_profiles(candidate_plist: Path, external_path: Path | None) -> tuple[list[dict[str, str]], str]:
    resource = candidate_plist.parent / "Resources/QuotaHostCompatibility.json"
    if external_path is not None and os.path.lexists(external_path):
        return read_config_file(external_path), "external"
    return read_config_file(resource), "bundled-default"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-plist", required=True, type=Path)
    parser.add_argument("--candidate-plist", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--legacy-source", type=Path,
                        help="Frozen legacy Swift profile source required when verifying an old embedded-profile candidate")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--external-config", type=Path,
                        help="Optional authoritative external JSON to verify; if absent, use the bundle default")
    parser.add_argument("--expected-candidate-version", default="0.1.0-a1-c12")
    args = parser.parse_args()

    result: dict[str, Any] = {"status": "FAIL", "readOnly": True}
    exit_code = 1
    try:
        host, host_bytes = read_plist(args.host_plist)
        candidate, _ = read_plist(args.candidate_plist)
        source = args.source.read_text(encoding="utf-8")
        source_bundle_id = source_string(source, "hostBundleIdentifier")
        host_identity = {
            "bundleIdentifier": host.get("CFBundleIdentifier"),
            "buildVersion": host.get("CFBundleVersion"),
            "shortVersion": host.get("CFBundleShortVersionString"),
            "infoPlistSHA256": hashlib.sha256(host_bytes).hexdigest(),
        }
        source_bundle_matches = source_bundle_id == TARGET_BUNDLE_ID
        candidate_bundle_matches = candidate.get("CFBundleIdentifier") == "local.msl.QuotaButton.Anchored"
        candidate_version_matches = candidate.get("CFBundleShortVersionString") == args.expected_candidate_version
        schema = candidate.get("QuotaHostCompatibilitySchemaVersion")
        legacy_presence = [key in candidate for key in LEGACY_PROFILE_KEYS]

        protocol: str
        profile_source: str
        profile_comparisons: dict[str, bool]
        if schema is not None:
            if type(schema) is not int or schema != SCHEMA_VERSION:
                raise VerificationError("Candidate declares an unsupported compatibility schema")
            if any(legacy_presence):
                raise VerificationError("Candidate mixes external-JSON and legacy host profile metadata")
            profiles, profile_source = load_new_protocol_profiles(args.candidate_plist, args.external_config)
            matches = any(
                all(profile[field] == host_identity[field] for field in PROFILE_KEYS)
                for profile in profiles
            )
            protocol = "external-json-v1"
            profile_comparisons = {"installedHostMatchesCompatibilityProfile": matches}
            candidate_profile: Any = {"profileCount": len(profiles), "configurationSource": profile_source}
        else:
            if not all(legacy_presence):
                raise VerificationError("Candidate has neither a complete legacy profile nor a supported JSON schema")
            candidate_profile = {
                "bundleIdentifier": candidate[LEGACY_PROFILE_KEYS[0]],
                "buildVersion": candidate[LEGACY_PROFILE_KEYS[1]],
                "shortVersion": candidate[LEGACY_PROFILE_KEYS[2]],
                "infoPlistSHA256": candidate[LEGACY_PROFILE_KEYS[3]],
            }
            matches = candidate_profile == host_identity
            protocol = "legacy-embedded-v1"
            profile_source = "candidate-info-plist"
            legacy_source_path = args.legacy_source or args.source
            legacy_source = legacy_source_path.read_text(encoding="utf-8")
            source_profile = {
                "bundleIdentifier": source_string(legacy_source, "hostBundleIdentifier"),
                "buildVersion": source_string(legacy_source, "supportedHostBuildVersion"),
                "shortVersion": source_string(legacy_source, "supportedHostShortVersion"),
                "infoPlistSHA256": source_string(legacy_source, "supportedHostInfoPlistSHA256"),
            }
            profile_comparisons = {
                "installedHostMatchesSourceProfile": source_profile == host_identity,
                "candidateMetadataMatchesSourceProfile": candidate_profile == source_profile,
            }

        comparisons = {
            "sourceTargetsCodexBundle": source_bundle_matches,
            "candidateIsAnchoredQuotaButton": candidate_bundle_matches,
            "candidateVersionMatchesExpected": candidate_version_matches,
            **profile_comparisons,
        }
        result = {
            "status": "PASS" if all(comparisons.values()) else "FAIL",
            "readOnly": True,
            "hostPlist": str(args.host_plist),
            "candidatePlist": str(args.candidate_plist),
            "source": str(args.source),
            "protocol": protocol,
            "profileSource": profile_source,
            "legacySource": str(args.legacy_source or args.source) if protocol == "legacy-embedded-v1" else None,
            "sourceProfile": source_profile if protocol == "legacy-embedded-v1" else None,
            "installedHost": host_identity,
            "candidateProfile": candidate_profile,
            "candidateIdentity": {
                "bundleIdentifier": candidate.get("CFBundleIdentifier"),
                "shortVersion": candidate.get("CFBundleShortVersionString"),
            },
            "expectedCandidateVersion": args.expected_candidate_version,
            "comparisons": comparisons,
        }
        exit_code = 0 if result["status"] == "PASS" else 1
    except (OSError, ValueError, plistlib.InvalidFileException, VerificationError) as error:
        result["error"] = str(error)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
