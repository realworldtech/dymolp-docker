# DYMO Label Printer CUPS Docker

A Docker container that provides a CUPS print server with compiled DYMO LW5xx drivers, ready to print to networked DYMO label printers. Designed to be used as a sidecar container for label printing solutions.

## Supported Printers

- DYMO LabelWriter 5XL
- DYMO LabelWriter 550 / 550 Turbo
- DYMO LabelWriter Wireless
- DYMO LabelManager MLS

## Quick Start

1. Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/realworldtech/dymolp-docker.git
cd dymolp-docker
```

2. Configure your printer in `docker-compose.yml`:

```yaml
environment:
  - PRINTER_NAME=DYMO-5XL
  - PRINTER_URI=socket://YOUR_PRINTER_IP:9100
  - PRINTER_PPD=lw5xl.ppd
  - PRINTER_DESCRIPTION=DYMO LabelWriter 5XL
```

3. Build and start:

```bash
docker compose up -d
```

The printer is automatically configured on first startup. CUPS web admin is available at `http://localhost:631` (default credentials: `admin`/`admin`).

## Sending Print Jobs

From the host or another container on the same network:

```bash
echo "Hello DYMO" | lpr -H localhost:631 -P DYMO-5XL
```

Or use the IPP URL directly: `ipp://localhost:631/printers/DYMO-5XL`

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CUPS_USER` | `admin` | CUPS admin username |
| `CUPS_PASSWORD` | `admin` | CUPS admin password |
| `PRINTER_NAME` | *(none)* | Printer name in CUPS (e.g. `DYMO-5XL`) |
| `PRINTER_URI` | *(none)* | Device URI (e.g. `socket://10.0.0.50:9100`) |
| `PRINTER_PPD` | `lw5xl.ppd` | PPD file name (see available PPDs below) |
| `PRINTER_DESCRIPTION` | Same as name | Human-readable printer description |
| `PRINTER_LOCATION` | *(empty)* | Printer location string |

## Available PPD Files

| File | Printer Model |
|---|---|
| `lw5xl.ppd` | LabelWriter 5XL |
| `lw5xlp.ppd` | LabelWriter 5XL (portrait) |
| `lw550.ppd` | LabelWriter 550 |
| `lw550p.ppd` | LabelWriter 550 (portrait) |
| `lw550t.ppd` | LabelWriter 550 Turbo |
| `lw550tp.ppd` | LabelWriter 550 Turbo (portrait) |
| `lww.ppd` | LabelWriter Wireless |
| `lmmls.ppd` | LabelManager MLS |

## Architecture

The Docker image uses a multi-stage build:

- **Stage 1 (builder):** Compiles the DYMO LW5xx Linux drivers from source on Debian Bookworm
- **Stage 2 (runtime):** Slim Debian image with CUPS, Avahi, and the compiled driver binaries + PPD files

On startup, the entrypoint script:
1. Creates the CUPS admin user
2. Starts dbus and Avahi (for AirPrint/Bonjour on Linux hosts)
3. Starts CUPS and auto-configures the printer from environment variables

## Linux Hosts

For Avahi/AirPrint multicast discovery on Linux, switch to host networking in `docker-compose.yml`:

```yaml
network_mode: host
```

For USB-connected printers, uncomment the devices section:

```yaml
devices:
  - /dev/bus/usb:/dev/bus/usb
```

## Driver Source Code Notice

The DYMO driver source code is included as a git submodule from [dymosoftware/Drivers](https://github.com/dymosoftware/Drivers). The `LW5xx_Linux` directory within that repository contains GPL v2 license files (`LICENSE` and `COPYING`), however the top-level Drivers repository itself is published without a license file. The licensing status of the overall repository is unclear. Users should assess this for their own use case.

The Dockerfile patches the driver source during build to fix known issues:
- Missing `#include <ctime>` in `LabelManagerLanguageMonitorV2.cpp`
- Autotools regeneration for missing `ppd/Linux` directory ([issue #5](https://github.com/dymosoftware/Drivers/issues/5))
