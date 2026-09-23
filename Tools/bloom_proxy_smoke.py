"""Forwarding a port out of a booted bloom-runner, the way the Mac does it.

`runner-smoke.py` calls `check_port_forwarding` once the server answers. It lists what is listening
with `listening_ports`, opens `GET /_bloom/v1/proxy?port=` to a TCP echo listener it started
itself, and checks that bytes go through both ways; then it checks the three refusals a client
acts on: no terminal ability (4401), one of Bloom's own ports (4403) and nothing listening (4502).

**This is the splice on the platform it ships for.** The Swift tests drive the route on whatever
the suite runs on; this drives the packaged binary on Linux, with a real socket at both ends, in
`packaged-runner` and in `Tools/sprite-smoke.sh`. A Sprite is Linux, so a forward that only worked
on a Mac would be found here and not by anybody's database client.

Standard library only, like the smoke: the WebSocket client below is the dozen lines of RFC 6455 a
client needs, masking included, because a server must refuse an unmasked frame from a client.
"""

import base64
import json
import os
import socket
import struct
import threading

TEXT, BINARY, CLOSE = 0x1, 0x2, 0x8
# `MachineSocket.maximumFrame`.
MAXIMUM_CLIENT_FRAME = 1 << 14


class WebSocket:
    def __init__(self, port, path):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=15)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                raise AssertionError(f"the proxy closed before upgrading: {head!r}")
            head += chunk
        status = head.split(b"\r\n", 1)[0]
        assert b" 101 " in status, status

    def send(self, opcode, payload):
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            header = struct.pack("!BB", 0x80 | opcode, 0x80 | length)
        elif length < 1 << 16:
            header = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, length)
        else:
            header = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, length)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def _exactly(self, count):
        data = b""
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise AssertionError("the proxy hung up mid-frame")
            data += chunk
        return data

    def receive(self):
        """The next frame as (opcode, payload). A close frame's payload is its code and reason."""
        first, second = self._exactly(2)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._exactly(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._exactly(8))[0]
        return first & 0x0F, self._exactly(length)

    def close_code(self):
        """Reads until the server closes, and answers its close code."""
        while True:
            opcode, payload = self.receive()
            if opcode == CLOSE:
                return struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else None

    def close(self):
        self.sock.close()


def echo_listener():
    """A TCP service inside the machine: answers every byte with the same byte. Returns its port."""
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen()

    def serve(connection):
        with connection:
            while data := connection.recv(65536):
                connection.sendall(data)

    def accept():
        while True:
            connection, _ = server.accept()
            threading.Thread(target=serve, args=(connection,), daemon=True).start()

    threading.Thread(target=accept, daemon=True).start()
    return server.getsockname()[1]


def unused_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def forward(port, target, token):
    socket_ = WebSocket(port, f"/_bloom/v1/proxy?port={target}")
    socket_.send(TEXT, json.dumps({"kind": "auth", "token": token}).encode())
    return socket_


def check_port_forwarding(port, request, session, viewer):
    """`request` is the smoke's own RPC helper; `session` may forward and `viewer` may only look."""
    echo = echo_listener()

    listing = {"protocol": "bloom-workspace", "version": 1, "command_id": "smoke-ports",
               "operation": {"kind": "listening_ports"}}
    status, body = request(port, "POST", "/_bloom/v1/rpc", token=session, body=listing)
    result = json.loads(body).get("result", {})
    assert status == 200 and result.get("kind") == "ports", (status, body)
    listed = {record["port"]: record["reserved"] for record in result["ports"]}
    assert listed.get(echo) is False, (echo, listed)
    # The Runner's own port is listening, since this request reached it, and must say it is Bloom's.
    assert listed.get(port) is True, (port, listed)

    through = forward(port, echo, session)
    # Many frames of the largest size the machine accepts from a client (a larger one closes the
    # socket with 1009, see `MachineSocket`), and far more than one TCP read, so the splice has to
    # carry it in pieces and keep them in order.
    sent = os.urandom(200_000)

    # On a thread of its own, beside the reads: an echo that cannot hand its bytes back stops
    # reading, and a writer waiting on it would wait for ever.
    def write():
        for start in range(0, len(sent), MAXIMUM_CLIENT_FRAME):
            through.send(BINARY, sent[start:start + MAXIMUM_CLIENT_FRAME])

    writer = threading.Thread(target=write, daemon=True)
    writer.start()
    received = b""
    while len(received) < len(sent):
        opcode, payload = through.receive()
        assert opcode == BINARY, (opcode, payload[:80])
        received += payload
    writer.join(timeout=30)
    assert received == sent, "the bytes that came back are not the bytes that went"
    through.close()

    refusals = [
        ("a token without the terminal ability", echo, viewer, 4401),
        ("Bloom's own port", port, session, 4403),
        ("a port nothing listens on", unused_port(), session, 4502),
    ]
    for description, target, token, expected in refusals:
        refused = forward(port, target, token)
        code = refused.close_code()
        refused.close()
        assert code == expected, f"forwarding {description} closed with {code}, not {expected}"

    print(f"FORWARD OK: {len(sent)} bytes through /_bloom/v1/proxy and back, and 4401, 4403, 4502 where they belong")
