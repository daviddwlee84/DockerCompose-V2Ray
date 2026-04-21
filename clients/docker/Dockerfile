# Use Alpine Linux as the base image
FROM alpine:latest

# NOTE: these is for downloading the Clash client from GitHub
# Install necessary packages
# RUN apk add --no-cache wget ca-certificates
#
# Set environment variables for Clash version and architecture
# ENV CLASH_VERSION v1.18.0
# ENV CLASH_ARCH 386
# ENV CLASH_URL https://github.com/Kuingsmile/clash-core/releases/download/1.18/clash-linux-${CLASH_ARCH}-${CLASH_VERSION}.gz

# Create the configuration directory for Clash
RUN mkdir -p /root/.config/clash/

# Download and install Clash
# RUN wget ${CLASH_URL} -O /tmp/clash.gz \
#     && gunzip /tmp/clash.gz \
#     && chmod +x /tmp/clash \
#     && mv /tmp/clash /usr/local/bin/clash

# Copy and install Clash
COPY ./clash-linux-386-v1.18.0.gz /tmp/clash.gz
RUN gunzip /tmp/clash.gz \
    && chmod +x /tmp/clash \
    && mv /tmp/clash /usr/local/bin/clash

# Copy Country.mmdb (optional)
# NOTE: if clash not found MMDB it will try to download it from https://cdn.jsdelivr.net/gh/Dreamacro/maxmind-geoip@release/Country.mmdb
# clash-1  | time="2024-11-21T11:34:05Z" level=info msg="Can't find MMDB, start download"
# clash-1  | time="2024-11-21T11:34:35Z" level=fatal msg="Initial configuration directory error: can't initial MMDB: can't download MMDB: Get \"https://cdn.jsdelivr.net/gh/Dreamacro/maxmind-geoip@release/Country.mmdb\": dial tcp 93.46.8.90:443: i/o timeout"
COPY ./Country.mmdb /root/.config/clash/Country.mmdb

# Set the working directory
WORKDIR /root/.config/clash/

# Expose ports (if necessary)
EXPOSE 7890 7891 9090

# Run Clash with the specified configuration file
CMD ["clash", "-f", "/root/.config/clash/config.yaml"]
