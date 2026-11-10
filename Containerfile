# Add the media, SMB and DAV tools shipped by the HA Nextcloud Office add-on.
# The base is the official Nextcloud 35.0.1 Apache image pinned by digest.
FROM docker.io/library/nextcloud@sha256:8cfe6765cdfe3fcecbbf25b4140cbf6f77c38a53e8988349a3900be9311ea11b

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      imagemagick ffmpeg smbclient davfs2 \
 && rm -rf /var/lib/apt/lists/*
