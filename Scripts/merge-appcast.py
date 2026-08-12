#!/usr/bin/env python3
"""Merge a new Sparkle appcast item into an existing cumulative appcast."""

import sys
import xml.etree.ElementTree as ET

def merge_appcasts(existing_path, new_path, output_path, max_versions=10):
    """A missing, empty or corrupt existing_path is bootstrapped; at most max_versions items kept."""

    # Do not also set xmlns:sparkle as an attribute; register_namespace emits it.
    ET.register_namespace('sparkle', 'http://www.andymatuschak.org/xml-namespaces/sparkle')

    existing_tree = None
    existing_root = None

    try:
        existing_tree = ET.parse(existing_path)
        existing_root = existing_tree.getroot()
    except (FileNotFoundError, ET.ParseError):
        existing_root = ET.Element('rss')
        existing_root.set('version', '2.0')
        channel = ET.SubElement(existing_root, 'channel')
        ET.SubElement(channel, 'title').text = 'Orbit'
        existing_tree = ET.ElementTree(existing_root)

    try:
        new_tree = ET.parse(new_path)
        new_root = new_tree.getroot()
    except ET.ParseError as e:
        print(f"Error: Failed to parse new appcast: {e}", file=sys.stderr)
        return False

    new_item = new_root.find('channel/item')
    if new_item is None:
        print("Error: No item found in new appcast", file=sys.stderr)
        return False

    ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
    new_version_elem = new_item.find('sparkle:version', ns)
    if new_version_elem is None:
        print("Error: No sparkle:version in new item", file=sys.stderr)
        return False
    new_version = new_version_elem.text

    existing_channel = existing_root.find('channel')
    if existing_channel is None:
        print("Error: No channel found in existing appcast", file=sys.stderr)
        return False

    for existing_item in list(existing_channel.findall('item')):
        existing_version_elem = existing_item.find('sparkle:version', ns)
        if existing_version_elem is not None and existing_version_elem.text == new_version:
            existing_channel.remove(existing_item)
            break

    first_item = existing_channel.find('item')
    if first_item is not None:
        item_index = list(existing_channel).index(first_item)
        existing_channel.insert(item_index, new_item)
    else:
        existing_channel.append(new_item)

    all_items = existing_channel.findall('item')
    if len(all_items) > max_versions:
        items_to_remove = all_items[max_versions:]
        for item in items_to_remove:
            existing_channel.remove(item)

    existing_tree.write(output_path, encoding='utf-8', xml_declaration=True)
    return True

if __name__ == '__main__':
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <existing> <new> <output> [max_versions]", file=sys.stderr)
        sys.exit(1)

    max_versions = 10
    if len(sys.argv) >= 5:
        try:
            max_versions = int(sys.argv[4])
        except ValueError:
            print(f"Error: max_versions must be an integer, got '{sys.argv[4]}'", file=sys.stderr)
            sys.exit(1)

    if not merge_appcasts(sys.argv[1], sys.argv[2], sys.argv[3], max_versions):
        sys.exit(1)
