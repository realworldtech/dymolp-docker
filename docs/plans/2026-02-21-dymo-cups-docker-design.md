# DYMO CUPS Docker Container Design

## Overview

A Docker container that provides a CUPS print server with compiled DYMO LW5xx drivers (supporting the 5XL, 550, and LabelManager series), AirPrint/Avahi discovery, and a web-based admin interface.

## Goals

- Build the DYMO LW5xx Linux drivers from source inside Docker
- Provide a CUPS print server that can send jobs to a networked DYMO printer
- Expose the CUPS web admin UI (port 631) for printer management
- Advertise printers via AirPrint/Bonjour (Avahi) so Apple devices can discover them
- Support USB passthrough as a future enhancement

## Architecture

### Multi-Stage Dockerfile

**Stage 1 — Builder (`debian:bookworm`)**

Compiles the DYMO drivers from the `Drivers/LW5xx_Linux` source:

1. Install build toolchain: `build-essential`, `autoconf`, `automake`, `libcups2-dev`, `libcupsimage2-dev`
2. Copy driver source into the build context
3. Run autotools regeneration: `aclocal && automake --add-missing` (fixes missing `ppd/Linux` directory issue from GitHub issue #5)
4. Run `./configure && make && make install DESTDIR=/staging`
5. Ensure `raster2dymolw_v2` symlink exists (CUPS expects the `_v2` suffix)

Artifacts produced:
- `/staging/usr/lib/cups/filter/raster2dymolw` — the CUPS raster filter binary
- `/staging/usr/share/cups/model/*.ppd` — PPD files for all supported models

**Stage 2 — Runtime (`debian:bookworm-slim`)**

Minimal image with CUPS and Avahi:

1. Install runtime packages: `cups`, `libcups2`, `libcupsimage2`, `avahi-daemon`, `libnss-mdns`, `dbus`
2. Copy compiled filter binary from builder to `/usr/lib/cups/filter/`
3. Create `raster2dymolw_v2` symlink
4. Copy PPD files from builder to `/usr/share/cups/model/`
5. Copy custom `cupsd.conf` and `entrypoint.sh`

### Docker Compose

```yaml
services:
  cups:
    build: .
    ports:
      - "631:631"
    network_mode: host  # Required for Avahi multicast
    environment:
      - CUPS_USER=admin
      - CUPS_PASSWORD=admin
    volumes:
      - cups-config:/etc/cups
      - cups-spool:/var/spool/cups
    restart: unless-stopped
    # Uncomment for USB passthrough:
    # devices:
    #   - /dev/bus/usb:/dev/bus/usb

volumes:
  cups-config:
  cups-spool:
```

### CUPS Configuration

`cupsd.conf` configured for:
- Listen on `0.0.0.0:631` (all interfaces)
- Allow remote administration from local network
- Enable printer sharing
- `BrowseLocalProtocols dnssd` for AirPrint advertisement

### Entrypoint Script

Startup sequence:
1. Create admin user with credentials from env vars (`CUPS_USER`/`CUPS_PASSWORD`)
2. Start `dbus-daemon` (required by Avahi)
3. Start `avahi-daemon` in background
4. Start `cupsd` in foreground

## File Structure

```
dymo-cups/
├── Dockerfile
├── docker-compose.yml
├── entrypoint.sh
├── cupsd.conf
├── Drivers/              # Cloned DYMO driver repo (git submodule or copy)
│   └── LW5xx_Linux/      # Driver source
└── docs/plans/
```

## Known Build Issues and Fixes

1. **`ppd/Linux` directory missing** (GitHub issue #5): Run `aclocal && automake --add-missing` before `./configure`
2. **`raster2dymolw_v2` not found**: CUPS expects the `_v2` suffix. Create a symlink from `raster2dymolw` to `raster2dymolw_v2`
3. **`#include <ctime>` missing**: Already fixed in current repo version, but the Dockerfile should handle this defensively

## Supported Printer Models

From the PPD files included:
- DYMO LabelWriter 5XL (`lw5xl.ppd`)
- DYMO LabelWriter 5XL (portrait) (`lw5xlp.ppd`)
- DYMO LabelWriter 550 (`lw550.ppd`)
- DYMO LabelWriter 550 (portrait) (`lw550p.ppd`)
- DYMO LabelWriter 550 Turbo (`lw550t.ppd`)
- DYMO LabelWriter 550 Turbo (portrait) (`lw550tp.ppd`)
- DYMO LabelWriter Wireless (`lww.ppd`)
- DYMO LabelManager MLS (`lmmls.ppd`)

## Future Enhancements

- USB device passthrough (uncomment `devices` in docker-compose)
- Environment variable-based printer auto-configuration at startup
- Health check endpoint
