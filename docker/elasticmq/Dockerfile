# chanbooru-elasticmq: upstream's elasticmq-native (the SQS stand-in the
# archives service reads), unchanged, with the Alpine fixes upstream has not
# shipped. 1.7.1 as published carried 8 fixable criticals, all in libcrypto3,
# libssl3, musl and zlib (scan of 2026-10-24); this one carries none.
#
# Built on the workstation and promoted, never built on the serving box: see
# docker/archives/Dockerfile and bin/chanbooru-image. Recovering it needs a box
# that reaches the Alpine mirror, and this directory at the deployed commit.
#
# Update: move the FROM pin to a newer release, or the package pins to newer
# Alpine builds (each >= 3 days old: org cooldown), then
# bin/chanbooru-image elasticmq promote.
FROM softwaremill/elasticmq-native:1.7.1@sha256:e4580ab9ad1bd5cd37b4ba04911bc5ccc8cd2d9ab4de56ece65acee71c24e05c

RUN apk add --no-cache --upgrade libcrypto3=3.5.9-r0 libssl3=3.5.9-r0 musl=1.2.5-r13 musl-utils=1.2.5-r13 zlib=1.3.2-r1
