#!/bin/bash
# Run WHILE the battle is frozen: finds the game's stuck connections and tries the same
# servers from adb shell at that same moment, to see if the network or the game is the problem.
# Usage: ./freeze_test.sh <label>     e.g.  ./freeze_test.sh mobile
LABEL="${1:-run}"
PKG=$(adb shell pm list packages | tr -d '\r' | grep -oE "com\.nianticlabs\.pokemongo(\.ares)?$" | head -1)
DIR="$(cd "$(dirname "$0")" && pwd)"; OUT="$DIR/captures/freeze_$(date +%Y%m%d-%H%M%S)_${LABEL}.txt"
[ "$(adb get-state 2>/dev/null)" = device ] || { echo "Phone not visible to adb"; exit 1; }
UID_=$(adb shell cmd package list packages -U $PKG | tr -d '\r' | grep -m1 -oE 'uid:[0-9]+' | cut -d: -f2)
[ -z "$UID_" ] && UID_=$(adb shell dumpsys package $PKG | tr -d '\r' | grep -m1 -oE '(userId|appId)=[0-9]+' | cut -d= -f2)
[ -z "$UID_" ] && { echo "Could not resolve game uid"; exit 1; }
echo "Game uid: $UID_. Open Pokemon GO, enter a battle, and wait until it is clearly frozen."
read -r -p ">> Press Enter while it is FROZEN... " _
adb shell log -p w -t PGDEBUG "MARK FREEZE_TEST" >/dev/null 2>&1

hex2ip() { local h=$1
  if [ ${#h} -eq 32 ]; then [ "${h:0:24}" = "0000000000000000FFFF0000" ] && h=${h:24:8} || { echo "v6:$1"; return; }; fi
  printf "%d.%d.%d.%d" 0x${h:6:2} 0x${h:4:2} 0x${h:2:2} 0x${h:0:2}; }
snap() { for t in tcp tcp6; do adb shell cat /proc/net/$t | tr -d '\r' | awk -v u="$UID_" '$8==u {print $4, $3}'; done; }

{
echo "label=$LABEL $(date) net=$(adb shell getprop gsm.network.type) game_uid=$UID_"
echo "## game sockets at freeze (state remote)"
snap > /tmp/pg_snap1.txt
STUCK=""
while read -r st rem; do
  ip=$(hex2ip "${rem%%:*}"); port=$((0x${rem##*:}))
  case $st in 02) s=SYN_SENT;; 01) s=ESTAB;; 06) s=TIME_WAIT;; 08) s=CLOSE_WAIT;; *) s=$st;; esac
  echo "$s $ip:$port"; [ "$st" = 02 ] && STUCK="$STUCK $ip:$port"
done < /tmp/pg_snap1.txt
TARGETS=$(echo "$STUCK 130.211.14.80:443 34.117.15.92:443" | tr ' ' '\n' | grep -v '^$' | grep -v '^v6:' | sort -u)
echo; echo "## adb-shell connects to the same servers, right now (10 each)"
for t in $TARGETS; do host=${t%:*}; port=${t##*:}; ok=0; rcs=""
  for i in $(seq 10); do rc=$(adb shell "toybox timeout 6 toybox nc -w 5 $host $port </dev/null >/dev/null 2>&1; echo \$?" | tr -d '\r'); rcs="$rcs $rc"; [ "$rc" != 1 ] && ok=$((ok+1)); done
  printf "%-22s connected %2d/10  rc:%s\n" "$t" $ok "$rcs"
done
echo; echo "## 10 simultaneous connects to 130.211.14.80:443 (burst test)"
adb shell 'for i in 1 2 3 4 5 6 7 8 9 10; do (toybox timeout 6 toybox nc -w 5 130.211.14.80 443 </dev/null >/dev/null 2>&1; echo -n "$? ") & done; wait; echo'
echo; echo "## game sockets again after tests"
snap | while read -r st rem; do ip=$(hex2ip "${rem%%:*}"); echo "$st $ip:$((0x${rem##*:}))"; done
} | tee "$OUT"
echo "Saved: $OUT"
