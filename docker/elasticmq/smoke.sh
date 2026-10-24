#!/usr/bin/env bash
# Smoke run for chanbooru-elasticmq (bin/chanbooru-image): the server starts
# and a message goes through a FIFO queue like the archives one, on a port
# bound to loopback and gone when this ends.
set -euo pipefail
C="chanbooru-elasticmq-smoke-$$"
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$C" -p 127.0.0.1::9324 "$1" >/dev/null
PORT="$(docker port "$C" 9324/tcp | sed -n 's/^127\.0\.0\.1:\([0-9]*\)$/\1/p' | head -1)"
[[ -n "$PORT" ]] || { echo "no loopback port for $C"; exit 1; }
URL="http://127.0.0.1:$PORT"
for _ in $(seq 1 30); do curl -sf -o /dev/null "$URL/?Action=ListQueues" && break; sleep 1; done
sqs() { curl -sf "$URL/$1" --data-urlencode "Action=$2" "${@:3}"; }
sqs "" CreateQueue -d QueueName=smoke.fifo -d Attribute.1.Name=FifoQueue -d Attribute.1.Value=true -d Attribute.2.Name=ContentBasedDeduplication -d Attribute.2.Value=true >/dev/null
sqs 000000000000/smoke.fifo SendMessage -d MessageGroupId=smoke --data-urlencode MessageBody=smoke-body-$$ >/dev/null
GOT="$(sqs 000000000000/smoke.fifo ReceiveMessage -d WaitTimeSeconds=2)"
grep -q "smoke-body-$$" <<< "$GOT" || { echo "the message did not come back: $GOT"; docker logs "$C" 2>&1 | tail -20; exit 1; }
echo "elasticmq smoke ok: a FIFO message went through on $(docker exec "$C" sh -c '. /etc/os-release; echo Alpine $VERSION_ID') with $(docker exec "$C" apk info -v 2>/dev/null | grep -E '^(musl|libssl3|zlib)-[0-9]' | tr '\n' ' ')"
