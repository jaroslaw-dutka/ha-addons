ARG BUILD_FROM

FROM $BUILD_FROM

ARG BUILD_VERSION
ARG BUILD_ARCH

RUN apk add icu icu-libs curl unzip

COPY run.sh /run.sh
RUN chmod a+x /run.sh

RUN curl -L -o /tmp/release.zip "https://github.com/jaroslaw-dutka/ha-fca/releases/download/v${BUILD_VERSION}/ha-fca-${BUILD_ARCH}.zip" \
    && mkdir -p /app \
    && unzip /tmp/release.zip -d /app \
    && rm /tmp/release.zip

LABEL org.opencontainers.image.source=https://github.com/jaroslaw-dutka/ha-fca

CMD [ "/run.sh" ]