#!/usr/bin/env python3
"""Decode an Android /proc/net/tcp{,6} dump (as saved by capture.sh / freeze_test.sh) and list one uid's sockets.
Usage: python3 procnet.py 21_sockets_at_freeze.txt <uid>"""
import sys, socket, struct, collections
ST={'01':'ESTAB','02':'SYN_SENT','03':'SYN_RECV','04':'FIN_W1','05':'FIN_W2','06':'TIME_W','07':'CLOSE','08':'CLOSE_W','09':'LAST_ACK','0A':'LISTEN','0B':'CLOSING'}
def a4(h):
    ip,p=h.split(':'); return socket.inet_ntoa(struct.pack('<I',int(ip,16))), int(p,16)
def a6(h):
    ip,p=h.split(':'); b=bytes.fromhex(ip); b=b''.join(b[i:i+4][::-1] for i in range(0,16,4))
    s=socket.inet_ntop(socket.AF_INET6,b)
    if s.startswith('64:ff9b::'): s+=' (NAT64)'
    if s.startswith('::ffff:'): s=s[7:]
    return s,int(p,16)
uid=sys.argv[2]; sec=None
for line in open(sys.argv[1]):
    line=line.rstrip()
    if line.startswith('-- '): sec=line[3:]; continue
    f=line.split()
    if not sec or len(f)<10 or f[0]=='sl': continue
    if f[7]!=uid: continue
    dec=a6 if sec.endswith('6') else a4
    l=dec(f[1]); r=dec(f[2]); txq,rxq=f[4].split(':')
    st=ST.get(f[3],f[3]) if sec.startswith('tcp') else ('ESTAB' if f[3]=='01' else 'UNCONN' if f[3]=='07' else f[3])
    print(f"{sec:5} {st:8} {l[0]}:{l[1]:<6} -> {r[0]}:{r[1]:<6} txq={int(txq,16)} rxq={int(rxq,16)} retr={int(f[6],16)}")
