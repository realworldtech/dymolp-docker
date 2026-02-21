# DYMO CUPS Docker Container Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Docker container running CUPS with compiled DYMO LW5xx drivers and AirPrint/Avahi support for printing to networked DYMO label printers.

**Architecture:** Multi-stage Dockerfile — Stage 1 compiles DYMO drivers from `Drivers/LW5xx_Linux` source using autotools on Debian Bookworm; Stage 2 copies the compiled filter binaries and PPD files into a slim runtime image with CUPS, Avahi, and dbus. Docker Compose orchestrates with host networking for Avahi multicast.

**Tech Stack:** Docker, Docker Compose, CUPS, Avahi/dbus, C++ autotools build (DYMO driver source), Debian Bookworm

---

### Task 1: Create the CUPS configuration file

**Files:**
- Create: `cupsd.conf`

**Step 1: Write `cupsd.conf`**

This configures CUPS to listen on all interfaces, allow remote admin, enable sharing, and advertise via dnssd (AirPrint).

```conf
# DYMO CUPS Docker - cupsd.conf

# Listen on all interfaces
Listen 0.0.0.0:631
Listen /run/cups/cups.sock

# Enable printer sharing
Browsing On
BrowseLocalProtocols dnssd
DefaultAuthType Basic
WebInterface Yes

# Share printers by default
DefaultShared Yes

# Restrict access to the server
<Location />
  Order allow,deny
  Allow all
</Location>

# Restrict access to the admin pages
<Location /admin>
  Order allow,deny
  Allow all
</Location>

# Restrict access to configuration files
<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow all
</Location>

# Restrict access to log files
<Location /admin/log>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow all
</Location>

# Set the default printer policy
<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order deny,allow
  </Limit>

  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Pause-Printer Resume-Printer Enable-Printer Disable-Printer Pause-Printer-After-Current-Job Hold-New-Jobs Release-Held-New-Jobs Deactivate-Printer Activate-Printer Restart-Printer Shutdown-Printer Startup-Printer Promote-Job Schedule-Job-After Cancel-Jobs CUPS-Accept-Jobs CUPS-Reject-Jobs>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Cancel-Job CUPS-Authenticate-Job>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit All>
    Order deny,allow
  </Limit>
</Policy>
```

**Step 2: Verify the file is syntactically reasonable**

Visual review only — we'll validate with `cupsd -t` inside the container later.

**Step 3: Commit**

```bash
git add cupsd.conf
git commit -m "Add CUPS configuration for remote access and AirPrint"
```

---

### Task 2: Create the entrypoint script

**Files:**
- Create: `entrypoint.sh`

**Step 1: Write `entrypoint.sh`**

This script creates the admin user, starts dbus and avahi, then runs cupsd in foreground.

```bash
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

# Copy default cupsd.conf if the volume is empty
if [ ! -f /etc/cups/cupsd.conf ]; then
    cp /etc/cups/cupsd.conf.default /etc/cups/cupsd.conf
fi

# Start CUPS in foreground
exec /usr/sbin/cupsd -f
```

**Step 2: Make executable (will be handled in Dockerfile COPY --chmod)**

**Step 3: Commit**

```bash
git add entrypoint.sh
git commit -m "Add entrypoint script for dbus, avahi, and CUPS startup"
```

---

### Task 3: Create the Dockerfile

**Files:**
- Create: `Dockerfile`

**Step 1: Write the multi-stage Dockerfile**

```dockerfile
# =============================================================================
# Stage 1: Build DYMO LW5xx drivers
# =============================================================================
FROM debian:bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    autoconf \
    automake \
    libcups2-dev \
    libcupsimage2-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY Drivers/LW5xx_Linux/ .

# Fix autotools issues (GitHub issue #5: missing ppd/Linux directory)
RUN aclocal && automake --add-missing || true

# Configure and build
RUN sh ./configure && make

# Install to staging directory for clean copy
RUN make install DESTDIR=/staging

# =============================================================================
# Stage 2: Runtime CUPS + Avahi
# =============================================================================
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    cups \
    libcups2 \
    libcupsimage2 \
    avahi-daemon \
    avahi-utils \
    libnss-mdns \
    dbus \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled DYMO filter binaries from builder
COPY --from=builder /staging/usr/lib/cups/filter/raster2dymolw_v2 /usr/lib/cups/filter/
COPY --from=builder /staging/usr/lib/cups/filter/raster2dymolm_v2 /usr/lib/cups/filter/

# Copy PPD files from builder
COPY --from=builder /staging/usr/share/cups/model/*.ppd /usr/share/cups/model/

# Back up default cupsd.conf, then install custom one
RUN cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.default
COPY cupsd.conf /etc/cups/cupsd.conf

# Install entrypoint
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Expose CUPS port
EXPOSE 631

# Health check
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -sf http://localhost:631/ || exit 1

ENTRYPOINT ["/entrypoint.sh"]
```

**Step 2: Commit**

```bash
git add Dockerfile
git commit -m "Add multi-stage Dockerfile for DYMO driver build and CUPS runtime"
```

---

### Task 4: Create docker-compose.yml

**Files:**
- Create: `docker-compose.yml`

**Step 1: Write `docker-compose.yml`**

```yaml
services:
  cups:
    build: .
    network_mode: host
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

**Step 2: Commit**

```bash
git add docker-compose.yml
git commit -m "Add docker-compose with host networking for Avahi multicast"
```

---

### Task 5: Create .dockerignore

**Files:**
- Create: `.dockerignore`

**Step 1: Write `.dockerignore`**

Keep the build context small by excluding git history, docs, and unnecessary driver directories.

```
.git
docs/
Drivers/.git
Drivers/LW4xx Linux/
Drivers/LW5xx_245/
**/*.o
**/*.a
```

**Step 2: Commit**

```bash
git add .dockerignore
git commit -m "Add .dockerignore to reduce build context size"
```

---

### Task 6: Test the Docker build

**Step 1: Build the image**

```bash
docker compose build
```

Expected: Successful build with both stages completing. Watch for:
- autotools stage completing without errors
- `make` compiling `raster2dymolw_v2` and `raster2dymolm_v2` successfully
- COPY commands finding the compiled artifacts

**Step 2: If the build fails, debug and fix**

Common issues to watch for:
- If `aclocal && automake` fails: try `autoconf -ivf` before `./configure` (per community advice)
- If `make` fails with missing headers: check the `#include <ctime>` fix is present
- If COPY fails with "file not found": check the DESTDIR install paths — run `find /staging -type f` in a debug build to see where files actually land

**Step 3: Start the container**

```bash
docker compose up -d
```

**Step 4: Verify CUPS is running**

```bash
curl -s http://localhost:631/ | head -20
```

Expected: HTML response from CUPS web interface.

**Step 5: Verify DYMO drivers are installed**

```bash
docker compose exec cups ls -la /usr/lib/cups/filter/raster2dymo*
docker compose exec cups ls -la /usr/share/cups/model/lw*.ppd
```

Expected: Filter binaries and PPD files present.

**Step 6: Verify Avahi is running**

```bash
docker compose exec cups avahi-browse -t _ipp._tcp
```

Expected: Avahi responding (may show no services yet until a printer is configured).

**Step 7: Commit any fixes**

If any changes were needed during debugging:

```bash
git add -A
git commit -m "Fix build issues discovered during Docker build testing"
```

---

### Task 7: Create a .gitignore and README

**Files:**
- Create: `.gitignore`

**Step 1: Write `.gitignore`**

```
# Build artifacts
*.o
*.a

# Docker volumes
cups-config/
cups-spool/
```

**Step 2: Commit all remaining files**

```bash
git add .gitignore
git commit -m "Add .gitignore for build artifacts"
```

---

### Task 8: Final integration test

**Step 1: Clean rebuild**

```bash
docker compose down -v
docker compose build --no-cache
docker compose up -d
```

**Step 2: Access CUPS web UI**

Open `http://localhost:631` in browser. Verify:
- Web UI loads
- Can log in with admin/admin
- Administration > Add Printer is accessible
- DYMO LabelWriter 5XL appears in the PPD selection when adding a printer

**Step 3: Stop the container**

```bash
docker compose down
```

**Step 4: Final commit if any changes needed**

```bash
git add -A
git commit -m "Final adjustments after integration testing"
```
