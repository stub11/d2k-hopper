# Gate 6 — Physical Preflight for Hopper 3810

This checklist is a hard stop before the first physical KN-3810 run. It is deliberately conservative: if any mandatory check is unknown or fails, do not enable D2K.

## 0. Access and recovery

Before changing anything, verify that an independent management path is available:

- SSH access works and the administrator can obtain a shell.
- Web management is reachable from a second device/path if possible.
- The router can be power-cycled without losing physical access.
- Keep the original firmware/recovery procedure available.

Do not perform the first activation remotely without a tested emergency access path.

## 1. Backup KeeneticOS startup configuration

Keenetic documents startup-config as the persistent user configuration file and recommends saving it before recovery/reset operations. The supported backup path is the router Web interface:

1. Open **System settings**.
2. Open **System files**.
3. Select **startup-config**.
4. Save the file to the operator workstation.
5. Record the backup filename, timestamp and target router.

Do not treat a shell dump of running-config as a substitute for the startup-config file backup.

After any intentional configuration change, save the configuration using the Keenetic CLI command supported by the installed KeeneticOS release:

    system configuration save

## 2. Identify the exact hardware/software profile

From SSH, record:

    uname -a
    uname -m
    free
    ndmc -c 'show version'

Do not assume that a configuration profile in this repository proves support for the installed KeeneticOS version.

## 3. Verify kernel prerequisites

Run exactly:

    lsmod | grep -E "xt_NFQUEUE|nfnetlink_queue"

Also verify the functional interfaces used by the D2K preflight:

    test -e /proc/net/netfilter/nfnetlink_queue && echo "OK nfnetlink_queue" || echo "FAIL nfnetlink_queue"
    grep -qw NFQUEUE /proc/net/ip_tables_targets && echo "OK NFQUEUE" || echo "FAIL NFQUEUE"
    grep -qw connbytes /proc/net/ip_tables_matches && echo "OK connbytes" || echo "FAIL connbytes"

Important: an empty lsmod result is not by itself proof that the feature is unavailable, because a required facility may be built into the kernel rather than exposed as a separately listed module. The /proc checks are the functional gate used by this repository's preflight.

## 4. Verify Entware and USB-backed /opt

Check:

    test -d /opt && echo "OK /opt" || echo "FAIL /opt"
    test -w /opt && echo "OK /opt writable" || echo "FAIL /opt writable"
    mount | grep -E ' on /opt( |$)'
    command -v opkg && opkg print-architecture

The repository treats D2K as an Entware application on the USB-backed /opt filesystem. Do not proceed if /opt is missing, read-only, or not the intended storage.

## 5. Verify D2K installation state without activation

Run the repository read-only preflight first:

    sh scripts/hopper-preflight.sh --strict

Then inspect the installed service:

    /opt/etc/init.d/S99d2k status
    ls -l /opt/sbin/d2k /opt/sbin/d2kd
    ls -l /opt/d2k/config /opt/d2k/state /opt/d2k/log 2>/dev/null || true

Do not use an activation command until the preflight is clean.

## 6. Read-only diagnostics and Panic Button / Emergency Rollback

Before activation, run the read-only diagnostics:

    sh scripts/hopper-detect.sh --dry-run

Keep scripts/rollback.sh available as the emergency rollback command set. It is intentionally separate from the activation path.

## 7. Panic Button / Emergency Rollback

The repository already contains scripts/rollback.sh. Its tested contract is to stop the PID recorded in D2K_PIDFILE and remove the D2K_HOPPER iptables chain from the filter, mangle and nat tables.

First try the service-level stop:

    /opt/etc/init.d/S99d2k stop

Then, if the datapath must be stopped immediately, use:

    if [ -r /var/run/d2kd.pid ]; then
        kill -9 "$(cat /var/run/d2kd.pid)" 2>/dev/null || true
        rm -f /var/run/d2kd.pid
    fi

Finally detach and delete the D2K chain:

    for table in filter mangle nat; do
        while iptables -t "$table" -D FORWARD -j D2K_HOPPER 2>/dev/null; do :; done
        iptables -t "$table" -F D2K_HOPPER 2>/dev/null || true
        iptables -t "$table" -X D2K_HOPPER 2>/dev/null || true
    done

Verify:

    ps | grep '[d]2kd' || true
    iptables -t filter -S | grep D2K_HOPPER || true
    iptables -t mangle -S | grep D2K_HOPPER || true
    iptables -t nat -S | grep D2K_HOPPER || true

If any D2K rule remains or d2kd continues running, stop the experiment and use the independent router recovery procedure.

## 8. First physical activation rule

For the first KN-3810 run:

1. Start in observation mode.
2. Keep the management connection open.
3. Monitor d2kd logs and router CPU/RAM.
4. Confirm ordinary traffic remains usable.
5. Do not combine the first D2K activation with unrelated KeeneticOS configuration changes.
6. Keep the Panic Button commands in a separate terminal ready to paste.

## 9. Stop conditions

Immediately roll back if any of these occur:

- SSH/Web management becomes unreliable.
- LAN/WAN connectivity is lost unexpectedly.
- d2kd repeatedly restarts.
- /opt disappears or becomes read-only.
- NFQUEUE/iptables state differs from the expected preflight.
- CPU/RAM pressure becomes abnormal.
- The operator cannot confirm that the D2K chain has been detached.

This checklist does not claim that the physical KN-3810 has been tested. It is a preflight gate only.
