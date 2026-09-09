"""Virtual pointer for isolated headless compositors used by the test suites."""
import socket
import struct
import time


def cursor_environment(runtime):
    """Hide the test pointer on wlroots versions with software-cursor leakage.

    These suites test image/overlay pixels, not cursor inclusion. A private
    transparent Xcursor avoids depending on compositor cursor-plane support.
    """
    theme = runtime / "icons/ouroshot-test"
    cursors = theme / "cursors"
    cursors.mkdir(parents=True)
    (theme / "index.theme").write_text("[Icon Theme]\nName=ouroshot-test\n")
    data = struct.pack("<4sIII", b"Xcur", 16, 0x10000, 1)
    data += struct.pack("<III", 0xfffd0002, 16, 28)
    data += struct.pack("<IIIIIIIII", 36, 0xfffd0002, 16, 1, 16, 16, 0, 0, 0)
    data += bytes(16 * 16 * 4)
    for name in ("left_ptr", "default", "crosshair"):
        (cursors / name).write_bytes(data)
    return {"XCURSOR_PATH": str(runtime / "icons"), "XCURSOR_THEME": "ouroshot-test", "XCURSOR_SIZE": "16"}


class Pointer:
    def __init__(self, runtime, display):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(3)
        self.sock.connect(str(runtime / display))
        self.buf = b""
        self.width, self.height = 640, 400
        self.send(1, 1, struct.pack("I", 2))
        self.send(1, 0, struct.pack("I", 3))
        manager = None
        while True:
            obj, op, data = self.read()
            if obj == 2 and op == 0:
                name, n = struct.unpack_from("II", data)
                if data[8:8+n-1] == b"zwlr_virtual_pointer_manager_v1":
                    manager = name
            if obj == 3:
                break
        assert manager is not None
        interface = b"zwlr_virtual_pointer_manager_v1\0"
        self.send(2, 0, struct.pack("II", manager, len(interface)) + interface + bytes(-len(interface) % 4) + struct.pack("II", 1, 4))
        self.send(4, 0, struct.pack("II", 0, 5))

    def send(self, obj, op, payload=b""):
        self.sock.sendall(struct.pack("II", obj, ((8+len(payload)) << 16) | op) + payload)

    def read(self):
        while len(self.buf) < 8:
            chunk = self.sock.recv(65536)
            assert chunk, "compositor disconnected"
            self.buf += chunk
        obj, header = struct.unpack_from("II", self.buf)
        size = header >> 16
        while len(self.buf) < size:
            chunk = self.sock.recv(65536)
            assert chunk, "compositor disconnected"
            self.buf += chunk
        data, self.buf = self.buf[8:size], self.buf[size:]
        if obj == 1 and header & 65535 == 0:
            raise RuntimeError(repr(data))
        return obj, header & 65535, data

    def move(self, x, y):
        self.send(5, 1, struct.pack("IIIII", int(time.monotonic()*1000) & 0xffffffff, int(x*256), int(y*256), self.width*256, self.height*256))
        self.send(5, 4)

    def button(self, state, button=272):
        self.send(5, 2, struct.pack("III", int(time.monotonic()*1000) & 0xffffffff, button, state))
        self.send(5, 4)

    def click(self, x, y, button=272):
        self.move(x, y)
        time.sleep(.05)
        self.button(1, button)
        time.sleep(.05)
        self.button(0, button)
