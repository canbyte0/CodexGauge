#!/usr/bin/env python3
"""Read-only consistency check for an installed Codex host and quota-button profile."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import sys
from pathlib import Path


def read_plist(path: Path) -> dict:
    with path.open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"Expected a plist dictionary: {path}")
    return value


def source_string(source: str, name: str) -> str:
    matches = re.findall(rf'\bstatic\s+let\s+{re.escape(name)}\s*=\s*"([^"]+)"', source)
    if not matches:
        raise ValueError(f"Missing Swift profile constant: {name}")
    # hostBundleIdentifier appears in both the testing and production branches;
    # the final literal belongs to the production #else branch.
    return matches[-1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-plist", required=True, type=Path)
    parser.add_argument("--candidate-plist", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--expected-candidate-version", default="0.1.0-a1-c12")
    args = parser.parse_args()

    host = read_plist(args.host_plist)
    candidate = read_plist(args.candidate_plist)
    source = args.source.read_text(encoding="utf-8")
    host_info_sha256 = hashlib.sha256(args.host_plist.read_bytes()).hexdigest()

    source_profile = {
        "bundleIdentifier": source_string(source, "hostBundleIdentifier"),
        "buildVersion": source_string(source, "supportedHostBuildVersion"),
        "shortVersion": source_string(source, "supportedHostShortVersion"),
        "infoPlistSHA256": source_string(source, "supportedHostInfoPlistSHA256"),
    }
    installed_host = {
        "bundleIdentifier": host.get("CFBundleIdentifier"),
        "buildVersion": host.get("CFBundleVersion"),
        "shortVersion": host.get("CFBundleShortVersionString"),
        "infoPlistSHA256": host_info_sha256,
    }
    candidate_profile = {
        "bundleIdentifier": candidate.get("QuotaHostProfileBundleIdentifier"),
        "buildVersion": candidate.get("QuotaHostProfileBuildVersion"),
        "shortVersion": candidate.get("QuotaHostProfileShortVersion"),
        "infoPlistSHA256": candidate.get("QuotaHostProfileInfoPlistSHA256"),
    }
    comparisons = {
        "installedHostMatchesSourceProfile": installed_host == source_profile,
        "candidateMetadataMatchesSourceProfile": candidate_profile == source_profile,
        "candidateIsAnchoredQuotaButton": candidate.get("CFBundleIdentifier") == "local.msl.QuotaButton.Anchored",
        "candidateVersionMatchesExpected": candidate.get("CFBundleShortVersionString") == args.expected_candidate_version,
    }
    result = {
        "status": "PASS" if all(comparisons.values()) else "FAIL",
        "readOnly": True,
        "hostPlist": str(args.host_plist),
        "candidatePlist": str(args.candidate_plist),
        "source": str(args.source),
        "installedHost": installed_host,
        "sourceProfile": source_profile,
        "candidateProfile": candidate_profile,
        "candidateIdentity": {
            "bundleIdentifier": candidate.get("CFBundleIdentifier"),
            "shortVersion": candidate.get("CFBundleShortVersionString"),
        },
        "expectedCandidateVersion": args.expected_candidate_version,
        "comparisons": comparisons,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"profile check failed: {error}", file=sys.stderr)
        raise SystemExit(2)
