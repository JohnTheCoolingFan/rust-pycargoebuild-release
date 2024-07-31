FROM ghcr.io/JohnTheCoolingFan/gentoo-action-image:main

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
