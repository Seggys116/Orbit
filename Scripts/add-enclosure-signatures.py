#!/usr/bin/env python3
"""Add sparkle:edSignature attributes to appcast enclosures; exits 1 unless every one is signed."""

import sys
import subprocess
import xml.etree.ElementTree as ET
import os

def get_dmg_signature(sign_update_path, private_key, dmg_path):
    """private_key is piped via stdin so it never reaches disk; returns None if signing failed."""
    result = subprocess.run(
        [sign_update_path, "-f", "-", "-p", dmg_path],
        input=private_key,
        capture_output=True,
        text=True
    )
    if result.returncode == 0:
        return result.stdout.strip()
    else:
        print(f"Error signing {dmg_path}: {result.stderr}", file=sys.stderr)
        return None

def add_signatures_to_appcast(sign_update_path, appcast_path, dmg_dir, private_key):

    ET.register_namespace('sparkle', 'http://www.andymatuschak.org/xml-namespaces/sparkle')

    try:
        tree = ET.parse(appcast_path)
    except ET.ParseError as e:
        print(f"Error: Failed to parse appcast: {e}", file=sys.stderr)
        return False

    root = tree.getroot()
    items_to_sign = []
    failed = False

    for item in root.findall('.//item'):
        enclosure = item.find('enclosure')
        if enclosure is not None:
            url = enclosure.get('url')
            if url:
                filename = url.split('/')[-1]
                dmg_path = os.path.join(dmg_dir, filename)
                items_to_sign.append((item, enclosure, filename, dmg_path))

    if not items_to_sign:
        print("Error: No enclosures found in appcast", file=sys.stderr)
        return False

    for item, enclosure, filename, dmg_path in items_to_sign:
        if not os.path.exists(dmg_path):
            print(f"Error: DMG not found: {dmg_path}", file=sys.stderr)
            failed = True
            continue

        sig = get_dmg_signature(sign_update_path, private_key, dmg_path)
        if not sig:
            print(f"Error: Failed to sign {filename}", file=sys.stderr)
            failed = True
            continue

        enclosure.set('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature', sig)
        print(f"Signed {filename}: {sig[:25]}...")

    if failed:
        return False

    tree.write(appcast_path, encoding='utf-8', xml_declaration=True)

    try:
        verify_tree = ET.parse(appcast_path)
    except ET.ParseError as e:
        print(f"Error: Failed to re-parse appcast after signing: {e}", file=sys.stderr)
        return False

    verify_root = verify_tree.getroot()
    for item in verify_root.findall('.//item'):
        enclosure = item.find('enclosure')
        if enclosure is not None:
            sig = enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature')
            if not sig:
                print(f"Error: Verification failed - enclosure has no signature after write", file=sys.stderr)
                return False

    print("Successfully added and verified enclosure signatures")
    return True

if __name__ == '__main__':
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <bin-dir> <appcast.xml> <dmg-dir>", file=sys.stderr)
        print(f"  bin-dir: Directory containing sign_update binary", file=sys.stderr)
        print(f"  appcast.xml: Path to appcast file to modify in-place", file=sys.stderr)
        print(f"  dmg-dir: Directory containing DMG files to sign", file=sys.stderr)
        print(f"  SPARKLE_PRIVATE_KEY environment variable: Base64-encoded EdDSA private key", file=sys.stderr)
        sys.exit(1)

    bin_dir = sys.argv[1]
    appcast_path = sys.argv[2]
    dmg_dir = sys.argv[3]

    if not os.path.isdir(bin_dir):
        print(f"Error: bin directory does not exist: {bin_dir}", file=sys.stderr)
        sys.exit(1)

    sign_update_path = os.path.join(bin_dir, "sign_update")
    if not os.path.exists(sign_update_path):
        print(f"Error: sign_update binary not found at {sign_update_path}", file=sys.stderr)
        sys.exit(1)

    private_key = os.environ.get('SPARKLE_PRIVATE_KEY')
    if not private_key:
        print("Error: SPARKLE_PRIVATE_KEY environment variable not set", file=sys.stderr)
        sys.exit(1)

    if not add_signatures_to_appcast(sign_update_path, appcast_path, dmg_dir, private_key):
        sys.exit(1)
