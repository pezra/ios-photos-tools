#!/bin/bash
# Runs the local S3 service (Moto in Docker), with versioned buckets pt-a and pt-b.
#   s3.sh up                     start it and create the buckets (its data goes when it stops)
#   s3.sh down                   stop it
#   s3.sh ls BUCKET              list object keys and sizes
#   s3.sh versions BUCKET        list every version of every object
#   s3.sh put BUCKET KEY FILE    put a file there, as something other than the app would
#   s3.sh rm BUCKET KEY          delete an object
source "$(dirname "$0")/env.sh"

# Moto checks no signatures, but treats requests with no Authorization header as anonymous.
auth=(-H "Authorization: AWS4-HMAC-SHA256 Credential=$S3_KEY/20260101/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=0"
      -H "x-amz-content-sha256: UNSIGNED-PAYLOAD")

case "${1:-}" in
up)
    if ! docker ps --format '{{.Names}}' | grep -qx "$S3_CONTAINER"; then
        docker run -d --rm --name "$S3_CONTAINER" -p "$S3_PORT:5000" "$S3_IMAGE" >/dev/null
    fi
    for _ in $(seq 30); do
        curl -s -o /dev/null "$S3_URL" && break
        sleep 1
    done
    for bucket in pt-a pt-b; do
        curl -sf -o /dev/null "${auth[@]}" -X PUT "$S3_URL/$bucket"
        curl -sf -o /dev/null "${auth[@]}" -X PUT "$S3_URL/$bucket?versioning=" -H "Content-Type: application/xml" \
            --data-binary '<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>'
    done
    echo "S3 at $S3_URL with versioned buckets pt-a and pt-b."
    ;;
down)
    docker stop "$S3_CONTAINER" >/dev/null 2>&1 || true
    echo "S3 stopped; its data is gone."
    ;;
ls)
    curl -sf "${auth[@]}" "$S3_URL/$2?list-type=2&max-keys=1000" | python3 -c '
import sys, xml.etree.ElementTree as ET
ns = {"s": "http://s3.amazonaws.com/doc/2006-03-01/"}
for c in ET.parse(sys.stdin).getroot().findall("s:Contents", ns):
    print(c.find("s:Size", ns).text.rjust(10), c.find("s:Key", ns).text)'
    ;;
versions)
    curl -sf "${auth[@]}" "$S3_URL/$2?versions=" | python3 -c '
import sys, xml.etree.ElementTree as ET
ns = {"s": "http://s3.amazonaws.com/doc/2006-03-01/"}
for v in ET.parse(sys.stdin).getroot().findall("s:Version", ns):
    print(v.find("s:Size", ns).text.rjust(10), v.find("s:IsLatest", ns).text.ljust(5), v.find("s:Key", ns).text)'
    ;;
put)
    curl -sf -o /dev/null "${auth[@]}" -X PUT --data-binary "@$4" "$S3_URL/$2/$3" && echo "Put $3"
    ;;
rm)
    curl -sf -o /dev/null "${auth[@]}" -X DELETE "$S3_URL/$2/$3" && echo "Deleted $3"
    ;;
*)
    echo "usage: s3.sh up|down|ls BUCKET|versions BUCKET|put BUCKET KEY FILE|rm BUCKET KEY" >&2
    exit 2
    ;;
esac
