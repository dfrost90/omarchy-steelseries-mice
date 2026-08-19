#!/usr/bin/env python3
"""Tests for the HID report decoding in aerox3-device.

The sample reports here were captured from a real Aerox 3 while pressing the
DPI button, with the preset table 800/1200/1600 written by SteelSeries GG.
"""

import importlib.machinery
import importlib.util
import pathlib
import sys

HELPER = pathlib.Path(__file__).parent.parent / "scripts" / "aerox3-device"
spec = importlib.util.spec_from_loader(
    "aerox3_device", importlib.machinery.SourceFileLoader("aerox3_device", str(HELPER))
)
device = importlib.util.module_from_spec(spec)
spec.loader.exec_module(device)

passed = 0
failed = 0


def check(name, expected, actual):
    global passed, failed
    if expected == actual:
        passed += 1
        print(f"  ok   {name}")
    else:
        failed += 1
        print(f"  FAIL {name}\n       expected: {expected}\n       actual:   {actual}")


def report(hexstr):
    return bytes.fromhex(hexstr.replace(" ", ""))


# Captured verbatim: 0xad, preset count, 0-based selection, then one encoded
# DPI byte per preset. 0x12/0x1b/0x24 are 800/1200/1600 in the device's table.
FIRST = "ad 03 00 12 1b 24" + " 00" * 58
SECOND = "ad 03 01 12 1b 24" + " 00" * 58
THIRD = "ad 03 02 12 1b 24" + " 00" * 58

check("decodes the selected index", 0, device.decode_report(report(FIRST))["selected"])
check("decodes a later selection", 2, device.decode_report(report(THIRD))["selected"])
check(
    "decodes the preset table",
    [800, 1200, 1600],
    device.decode_report(report(SECOND))["presets"],
)
check(
    "reads only as many presets as the count byte claims",
    2,
    len(device.decode_report(report("ad 02 00 12 1b" + " 00" * 59))["presets"]),
)
check(
    "ignores reports that are not DPI notifications",
    None,
    device.decode_report(report("01 02 03 04")),
)
check("ignores an empty report", None, device.decode_report(b""))
check(
    "ignores a truncated report",
    None,
    device.decode_report(report("ad 03 00 12")),
)
check(
    "ignores a report whose selection exceeds its own table",
    None,
    device.decode_report(report("ad 02 05 12 1b" + " 00" * 59)),
)
check(
    "ignores a DPI code the device table does not define",
    None,
    device.decode_report(report("ad 01 00 13" + " 00" * 60)),
)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
