#!/bin/bash
set -e

# Default credentials
CUPS_USER="${CUPS_USER:-admin}"
CUPS_PASSWORD="${CUPS_PASSWORD:-admin}"

# Create the CUPS admin user if it doesn't exist
if ! id "$CUPS_USER" &>/dev/null; then
    useradd -r -G lpadmin -M -s /usr/sbin/nologin "$CUPS_USER"
fi
echo "${CUPS_USER}:${CUPS_PASSWORD}" | chpasswd

# Ensure required directories exist
mkdir -p /run/dbus /run/cups /run/avahi-daemon

# Clean up stale pid files
rm -f /run/dbus/pid /run/avahi-daemon/pid

# Start dbus (required by avahi)
dbus-daemon --system --nofork &
sleep 1

# Start avahi for AirPrint/Bonjour discovery
avahi-daemon --no-chroot -D

# Start CUPS in background so we can configure it, then bring to foreground
/usr/sbin/cupsd

# Wait for CUPS to be ready
for i in $(seq 1 10); do
    if curl -sf http://localhost:631/ > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Auto-configure printer if env vars are set
if [ -n "$PRINTER_NAME" ] && [ -n "$PRINTER_URI" ]; then
    PRINTER_PPD="${PRINTER_PPD:-lw5xl.ppd}"
    PRINTER_DESCRIPTION="${PRINTER_DESCRIPTION:-$PRINTER_NAME}"

    # Resolve PPD path (allow short name like "lw5xl.ppd" or full path)
    if [ -f "/usr/share/cups/model/$PRINTER_PPD" ]; then
        PPD_PATH="/usr/share/cups/model/$PRINTER_PPD"
    elif [ -f "$PRINTER_PPD" ]; then
        PPD_PATH="$PRINTER_PPD"
    else
        echo "ERROR: PPD file not found: $PRINTER_PPD"
        echo "Available PPDs:"
        ls /usr/share/cups/model/*.ppd
        exit 1
    fi

    # Check if printer already exists (persisted in volume)
    if lpstat -p "$PRINTER_NAME" > /dev/null 2>&1; then
        echo "Printer '$PRINTER_NAME' already configured"
    else
        echo "Adding printer '$PRINTER_NAME' at $PRINTER_URI (PPD: $PRINTER_PPD)"
        lpadmin -p "$PRINTER_NAME" -E \
            -v "$PRINTER_URI" \
            -P "$PPD_PATH" \
            -D "$PRINTER_DESCRIPTION" \
            -L "${PRINTER_LOCATION:-}" \
            -o printer-is-shared=true
        lpadmin -d "$PRINTER_NAME"
        echo "Printer '$PRINTER_NAME' added and set as default"
    fi

    cupsctl --share-printers
fi

# Stop the background CUPS and restart in foreground
kill "$(cat /run/cups/cupsd.pid)" 2>/dev/null || true
sleep 1

exec /usr/sbin/cupsd -f
