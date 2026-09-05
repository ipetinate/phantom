"""
Writes the Sparkle appcast for a Phantom release.

Phantom's feed lives where Phantom's releases live: appcast.xml is an asset of
every GitHub release, and the app reads it through the stable alias
    https://github.com/ipetinate/phantom/releases/latest/download/appcast.xml
so no server, bucket or domain is involved — only this repository.

Expects, in the current directory:
    - sign_update.txt   the output of Sparkle's sign_update for Phantom.dmg
    - appcast.xml       the previous release's feed, when there is one; a
                        missing or empty file starts a new feed. The history is
                        kept so a reader several versions behind still sees an
                        entry, and pruned so the file cannot grow forever.

And in the environment:
    - PHANTOM_VERSION   X.Y.Z, what CFBundleShortVersionString says
    - PHANTOM_BUILD     the build number, what CFBundleVersion says — Sparkle
                        compares this one, so it must be monotonic
    - PHANTOM_TAG       the git tag the DMG is published under
    - PHANTOM_COMMIT    the short commit hash

Writes appcast.xml in place.

The build number is the item's identity. An item with the same build is replaced
rather than duplicated: two items claiming one build would make Sparkle report a
bad signature whenever it picked the wrong one.
"""

import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

REPO = "https://github.com/ipetinate/phantom"
MINIMUM_SYSTEM_VERSION = "13.0"
KEEP = 15
PUBDATE = "%a, %d %b %Y %H:%M:%S %z"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

version = os.environ["PHANTOM_VERSION"]
build = os.environ["PHANTOM_BUILD"]
tag = os.environ["PHANTOM_TAG"]
commit = os.environ["PHANTOM_COMMIT"]

with open("sign_update.txt", encoding="utf-8") as f:
    attrs = {}
    for pair in f.read().split(" "):
        key, value = pair.split("=", 1)
        value = value.strip()
        if value.startswith('"'):
            value = value[1:-1]
        attrs[key] = value

for required in ("sparkle:edSignature", "length"):
    if not attrs.get(required):
        sys.exit(f"sign_update.txt has no {required}: the DMG was not signed")

ET.register_namespace("sparkle", SPARKLE)

if os.path.exists("appcast.xml") and os.path.getsize("appcast.xml") > 0:
    tree = ET.parse("appcast.xml")
    channel = tree.find("channel")
else:
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Phantom"
    ET.SubElement(channel, "link").text = f"{REPO}/releases"
    ET.SubElement(channel, "description").text = "Phantom releases"
    ET.SubElement(channel, "language").text = "en"
    tree = ET.ElementTree(root)

namespaces = {"sparkle": SPARKLE}
for item in list(channel.findall("item")):
    sparkle_version = item.find("sparkle:version", namespaces)
    if sparkle_version is not None and sparkle_version.text == build:
        channel.remove(item)
    elif item.find("pubDate") is None:
        channel.remove(item)

items = channel.findall("item")
items.sort(key=lambda i: datetime.strptime(i.find("pubDate").text, PUBDATE))
for item in items[: max(0, len(items) - (KEEP - 1))]:
    channel.remove(item)

item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Phantom {version}"
ET.SubElement(item, "pubDate").text = datetime.now(timezone.utc).strftime(PUBDATE)
ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = MINIMUM_SYSTEM_VERSION
ET.SubElement(item, "link").text = f"{REPO}/releases/tag/{tag}"
ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink").text = f"{REPO}/releases/tag/{tag}"
ET.SubElement(item, "description").text = (
    f"Phantom {version}, build {build}, commit {commit}."
)
ET.SubElement(
    item,
    "enclosure",
    {
        "url": f"{REPO}/releases/download/{tag}/Phantom.dmg",
        "type": "application/octet-stream",
        "length": attrs["length"],
        f"{{{SPARKLE}}}edSignature": attrs["sparkle:edSignature"],
    },
)

ET.indent(tree, space="  ")
tree.write("appcast.xml", encoding="utf-8", xml_declaration=True)
print(f"appcast.xml: {len(channel.findall('item'))} item(s), newest {version} (build {build})")
