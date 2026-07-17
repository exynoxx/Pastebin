#!/usr/bin/env bash
# Block until the forked deploy session ships a NEW api image to the Pi, then exit 0.
# Detection: the deploy-pastebin-api-1 container's image id changes from the baseline.
set -u
BASELINE_SHORT="0142a71af4cb"   # api image id captured before the deploy started
POLL=20                          # seconds between checks
MAX=2400                         # give up after 40 min (deploy failed / never happened)

cd /home/nicholas/Dokumenter/git/Pastebin
set -a; . ./.taskenv 2>/dev/null; set +a
PI=100.120.214.111
SSH="sshpass -p ${PI_PASS} ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 pi@${PI}"

elapsed=0
while [ "$elapsed" -lt "$MAX" ]; do
  imgid=$($SSH 'docker inspect -f "{{.Image}}" deploy-pastebin-api-1 2>/dev/null' 2>/dev/null | sed 's/^sha256://')
  started=$($SSH 'docker inspect -f "{{.State.StartedAt}}" deploy-pastebin-api-1 2>/dev/null' 2>/dev/null)
  short=${imgid:0:12}
  ts=$(date +%H:%M:%S)
  if [ -n "$short" ] && [ "$short" != "$BASELINE_SHORT" ]; then
    echo "[$ts] DEPLOY DETECTED: api image ${short} (was ${BASELINE_SHORT}), started ${started}"
    exit 0
  fi
  echo "[$ts] still baseline (${short:-unreachable}); waited ${elapsed}s"
  sleep "$POLL"
  elapsed=$((elapsed + POLL))
done
echo "TIMEOUT after ${MAX}s: api image still ${BASELINE_SHORT} — deploy did not land"
exit 3
