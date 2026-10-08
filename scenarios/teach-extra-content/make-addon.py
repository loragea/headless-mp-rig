#!/usr/bin/env python3
"""make-addon.py — write content/teach-token.omwaddon, the plugin teach-extra-content loads.

Run:  python3 make-addon.py        (rewrites content/teach-token.omwaddon next to this file)

The plugin is written field by field from the public ESM3 (TES3) record format, so nothing in it
comes from any game: one MISC item record "teach_token" that reuses a mesh the free example-suite
already ships (marker_travel.dae), and one reference to it lying on the floor of exterior cell
0, -7, between the two teaching players. Its master is template.omwgame (example-suite).

ESM3 layout: a record is <4-byte type><uint32 data size><uint32 0><uint32 flags><subrecords>; a
subrecord is <4-byte name><uint32 size><data>. Strings are zero-terminated.
"""
import os
import struct

MASTER = "template.omwgame"
ITEM_ID = "teach_token"


def zstr(s):
    return s.encode("ascii") + b"\0"


def sub(name, data):
    return name.encode("ascii") + struct.pack("<I", len(data)) + data


def record(rtype, subs, flags=0):
    data = b"".join(subs)
    return rtype.encode("ascii") + struct.pack("<III", len(data), 0, flags) + data


def header(num_records):
    author = b"headless-mp-rig".ljust(32, b"\0")
    desc = b"teach-extra-content: one item on the floor of cell 0, -7".ljust(256, b"\0")
    hedr = struct.pack("<fI", 1.3, 0) + author + desc + struct.pack("<I", num_records)
    # DATA is the master's size in bytes; OpenMW does not check it, so 0 keeps this file independent
    # of the example-suite revision.
    return record("TES3", [sub("HEDR", hedr), sub("MAST", zstr(MASTER)), sub("DATA", struct.pack("<Q", 0))])


def misc_item():
    return record("MISC", [
        sub("NAME", zstr(ITEM_ID)),
        sub("MODL", zstr("marker_travel.dae")),         # a mesh in example-suite's game_template/data/meshes
        sub("FNAM", zstr("Teaching Token")),
        sub("MCDT", struct.pack("<fii", 1.0, 1, 0)),    # weight, value, unused
    ])


def cell_with_token():
    # Exterior cell (0, -7): flags 0 (not interior), grid x, grid y. It is not in the master.
    return record("CELL", [
        sub("NAME", zstr("")),
        sub("DATA", struct.pack("<Iii", 0, 0, -7)),
        sub("FRMR", struct.pack("<I", 1)),              # reference number 1 of this plugin
        sub("NAME", zstr(ITEM_ID)),
        sub("DATA", struct.pack("<6f", 4224.0, -53120.0, -2040.0, 0.0, 0.0, 0.0)),  # x y z, rotation
    ])


def main():
    body = [misc_item(), cell_with_token()]
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "content", "teach-token.omwaddon")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as fh:
        fh.write(header(len(body)) + b"".join(body))
    print(out)


if __name__ == "__main__":
    main()
