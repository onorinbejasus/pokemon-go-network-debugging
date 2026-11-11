# Pokémon GO battles freeze on T‑Mobile (Galaxy S26 Ultra): the phone drops IPv4 packets with "Don't Fragment" cleared

**TL;DR.** On my Galaxy S26 Ultra on T‑Mobile (US), every battle in Pokémon GO (trainer, Team Leader, Rocket, raid) freezes while loading. It happens on 5G and LTE alike, but never on Wi‑Fi, never when tethered to another phone, and never while roaming in Tokyo, Copenhagen, or Mexico City. The cause:

1. **This phone, on T‑Mobile mobile data, silently drops any IPv4 packet whose Don't‑Fragment (DF) bit is clear.** You can reproduce this without the game: `ping -M dont 8.8.8.8` gets 0/5 replies on mobile data and 5/5 on Wi‑Fi. With DF set (`-M do`), it's 5/5 on both.
2. **Pokémon GO clears DF on some of its connections**: always to `pushgateway-release.nianticlabs.com`, and on about half of its connections to `pgorelease.nianticlabs.com`, the main game API. Both servers are IPv4‑only. Every other app on the phone, and the game's other connections, send packets with DF set.
3. When a battle starts, the game opens new connections to those servers. On mobile data their packets are dropped, so the game retries every ~1.5 s forever. The game hasn't crashed (it still responds to taps); it's just waiting.

**Workaround:** run [PCAPdroid](https://github.com/emanuele-f/PCAPdroid) (no root needed, no dump, TLS decryption **off**) while playing on mobile data. It re‑sends the game's traffic from its own connections, which have DF set, and battles work.

**Am I affected?** If you have adb, run [`scripts/df_ping_test.sh`](scripts/df_ping_test.sh) on mobile data. If "DF clear" gets 0 replies while "DF set" works, you have the same problem. Without adb: if battles freeze on mobile data but work with PCAPdroid running, you very likely have it.

| | |
|---|---|
| Phone | Samsung Galaxy S26 Ultra, `SM-S948U1` (US unlocked, T‑Mobile CSC), Android 17, build `S948U1UEU5BZJA`, security patch 2026‑10‑05 |
| Carrier | T‑Mobile US (310‑260), APN `fast.t-mobile.com`, 5G SA (n41) and LTE both affected |
| Game | Pokémon GO 0.435.1. Both the Galaxy Store build (`com.nianticlabs.pokemongo.ares`) and the Play Store build are affected |
| Location | Chicago, IL. Not reproducible while roaming in Mexico City |
| Date | 2026‑11‑10 (log timestamps are US Central (UTC‑6); packet‑capture timestamps are UTC) |

---

## Who needs to fix what

**Samsung / T‑Mobile: this is the actual defect.** A phone shouldn't drop valid IPv4 packets just because DF is clear. On this device, Android's own IPv4‑over‑IPv6 translator (`clatd`) is **not running** on the T‑Mobile data connection. Instead, the network gives the phone the IPv4 address `192.0.0.8/27` directly, so the translation to T‑Mobile's IPv6‑only core happens in the modem or the network. My best guess (not confirmed) is that this translator handles DF‑clear IPv4 packets the old RFC 2765 way: it adds an IPv6 Fragment header (an "atomic fragment", deprecated by RFC 8021), and packets carrying one get dropped. Wi‑Fi, tethering and roaming all give the phone native IPv4, so no translation happens there. Repro: `adb shell ping -c 5 -M dont 8.8.8.8` on mobile data.

**Scopely / Niantic: an easy fix that would sidestep the problem for everyone.** The client clears DF on its connections to `pushgateway-release.nianticlabs.com` (34.117.15.92) and on some connections to `pgorelease.nianticlabs.com` (130.211.14.80). That looks like a socket option such as `IP_MTU_DISCOVER=IP_PMTUDISC_DONT`, or `Socket.DontFragment=false` in .NET/Unity. Either of these would fix it:
- Leave DF at the OS default (set) on those sockets.
- Publish AAAA (IPv6) records for those hosts, as some of the game's other endpoints already have. Over IPv6 there's no translation, so DF never comes into play.

---

## How we got here (the investigation)

Every step below links to the redacted evidence it's based on. All capture and test scripts are in [`scripts/`](scripts/).

### 1. First capture: mobile data vs. Wi‑Fi

[`scripts/capture.sh`](scripts/capture.sh) records device and carrier properties and the network configuration, runs ping/MTU probes, then records logcat while I tap into a battle and mark the moment of the freeze. At the freeze it also snapshots the game's sockets, re‑runs the probes, and finally takes an Android bug report. I ran it once on mobile data (battle froze) and once on Wi‑Fi (battle loaded).

What this showed:
- **The phone is on T‑Mobile 5G SA, and IPv4 is unusual.** The data interface gets `192.0.0.8/27` directly with MTU 1436, and Android's 464XLAT (`clatd`) reports `<not started>`. On most T‑Mobile phones, Android runs `clatd` itself. → [`network-config-mobile.txt`](evidence/01-baseline/network-config-mobile.txt), [`connectivity-networks-mobile.txt`](evidence/03-ruling-things-out/connectivity-networks-mobile.txt), [`device-and-carrier.txt`](evidence/01-baseline/device-and-carrier.txt)
- **The connection itself is healthy, even during the freeze.** Ping to 8.8.8.8 and Google's IPv6 DNS works, and every packet size up to the 1436‑byte MTU gets through. So there's no MTU black hole. (In hindsight, these probes couldn't have caught the problem: `-M do` sets DF.) → [`mtu-probes-*.txt`](evidence/01-baseline/)
- **The game isn't hung.** While "frozen", the game process keeps handling touches and location updates and logs no errors. It's waiting on the network. → [`game-logcat-during-freeze-mobile.txt`](evidence/02-the-freeze/game-logcat-during-freeze-mobile.txt)

### 2. What the game is waiting for

Decoding the game's sockets (uid 10403) at the moment of the freeze:

| Server | Mobile (froze) | Wi‑Fi (worked) |
|---|---|---|
| `34.117.15.92:443` (pushgateway‑release) | **SYN_SENT, 8 SYN retransmits, no reply** | established |
| `130.211.14.80:443` (pgorelease) | established connections OK, but **new ones stuck in SYN_SENT** | all established |

→ [`game-sockets-at-freeze-mobile.txt`](evidence/02-the-freeze/game-sockets-at-freeze-mobile.txt), [`game-sockets-at-freeze-wifi.txt`](evidence/02-the-freeze/game-sockets-at-freeze-wifi.txt), [`ss-detail-game-sockets-mobile.txt`](evidence/02-the-freeze/ss-detail-game-sockets-mobile.txt) (one socket: `segs_out:11`, `retrans:1/10`, nothing ever received)

netd's connect log shows the game's behaviour: after tapping into the battle on mobile data, it calls `connect()` **every 1.53 s, like a metronome, for over 2½ minutes** until the capture ended. On Wi‑Fi its connection activity is normal and irregular. → [`game-connect-timeline-mobile.txt`](evidence/02-the-freeze/game-connect-timeline-mobile.txt) vs [`game-connect-timeline-wifi.txt`](evidence/02-the-freeze/game-connect-timeline-wifi.txt)

### 3. Ruling things out

| Suspect | Verdict | Evidence |
|---|---|---|
| 5G standalone | ❌ Battles also freeze with 5G turned off (LTE) | user test |
| T‑Mobile can't reach those servers | ❌ 10/10 fresh TCP connects from `adb shell` to the same IP:ports on 5G, LTE and Wi‑Fi | [`net-test-*.txt`](evidence/03-ruling-things-out/) |
| MTU / PMTU black hole | ❌ every size up to the MTU passes | [`mtu-probes-*`](evidence/01-baseline/) |
| Per‑app firewall / Data Saver | ❌ game not on the active deny list; Data Saver off | [`firewall-l4s-datasaver-mobile.txt`](evidence/03-ruling-things-out/firewall-l4s-datasaver-mobile.txt) |
| Samsung L4S marking | ❌ game is in Samsung's "L4S RT map", but L4S is globally disabled (`sL4sEnabledMap: false`) | same file |
| TCP Fast Open / ECN | ❌ counters didn't move across ~350 game connections | [`tcp-fastopen-ecn-counters.txt`](evidence/03-ruling-things-out/tcp-fastopen-ecn-counters.txt) |
| Private DNS (AdGuard) | ❌ same server IPs resolved on both networks; the problem is at TCP SYN, after DNS | sockets above |
| Galaxy Store vs Play Store build | ❌ both affected | user test |
| App hang | ❌ UI thread alive throughout | logcat above |

### 4. Testing during the freeze: it's the game's packets, not the destination

[`scripts/freeze_test.sh`](scripts/freeze_test.sh) runs **while the battle is frozen**. It lists the game's stuck sockets, then has `adb shell` connect to the very same servers at the very same moment.

- Game: `SYN_SENT` to `130.211.14.80:443` (×3) and `34.117.15.92:443`, with no reply.
- Shell, same moment, same network: **10/10** to each, plus **10/10 in a simultaneous burst**.

→ [`freeze-test-mobile.txt`](evidence/04-root-cause/freeze-test-mobile.txt)

So the network and the servers are fine. Something about the packets the game sends gets them dropped.

### 5. PCAPdroid: the battle works, and the capture shows what's different

With [PCAPdroid](https://github.com/emanuele-f/PCAPdroid) running (a local VPN that re‑originates traffic; no root, no TLS decryption), **the battle loaded on LTE**. PCAPdroid records packets as the apps sent them, before it re‑sends them, so its capture shows the game's raw IPv4 headers:

```
Outbound IPv4 packets (all apps, ~2 min): 1122   with DF CLEAR: 319
DF-clear packets by destination:
  130.211.14.80  (pgorelease.nianticlabs.com)           300
  34.117.15.92   (pushgateway-release.nianticlabs.com)   19
```

Only the game clears DF, and only on connections to those two servers: always for pushgateway‑release, and on 9 of 17 TLS connections for pgorelease. Every other app, the game's connections to its other servers, and the shell's test connections all have DF set. That's also why every earlier test passed.

→ [`df-analysis.txt`](evidence/04-root-cause/df-analysis.txt), [`pcapdroid-game-servers-headers-only.pcap`](evidence/04-root-cause/pcapdroid-game-servers-headers-only.pcap) (headers only, filtered to the game's servers; analyse it with [`scripts/df_analysis.py`](scripts/df_analysis.py))

### 6. Confirmation without the game

```
                       mobile data (T-Mobile)   Wi-Fi
ping -M do   8.8.8.8         5/5                 5/5
ping -M dont 8.8.8.8         0/5                 5/5
```

→ [`ping-df-test.txt`](evidence/04-root-cause/ping-df-test.txt)

This explains every observation:
- **Every battle type:** they all need fresh connections to those servers.
- **Mobile data only:** that's the only path where IPv4 gets translated.
- **Only this phone:** its IPv4 translation happens in the modem/network instead of Android's `clatd`.
- **Fine in Mexico, tethered, and with PCAPdroid:** those paths either use native IPv4 or re‑send the traffic with DF set.

---

## Reproduce it yourself

Requirements: a Mac or Linux machine with `adb` (`brew install --cask android-platform-tools`), USB debugging enabled, phone on **USB** (not wireless debugging), and Wi‑Fi off on the phone for mobile tests.

| Script | What it does |
|---|---|
| [`df_ping_test.sh`](scripts/df_ping_test.sh) | 10‑second check for the root cause (ping with DF set vs clear) |
| [`capture.sh <label>`](scripts/capture.sh) | Full capture: device/network info, probes, logcat with battle markers, socket snapshot, optional bug report |
| [`net_test.sh <label>`](scripts/net_test.sh) | 10 fresh TCP connects to each game server over IPv4 and via T‑Mobile NAT64 |
| [`freeze_test.sh <label>`](scripts/freeze_test.sh) | Run while frozen: game's stuck sockets vs. shell connects at the same moment |
| [`procnet.py`](scripts/procnet.py) | Decode `/proc/net/tcp{,6}` dumps for one uid |
| [`df_analysis.py`](scripts/df_analysis.py) | Flow and DF summary for a raw‑IP pcap (e.g. from PCAPdroid) |

Note: `capture.sh` and `freeze_test.sh` write to a `captures/` folder next to themselves. Those raw captures contain personal data (see below), so don't publish them unredacted.

---

## About the data in this repo

Raw Android logs and bug reports contain far more personal data than can be reliably scrubbed: precise GPS fixes, Wi‑Fi network names, MAC addresses, account names, installed apps, and other apps' traffic. So this repo publishes **only curated excerpts** relevant to each step, with these redactions:

- GPS coordinates → `[REDACTED]`
- The phone's own global IPv6 addresses (T‑Mobile and home ISP) and link‑local addresses → `[IPv6-REDACTED]` / `[fe80-REDACTED]`
- MAC addresses, Wi‑Fi SSID, user and host names
- The packet capture is filtered to the game's three Google Cloud servers and **truncated to IP+TCP headers** (no payload, no TLS data)

Not published: full logcat, full bug reports, full connectivity dumps, screenshots and the full packet capture. **Samsung, T‑Mobile and Scopely engineers can request the unredacted captures privately**; open an issue on this repo or reach out to me privately via email or reddit (same username as github).

Kept as‑is because they aren't identifying: the phone model and build, carrier, Google Cloud server IPs, T‑Mobile's internal `192.0.0.x` / `fd00:976a::` addresses, PCAPdroid's virtual `10.215.173.x` addresses, and private LAN `192.168.x.x` addresses.
