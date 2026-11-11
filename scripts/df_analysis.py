#!/usr/bin/env python3
"""Summarise TCP flows in a raw-IP pcap (e.g. a PCAPdroid capture) and flag packets
sent with the IPv4 Don't-Fragment bit CLEAR.  Pure stdlib.
Usage: python3 df_analysis.py capture.pcap [server_ip ...]"""
import struct, sys, socket, collections, datetime

def packets(path):
    with open(path, 'rb') as f:
        gh = f.read(24)
        magic = struct.unpack('<I', gh[:4])[0]
        e = '<' if magic in (0xa1b2c3d4, 0xa1b23c4d) else '>'
        linktype = struct.unpack(e + 'I', gh[20:24])[0]
        if linktype not in (101, 228):
            sys.exit(f'unsupported linktype {linktype} (expected raw IP)')
        while True:
            h = f.read(16)
            if len(h) < 16: break
            ts, us, caplen, origlen = struct.unpack(e + 'IIII', h)
            yield ts + us / 1e6, f.read(caplen)

def main():
    path, servers = sys.argv[1], set(sys.argv[2:])
    flows = collections.OrderedDict()
    out_total = out_nodf = 0
    nodf_by_dst = collections.Counter()
    for ts, p in packets(path):
        if not p or p[0] >> 4 != 4: continue
        ihl = (p[0] & 15) * 4
        flags = struct.unpack('!H', p[6:8])[0]
        df = bool(flags & 0x4000)
        proto = p[9]
        src, dst = socket.inet_ntoa(p[12:16]), socket.inet_ntoa(p[16:20])
        outbound = src.startswith('10.215.') or src.startswith('192.0.0.')
        if outbound:
            out_total += 1
            if not df: out_nodf += 1; nodf_by_dst[dst] += 1
        if proto != 6 or len(p) < ihl + 14: continue
        sp, dp = struct.unpack('!HH', p[ihl:ihl + 4])
        tf = p[ihl + 13]
        key = (src, sp, dst, dp) if outbound else (dst, dp, src, sp)
        fl = flows.setdefault(key, {'t': ts, 'df': set(), 'synack': False, 'pkts_out': 0, 'pkts_in': 0})
        if outbound: fl['df'].add('DF' if df else 'no-DF'); fl['pkts_out'] += 1
        else:
            fl['pkts_in'] += 1
            if tf & 0x12 == 0x12: fl['synack'] = True
    print(f'Outbound IPv4 packets: {out_total}   with DF CLEAR: {out_nodf}')
    print('DF-clear packets by destination:')
    for d, n in nodf_by_dst.most_common(): print(f'  {d:16} {n}')
    print()
    print('TCP flows' + (f' to {", ".join(sorted(servers))}' if servers else '') + ':')
    print(f'{"start (UTC)":15} {"destination":22} {"src port":>8}  {"IP flags":10} {"SYN-ACK":7} {"pkts out/in"}')
    for (s, sp, d, dp), fl in flows.items():
        if servers and d not in servers: continue
        t = datetime.datetime.fromtimestamp(fl['t'], datetime.timezone.utc).strftime('%H:%M:%S.%f')[:12]
        print(f'{t:15} {d + ":" + str(dp):22} {sp:>8}  {",".join(sorted(fl["df"])):10} {str(fl["synack"]):7} {fl["pkts_out"]}/{fl["pkts_in"]}')

if __name__ == '__main__':
    main()
