
FROM node:24 AS base

ENV ZIG_VERSION=0.15.1
ENV ZIG_PATH=/zig/${ZIG_VERSION}/files

RUN wget -q https://github.com/marler8997/zigup/releases/download/v2025_05_24/zigup-x86_64-linux.tar.gz && \
    tar -zxvf zigup-x86_64-linux.tar.gz -C /usr/bin \
    && chmod +x /usr/bin/zigup \
    && zigup $ZIG_VERSION --install-dir /zig \
    && chmod -R a+w ${ZIG_PATH} \
    && rm zigup.ubuntu-latest-x86_64.zip /usr/bin/zigup

FROM busybox AS build

COPY --from=base /zig/0.12.0/files/lib /lib
COPY --from=base /usr/bin/zig /bin/zig

CMD ["sh"]
