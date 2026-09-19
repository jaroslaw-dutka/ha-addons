"""reSpeaker Console backend for Home Assistant ingress.

Serves the web build of reSpeaker Console and implements its Tauri commands
(src-tauri/src/xvf/commands.rs) over HTTP:
  POST /api/invoke/<command>  - JSON args in, {"result": ...} or {"error": "..."} out
  GET  /api/events            - server-sent events for "xvf://log"
"""

import json
import mimetypes
import os
import queue
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import usb.core

import xvf_usb
from xvf_usb import XvfDevice, XvfError, find_parameter

PORT = int(os.environ.get("CONSOLE_PORT", "8538"))
# The add-on runs on the host network - only the Supervisor ingress proxy may connect
ALLOWED_CLIENTS = set(os.environ.get("CONSOLE_ALLOW", "172.30.32.2").split(","))
WWW = Path(os.environ.get("CONSOLE_WWW", Path(__file__).with_name("www"))).resolve()
DFU_HINT = (
    "Firmware flashing is not available in the Home Assistant add-on. "
    "Use reSpeaker Console on a computer to update the XVF3800 firmware."
)

device_lock = threading.Lock()
current = None  # XvfDevice
subscribers = set()
subscribers_lock = threading.Lock()


def emit_log(level, message):
    print(f"console: [{level}] {message}", flush=True)
    event = {
        "event": "xvf://log",
        "payload": {
            "level": level,
            "message": message,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        },
    }
    with subscribers_lock:
        for q in subscribers:
            q.put(event)


def require_device():
    if current is None:
        raise XvfError("no device is currently connected")
    return current


def release(message):
    global current
    if current is not None:
        current.close()
        current = None
        emit_log("info", message)


def normalize_values(param, values):
    if len(values) != param["length"]:
        raise XvfError(f"{param['name']} expects {param['length']} value(s), got {len(values)}")
    out = []
    for v in values:
        if isinstance(v, bool):
            out.append(1.0 if v else 0.0)
        elif isinstance(v, (int, float)):
            out.append(float(v))
        elif isinstance(v, str):
            try:
                out.append(float(v))
            except ValueError as err:
                raise XvfError(f"cannot parse '{v}' as number: {err}") from err
        else:
            raise XvfError(f"unsupported value type: {v!r}")
    return out


# ----- Commands (same names, arguments and results as the Tauri build) -----

def xvf_list_commands():
    return xvf_usb.PARAMETERS


def xvf_list_devices(vid=None):
    vid = vid or xvf_usb.DEFAULT_VID
    try:
        devices = xvf_usb.list_devices(vid)
    except usb.core.USBError as err:
        emit_log("error", f"Failed to list devices: {err}")
        raise XvfError(str(err)) from err
    emit_log("info", f"Scanned USB bus for vid=0x{vid:04x}, found {len(devices)} device(s)")
    return devices


def xvf_connect(args=None):
    global current
    args = args or {}
    if current is not None:
        emit_log("info", "Closing previous device before reconnecting")
        release("Released current USB device handle")
    try:
        dev = XvfDevice(
            vid=args.get("vid") or xvf_usb.DEFAULT_VID,
            pid=args.get("pid"),
            bus=args.get("bus"),
            address=args.get("address"),
        )
    except (XvfError, usb.core.USBError) as err:
        emit_log("error", f"Connect failed: {err}")
        raise XvfError(str(err)) from err
    d = dev.descriptor
    emit_log(
        "info",
        f"Connected to {d['manufacturer'] or '<unknown>'} {d['product'] or '<unknown>'} "
        f"({d['serial'] or '<no serial>'}) bus={d['bus']} addr={d['address']}",
    )
    current = dev
    return d


def xvf_disconnect():
    release("Disconnected from device")


def xvf_release_device():
    release("Released current USB device handle")


def xvf_current_device():
    # Asked when the page loads - unlike the desktop app there is no "scan and connect"
    # moment in a panel, so attach to the board right away when it is on the bus
    if current is None and xvf_usb.list_devices():
        try:
            xvf_connect()
        except XvfError:
            pass
    return current.descriptor if current is not None else None


def xvf_read(name):
    param = find_parameter(name)
    dev = require_device()
    try:
        return dev.read_parameter(param)
    except XvfError as err:
        emit_log("error", f"Read {name} failed: {err}")
        raise


def xvf_write(name, values):
    param = find_parameter(name)
    floats = normalize_values(param, values)
    dev = require_device()
    try:
        dev.write_parameter(param, floats)
    except XvfError as err:
        emit_log("error", f"Write {name} failed: {err}")
        raise
    emit_log("info", f"Write {name} = {floats}")


def xvf_read_many(names):
    results = []
    for name in names:
        try:
            values = require_device().read_parameter(find_parameter(name))
            results.append({"name": name, "ok": True, "values": values, "error": None})
        except XvfError as err:
            results.append({"name": name, "ok": False, "values": [], "error": str(err)})
    return results


def xvf_reboot_device():
    global current
    dev = require_device()
    # The board re-enumerates; the add-on also restarts Voice Assistant for the new device
    dev.write_parameter(find_parameter("REBOOT"), [1.0])
    emit_log("warn", "Rebooting device; USB connection will be reset")
    time.sleep(0.2)
    dev.close()
    current = None


def xvf_check_dfu_util():
    return {
        "available": False,
        "executable": "dfu-util",
        "versionOutput": "",
        "listOutput": "",
        "hint": DFU_HINT,
    }


def xvf_flash_firmware(path=None):
    emit_log("error", DFU_HINT)
    raise XvfError(DFU_HINT)


COMMANDS = {
    fn.__name__: fn
    for fn in (
        xvf_list_commands, xvf_list_devices, xvf_connect, xvf_disconnect, xvf_release_device,
        xvf_current_device, xvf_read, xvf_write, xvf_read_many, xvf_reboot_device,
        xvf_check_dfu_util, xvf_flash_firmware,
    )
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, status, body, content_type="application/json", cache="no-store"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", cache)
        self.end_headers()
        self.wfile.write(data)

    def _allowed(self):
        if self.client_address[0] in ALLOWED_CLIENTS:
            return True
        self._send(403, {"error": "forbidden"})
        return False

    def do_GET(self):
        if not self._allowed():
            return
        path = self.path.split("?", 1)[0]
        if path == "/api/events":
            return self._events()
        file = (WWW / path.lstrip("/")).resolve()
        if path == "/" or not file.is_file() or WWW not in file.parents:
            file = WWW / "index.html"
        content_type = mimetypes.guess_type(file.name)[0] or "application/octet-stream"
        # Vite puts content hashes in asset names
        cache = "public, max-age=31536000, immutable" if "/assets/" in path else "no-cache"
        self._send(200, file.read_bytes(), content_type, cache)

    def do_POST(self):
        if not self._allowed():
            return
        path = self.path.split("?", 1)[0]
        command = COMMANDS.get(path.removeprefix("/api/invoke/"))
        if not path.startswith("/api/invoke/") or command is None:
            return self._send(404, {"error": f"unknown command: {path}"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            args = json.loads(self.rfile.read(length) or b"{}")
            with device_lock:
                result = command(**args)
            self._send(200, {"result": result})
        except XvfError as err:
            self._send(400, {"error": str(err)})
        except (TypeError, ValueError) as err:
            self._send(400, {"error": f"invalid arguments: {err}"})

    def _events(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        q = queue.Queue()
        with subscribers_lock:
            subscribers.add(q)
        try:
            while True:
                try:
                    data = f"data: {json.dumps(q.get(timeout=15))}\n\n"
                except queue.Empty:
                    data = ": keepalive\n\n"
                self.wfile.write(data.encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with subscribers_lock:
                subscribers.discard(q)
            self.close_connection = True


if __name__ == "__main__":
    mimetypes.add_type("text/javascript", ".js")
    mimetypes.add_type("image/svg+xml", ".svg")
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print(f"console: reSpeaker Console listening on port {PORT}", flush=True)
    server.serve_forever()
