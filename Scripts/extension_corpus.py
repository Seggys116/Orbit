#!/usr/bin/env python3
"""Orbit extension corpus manager: the only reader and writer of Chromium/extension-corpus.json.

Vendors a pinned corpus of real Chrome Web Store extensions under ThirdParty/extension-corpus
(gitignored) so the live-engine suite can assert behaviour a half-implemented browser cannot
fake -- see refs/EXTENSION_CONFORMANCE.md section 7.5. Downloads are SHA-256 verified and fail
closed. Unpacking drops the CRX3 signing key an extension's id derives from, so each vendored
manifest.json records it and every step re-asserts the id against both crx_id and the pinned
store id. The download request matches ChromeWebStoreClient.swift byte-for-byte.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import datetime
import hashlib
import io
import json
import os
import shutil
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

MANIFEST_PATH = os.path.join(REPO_ROOT, "Chromium", "extension-corpus.json")
CHROMIUM_MANIFEST_PATH = os.path.join(REPO_ROOT, "Chromium", "chromium-version.json")

DEFAULT_UNPACK_ROOT = "ThirdParty/extension-corpus"
DEFAULT_UPDATE_SERVICE_URL = "https://clients2.google.com/service/update2/crx"
CRX_CACHE_DIRNAME = ".crx"
MARKER_NAME = ".orbit-corpus.json"

MAX_CRX_BYTES = 512 * 1024 * 1024
REQUEST_TIMEOUT = 60

_IS_TTY = sys.stdout.isatty()
_USE_COLOR = _IS_TTY and os.environ.get("NO_COLOR") is None

def _c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _USE_COLOR else text

def bold(t: str) -> str:
    return _c("1", t)

def dim(t: str) -> str:
    return _c("2", t)

def green(t: str) -> str:
    return _c("32", t)

def yellow(t: str) -> str:
    return _c("33", t)

def red(t: str) -> str:
    return _c("31", t)

def cyan(t: str) -> str:
    return _c("36", t)

def info(msg: str) -> None:
    print(f"{cyan('==>')} {msg}")

def step(msg: str) -> None:
    print(f"{dim('  ->')} {msg}")

def warn(msg: str) -> None:
    print(f"{yellow('warning:')} {msg}", file=sys.stderr)

def die(msg: str, code: int = 1):
    print(f"{red('error:')} {msg}", file=sys.stderr)
    sys.exit(code)

def human_bytes(n) -> str:
    if not n or n <= 0:
        return "unknown"
    units = ["B", "KB", "MB", "GB"]
    value = float(n)
    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            return f"{int(value)} B" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024.0
    return f"{value:.1f} GB"

##
# Manifest.
##

def load_manifest() -> dict:
    if not os.path.exists(MANIFEST_PATH):
        die(
            f"Manifest missing: {MANIFEST_PATH}\n"
            "  This does not look like a complete Orbit checkout. Re-clone the repository."
        )
    try:
        with open(MANIFEST_PATH, "r", encoding="utf-8") as handle:
            manifest = json.load(handle)
    except json.JSONDecodeError as exc:
        die(f"Manifest is not valid JSON ({exc}). Fix {MANIFEST_PATH} by hand, then re-run.")
    except OSError as exc:
        die(f"Could not read {MANIFEST_PATH}: {exc}")
    if not isinstance(manifest.get("extensions"), list) or not manifest["extensions"]:
        die(f"{MANIFEST_PATH} declares no extensions.")
    return manifest

ENTRY_KEY_ORDER = [
    "id",
    "name",
    "version",
    "sha256",
    "crx_bytes",
    "unavailable",
    "exercises",
    "expectation",
]

def save_manifest(manifest: dict) -> None:
    top_order = ["_readme", "update_service_url", "unpack_root", "pinned_at", "extensions"]
    ordered = {key: manifest[key] for key in top_order if key in manifest}
    for key, value in manifest.items():
        if key not in ordered:
            ordered[key] = value

    entries = []
    for entry in ordered.get("extensions", []):
        row = {key: entry[key] for key in ENTRY_KEY_ORDER if key in entry}
        for key, value in entry.items():
            if key not in row:
                row[key] = value
        entries.append(row)
    ordered["extensions"] = entries

    with open(MANIFEST_PATH, "w", encoding="utf-8") as handle:
        json.dump(ordered, handle, indent=2)
        handle.write("\n")

def chromium_major() -> str:
    try:
        with open(CHROMIUM_MANIFEST_PATH, "r", encoding="utf-8") as handle:
            version = json.load(handle)["chromium_version"]
    except (OSError, json.JSONDecodeError, KeyError) as exc:
        die(
            f"Could not read chromium_version from {CHROMIUM_MANIFEST_PATH}: {exc}\n"
            "  The download request's prodversion comes from there, exactly as ChromeWebStoreClient does."
        )
    return version.split(".")[0]

def unpack_root(manifest: dict) -> str:
    return os.path.join(REPO_ROOT, manifest.get("unpack_root", DEFAULT_UNPACK_ROOT))

def crx_cache_dir(manifest: dict) -> str:
    return os.path.join(unpack_root(manifest), CRX_CACHE_DIRNAME)

def crx_path(manifest: dict, entry: dict, version: str) -> str:
    return os.path.join(crx_cache_dir(manifest), f"{entry['id']}-{version}.crx")

def unpack_dir(manifest: dict, entry: dict, version: str) -> str:
    return os.path.join(unpack_root(manifest), f"{entry['id']}-{version}")

def slug(text: str) -> str:
    return "".join(ch for ch in text.lower() if ch.isalnum())

def select_entries(manifest: dict, selectors: list) -> list:
    entries = manifest["extensions"]
    if not selectors:
        return list(entries)
    chosen = []
    for selector in selectors:
        wanted = slug(selector)
        matches = [e for e in entries if e["id"] == selector or slug(e["name"]) == wanted]
        if not matches:
            known = ", ".join(f"{e['name']} ({e['id']})" for e in entries)
            die(f"'{selector}' matches no corpus entry.\n  Known entries: {known}")
        for match in matches:
            if match not in chosen:
                chosen.append(match)
    return chosen

##
# Chrome Web Store update service.
##

def download_request_url(update_service_url: str, extension_id: str, prodversion: str) -> str:
    """The URL ChromeWebStoreClient.downloadRequestURL(forExtensionID:) builds.

    The `x` value is the unencoded `id=<id>&uc`, percent-encoded whole -- encoding it any
    other way makes the service ignore the id and answer for no application at all.
    """
    query = [
        ("response", "redirect"),
        ("acceptformat", "crx3"),
        ("prodversion", prodversion),
        ("x", f"id={extension_id}&uc"),
    ]
    encoded = "&".join(f"{key}={urllib.parse.quote(value, safe='')}" for key, value in query)
    return f"{update_service_url}?{encoded}"

class Unavailable(Exception):
    """The store refused to serve this extension; recorded in the manifest verbatim."""

def download_crx(url: str) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Orbit-extension-corpus/1.0", "Accept": "*/*"},
    )
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            status = getattr(response, "status", None) or response.getcode()
            if status in (204, 404):
                raise Unavailable(f"HTTP {status} {response.reason} from {response.geturl()}")
            content_type = (response.headers.get("Content-Type") or "").lower()
            if "text/html" in content_type:
                raise Unavailable(f"HTTP {status} returned {content_type}, not an extension package")
            declared = response.headers.get("Content-Length")
            if declared and int(declared) > MAX_CRX_BYTES:
                raise Unavailable(f"declared {declared} bytes, over the {MAX_CRX_BYTES} byte ceiling")
            buffer = io.BytesIO()
            while True:
                chunk = response.read(256 * 1024)
                if not chunk:
                    break
                buffer.write(chunk)
                if buffer.tell() > MAX_CRX_BYTES:
                    raise Unavailable(f"response exceeded the {MAX_CRX_BYTES} byte ceiling")
            data = buffer.getvalue()
    except urllib.error.HTTPError as exc:
        raise Unavailable(f"HTTP {exc.code} {exc.reason}") from exc
    except urllib.error.URLError as exc:
        die(f"Could not reach the Chrome Web Store update service: {exc.reason}\n  url: {url}")
    except OSError as exc:
        die(f"Download failed: {exc}\n  url: {url}")

    if not data:
        raise Unavailable("the update service returned an empty body")
    if not data.startswith(b"Cr24"):
        raise Unavailable(f"the response is not a CRX (first bytes {data[:8]!r})")
    return data

##
# CRX3: 'Cr24', u32 version, u32 header length, header bytes, then a plain zip.
##

def crx_zip_offset(data: bytes) -> int:
    if len(data) < 16 or data[:4] != b"Cr24":
        die("Not a CRX file: missing the Cr24 magic.")
    version = struct.unpack_from("<I", data, 4)[0]
    if version == 3:
        header_length = struct.unpack_from("<I", data, 8)[0]
        offset = 12 + header_length
    elif version == 2:
        public_key_length, signature_length = struct.unpack_from("<II", data, 8)
        offset = 16 + public_key_length + signature_length
    else:
        die(f"Unsupported CRX format version {version}; only 2 and 3 exist.")
    if offset <= 0 or offset >= len(data):
        die(f"CRX header claims the archive starts at byte {offset}, past the end of a {len(data)} byte file.")
    if data[offset:offset + 2] not in (b"PK",):
        die(f"CRX header points at byte {offset}, which is not the start of a zip archive.")
    return offset

def crx_archive(data: bytes) -> zipfile.ZipFile:
    return zipfile.ZipFile(io.BytesIO(data[crx_zip_offset(data):]))

##
# CRX3 identity, parsed as Orbit/Engine/Extensions/CRX3Archive.swift does:
# CrxFileHeader field 2 sha256_with_rsa, 3 sha256_with_ecdsa, 10000
# signed_header_data; AsymmetricKeyProof field 1 public_key; SignedData
# field 1 crx_id.
##

CRX3_PREAMBLE_SIZE = 12
CRX3_MAX_HEADER_BYTES = 1024 * 1024

class MalformedCRX(Exception):
    """The container's bytes do not parse; the caller reports which file."""

def protobuf_fields(data: bytes):
    """(field number, payload) for every length-delimited field; varints skipped."""
    offset = 0
    limit = len(data)

    def varint() -> int:
        nonlocal offset
        value = 0
        shift = 0
        while True:
            if offset >= limit:
                raise MalformedCRX("a varint was truncated before its terminating byte")
            if shift >= 64:
                raise MalformedCRX("a varint used more continuation bytes than a 64-bit value can need")
            byte = data[offset]
            offset += 1
            value |= (byte & 0x7F) << shift
            if not byte & 0x80:
                return value
            shift += 7

    while offset < limit:
        tag = varint()
        number = tag >> 3
        wire_type = tag & 0x7
        if wire_type == 0:
            varint()
            continue
        if wire_type != 2:
            raise MalformedCRX(f"field {number} used wire type {wire_type}, which none of CRX3's messages use")
        length = varint()
        if length > limit - offset:
            raise MalformedCRX("a length-delimited field's declared length runs past the end of the message")
        yield number, data[offset:offset + length]
        offset += length

def extension_id_from_bytes(raw: bytes) -> str:
    """Chromium's id encoding: each nibble 0-15 mapped to 'a'-'p'."""
    return "".join(chr(ord("a") + nibble) for byte in raw for nibble in (byte >> 4, byte & 0xF))

def extension_id_from_public_key(public_key: bytes) -> str:
    return extension_id_from_bytes(hashlib.sha256(public_key).digest()[:16])

def crx3_header_bytes(data: bytes) -> bytes:
    if len(data) < CRX3_PREAMBLE_SIZE or data[:4] != b"Cr24":
        raise MalformedCRX("missing the Cr24 magic")
    version = struct.unpack_from("<I", data, 4)[0]
    if version == 2:
        raise MalformedCRX(
            "this is a CRX2 package, which carries no CRX3 header; Orbit's own CRX3Archive refuses CRX2 too"
        )
    if version != 3:
        raise MalformedCRX(f"unsupported CRX format version {version}")
    header_length = struct.unpack_from("<I", data, 8)[0]
    if header_length > CRX3_MAX_HEADER_BYTES or header_length > len(data) - CRX3_PREAMBLE_SIZE:
        raise MalformedCRX(f"the header claims {header_length} bytes, which a {len(data)} byte file cannot hold")
    return data[CRX3_PREAMBLE_SIZE:CRX3_PREAMBLE_SIZE + header_length]

def crx3_identity(data: bytes):
    """(DER RSA public key, extension id) for the proof the header's crx_id names.

    A CRX carries several proofs (publisher + developer keys); only the RSA proof whose
    derived id equals crx_id is the extension's -- ECDSA proofs are never candidates, since
    manifest.json's `key` is an RSA SubjectPublicKeyInfo.
    """
    header = crx3_header_bytes(data)

    rsa_proofs = []
    signed_header_data = None
    for number, payload in protobuf_fields(header):
        if number == 2:
            rsa_proofs.append(payload)
        elif number == 10000:
            signed_header_data = payload

    if signed_header_data is None:
        raise MalformedCRX("the header has no signed_header_data, so it declares no crx_id")

    declared = None
    for number, payload in protobuf_fields(signed_header_data):
        if number == 1:
            declared = payload
    if declared is None or len(declared) != 16:
        raise MalformedCRX(f"the declared crx_id is {len(declared or b'')} bytes; a CRX3 crx_id is exactly 16")
    declared_id = extension_id_from_bytes(declared)

    public_keys = []
    for proof in rsa_proofs:
        for number, payload in protobuf_fields(proof):
            if number == 1:
                public_keys.append(payload)
    if not public_keys:
        raise MalformedCRX("the header carries no RSA public key")

    for public_key in public_keys:
        if extension_id_from_public_key(public_key) == declared_id:
            return public_key, declared_id

    derived = ", ".join(extension_id_from_public_key(key) for key in public_keys)
    raise MalformedCRX(
        f"none of the header's {len(public_keys)} RSA key(s) hash to its own declared id {declared_id} "
        f"(they hash to {derived}); the container claims an identity it cannot have signed"
    )

def crx3_identity_of_file(path: str):
    with open(path, "rb") as handle:
        preamble = handle.read(CRX3_PREAMBLE_SIZE)
        if len(preamble) < CRX3_PREAMBLE_SIZE:
            raise MalformedCRX("the file is too short to hold a CRX3 preamble")
        header_length = struct.unpack_from("<I", preamble, 8)[0]
        if header_length > CRX3_MAX_HEADER_BYTES:
            raise MalformedCRX(f"the header claims {header_length} bytes, past the {CRX3_MAX_HEADER_BYTES} byte ceiling")
        return crx3_identity(preamble + handle.read(header_length))

def manifest_key_identity(extension_manifest: dict):
    """The extension id manifest.json's own `key` field derives, or None."""
    encoded = extension_manifest.get("key")
    if not isinstance(encoded, str) or not encoded:
        return None
    try:
        return extension_id_from_public_key(base64.b64decode(encoded, validate=True))
    except (binascii.Error, ValueError):
        return None

def write_store_identity(directory: str, public_key: bytes, extension_id: str) -> None:
    """Records the CRX3 signing key as manifest.json's `key`, so the unpacked
    directory loads under its store id instead of a path-derived one."""
    path = os.path.join(directory, "manifest.json")
    with open(path, "rb") as handle:
        raw = handle.read()
    try:
        extension_manifest = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        die(f"The unpacked manifest.json is not valid JSON: {exc}")
    if not isinstance(extension_manifest, dict):
        die("The unpacked manifest.json is not a JSON object.")

    encoded = base64.b64encode(public_key).decode("ascii")
    shipped = manifest_key_identity(extension_manifest)
    if shipped is not None and shipped != extension_id:
        die(
            f"{path} already ships a `key` deriving id {shipped}, but the CRX3 header is signed for "
            f"{extension_id}. Nothing was rewritten. The package's declared identity disagrees with its own "
            "manifest, which is a supply-chain question, not a formatting one."
        )

    extension_manifest["key"] = encoded
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(extension_manifest, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

def read_crx_manifest(data: bytes) -> dict:
    with crx_archive(data) as archive:
        try:
            raw = archive.read("manifest.json")
        except KeyError:
            die("The downloaded CRX contains no manifest.json; it is not a Chrome extension package.")
    try:
        return json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        die(f"The CRX's manifest.json is not valid JSON: {exc}")

def resolve_localized_name(data: bytes, extension_manifest: dict) -> str:
    """Chrome extensions usually carry `__MSG_extName__`; resolve it from _locales."""
    name = extension_manifest.get("name", "")
    if not (name.startswith("__MSG_") and name.endswith("__")):
        return name
    message_key = name[len("__MSG_"):-2]
    default_locale = extension_manifest.get("default_locale", "en")
    with crx_archive(data) as archive:
        for candidate in (default_locale, "en", "en_US"):
            path = f"_locales/{candidate}/messages.json"
            try:
                raw = archive.read(path)
            except KeyError:
                continue
            try:
                messages = json.loads(raw.decode("utf-8-sig"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            for key, value in messages.items():
                if key.lower() == message_key.lower() and isinstance(value, dict):
                    return value.get("message", name)
    return name

def safe_member_path(destination: str, member_name: str):
    """Rejects absolute, traversing and (on this platform) backslash-separated entries."""
    normalized = member_name.replace("\\", "/")
    if normalized.endswith("/"):
        return None
    if normalized.startswith("/") or ".." in normalized.split("/"):
        die(f"CRX archive contains an unsafe path: {member_name}")
    target = os.path.normpath(os.path.join(destination, *normalized.split("/")))
    if os.path.commonpath([os.path.abspath(target), os.path.abspath(destination)]) != os.path.abspath(destination):
        die(f"CRX archive contains an escaping path: {member_name}")
    return target

def unpack_crx(data: bytes, destination: str, public_key: bytes, extension_id: str) -> int:
    staging = destination + ".staging"
    if os.path.isdir(staging):
        shutil.rmtree(staging)
    os.makedirs(staging, exist_ok=True)

    written = 0
    with crx_archive(data) as archive:
        for member in archive.infolist():
            target = safe_member_path(staging, member.filename)
            if target is None:
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with archive.open(member) as source, open(target, "wb") as handle:
                shutil.copyfileobj(source, handle)
            written += 1

    if not os.path.isfile(os.path.join(staging, "manifest.json")):
        shutil.rmtree(staging)
        die("The unpacked CRX has no manifest.json at its root; it is not a loadable extension.")

    write_store_identity(staging, public_key, extension_id)

    if os.path.isdir(destination):
        shutil.rmtree(destination)
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    os.rename(staging, destination)
    return written

##
# On-disk state.
##

def sha256_of_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def sha256_of_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def write_marker(directory: str, entry: dict, version: str, checksum: str) -> None:
    with open(os.path.join(directory, MARKER_NAME), "w", encoding="utf-8") as handle:
        json.dump({"id": entry["id"], "name": entry["name"], "version": version, "sha256": checksum}, handle, indent=2)
        handle.write("\n")

def read_marker(directory: str):
    try:
        with open(os.path.join(directory, MARKER_NAME), "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None

def unpacked_manifest(directory: str):
    try:
        with open(os.path.join(directory, "manifest.json"), "rb") as handle:
            return json.loads(handle.read().decode("utf-8-sig"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None

def entry_state(manifest: dict, entry: dict) -> dict:
    """(state, detail) for one entry, checked against the version pinned right now."""
    version = entry.get("version")
    checksum = entry.get("sha256")
    state = {
        "version": version,
        "unavailable": entry.get("unavailable"),
        "directory": None,
        "crx": None,
        "manifest_version": None,
        "manifest_version_on_disk": None,
        "extension_id": None,
        "ok": False,
        "reason": "",
    }
    if not version or not checksum:
        state["reason"] = entry.get("unavailable") or "not pinned"
        return state

    directory = unpack_dir(manifest, entry, version)
    archive = crx_path(manifest, entry, version)
    state["directory"] = directory
    state["crx"] = archive

    if not os.path.isdir(directory):
        state["reason"] = "not unpacked"
        return state
    extension_manifest = unpacked_manifest(directory)
    if extension_manifest is None:
        state["reason"] = "unpacked directory has no readable manifest.json"
        return state
    state["manifest_version"] = extension_manifest.get("manifest_version")
    state["manifest_version_on_disk"] = extension_manifest.get("version")
    if extension_manifest.get("version") != version:
        state["reason"] = f"unpacked manifest.json is {extension_manifest.get('version')}, pin is {version}"
        return state

    on_disk_id = manifest_key_identity(extension_manifest)
    state["extension_id"] = on_disk_id
    if on_disk_id is None:
        state["reason"] = (
            "unpacked manifest.json carries no usable `key`, so Chromium derives the id from this directory's path"
        )
        return state
    if on_disk_id != entry["id"]:
        state["reason"] = f"unpacked manifest.json's `key` derives id {on_disk_id}, not the pinned {entry['id']}"
        return state

    marker = read_marker(directory)
    if not marker or marker.get("sha256") != checksum:
        state["reason"] = "unpacked from a CRX whose hash does not match the pin"
        return state

    if not os.path.isfile(archive):
        state["reason"] = "CRX not cached (cannot re-verify the bytes)"
        return state
    if sha256_of_file(archive) != checksum:
        state["reason"] = "cached CRX fails its SHA-256"
        return state

    try:
        _, signed_id = crx3_identity_of_file(archive)
    except (MalformedCRX, OSError) as exc:
        state["reason"] = f"cached CRX's identity could not be read: {exc}"
        return state
    if signed_id != entry["id"]:
        state["reason"] = f"cached CRX is signed for {signed_id}, not the pinned {entry['id']}"
        return state

    state["ok"] = True
    return state

##
# Commands.
##

def cmd_status(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    prodversion = chromium_major()

    print(bold("Orbit extension corpus"))
    print(f"  Manifest          {dim(os.path.relpath(MANIFEST_PATH, REPO_ROOT))}")
    print(f"  Unpack root       {dim(os.path.relpath(unpack_root(manifest), REPO_ROOT))}")
    print(f"  prodversion       {prodversion}  {dim('(from Chromium/chromium-version.json)')}")
    print()

    missing = 0
    unavailable = 0
    for entry in manifest["extensions"]:
        state = entry_state(manifest, entry)
        name = entry["name"]
        if state["ok"]:
            mv = state["manifest_version"]
            detail = dim(f"MV{mv}  {os.path.relpath(state['directory'], REPO_ROOT)}")
            print(f"  {green('verified   ')}  {name} {entry['version']}  {detail}")
        elif entry.get("unavailable"):
            print(f"  {red('unavailable')}  {name}  {dim(entry['unavailable'])}")
            unavailable += 1
        else:
            print(f"  {yellow('missing    ')}  {name} {entry.get('version') or '-'}  {dim(state['reason'])}")
            missing += 1
        print(f"               {dim(entry['id'])}  {dim(entry['exercises'])}")

    total = len(manifest["extensions"])
    print()
    if missing:
        print(f"{yellow(str(missing))} of {total} not vendored. Run: {bold('Scripts/extension-corpus fetch')}")
    else:
        print(green(f"All {total - unavailable} downloadable entries are present and hash-verified."))
    if unavailable:
        print(dim(f"{unavailable} entr{'y' if unavailable == 1 else 'ies'} the store will not serve; tests skip those by name."))
    return 0

def fetch_one(manifest: dict, entry: dict, prodversion: str, force: bool) -> bool:
    name = entry["name"]
    version = entry.get("version")
    checksum = entry.get("sha256")

    if entry.get("unavailable") and not version:
        warn(f"{name} is recorded unavailable ({entry['unavailable']}); skipping.")
        return True
    if not version or not checksum:
        die(
            f"{name} ({entry['id']}) has no pinned version or sha256.\n"
            f"  Pin it deliberately first: Scripts/extension-corpus pin {entry['id']}"
        )

    state = entry_state(manifest, entry)
    if state["ok"] and not force:
        step(f"{name} {version} already present and verified")
        return True

    url = download_request_url(manifest.get("update_service_url", DEFAULT_UPDATE_SERVICE_URL), entry["id"], prodversion)
    archive_path = crx_path(manifest, entry, version)

    data = None
    if os.path.isfile(archive_path) and not force:
        if sha256_of_file(archive_path) == checksum:
            step(f"{name}: cached CRX is valid, skipping download")
            with open(archive_path, "rb") as handle:
                data = handle.read()

    if data is None:
        info(f"Downloading {name} {version}")
        try:
            data = download_crx(url)
        except Unavailable as exc:
            die(
                f"The Chrome Web Store would not serve {name} ({entry['id']}): {exc}\n"
                f"  Nothing was unpacked. If this is permanent, re-pin: Scripts/extension-corpus pin {entry['id']}"
            )
        actual = sha256_of_bytes(data)
        if actual != checksum:
            served = read_crx_manifest(data).get("version", "unknown")
            die(
                f"SHA-256 mismatch for {name} ({entry['id']}). Nothing was unpacked.\n"
                f"  expected  {checksum}   (pinned version {version})\n"
                f"  actual    {actual}   (served version {served})\n"
                "  The store is serving a different build than the pin. Either the pin is stale --\n"
                f"  re-pin deliberately with `Scripts/extension-corpus pin {entry['id']}` and re-verify the\n"
                "  expectation against the new build -- or the download was tampered with."
            )
        os.makedirs(os.path.dirname(archive_path), exist_ok=True)
        partial = archive_path + ".part"
        with open(partial, "wb") as handle:
            handle.write(data)
        os.replace(partial, archive_path)

    extension_manifest = read_crx_manifest(data)
    if extension_manifest.get("version") != version:
        die(
            f"{name}'s CRX passed its hash but its manifest.json says version "
            f"{extension_manifest.get('version')}, not the pinned {version}. Nothing was unpacked."
        )

    try:
        public_key, signed_id = crx3_identity(data)
    except MalformedCRX as exc:
        die(f"{name}'s CRX3 header does not parse: {exc}. Nothing was unpacked.")
    if signed_id != entry["id"]:
        die(
            f"{name}'s CRX is signed for extension id {signed_id}, not the pinned {entry['id']}. Nothing was unpacked.\n"
            "  The id is derived from the signing key in the CRX3 header, so this package is a different\n"
            "  extension than the pin names however it was served. Do not adjust the pin to match: that is a\n"
            "  supply-chain question, not a formatting one."
        )

    destination = unpack_dir(manifest, entry, version)
    count = unpack_crx(data, destination, public_key, signed_id)
    write_marker(destination, entry, version, checksum)
    step(
        f"{name} {version}  MV{extension_manifest.get('manifest_version')}  "
        f"{count} files  {human_bytes(len(data))}  -> {os.path.relpath(destination, REPO_ROOT)}"
    )
    step(f"store identity  {signed_id}  {dim('(CRX3 signing key recorded as manifest.json `key`)')}")
    return True

def cmd_fetch(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    prodversion = chromium_major()
    entries = select_entries(manifest, args.selector)

    info(f"Fetching {len(entries)} pinned extension(s) with prodversion={prodversion}")
    for entry in entries:
        fetch_one(manifest, entry, prodversion, args.force)

    print()
    info(green("Corpus ready."))
    print(dim(f"  {os.path.relpath(unpack_root(manifest), REPO_ROOT)}"))
    return 0

def cmd_pin(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    prodversion = chromium_major()
    entries = select_entries(manifest, args.selector)
    update_service_url = manifest.get("update_service_url", DEFAULT_UPDATE_SERVICE_URL)

    changed = 0
    for entry in entries:
        url = download_request_url(update_service_url, entry["id"], prodversion)
        info(f"Resolving {entry['name']} ({entry['id']})")
        try:
            data = download_crx(url)
        except Unavailable as exc:
            entry["version"] = None
            entry["sha256"] = None
            entry["crx_bytes"] = None
            entry["unavailable"] = str(exc)
            changed += 1
            warn(f"{entry['name']} is not downloadable: {exc}  (recorded as unavailable)")
            continue

        extension_manifest = read_crx_manifest(data)
        version = extension_manifest.get("version")
        if not version:
            die(f"{entry['name']}'s manifest.json declares no version; refusing to pin it.")
        try:
            _, signed_id = crx3_identity(data)
        except MalformedCRX as exc:
            die(f"{entry['name']}'s CRX3 header does not parse: {exc}. Nothing was pinned.")
        if signed_id != entry["id"]:
            die(
                f"The store served a package signed for {signed_id} in answer to a request for {entry['id']}.\n"
                f"  Nothing was pinned. The id comes from the signing key, so this is a different extension."
            )
        store_name = resolve_localized_name(data, extension_manifest)
        checksum = sha256_of_bytes(data)
        previous = entry.get("version")

        entry["version"] = version
        entry["sha256"] = checksum
        entry["crx_bytes"] = len(data)
        entry.pop("unavailable", None)
        changed += 1

        step(f"{previous or 'unpinned'} -> {green(version)}  MV{extension_manifest.get('manifest_version')}")
        step(f"signed for  {signed_id}")
        step(f"store name  {store_name}")
        step(f"sha256      {checksum}")
        step(f"crx_bytes   {len(data)}  ({human_bytes(len(data))})")

    if changed:
        manifest["pinned_at"] = datetime.date.today().isoformat()
        save_manifest(manifest)
        print()
        info(f"Wrote {os.path.relpath(MANIFEST_PATH, REPO_ROOT)}")
        print(dim("  Next: Scripts/extension-corpus fetch    to unpack the newly pinned builds."))
    return 0

def cmd_verify(args: argparse.Namespace) -> int:
    manifest = load_manifest()
    entries = select_entries(manifest, args.selector)
    failed = []

    for entry in entries:
        state = entry_state(manifest, entry)
        if state["ok"]:
            print(
                f"  [{green('ok  ')}] {entry['name']} {entry['version']}  "
                f"{dim('MV' + str(state['manifest_version']))}  {dim('id ' + state['extension_id'])}"
            )
        elif entry.get("unavailable"):
            print(f"  [{yellow('skip')}] {entry['name']}  {dim(entry['unavailable'])}")
        else:
            print(f"  [{red('FAIL')}] {entry['name']} {entry.get('version') or '-'}  {dim(state['reason'])}")
            failed.append(f"{entry['name']} ({entry['id']}): {state['reason']}")

    print()
    if failed:
        for line in failed:
            print(f"  {red('-')} {line}")
        print()
        die(f"{len(failed)} corpus entr{'y' if len(failed) == 1 else 'ies'} did not verify. Run: Scripts/extension-corpus fetch")
    print(green("Every checked entry matches its pin."))
    return 0

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="Scripts/extension-corpus",
        description="Vendor and verify the pinned corpus of real Chrome extensions the live-engine suite loads.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  Scripts/extension-corpus status\n"
            "  Scripts/extension-corpus fetch\n"
            "  Scripts/extension-corpus fetch vimium darkreader\n"
            "  Scripts/extension-corpus verify\n"
            "  Scripts/extension-corpus pin gppongmhjkpfnbhagpmjfkannfbllamg\n"
            "\n"
            "pins move only when you run `pin`, never as a side effect of `fetch`:\n"
            "an extension that updates underneath the suite turns it into a flake\n"
            "generator, and each expectation was verified against one exact build.\n"
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_status = sub.add_parser("status", help="show what is pinned, present and hash-verified")
    p_status.set_defaults(func=cmd_status)

    p_fetch = sub.add_parser("fetch", help="download, verify and unpack the pinned CRXs")
    p_fetch.add_argument("selector", nargs="*", help="ids or names; all entries when omitted")
    p_fetch.add_argument("--force", action="store_true", help="re-download and re-unpack even when already verified")
    p_fetch.set_defaults(func=cmd_fetch)

    p_pin = sub.add_parser("pin", help="record the store's current version, sha256 and size for each entry")
    p_pin.add_argument("selector", nargs="*", help="ids or names; all entries when omitted")
    p_pin.set_defaults(func=cmd_pin)

    p_verify = sub.add_parser("verify", help="re-hash what is on disk against the manifest")
    p_verify.add_argument("selector", nargs="*", help="ids or names; all entries when omitted")
    p_verify.set_defaults(func=cmd_verify)

    return parser

def main(argv: list) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print()
        die("Interrupted.", code=130)

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
