package control

import (
    "encoding/binary"
    "net"
    "os"
    "path/filepath"
    "testing"
)

func TestSetPlanAddr6WireFormat(t *testing.T) {
    dir := t.TempDir()
    path := filepath.Join(dir, "ctl.sock")
    ln, err := net.Listen("unix", path)
    if err != nil { t.Fatal(err) }
    defer ln.Close()

    got := make(chan []byte, 1)
    go func() {
        c, err := ln.Accept()
        if err != nil { return }
        defer c.Close()
        hdr := make([]byte, 6)
        if _, err := c.Read(hdr); err != nil { return }
        n := int(binary.BigEndian.Uint32(hdr[:4])) - 2
        body := make([]byte, n)
        if _, err := c.Read(body); err != nil { return }
        got <- append(hdr, body...)
    }()

    c, err := Dial(path)
    if err != nil { t.Fatal(err) }
    defer c.Close()

    ip := [16]byte{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1}
    tlv := []byte{1, 2, 3}
    if err := c.SetPlanAddr6(ip, tlv); err != nil { t.Fatal(err) }

    frame := <-got
    if binary.BigEndian.Uint16(frame[4:6]) != CmdSetAddr6 { t.Fatalf("command %#x", binary.BigEndian.Uint16(frame[4:6])) }
    if len(frame) != 6+16+len(tlv) { t.Fatalf("frame length %d", len(frame)) }
    if string(frame[6:22]) != string(ip[:]) { t.Fatal("IPv6 address bytes changed") }
    if string(frame[22:]) != string(tlv) { t.Fatal("TLV bytes changed") }
}

func TestNextParsesTypedIPv6Key(t *testing.T) {
    dir := t.TempDir()
    path := filepath.Join(dir, "ctl.sock")
    ln, err := net.Listen("unix", path)
    if err != nil { t.Fatal(err) }
    defer ln.Close()

    go func() {
        c, err := ln.Accept()
        if err != nil { return }
        defer c.Close()
        body := make([]byte, 37)
        body[0] = 6
        for i := 0; i < 16; i++ { body[1+i] = byte(i) }
        for i := 0; i < 16; i++ { body[17+i] = byte(16+i) }
        binary.BigEndian.PutUint16(body[33:35], 443)
        binary.BigEndian.PutUint16(body[35:37], 50000)
        frame := make([]byte, 6+len(body))
        binary.BigEndian.PutUint32(frame[:4], uint32(2+len(body)))
        binary.BigEndian.PutUint16(frame[4:6], EvHello)
        copy(frame[6:], body)
        _, _ = c.Write(frame)
    }()

    c, err := Dial(path)
    if err != nil { t.Fatal(err) }
    defer c.Close()
    ev, err := c.Next()
    if err != nil { t.Fatal(err) }
    if ev.Key.Family != 6 { t.Fatalf("family %d", ev.Key.Family) }
    if ev.Key.LowIP6[0] != 0 || ev.Key.HighIP6[15] != 31 { t.Fatal("IPv6 key corrupted") }
    if ev.Key.LowPort != 443 || ev.Key.HighPort != 50000 { t.Fatal("ports corrupted") }
}

func TestDelPlanAddr6WireFormat(t *testing.T) {
    dir := t.TempDir()
    path := filepath.Join(dir, "ctl.sock")
    ln, err := net.Listen("unix", path)
    if err != nil { t.Fatal(err) }
    defer ln.Close()

    done := make(chan []byte, 1)
    go func() {
        c, err := ln.Accept()
        if err != nil { return }
        defer c.Close()
        buf := make([]byte, 24)
        n, _ := c.Read(buf)
        done <- buf[:n]
    }()
    c, err := Dial(path)
    if err != nil { t.Fatal(err) }
    defer c.Close()
    ip := [16]byte{0x20,1,0xdb,0x8,0,0,0,0,0,0,0,0,0,0,0,2}
    if err := c.DelPlanAddr6(ip); err != nil { t.Fatal(err) }
    frame := <-done
    if binary.BigEndian.Uint16(frame[4:6]) != CmdDelAddr6 { t.Fatalf("command %#x", binary.BigEndian.Uint16(frame[4:6])) }
    if string(frame[6:]) != string(ip[:]) { t.Fatal("IPv6 address bytes changed") }
    _ = os.Remove(path)
}
