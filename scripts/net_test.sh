#!/bin/bash
# Repeated fresh TCP connects from the PHONE to the servers Pokemon GO couldn't reach.
# Usage: ./net_test.sh <label>    e.g. mobile-5g | mobile-lte | wifi
LABEL="${1:-run}"; N=10
DIR="$(cd "$(dirname "$0")" && pwd)"; OUT="$DIR/captures/nettest_$(date +%Y%m%d-%H%M%S)_${LABEL}.txt"
[ "$(adb get-state 2>/dev/null)" = device ] || { echo "Phone not visible to adb"; exit 1; }
TARGETS="v4:34.117.15.92 nat64:64:ff9b::2275:f5c v4:130.211.14.80 nat64:64:ff9b::82d3:e50 v4:34.110.167.47 nat64:64:ff9b::226e:a72f v4:142.250.191.100 v4:1.1.1.1"
{
echo "label=$LABEL $(date)  net=$(adb shell getprop gsm.network.type)  wifi: $(adb shell dumpsys wifi | grep -m1 'Wi-Fi is')"
for t in $TARGETS; do
  kind=${t%%:*}; host=${t#*:}; ok=0; rcs=""
  for i in $(seq $N); do
    rc=$(adb shell "toybox timeout 6 toybox nc -w 5 $host 443 </dev/null >/dev/null 2>&1; echo \$?" | tr -d '\r')
    rcs="$rcs $rc"; [ "$rc" != 1 ] && ok=$((ok+1))
  done
  printf "%-6s %-24s connected %2d/%d   rc:%s\n" "$kind" "$host" $ok $N "$rcs"
done
} | tee "$OUT"
echo "Saved: $OUT"
