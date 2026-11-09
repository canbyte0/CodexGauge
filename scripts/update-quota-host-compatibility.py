#!/usr/bin/env python3
"""Display or explicitly approve the current Codex host compatibility profile."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import tempfile
from pathlib import Path
from typing import Any

TARGET_BUNDLE_ID = "com.openai.codex"
SCHEMA_VERSION = 1
MAX_CONFIG_BYTES = 65_536
DEFAULT_CONFIG = Path.home() / "Library/Application Support/CodexGauge/host-compatibility.json"
EXPECTED_ROOT_KEYS = {"schemaVersion", "profiles"}
EXPECTED_PROFILE_KEYS = {"bundleIdentifier", "buildVersion", "shortVersion", "infoPlistSHA256"}
BUILD_PATTERN = re.compile(r"^[0-9]{1,64}$")
SHORT_VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){0,7}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class ConfigError(ValueError):
    pass


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ConfigError(f"JSON 对象含重复字段：{key}")
        result[key] = value
    return result


def decode_config(data: bytes) -> dict[str, Any]:
    if not data:
        raise ConfigError("配置文件为空")
    if len(data) > MAX_CONFIG_BYTES:
        raise ConfigError("配置文件超过 64 KiB 限制")
    try:
        document = json.loads(data.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ConfigError("配置不是有效 UTF-8 JSON") from error
    if not isinstance(document, dict) or set(document) != EXPECTED_ROOT_KEYS:
        raise ConfigError("顶层字段必须且只能包含 schemaVersion、profiles")
    if type(document["schemaVersion"]) is not int or document["schemaVersion"] != SCHEMA_VERSION:
        raise ConfigError("不支持的 schemaVersion")
    profiles = document["profiles"]
    if not isinstance(profiles, list) or not profiles:
        raise ConfigError("profiles 必须是非空数组")
    seen: set[tuple[str, str, str]] = set()
    for index, profile in enumerate(profiles):
        if not isinstance(profile, dict) or set(profile) != EXPECTED_PROFILE_KEYS:
            raise ConfigError(f"profiles[{index}] 字段不完整或包含未知字段")
        if any(not isinstance(profile[key], str) for key in EXPECTED_PROFILE_KEYS):
            raise ConfigError(f"profiles[{index}] 的身份字段必须为字符串")
        if profile["bundleIdentifier"] != TARGET_BUNDLE_ID:
            raise ConfigError(f"profiles[{index}] 不是目标 Codex bundle ID")
        if not BUILD_PATTERN.fullmatch(profile["buildVersion"]):
            raise ConfigError(f"profiles[{index}] buildVersion 格式无效")
        if len(profile["shortVersion"].encode("utf-8")) > 128 or not SHORT_VERSION_PATTERN.fullmatch(profile["shortVersion"]):
            raise ConfigError(f"profiles[{index}] shortVersion 格式无效")
        if not SHA256_PATTERN.fullmatch(profile["infoPlistSHA256"]):
            raise ConfigError(f"profiles[{index}] infoPlistSHA256 必须是64位小写十六进制")
        key = (profile["bundleIdentifier"], profile["buildVersion"], profile["shortVersion"])
        if key in seen:
            raise ConfigError(f"profiles[{index}] 版本身份重复或存在歧义")
        seen.add(key)
    return document


def identity_from_plist(path: Path) -> dict[str, str]:
    raw = path.read_bytes()
    if len(raw) > 4 * 1024 * 1024:
        raise ConfigError("宿主 Info.plist 超过大小限制")
    try:
        metadata = plistlib.loads(raw)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise ConfigError(f"无法读取宿主 Info.plist：{path}") from error
    if not isinstance(metadata, dict):
        raise ConfigError("宿主 Info.plist 不是字典")
    bundle_id = metadata.get("CFBundleIdentifier")
    build = metadata.get("CFBundleVersion")
    short_version = metadata.get("CFBundleShortVersionString")
    if not all(isinstance(value, str) and value for value in (bundle_id, build, short_version)):
        raise ConfigError("宿主 Info.plist 缺少必需的身份字符串")
    if bundle_id != TARGET_BUNDLE_ID:
        raise ConfigError(f"宿主 bundle ID 不匹配：{bundle_id}")
    profile = {
        "bundleIdentifier": bundle_id,
        "buildVersion": build,
        "shortVersion": short_version,
        "infoPlistSHA256": hashlib.sha256(raw).hexdigest(),
    }
    # Reuse the configuration validator for exact string/format checks.
    decode_config(json.dumps({"schemaVersion": SCHEMA_VERSION, "profiles": [profile]}).encode("utf-8"))
    return profile


def template_path(script_path: Path) -> Path:
    script_directory = script_path.resolve().parent
    root = script_directory.parent
    candidates = [
        script_directory / "QuotaHostCompatibility.json",
        root / "Resources/QuotaHostCompatibility.json",
        root / "QuotaHostCompatibility.json",
        root / "QuotaButton.app/Contents/Resources/QuotaHostCompatibility.json",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise ConfigError("找不到随包提供的 QuotaHostCompatibility.json 模板")


def read_config(path: Path) -> dict[str, Any]:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ConfigError(f"现有配置不是普通文件：{path}")
    if info.st_size > MAX_CONFIG_BYTES:
        raise ConfigError("现有配置超过 64 KiB 限制，拒绝覆盖")
    return decode_config(path.read_bytes())


def atomic_write(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    serialized = (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if len(serialized) > MAX_CONFIG_BYTES:
        raise ConfigError("更新后配置超过 64 KiB 限制")
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(serialized)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def approve(config_path: Path, template: Path, current: dict[str, str]) -> tuple[bool, int]:
    if os.path.lexists(config_path):
        document = read_config(config_path)
    else:
        document = read_config(template)
    key = (current["bundleIdentifier"], current["buildVersion"], current["shortVersion"])
    existing = [p for p in document["profiles"] if
                (p["bundleIdentifier"], p["buildVersion"], p["shortVersion"]) == key]
    if existing:
        if existing[0]["infoPlistSHA256"] != current["infoPlistSHA256"]:
            raise ConfigError("相同版本号已登记为不同 Info.plist 哈希，存在歧义；未写入")
        return False, len(document["profiles"])
    document["profiles"].append(current)
    # Validate the full document again before committing it atomically.
    serialized = (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    validated = decode_config(serialized)
    atomic_write(config_path, validated)
    return True, len(validated["profiles"])


def main() -> int:
    parser = argparse.ArgumentParser(description="只读显示或显式登记当前 Codex 宿主兼容身份")
    parser.add_argument("--host-plist", type=Path,
                        default=Path("/Applications/ChatGPT.app/Contents/Info.plist"),
                        help="公开的 Codex Info.plist 路径（测试时可指向合成文件）")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG,
                        help="外置配置路径；默认写入 CodexGauge Application Support")
    parser.add_argument("--approve-current-host", action="store_true",
                        help="明确批准并原子登记当前宿主；不传时只读，不写文件")
    args = parser.parse_args()
    try:
        current = identity_from_plist(args.host_plist)
        print("当前公开宿主身份：")
        for key in ("bundleIdentifier", "buildVersion", "shortVersion", "infoPlistSHA256"):
            print(f"  {key}: {current[key]}")
        if not args.approve_current_host:
            print("只读检查完成；未写入或修改兼容配置。")
            return 0
        changed, count = approve(args.config.expanduser(), template_path(Path(__file__)), current)
        if changed:
            print(f"已原子登记到：{args.config.expanduser()}")
        else:
            print(f"该版本已登记，无需写入：{args.config.expanduser()}")
        print(f"profiles 条目数：{count}。重启额度按钮 App 后生效；登记不代表真实界面已验收。")
        return 0
    except (OSError, ConfigError) as error:
        print(f"配置未更新：{error}", file=os.sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
