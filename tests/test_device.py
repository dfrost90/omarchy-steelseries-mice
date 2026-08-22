#!/usr/bin/env python3
"""Tests for the device helper.

Two kinds of test live here. The report fixtures were captured from a real
Aerox 3 while pressing the DPI button, with the preset table 800/1200/1600
written by SteelSeries GG — those pin down behaviour that only hardware could
have revealed.

The rest sweep every device rivalcfg knows. None of that hardware is here, but
capability derivation and payload building are pure functions of the profile,
so a device nobody owns can still be checked for the mistakes that actually
happen: a missing field, a range that reads backwards, a table the panel would
render as an empty row.
"""

import importlib.machinery
import importlib.util
import pathlib
import sys

HELPER = pathlib.Path(__file__).parent.parent / "scripts" / "steelseries-device"
spec = importlib.util.spec_from_loader(
    "steelseries_device",
    importlib.machinery.SourceFileLoader("steelseries_device", str(HELPER)),
)
device = importlib.util.module_from_spec(spec)
spec.loader.exec_module(device)

AEROX3 = "1038:1836"
PROFILES = device.profiles()

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


def aerox3_setting():
    return device.sensitivity_setting(PROFILES[AEROX3])


def decode(hexstr):
    return device.decode_report(report(hexstr), aerox3_setting(), AEROX3)


# --- decoding a button press -----------------------------------------------
#
# Captured verbatim: 0xad, preset count, 0-based selection, then one encoded
# DPI byte per preset. 0x12/0x1b/0x24 are 800/1200/1600 in the device's table.

FIRST = "ad 03 00 12 1b 24" + " 00" * 58
SECOND = "ad 03 01 12 1b 24" + " 00" * 58
THIRD = "ad 03 02 12 1b 24" + " 00" * 58

check("decodes the selected index", 0, decode(FIRST)["selected"])
check("decodes a later selection", 2, decode(THIRD)["selected"])
check("decodes the preset table", [800, 1200, 1600], decode(SECOND)["presets"])
check(
    "reads only as many presets as the count byte claims",
    2,
    len(decode("ad 02 00 12 1b" + " 00" * 59)["presets"]),
)
check("ignores reports that are not DPI notifications", None, decode("01 02 03 04"))
check("ignores an empty report", None, device.decode_report(b"", aerox3_setting(), AEROX3))
check("ignores a truncated report", None, decode("ad 03 00 12"))
check(
    "ignores a report whose selection exceeds its own table",
    None,
    decode("ad 02 05 12 1b" + " 00" * 59),
)
check(
    "ignores a report claiming more presets than the device holds",
    None,
    decode("ad 09 00 12 1b 24 12 1b 24 12 1b 24" + " 00" * 52),
)
check(
    "ignores a DPI code the device table does not define",
    None,
    decode("ad 01 00 13" + " 00" * 60),
)


# --- outgoing payload ------------------------------------------------------
#
# The device numbers the selected preset from 0, but rivalcfg's profile
# declares first_preset: 1 and adds it. Verified against hardware: writing
# byte 0x00 makes the mouse report index 0, and 0x02 reports index 2, while
# the byte rivalcfg would send for the last of three presets (0x03) is out of
# range and silently discarded.
def payload_hex(presets, selected, ident=AEROX3):
    setting = device.sensitivity_setting(PROFILES[ident])
    return " ".join(
        "%02x" % b for b in device.sensitivity_payload(setting, ident, presets, selected)
    )


check(
    "the first preset is selected with a zero byte",
    "2d 03 00 12 1b 24",
    payload_hex([800, 1200, 1600], 0),
)
check(
    "the last preset is selected in range, not one past the end",
    "2d 03 02 12 1b 24",
    payload_hex([800, 1200, 1600], 2),
)
check(
    "a middle preset selects itself",
    "2d 03 01 12 1b 24",
    payload_hex([800, 1200, 1600], 1),
)
check(
    "a single-preset table encodes one code and selects it",
    "2d 01 00 12",
    payload_hex([800], 0),
)
check(
    "the payload round-trips through the decoder",
    {"selected": 2, "presets": [800, 1200, 1600]},
    decode(
        "ad "
        + " ".join(payload_hex([800, 1200, 1600], 2).split()[1:])
        + " 00" * 58
    ),
)

# A device rivalcfg describes as numbering from 1 is left alone: the override
# applies only where the real numbering has been checked, so an unverified
# device gets exactly the bytes rivalcfg would have sent.
RIVAL3 = next(
    ident
    for ident, profile in PROFILES.items()
    if profile["name"].startswith("SteelSeries Rival 3")
    and (device.sensitivity_setting(profile) or {}).get("first_preset") == 1
)
RIVAL3_SETTING = device.sensitivity_setting(PROFILES[RIVAL3])
check(
    "an unverified device keeps rivalcfg's own preset numbering",
    1,
    device.sensitivity_payload(RIVAL3_SETTING, RIVAL3, [800, 1600], 0)[
        len(RIVAL3_SETTING["command"]) + 1
    ],
)
check(
    "the verified override changes the Aerox 3 and nothing else",
    ["1038:1836"],
    sorted(device.VERIFIED),
)


# --- capabilities, across every device rivalcfg knows -----------------------

CAPS = {ident: device.capabilities(profile, ident) for ident, profile in PROFILES.items()}

check("every known device yields capabilities", [], [i for i, c in CAPS.items() if c is None])
check(
    "the Aerox 3 is the one device marked verified",
    ["1038:1836"],
    sorted(i for i, c in CAPS.items() if c["verified"]),
)
check(
    "every device offers at least one polling rate",
    [],
    [i for i, c in CAPS.items() if not c["pollingOptions"]],
)
check(
    "every DPI range runs upwards",
    [],
    [i for i, c in CAPS.items() if c["dpiMin"] > c["dpiMax"]],
)
check(
    "a DPI range always has a step, and a fixed list never does",
    [],
    [i for i, c in CAPS.items() if bool(c["dpiValues"]) == bool(c["dpiStep"])],
)
check(
    "every device has room for at least one preset",
    [],
    [i for i, c in CAPS.items() if not 1 <= c["presetMin"] <= c["presetMax"]],
)
check(
    "the default table fits the device it belongs to",
    [],
    [
        i
        for i, c in CAPS.items()
        if not c["presetMin"] <= len(c["defaultPresets"]) <= c["presetMax"]
    ],
)
check(
    "every default DPI lies inside the device's own range",
    [],
    [
        i
        for i, c in CAPS.items()
        if any(not c["dpiMin"] <= dpi <= c["dpiMax"] for dpi in c["defaultPresets"])
    ],
)
check(
    "every default polling rate is one the device accepts",
    [],
    [i for i, c in CAPS.items() if c["defaultPolling"] not in c["pollingOptions"]],
)
check(
    "fixed-slot devices are never offered a selection they cannot take",
    [],
    [i for i, c in CAPS.items() if c["mode"] == "pair" and (c["selectable"] or c["tracking"])],
)
check(
    "fixed-slot devices hold exactly two slots",
    [],
    [i for i, c in CAPS.items() if c["mode"] == "pair" and (c["presetMin"], c["presetMax"]) != (2, 2)],
)
check(
    "nothing is tracked that cannot also be selected",
    [],
    [i for i, c in CAPS.items() if c["tracking"] and not c["selectable"]],
)


# --- payloads, across every device that holds a preset table ---------------
#
# Building a payload exercises rivalcfg's encoder against the profile's own
# limits. A profile whose declared range its encoder rejects would fail here
# rather than on somebody's desk.

def counts_presets(setting, byte, expected):
    """Whether the byte after the command names `expected` presets.

    Most devices put the count there as a plain number. The Sensei TEN instead
    puts a bitmask with one bit per enabled preset, which is why this is worth
    asking rather than assuming.
    """
    if setting.get("count_mode") == "flag":
        return bin(byte).count("1") == expected
    return byte == expected


TABLES = {i: c for i, c in CAPS.items() if c["mode"] == "table"}
broken = []
for ident, caps in TABLES.items():
    setting = device.sensitivity_setting(PROFILES[ident])
    table = caps["defaultPresets"]
    width = len(setting["command"])
    try:
        for index in range(len(table)):
            payload = device.sensitivity_payload(setting, ident, table, index)
            base = device.first_preset(setting, ident)
            if list(payload[:width]) != list(setting["command"]):
                broken.append((ident, "command prefix"))
            elif not counts_presets(setting, payload[width], len(table)):
                broken.append((ident, "preset count"))
            elif payload[width + 1] != index + base:
                broken.append((ident, "selection byte"))
    except Exception as error:  # noqa: BLE001 - the failure is the assertion
        broken.append((ident, repr(error)))

check("every preset table encodes for every device that holds one", [], broken)

edges = []
for ident, caps in TABLES.items():
    setting = device.sensitivity_setting(PROFILES[ident])
    for dpi in (caps["dpiMin"], caps["dpiMax"]):
        try:
            device.sensitivity_payload(setting, ident, [dpi], 0)
        except Exception as error:  # noqa: BLE001
            edges.append((ident, dpi, repr(error)))

check("both ends of every DPI range encode", [], edges)

full = []
for ident, caps in TABLES.items():
    setting = device.sensitivity_setting(PROFILES[ident])
    table = [caps["dpiMin"]] * caps["presetMax"]
    try:
        device.sensitivity_payload(setting, ident, table, caps["presetMax"] - 1)
    except Exception as error:  # noqa: BLE001
        full.append((ident, repr(error)))

check("a full table selecting its last preset encodes everywhere", [], full)


# --- which devices the panel promises to follow ----------------------------

check(
    "tracking is claimed only where the report layout is the one we decoded",
    [],
    [
        ident
        for ident, caps in TABLES.items()
        if caps["tracking"]
        and not (
            len(device.sensitivity_setting(PROFILES[ident])["command"]) == 1
            and device.sensitivity_setting(PROFILES[ident]).get("dpi_length_byte") == 1
            and "output_choices" in device.sensitivity_setting(PROFILES[ident])
        )
    ],
)
check(
    "a two-byte DPI code is not claimed as trackable",
    False,
    any(
        caps["tracking"]
        and device.sensitivity_setting(PROFILES[ident]).get("dpi_length_byte") != 1
        for ident, caps in TABLES.items()
    ),
)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
