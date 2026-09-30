# Gate 3 — NFQUEUE Forwarding Path

**PASS — verified by GitHub Actions Run 36715017460 (run #56).**

Verified commit: `37953c1a19dc79e55a5e3aa7e30b19bcec4a780e`.

## Serial evidence

```
GATE3_RESULT=SUCCESS
GATE3_COUNTERS seen=120 accepted=120 dropped=0 verdict_fail=0 send_fail=0 recv_err=0 lost=0
GATE3: PASS HTTP=20/20 bypass=200 QEMU_RC=0
HTTP_BYPASS=200
```

The d2kd counters also report:

```
пакетов 120, байт 6440, пропущено 120, снято 0
потеряно ядром 0, ошибок вердикта 0, ошибок отправки 0, ошибок чтения 0
```

All 20 HTTP probes returned HTTP 200. The post-stop queue-bypass probe returned HTTP 200 while the VM remained alive after d2kd exited.

## CI and artifact

- Workflow: Gate 3 — MIPS NFQUEUE Forwarding Path
- Run ID: **36715017460**
- Run number: **56**
- Job: `nfqueue-forwarding`
- Conclusion: **success**
- Artifact: `gate3-nfqueue-evidence.zip`
- Artifact ID: **11095719033**
- Artifact size: **438301 bytes**
- Artifact: https://github.com/stub11/d2k-hopper/actions/runs/36715017460/artifacts/11095719033

## Compatibility fixes

- WAN bootstrap uses kernel DHCP before iproute2 is installed.
- Isolated LAN bridge plus MASQUERADE provides the HTTP return path.
- d2kd performs legacy `PF_BIND(AF_INET)` before NFQUEUE queue binding for Debian Malta kernel 3.2.
- FORWARD uses NFQUEUE queue 0 with `--queue-bypass`.
- CI rejects kernel panic, NFQUEUE queue-full and OOM signatures.

## Gate result

Gate 3 NFQUEUE forwarding path is closed based on the successful QEMU serial evidence and preserved CI artifact.
