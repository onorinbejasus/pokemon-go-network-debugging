#!/bin/bash
# Pokemon GO battle-freeze capture.
# Usage:  ./capture.sh <label>     e.g.  ./capture.sh mobile   |   ./capture.sh wifi
# Phone must be connected by USB cable (NOT wireless debugging - that needs Wi-Fi).
set -u
LABEL="${1:-run}"
DIR="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/captures/${TS}_${LABEL}"

if ! command -v adb >/dev/null 2>&1; then
  echo "adb not found. Install it with:  brew install --cask android-platform-tools   then rerun."; exit 1
fi
adb start-server >/dev/null 2>&1
STATE="$(adb get-state 2>/dev/null)"
if [ "$STATE" != "device" ]; then
  echo "Phone not visible to adb (state: ${STATE:-none})."
  echo "Plug in USB, unlock the phone, accept the 'Allow USB debugging?' prompt, then rerun."
  adb devices; exit 1
fi
mkdir -p "$OUT"
# Play Store build is com.nianticlabs.pokemongo, Galaxy Store build is com.nianticlabs.pokemongo.ares
PKG=$(adb shell pm list packages | tr -d '\r' | grep -oE "com\.nianticlabs\.pokemongo(\.ares)?$" | head -1)
echo "== Game package: ${PKG:-not found}"
s() { adb shell "$@" 2>&1; }
mark() { adb shell log -p w -t PGDEBUG "MARK $1" >/dev/null 2>&1; echo "[$(date +%H:%M:%S)] MARK $1" | tee -a "$OUT/marks.txt"; }

echo "== Capturing to: $OUT"
echo "== Wi-Fi state on phone: $(s dumpsys wifi | grep -m1 'Wi-Fi is')"
echo "   (for a 'mobile' run, Wi-Fi should be OFF on the phone)"

echo "-- device / carrier info"
{
  echo "label=$LABEL captured=$(date)"
  for p in ro.product.model ro.build.fingerprint ro.build.version.release ro.build.version.security_patch \
           ro.csc.sales_code ro.boot.carrierid gsm.operator.alpha gsm.sim.operator.alpha gsm.operator.numeric \
           gsm.sim.operator.numeric gsm.network.type gsm.operator.isroaming; do
    echo "$p=$(s getprop $p)"
  done
  echo "preferred_network_mode=$(s settings get global preferred_network_mode)"
  echo; echo "## Pokemon GO package"; s dumpsys package $PKG | grep -E "versionName|versionCode|lastUpdateTime"
  echo; echo "## telephony (filtered)"
  s dumpsys telephony.registry | grep -iE "mDataConnectionState|mDataNetworkType|nrState|isUsingCarrierAggregation|mServiceState=|getRilDataRadioTechnology|mPhysicalChannelConfigs" | head -40
} > "$OUT/00_device.txt"

echo "-- network config"
{
  echo "## private DNS: mode=$(s settings get global private_dns_mode) spec=$(s settings get global private_dns_specifier)"
  echo "## data saver:"; s cmd netpolicy get restrict-background
  echo "## always-on VPN app: $(s settings get secure always_on_vpn_app)"
  echo; echo "## ip addr"; s ip addr
  echo; echo "## ip -4 route (all tables)"; s ip -4 route show table all
  echo; echo "## ip -6 route (all tables)"; s ip -6 route show table all
  echo; echo "## ip rule"; s ip rule
} > "$OUT/01_network_config.txt"
s dumpsys connectivity > "$OUT/02_connectivity.txt"

probe() {
  echo "## $(date +%H:%M:%S) basic reachability"
  s ping -c 4 -W 2 8.8.8.8
  s ping6 -c 4 -W 2 2001:4860:4860::8888
  echo; echo "## IPv4 path-MTU (DF set) - payload sizes"
  for sz in 1472 1452 1432 1412 1392 1372 1352 1300 1252 1200; do
    r=$(s ping -c 2 -W 2 -M do -s $sz 8.8.8.8 | grep -E "received|too long|mtu" | tr '\n' ' '); echo "v4 $sz: $r"
  done
  echo; echo "## IPv6 path-MTU - payload sizes"
  for sz in 1452 1432 1412 1392 1372 1352 1300 1232; do
    r=$(s ping6 -c 2 -W 2 -M do -s $sz 2001:4860:4860::8888 | grep -E "received|too long|mtu" | tr '\n' ' '); echo "v6 $sz: $r"
  done
}
echo "-- network probes (~1 min)"
probe > "$OUT/03_net_probes_before.txt"

echo "-- starting logcat (all buffers)"
adb logcat -b all -c >/dev/null 2>&1
adb logcat -b all -v threadtime > "$OUT/10_logcat_all.txt" 2>&1 &
LPID=$!
trap 'kill $LPID 2>/dev/null; echo; echo "Interrupted - partial capture in $OUT"; exit 1' INT

echo "PGO pid at start: $(s pidof $PKG)" >> "$OUT/marks.txt"
echo
echo "Now on the phone: open Pokemon GO and get to the point right before a battle (gym/raid/Rocket/trainer)."
read -r -p ">> Press Enter the moment you TAP INTO the battle... " _
mark "BATTLE_START"
read -r -p ">> Press Enter when it is clearly FROZEN (or when the battle loads fine)... " _
mark "FROZEN_OR_LOADED"
echo "PGO pid at freeze: $(s pidof $PKG)" >> "$OUT/marks.txt"
adb exec-out screencap -p > "$OUT/20_screen_at_freeze.png" 2>/dev/null
{
  echo "## sockets at freeze"; s ss -tuanp 2>&1 || true
  echo; echo "## /proc/net (fallback)"; for f in tcp tcp6 udp udp6; do echo "-- $f"; s cat /proc/net/$f; done
} > "$OUT/21_sockets_at_freeze.txt"
probe > "$OUT/22_net_probes_during_freeze.txt"
echo "Leaving the game as-is for ~30 more seconds of logging..."
sleep 30
mark "END"
kill $LPID 2>/dev/null; wait $LPID 2>/dev/null
trap - INT

read -r -p ">> Also grab a full Android bug report? Takes 2-4 min, very useful [y/N] " yn
case "$yn" in [yY]*) echo "-- adb bugreport..."; adb bugreport "$OUT/30_bugreport.zip" ;; esac

echo
echo "Done. Capture saved in: $OUT"
ls -la "$OUT"
