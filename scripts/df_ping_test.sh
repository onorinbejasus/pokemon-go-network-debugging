#!/bin/bash
# Quick check: does this phone drop IPv4 packets that have the Don't-Fragment bit CLEAR?
# Run once with Wi-Fi OFF (mobile data) and once on Wi-Fi. Phone connected via USB with adb debugging on.
for mode in do dont; do
  r=$(adb shell ping -c 5 -W 2 -M $mode 8.8.8.8 | grep -E "packets transmitted")
  printf "DF %-4s (-M %-4s): %s\n" "$([ $mode = do ] && echo set || echo clear)" "$mode" "$r"
done
