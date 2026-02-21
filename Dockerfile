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
    libboost-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY Drivers/LW5xx_Linux/ .

# Fix autotools issues (GitHub issue #5: missing ppd/Linux directory)
RUN aclocal && automake --add-missing || true

# Patch missing #include <ctime> in LabelManagerLanguageMonitorV2.cpp
RUN sed -i '/#include <unistd.h>/a #include <ctime>' src/lm/LabelManagerLanguageMonitorV2.cpp

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
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled DYMO filter binaries from builder
COPY --from=builder /staging/usr/lib/cups/filter/raster2dymolw_v2 /usr/lib/cups/filter/
COPY --from=builder /staging/usr/lib/cups/filter/raster2dymolm_v2 /usr/lib/cups/filter/

# Copy PPD files from builder
COPY --from=builder /staging/usr/share/cups/model/*.ppd /usr/share/cups/model/

# Install custom cupsd.conf (Docker seeds named volumes from image on first run)
COPY cupsd.conf /etc/cups/cupsd.conf

# Install entrypoint
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Expose CUPS port
EXPOSE 631

# Health check
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -sf http://localhost:631/ || exit 1

ENTRYPOINT ["/entrypoint.sh"]
