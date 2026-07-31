#!/usr/bin/env python3
"""Adds (or replaces) one version's entry in a Sparkle appcast.

Sparkle picks the newest item, so strictly only the latest matters — but keeping
the history means the release-notes of older versions stay readable, and it makes
the feed diffable in git.

Usage:
    update-appcast.py --appcast appcast.xml --version 0.2.0 \
        --url https://.../Claude%20Live%200.2.0.dmg \
        --signature <edSignature> --length <bytes> \
        --min-system 14.0 --notes RELEASE_NOTES.md
"""

import argparse
import html
import os
import re
import xml.etree.ElementTree as ET
from email.utils import format_datetime
from datetime import datetime, timezone

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def notes_to_html(path):
    """Very small Markdown subset → HTML: headings, bullets, paragraphs.

    Sparkle renders the description as HTML in its update window. A full Markdown
    parser would be overkill for release notes written by one person.
    """
    if not path or not os.path.exists(path):
        return "<p>Correzioni e miglioramenti.</p>"

    out, in_list = [], False
    for raw in open(path, encoding="utf-8").read().splitlines():
        line = raw.rstrip()
        if not line.strip():
            if in_list:
                out.append("</ul>")
                in_list = False
            continue
        if line.startswith("#"):
            if in_list:
                out.append("</ul>")
                in_list = False
            level = len(line) - len(line.lstrip("#"))
            out.append(f"<h{min(level+2,6)}>{html.escape(line.lstrip('# ').strip())}</h{min(level+2,6)}>")
        elif line.lstrip().startswith(("- ", "* ")):
            if not in_list:
                out.append("<ul>")
                in_list = True
            text = html.escape(line.lstrip()[2:].strip())
            # `code` spans are the only inline markup worth keeping.
            text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
            out.append(f"<li>{text}</li>")
        else:
            if in_list:
                out.append("</ul>")
                in_list = False
            text = html.escape(line.strip())
            text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
            out.append(f"<p>{text}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def load_or_create(path, title):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        tree = ET.parse(path)
        channel = tree.getroot().find("channel")
        if channel is None:
            raise SystemExit(f"{path}: manca <channel>")
        return tree, channel

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = title
    ET.SubElement(channel, "description").text = f"Aggiornamenti di {title}"
    ET.SubElement(channel, "language").text = "it"
    return ET.ElementTree(rss), channel


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--appcast", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--signature", required=True)
    ap.add_argument("--length", required=True)
    ap.add_argument("--min-system", default="14.0")
    ap.add_argument("--notes")
    ap.add_argument("--title", default="Claude Live")
    args = ap.parse_args()

    tree, channel = load_or_create(args.appcast, args.title)

    # Replace any existing entry for this version, so re-running a release is safe.
    for item in channel.findall("item"):
        version = item.find(f"{{{SPARKLE_NS}}}version")
        if version is not None and version.text == args.version:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Versione {args.version}"
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = args.min_system
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, "description").text = notes_to_html(args.notes)
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": str(args.length),
        "type": "application/octet-stream",
        f"{{{SPARKLE_NS}}}edSignature": args.signature,
    })

    # Newest first: Sparkle does not require it, but it keeps the file readable.
    first_item = channel.find("item")
    if first_item is None:
        channel.append(item)
    else:
        children = list(channel)
        channel.insert(children.index(first_item), item)

    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"appcast aggiornato: {args.appcast} (versione {args.version})")


if __name__ == "__main__":
    main()
