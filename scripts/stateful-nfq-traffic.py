#!/usr/bin/env python3
"""Synthetic complete TCP segments through the real kernel NFQUEUE in a lab netns."""
import socket
import struct
import sys
import time
from pathlib import Path


def checksum(data):
    data += b"\0" * (len(data) % 2)
    total = sum(struct.unpack("!" + "H" * (len(data) // 2), data))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


def packet(reverse, flags, seq, ack, payload):
    a, b = socket.inet_aton("192.0.2.1"), socket.inet_aton("192.0.2.2")
    src, dst = (b, a) if reverse else (a, b)
    ports = (443, 1234) if reverse else (1234, 443)
    tcp = struct.pack("!HHIIBBHHH", *ports, seq, ack, 0x50, flags, 4096, 0, 0)
    pseudo = src + dst + struct.pack("!BBH", 0, 6, len(tcp) + len(payload))
    tcp = tcp[:16] + struct.pack("!H", checksum(pseudo + tcp + payload)) + tcp[18:]
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 40 + len(payload), 0, 0, 64, 6, 0, src, dst)
    ip = ip[:10] + struct.pack("!H", checksum(ip)) + ip[12:]
    return ip + tcp + payload


CASES = [
    (False, 0x18, 101, 201, b"early", 0),
    (False, 0x03, 100, 0, b"", 0),
    (False, 0x02, 100, 0, b"", 1),
    (True, 0x12, 200, 101, b"", 1),
    (False, 0x10, 101, 201, b"", 1),
    (False, 0x18, 101, 201, b"hello", 1),
    (True, 0x18, 201, 106, b"reply", 1),
    (False, 0x11, 106, 206, b"", 1),
    (True, 0x10, 206, 107, b"", 1),
    (True, 0x11, 206, 107, b"", 1),
    (False, 0x10, 107, 207, b"", 1),
    (False, 0x18, 107, 207, b"late", 0),
    (False, 0x02, 300, 0, b"", 1),
    (True, 0x14, 0, 301, b"", 1),
]


if sys.argv[1] == "send":
    with socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, 71)
        for reverse, flags, seq, ack, payload, _ in CASES:
            dst = "192.0.2.1" if reverse else "192.0.2.2"
            sock.sendto(packet(reverse, flags, seq, ack, payload), (dst, 0))
            time.sleep(0.03)
else:
    lines = Path(sys.argv[2]).read_text().splitlines()
    verdicts = [int(line.split()[2]) for line in lines if line.startswith("V ")]
    assert verdicts == [case[-1] for case in CASES], verdicts
    events = [list(map(int, line.split()[1:])) for line in lines if line.startswith("E ")]
    assert [e[-1] for e in events] == list(range(1, len(events) + 1)), events
    assert sum(e[0] == 0x20 for e in events) == 2, events
    assert [e[3] for e in events if e[0] == 0x22] == [1, 2], events
    print("real libnetfilter_queue: PASS (14 kernel packets, ACCEPT/DROP, FIN/RST events)")
