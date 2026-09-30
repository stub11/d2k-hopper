# Gate 3 — NFQUEUE Forwarding Path

## Result

**Gate 3: PASS**

- Workflow: `Gate 3 — MIPS NFQUEUE Forwarding Path`
- Run ID: `36715017460` (Run #56)
- Tested commit: `37953c1a19dc79e55a5e3aa7e30b19bcec4a780e`
- PR: #24 (Gate 3 evidence/final fixes)
- Merge commit: `fa06cdb0548d44b59c38c438bf93a51ba02dcb26`
- Artifact: `gate3-nfqueue-evidence`
- Artifact ID: `11095719033`
- Artifact SHA-256: `335d98ca46e0f756a10834b174bfbf785f06d1797d29416e47eb239846b0cf46`

## Required evidence

QEMU serial/host evidence from Run #56:

```
GATE3: iptables FORWARD NFQUEUE queue=0 bypass=1 installed
GATE3: launching real /opt/bin/d2kd --mode observe --queue 0
GATE3_READY
...
пакетов 120, байт 6440, пропущено 120, снято 0
потеряно ядром 0, ошибок вердикта 0, ошибок отправки 0, ошибок чтения 0
...
GATE3_D2KD_STOPPED
GATE3: keeping VM alive for host-side queue-bypass probe
HTTP_BYPASS=200
GATE3_RESULT=SUCCESS
GATE3_COUNTERS seen=120 accepted=120 dropped=0 verdict_fail=0 send_fail=0 recv_err=0 lost=0
GATE3: PASS HTTP=20/20 bypass=200 QEMU_RC=0
```

The host-side request loop recorded `HTTP[1]=200` through `HTTP[20]=200`.

Final d2kd criteria:

- `seen=120 > 0`
- `accepted=120 == seen`
- `dropped=0`
- `verdict_fail=0`
- `send_fail=0`
- `recv_err=0`
- `lost=0`
- HTTP responses: **20/20 = 200 OK**
- queue-bypass after d2kd stop: **HTTP_BYPASS=200**
- QEMU exit: **0**
- No forbidden kernel fault signatures were reported: kernel panic, `nf_queue full`, OOM-killer/out-of-memory.

## Network path

The test uses:

1. QEMU MIPS Malta WAN interface with host forwarding on TCP/18080.
2. Guest DNAT from TCP/18080 to `10.20.0.2:80`.
3. Guest `FORWARD` rule inserted with:
   `-I FORWARD -p tcp --dport 80 -j NFQUEUE --queue-num 0 --queue-bypass`
4. Real C `d2kd` running in observe mode on NFQUEUE 0.
5. LAN-side MASQUERADE so the isolated HTTP namespace returns traffic through the MIPS gateway.
6. Legacy Linux 3.2 `PF_BIND(AF_INET)` before queue binding, required for the Malta kernel.
7. A post-stop request verifies `--queue-bypass` while the VM remains alive.

## Artifacts

The workflow uploaded `gate3-nfqueue-evidence` containing the QEMU serial log and built MIPS d2kd evidence files. The artifact is retained by GitHub Actions according to the workflow retention policy.

Gate 3 is closed by the successful Run #56 evidence above.
