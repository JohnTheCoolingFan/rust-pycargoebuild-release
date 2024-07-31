FROM ghcr.io/johnthecoolingfan/gentoo-action-image:main

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
