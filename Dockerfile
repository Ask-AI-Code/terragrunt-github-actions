FROM alpine:3 

RUN apk update && \
    apk upgrade --no-cache && \
    apk add --no-cache \
    bash ca-certificates openssl curl git jq openssh && \
    update-ca-certificates

COPY ["src", "/src/"]

ENTRYPOINT ["/src/main.sh"]
