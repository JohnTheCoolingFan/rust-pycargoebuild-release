FROM ghcr.io/johnthecoolingfan/gentoo-action-image:main

RUN emerge app-portage/pycargoebuild

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
