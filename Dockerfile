FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# ffmpeg from Ubuntu 22.04 universe is built with libx265, nvenc and vaapi (qsv) support.
# intel-media-va-driver-non-free + vainfo are only needed if you pass through /dev/dri for QSV.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        curl \
        python3 \
        ca-certificates \
        coreutils \
        util-linux \
        intel-media-va-driver-non-free \
        vainfo \
        unrar \
        p7zip-full \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh

WORKDIR /app
ENTRYPOINT ["/app/scripts/entrypoint.sh"]
