"""XVF3800 USB transport - port of reSpeaker Console's src-tauri/src/xvf/device.rs.

Only vendor control transfers addressed to the device are used, so no interface
is claimed and Linux Voice Assistant keeps working with the board at the same time.
"""

import json
import math
import re
import struct
import time
from pathlib import Path

import usb.core
import usb.util

DEFAULT_VID = 0x2886
USB_TIMEOUT_MS = 5000
CONTROL_SUCCESS = 0
SERVICER_COMMAND_RETRY = 64
MAX_READ_RETRY = 100
REQUEST_OUT = usb.util.CTRL_OUT | usb.util.CTRL_TYPE_VENDOR | usb.util.CTRL_RECIPIENT_DEVICE
REQUEST_IN = usb.util.CTRL_IN | usb.util.CTRL_TYPE_VENDOR | usb.util.CTRL_RECIPIENT_DEVICE
DFU_CLASS, DFU_SUBCLASS, DFU_MODE_PROTOCOL = 0xFE, 0x01, 0x02


def load_parameters(path=Path(__file__).with_name("parameters.rs")):
    """Read the p!(name, resid, cmdid, length, access, kind, description) table
    from reSpeaker Console's src-tauri/src/xvf/parameters.rs."""
    src = path.read_text(encoding="utf-8")
    table = src[src.index("pub static PARAMETERS") : src.index("pub fn find")]
    string, number = r'"((?:[^"\\]|\\.)*)"', r"(\d+)"
    entry = re.compile(
        r"p!\(\s*"
        + r"\s*,\s*".join([string, number, number, number, string, string, string])
        + r"\s*,?\s*\)"
    )
    params = [
        {
            "name": name,
            "resid": int(resid),
            "cmdid": int(cmdid),
            "length": int(length),
            "access": access,
            "kind": kind,
            # Rust string continuation (backslash + newline) is not valid JSON
            "description": json.loads('"' + re.sub(r"\\\n\s*", "", desc) + '"'),
        }
        for name, resid, cmdid, length, access, kind, desc in entry.findall(table)
    ]
    if len(params) != table.count("p!("):
        raise RuntimeError(f"parsed {len(params)} of {table.count('p!(')} parameters")
    return params


PARAMETERS = load_parameters()
BY_NAME = {p["name"]: p for p in PARAMETERS}

# kind -> (struct format, bytes per value, (min, max) for integer kinds)
KINDS = {
    "uint8": ("B", 1, (0, 0xFF)),
    "char": ("B", 1, None),
    "uint16": ("H", 2, (0, 0xFFFF)),
    "uint32": ("I", 4, (0, 0xFFFFFFFF)),
    "int32": ("i", 4, (-0x80000000, 0x7FFFFFFF)),
    "float": ("f", 4, None),
    "radians": ("f", 4, None),
}


class XvfError(Exception):
    pass


def find_parameter(name):
    param = BY_NAME.get(name)
    if param is None:
        raise XvfError(f"Unknown parameter: {name}")
    return param


def response_length(param):
    return 1 + param["length"] * KINDS[param["kind"]][1]


def encode_payload(param, values):
    fmt, _, bounds = KINDS[param["kind"]]
    if fmt == "f":
        return struct.pack("<" + "f" * len(values), *values)
    out = []
    for v in values:
        if bounds and not bounds[0] <= v <= bounds[1]:
            raise XvfError(f"value out of range for {param['kind']}: {v}")
        out.append(int(v) & 0xFF if param["kind"] == "char" else int(v))
    return struct.pack("<" + fmt * len(out), *out)


def decode_response(param, payload):
    fmt, size, _ = KINDS[param["kind"]]
    count = param["length"]
    if param["kind"] == "char":
        raw = bytes(payload[:count])
        return [raw.split(b"\x00", 1)[0].decode(errors="replace")]
    values = struct.unpack("<" + fmt * count, bytes(payload[: count * size]))
    # Non-finite floats are not valid JSON - serde maps them to null as well
    return [None if isinstance(v, float) and not math.isfinite(v) else v for v in values]


def is_dfu_bootloader_device(dev):
    if (dev.bDeviceClass, dev.bDeviceSubClass, dev.bDeviceProtocol) == (
        DFU_CLASS, DFU_SUBCLASS, DFU_MODE_PROTOCOL
    ):
        return True
    try:
        for config in dev:
            for intf in config:
                if (intf.bInterfaceClass, intf.bInterfaceSubClass, intf.bInterfaceProtocol) == (
                    DFU_CLASS, DFU_SUBCLASS, DFU_MODE_PROTOCOL
                ):
                    return True
    except usb.core.USBError:
        pass
    return False


def _string(dev, index):
    if not index:
        return None
    try:
        return usb.util.get_string(dev, index).strip()
    except (usb.core.USBError, ValueError):
        return None


def describe(dev, is_dfu=None):
    return {
        "vid": dev.idVendor,
        "pid": dev.idProduct,
        "bus": dev.bus,
        "address": dev.address,
        "manufacturer": _string(dev, dev.iManufacturer),
        "product": _string(dev, dev.iProduct),
        "serial": _string(dev, dev.iSerialNumber),
        "vidHex": f"0x{dev.idVendor:04x}",
        "pidHex": f"0x{dev.idProduct:04x}",
        "isDfu": is_dfu_bootloader_device(dev) if is_dfu is None else is_dfu,
    }


def list_devices(vid=DEFAULT_VID):
    devices = [describe(d) for d in usb.core.find(find_all=True, idVendor=vid)]
    return sorted(devices, key=lambda d: (d["bus"], d["address"], d["pid"]))


class XvfDevice:
    def __init__(self, vid=DEFAULT_VID, pid=None, bus=None, address=None):
        self.vid, self.pid = vid, pid
        for dev in usb.core.find(find_all=True, idVendor=vid):
            if pid is not None and dev.idProduct != pid:
                continue
            if bus is not None and address is not None and (dev.bus, dev.address) != (bus, address):
                continue
            self._attach(dev)
            return
        pid_display = f"0x{pid:04x}" if pid is not None else "auto"
        raise XvfError(f"device not found (vid=0x{vid:04x}, pid={pid_display})")

    def _attach(self, dev):
        self.dev = dev
        self.descriptor = describe(dev, is_dfu=False)
        self.descriptor["isDfu"] = not self._runtime_probe_available()

    def _runtime_probe_available(self):
        for name in ("VERSION", "BLD_MSG"):
            try:
                self._read_unchecked(BY_NAME[name])
                return True
            except (XvfError, usb.core.USBError):
                pass
        return False

    def close(self):
        usb.util.dispose_resources(self.dev)

    def _reattach(self):
        """The board re-enumerates after a reboot or re-plug - pick up the new handle."""
        self.close()
        dev = usb.core.find(idVendor=self.vid, idProduct=self.descriptor["pid"])
        if dev is None:
            return False
        self._attach(dev)
        return True

    def _transfer(self, fn):
        try:
            return fn()
        except usb.core.USBError as err:
            if err.errno == 19 and self._reattach():
                try:
                    return fn()
                except usb.core.USBError as err2:
                    raise XvfError(f"usb error: {err2.strerror or err2}") from err2
            raise XvfError(f"usb error: {err.strerror or err}") from err

    def _ensure_runtime(self):
        if self.descriptor["isDfu"]:
            raise XvfError("device is in DFU mode; runtime parameter IO is unavailable")

    def write_parameter(self, param, values):
        self._ensure_runtime()
        if param["access"] not in ("wo", "rw"):
            raise XvfError(f"parameter {param['name']} is read-only")
        if len(values) != param["length"]:
            raise XvfError(
                f"{param['name']} expects {param['length']} value(s), got {len(values)}"
            )
        payload = encode_payload(param, values)
        self._transfer(
            lambda: self.dev.ctrl_transfer(
                REQUEST_OUT, 0, param["cmdid"], param["resid"], payload, USB_TIMEOUT_MS
            )
        )

    def read_parameter(self, param):
        self._ensure_runtime()
        return self._transfer(lambda: self._read_unchecked(param))

    def _read_unchecked(self, param):
        if param["access"] not in ("ro", "rw"):
            raise XvfError(f"parameter {param['name']} is write-only")
        wvalue = 0x80 | param["cmdid"]
        length = response_length(param)
        attempts = 1
        response = self.dev.ctrl_transfer(REQUEST_IN, 0, wvalue, param["resid"], length, USB_TIMEOUT_MS)
        while True:
            if len(response) == 0:
                raise XvfError("unknown status code: 0")
            if response[0] == CONTROL_SUCCESS:
                break
            if response[0] != SERVICER_COMMAND_RETRY:
                raise XvfError(f"unknown status code: {response[0]}")
            if attempts > MAX_READ_RETRY:
                raise XvfError(f"read attempt exceeded {MAX_READ_RETRY} times")
            attempts += 1
            time.sleep(0.01)
            response = self.dev.ctrl_transfer(
                REQUEST_IN, 0, wvalue, param["resid"], length, USB_TIMEOUT_MS
            )
        return decode_response(param, response[1:])
