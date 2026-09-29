# Hopper preflight and doctor layer

\`scripts/hopper-preflight.sh\` is a read-only gate intended to run before D2K installation or activation on a Keenetic Hopper.

It checks:
- required Entware commands;
- router architecture/model/RAM information;
- \`nfnetlink_queue\`, \`NFQUEUE\` and \`connbytes\` kernel prerequisites;
- Entware \`opkg\` architectures;
- \`/opt\` presence and writability.

It never changes firewall rules, services, configuration or package state. \`--strict\` additionally treats warnings as failures.

The design deliberately separates detection from installation: a failed prerequisite is discovered before D2K changes the running router.
