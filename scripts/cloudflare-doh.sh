#!/bin/sh
# D2K — safe Cloudflare DNS-over-HTTPS helper for Keenetic CLI
set -eu

ENDPOINT=${DOH_ENDPOINT:-https://cloudflare-dns.com/dns-query}
BACKUP_DIR=${D2K_BACKUP_DIR:-/opt/var/backups/d2k}
BACKUP_FILE="$BACKUP_DIR/dns-proxy-before-doh.txt"

usage() {
    cat <<'EOF'
Usage:
  cloudflare-doh.sh --dry-run
  cloudflare-doh.sh --apply
  cloudflare-doh.sh --rollback
  cloudflare-doh.sh --help

--dry-run  inspect the current DNS-proxy state and print the commands that would run.
--apply    back up current DNS-proxy state, then add Cloudflare DoH.
--rollback remove the Cloudflare endpoint added by this script, if present.

The script does not disable existing DNS servers and never overwrites the whole
router configuration. Test on the target firmware before production use.
EOF
}

require_ndmc() {
    command -v ndmc >/dev/null 2>&1 || {
        echo "ndmc not found; this script must run on the Keenetic CLI environment" >&2
        exit 1
    }
}

show_dns() {
    ndmc -c "show dns-proxy"
}

case "${1:-}" in
    --help) usage; exit 0 ;;
    --dry-run)
        require_ndmc
        echo "Current DNS-proxy state:"
        show_dns
        echo
        echo "Would run: mkdir -p $BACKUP_DIR"
        echo "Would back up: $BACKUP_FILE"
        echo "Would add: dns-proxy https upstream $ENDPOINT"
        exit 0
        ;;
    --apply)
        require_ndmc
        mkdir -p "$BACKUP_DIR"
        show_dns >"$BACKUP_FILE"
        if grep -F "$ENDPOINT" "$BACKUP_FILE" >/dev/null 2>&1; then
            echo "Cloudflare endpoint already present; backup saved to $BACKUP_FILE"
            exit 0
        fi
        echo "Backup: $BACKUP_FILE"
        echo "Applying: dns-proxy https upstream $ENDPOINT"
        ndmc -c "dns-proxy https upstream $ENDPOINT"
        echo "Applied. Verify with: ndmc -c 'show dns-proxy'"
        ;;
    --rollback)
        require_ndmc
        if [ ! -f "$BACKUP_FILE" ]; then
            echo "No backup found at $BACKUP_FILE; refusing rollback." >&2
            exit 1
        fi
        if grep -F "$ENDPOINT" "$BACKUP_FILE" >/dev/null 2>&1; then
            echo "Endpoint existed before this script; leaving it unchanged."
            exit 0
        fi
        echo "Removing endpoint added by this script."
        ndmc -c "no dns-proxy https upstream $ENDPOINT"
        echo "Rollback command completed. Verify with: ndmc -c 'show dns-proxy'"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
