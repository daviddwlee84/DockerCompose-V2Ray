# Browser intermittently can't load Google; mihomo logs `match Match using Final` with a bare IP

**Symptom** (observed on the *client* machine running mihomo in TUN mode, inside
mainland China): Zen Browser (a Firefox fork) fails to load Google — **sometimes**.
Reload and it may work. It is not a hard failure, and nothing points at the node:
a direct probe of the proxy port succeeds every time.

```sh
$ curl -x http://127.0.0.1:7890 -o /dev/null -w '%{http_code}\n' https://www.google.com/generate_204
204          # the node is fine — this is NOT a node/subscription problem
```

The greppable tell is in the mihomo log — a connection matched **by raw IP with no
domain attached**, so every `DOMAIN-SUFFIX` rule is structurally unreachable and it
falls through to the final catch-all:

```
[TCP] 198.18.0.1:46422 --> 157.240.7.20:443 match Match using Final[<node>]
```

Healthy traffic reads
`--> www.google.com:443 match DomainSuffix(google.com) using PROXY[...]`.
`157.240.7.20` is a **Facebook** address being dialed for a Google request — that
is the poison.

**Qualify the grep before you trust it.** `match Match using Final` against a bare
IP is only diagnostic on ports you expect to carry TLS/HTTP (443/80) for hostnames
you *have* rules for. IP-literal dials on other ports produce the identical line
perfectly legitimately and will drown you in false positives — on this host an frp
client dialing `<ip>:7000` accounts for 244 of the 352 such lines logged *after*
the fix. Port 7000 is in no `sniff:` port list and the dial carries no hostname, so
it can only ever land on `MATCH,Final`.

`ping` looks healthy and is lying to you:

```
$ ping www.google.com
PING www.google.com (69.171.235.22) 56(84) bytes of data.
64 bytes from 69.171.235.22: icmp_seq=1 ttl=64 time=0.169 ms
```

`69.171.235.22` is **also a Facebook/Meta** address, and `0.169 ms` is mihomo's TUN
device answering the ICMP locally — not a real round trip. **Under TUN, `ping`
tells you nothing about connectivity or latency**; it will happily "succeed"
against a forged address.

## Environment

Ubuntu workstation, `uid 1000`, mainland China (GFW DNS poisoning active).
mihomo v1.19.29 as a **systemd `--user`** unit, config `~/.config/mihomo/config.yaml`.
TUN on (device `Meta`, `stack: system`, `auto-route: true`, `dns-hijack: [any:53]`),
`mixed-port: 7890`, `external-controller: 127.0.0.1:9090`. No root — file caps
`CAP_NET_ADMIN` + `CAP_NET_BIND_SERVICE`. Tailscale also active; `systemd-resolved`
in stub mode. 1144 `DOMAIN-SUFFIX` rules in the ruleset.

Client-side only — nothing in this repo's deploy path, though the same traps are
latent in `clients/mihomo-docker/config.example.yaml` (see Follow-up). Background
research notes on the mihomo core live in [`docs/clash/`](../docs/clash/README.md)
(Traditional Chinese).

The broken part of the old config:

```yaml
dns:
  enable: true
  ipv6: false
  nameserver-policy:
    "+.home.arpa": "<lan-dns-ip>"
  nameserver:
    - 8.8.8.8          # <-- plain UDP:53
    - 1.1.1.1          # <-- plain UDP:53
  fallback:
    - 1.1.1.1
    - 8.8.8.8
# no enhanced-mode key at all  => mihomo defaults to redir-host
# no sniffer block, no profile block
```

## How it was diagnosed (2026-07-29)

- **The tell: the log matched on an IP, never on a domain.** `match Match using
  Final` for a `:443` flow means mihomo could not attach a hostname to the
  connection, so all 1144 `DOMAIN-SUFFIX` rules were unreachable for it. That points
  at the *IP↔domain mapping* — not at the node, not at the rules.
- The proxy-port probe returned `204` while the browser failed → the outbound node
  is healthy; the fault is upstream of dialing, in resolution / rule matching.
- The dialed IPs were Facebook ranges for Google hostnames → forged answers, so the
  question became *who is producing them, and which resolution path did the browser
  actually take*.
- **Repeated resolution of the same name returned a different forged IP each time**
  — `31.13.92.37`, `69.171.235.22`, `174.132.167.252`, `185.45.5.35`, all TTL ≈101s.
  Rotating answers with a short TTL are the GFW's signature.
- Since `dns.nameserver` was plain UDP `8.8.8.8` / `1.1.1.1`, **mihomo's own upstream
  was a poisoned path too** — so every client that mihomo *did* answer got poison
  manufactured by mihomo itself.
- Two independent probes then *disagreed* about whether DNS was being hijacked at
  all. That contradiction is what makes this bug hard, and resolving it is what
  identified the browser's actual resolution path.

### The subtlety: two probes disagree, and both are correct

```sh
$ dig +short @<lan-router-ip>  www.google.com   # 198.18.0.4  (hijacked by mihomo)
$ dig +short @198.51.100.99    www.google.com   # 198.18.0.4  (hijacked — and that IP is
                                                #  TEST-NET-2; nothing exists there)
$ resolvectl query www.google.com               # 185.45.5.35 -- link: eno1   (NOT hijacked)
                                                # 2001::1     -- link: eno1   (poisoned AAAA)
```

Getting an answer from `198.51.100.99` — an [RFC 5737](https://www.rfc-editor.org/rfc/rfc5737)
TEST-NET-2 address (`198.51.100.0/24`) where no server can possibly exist —
**proves** `dns-hijack: any:53` works for processes that speak DNS directly:
mihomo answered on behalf of a nonexistent server. Yet `resolvectl` walks straight
past it.

Why: `auto-route` installs, among others,

```
9001:  not from all dport 53 lookup main suppress_prefixlength 0
```

which deliberately **excludes** dport-53 from the main-table shortcut, so DNS falls
through to rule `9002` → table `2022` → `via 198.18.0.2 dev Meta` and gets hijacked.
`systemd-resolved`, however, does per-link DNS with `SO_BINDTODEVICE(eno1)`. **That
pins the output interface, so table 2022's `dev Meta` routes can no longer satisfy
the lookup and it falls through to `main`** — the policy rules are still consulted,
they simply cannot bind the socket to a different device. Demonstrated:

```sh
$ ip route get 8.8.8.8 ipproto udp dport 53
8.8.8.8 via 198.18.0.2 dev Meta table 2022 src 198.18.0.1        # hijacked
$ ip route get 8.8.8.8 oif eno1 ipproto udp dport 53
8.8.8.8 via <lan-router-ip> dev eno1 src <lan-host-ip>           # main table — escapes
```

Consequence, and this is the load-bearing part: **anything using the glibc/NSS
system resolver — i.e. every normal application, browsers included — still receives
poisoned answers even with `dns-hijack` on.** So the tempting early hypothesis
("DNS is bypassing mihomo") was **half right**: `dns-hijack` covers `dig`/`curl`-style
direct DNS, it does not cover `systemd-resolved`, and the client that was broken sits
on the uncovered side. Verified before *and* after the fix:
`dig @127.0.0.53 www.google.com` → `31.13.92.37`, `resolvectl query www.google.com`
→ `104.244.42.197`. A successful `dig` hijack is not proof that the machine is
covered. The sniffer is what rescues that traffic.

## Root cause

A chain; every link is independently worth remembering.

1. **Plaintext DNS inside a censored network, on two paths at once.** The GFW
   forge-answers UDP:53 to `8.8.8.8` / `1.1.1.1`, so mihomo received, cached and
   served forged answers to anything it answered — a different one per query. In
   parallel, `systemd-resolved` forwarded to the LAN router over the un-hijacked
   `SO_BINDTODEVICE` path and got its own forged answers. Encrypting the *client's*
   path to mihomo is pointless while mihomo's own path out is cleartext.
2. **The browser never asked mihomo.** It resolved through the glibc/NSS resolver →
   `systemd-resolved` → LAN router → GFW. So mihomo had **no mapping at all** for
   the IPs the browser then dialed — not a stale one. (For the record, `redir-host`
   is not as forgetful as folklore says: `dns/enhancer.go` builds a
   `lru.New(lru.WithSize[netip.Addr, string](4096))` and `dns/middleware.go`'s
   `withMapping` stores each answer with `SetWithExpire(ip, host, now + answer TTL)`.
   4096 live mappings expiring on the upstream TTL — but only for answers **mihomo
   itself issued**.)
3. The connection therefore arrived at the TUN carrying an IP mihomo **cannot name**
   → the 1144 `DOMAIN-SUFFIX` rules cannot match → it falls through to `MATCH,Final`
   → mihomo dials the **poisoned Facebook IP** through the proxy node → TLS with
   `SNI: www.google.com` arrives at a Facebook edge → reset → browser shows a
   connection error.
4. It presented as **intermittent rather than always-broken** — a reload could
   succeed — because the browser caches by its own policy (60s+, ignoring TTL) while
   each fresh lookup returned a different forged address. Carry away the shape, not
   the timing: *browser-only failure while the proxy port is healthy is a
   DNS-path signature, not a node problem.*

## Fix

Two independent repairs: **(a)** stop producing and consuming poison — encrypted
literal-IP upstreams plus a `fallback-filter` that rejects forged answers, and a
sniffer so that bare-IP connections from system-resolver clients recover their
hostname; **(b)** `fake-ip` (+ persistence) so that clients which *do* query mihomo
get a stable, permanently reverse-mappable address. (b) does not help the browser
here — it never queries mihomo — it removes the whole class of
mapping-lifetime bugs for everything that does. Applied to
`~/.config/mihomo/config.yaml`:

```yaml
ipv6: false            # top level. Was implicitly true while dns.ipv6 was false —
                       # inconsistent, and this machine has no working IPv6:
                       # `ip -6 route get 2001::1` => Network is unreachable, and
                       # mihomo installs no IPv6 ip-rules at all. Keeping poisoned
                       # AAAA records around buys nothing but an ENETUNREACH per dial.

profile:
  store-selected: true
  store-fake-ip: true  # see gotchas

dns:
  enable: true
  ipv6: false
  listen: 127.0.0.1:1053          # loopback only. 1053 rather than 53 because
                                  # systemd-resolved's stub already owns :53 — NOT a
                                  # privilege issue (mihomo holds CAP_NET_BIND_SERVICE).
                                  # Real traffic arrives via dns-hijack; this port is
                                  # for `dig` debugging.
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16    # compile-time default; TUN's inet4-address
                                  # 198.18.0.1/30 is DERIVED from it. Do not change it.
  fake-ip-filter-mode: blacklist
  fake-ip-filter:                 # must be written IN FULL — a YAML list REPLACES
    - dns.msftnsci.com            # the built-ins, so copy the three back
    - www.msftnsci.com
    - www.msftconnecttest.com
    - "+.home.arpa"               # LAN split-DNS — must get the real LAN IP
    - "+.lan"
    - "+.local"
    - localhost
    - "+.ts.net"                  # Tailscale MagicDNS ("+", never "*" — see gotcha)
    - "+.japaneast.cloudapp.azure.com"   # proxy-server domains: a faked node
                                  # hostname is an instant self-inflicted outage
    - "+.pool.ntp.org"            # NTP / captive-portal probes
    - "+.ntp.org"
    - time.windows.com
    - captive.apple.com

  # Domestic encrypted DNS addressed by LITERAL IP, so cold start needs zero prior
  # DNS. 120.53.53.53 IS doh.pub — the IP form removes even the bootstrap hostname.
  nameserver:
    - https://223.5.5.5/dns-query
    - https://120.53.53.53/dns-query
    - tls://223.5.5.5:853

  # MANDATORY when any proxy `server:` is a hostname (most nodes here are
  # *.japaneast.cloudapp.azure.com). mihomo forces this group to resolve
  # direct + rule-free, which is what breaks the chicken-and-egg.
  proxy-server-nameserver:
    - https://223.5.5.5/dns-query
    - https://120.53.53.53/dns-query

  # Foreign DoH PINNED THROUGH THE PROXY. batchExchange races all fallback clients
  # concurrently and takes the first success, so listing a hard-pinned node AND the
  # user's selector gives redundancy.
  fallback:
    - https://1.1.1.1/dns-query#<literal-ip-node>   # pinned to a node whose server: is
                                                    # a literal IP -> needs no DNS at all
    - https://8.8.8.8/dns-query#PROXY               # follows the current selection

  fallback-lazy-query: true   # default false fires a PROXIED DoH query on EVERY cache
                              # miss, even for domains that resolve entirely inside CN:
                              # a wasted round trip per lookup, and it ships the whole
                              # domestic domain list abroad.

  fallback-filter:
    geoip: true
    geoip-code: CN
    # This — NOT nameserver-policy — is where "resolve these overseas domains
    # abroad" belongs. Listed domains take the shouldOnlyQueryFallback shortcut
    # straight to the proxied DoH resolver, and unlike a policy they stay inside
    # the anti-poisoning machinery. Put here anything you were tempted to pin:
    domain:
      - "+.google.com"
      - "+.anthropic.com"
      - "+.openai.com"
    ipcidr:
      - 0.0.0.0/8
      - 240.0.0.0/4
      - 31.13.64.0/18        # observed poison: Facebook
      - 69.171.224.0/19      # observed poison: Facebook
      - 157.240.0.0/16       # observed poison: Facebook
      - 104.244.42.0/24      # observed poison: Twitter
      - 174.132.0.0/16
      - 185.45.4.0/22
      - 202.106.199.35/32    # CN-GEOLOCATED sinkholes — `geoip: true` alone waves
      - 202.106.1.2/32       # these straight through

sniffer:
  enable: true
  override-destination: true
  parse-pure-ip: true
  sniff:                     # `enable: true` WITHOUT this block is a SILENT NO-OP
    HTTP: { ports: [80, 8080, 8880] }
    TLS:  { ports: [443, 8443] }
    QUIC: { ports: [443, 8443] }
  skip-dst-address: [ ... every no-resolve rule target — see gotcha ... ]
```

## Required post-apply steps — a restart alone LOOKS like the fix failed

```sh
systemctl --user restart mihomo
resolvectl flush-caches
# then in the browser: about:networking#dns -> Clear DNS Cache  (or just restart it)
```

Both `systemd-resolved` and Firefox/Zen still hold the old poisoned IPs otherwise,
and you will conclude the new config did nothing.

## Gotcha: fake-ip vs redir-host — mapping *lifetime* is the whole point

`redir-host` hands the client the **real** (here: forged) IP and keeps a 4096-entry
IP→host LRU whose entries expire at the answer's TTL (≈101s for GFW forgeries). Any
client that caches longer than that — or, as here, one that never asked mihomo at
all — presents an IP mihomo can't name, and you land in `match Match using Final`.

`fake-ip` hands the client a stable `198.18.x.x` from the pool and owns both
directions of the mapping. The same domain always gets the same fake IP, so
**client-side cache lifetime becomes irrelevant** for every client that actually
queries mihomo. It cannot help a client that resolves around mihomo — that is the
sniffer's job.

Transferable rule: **when rules stop matching for one domain, check the DNS mode and
which resolver the failing client uses before you touch the rules.**

## Gotcha: `profile.store-fake-ip: true` with fake-ip

Without it the fake-ip pool is a **1000-entry in-memory LRU, wiped on every restart**.
Clients still hold `198.18.x.x` from before the restart; on reconnect
`preHandleMetadata` fails to reverse-map it and raises

```
fake DNS record 198.18.0.x missing
```

What happens next depends on the protocol, and it is not what the wording suggests:

- **TCP** — `tunnel/tunnel.go` (`handleTCPConn`) records the failure in a
  `preHandleFailed` flag and then *deliberately* gives the sniffer a chance; the
  upstream comment reads "Try to sniff a domain when `preHandleMetadata` failed,
  this is usually caused by a 'Fake DNS record missing' error when enhanced-mode is
  fake-ip." If `TCPSniff` succeeds the flag is cleared and the connection proceeds.
  With `parse-pure-ip: true`, `shouldOverride()` returns true here precisely because
  `Host` is still empty after the failed reverse-map.
- **UDP** — no such rescue: `tunnel.go` drops the packet before the NAT entry and
  sniffer exist. QUIC / HTTP3 on UDP 443 simply vanishes.

So `store-fake-ip: true` is not the difference between working and unrescuably
dead — it is the difference between deterministic mapping and a silent dependence
on sniffing (which only covers TCP, only on the ports you declared). Turn it on: the
mapping persists in `cache.db`, survives restarts, and loses the 1000-entry ceiling.
Pair it with `store-selected: true` so the manually chosen node also survives
`systemctl --user restart mihomo`.

In a container, note that `cache.db` lands next to `config.yaml` in the config dir:
that directory must be writable **and durable**, or `store-fake-ip: true` silently
buys nothing (see Follow-up).

## Gotcha: `sniffer.enable: true` without an explicit `sniff:` block is a silent no-op

No error, no warning, no config-test failure — the sniffer simply never sniffs. The
protocols and ports must be declared. Likewise `override-destination: false` gets you
*correct rule matching* while still **dialing the original (possibly poisoned) IP** —
matching is not dialing.

## Gotcha: the sniffer and fake-ip cover disjoint paths

`shouldOverride()` returns true only when `metadata.Host == "" && parse-pure-ip`, and
a successful fake-ip reverse-map **populates** `Host`. So fake-ip traffic *whose
record is still present* skips the sniffer entirely; the two features do not fight.
The sniffer's job is **bare-IP connections** — traffic from apps using the
glibc/system resolver (see the two-probes section, i.e. the browser in this
incident) and IP-literal dials — plus the one overlap noted above, TCP whose fake-IP
record went missing. Enable both.

## Gotcha: `sniffer.skip-dst-address` must cover every `no-resolve` rule target

Under `override-destination`, `replaceDomain()` executes
`metadata.DstIP = netip.Addr{}`. A rule carrying `no-resolve` never re-resolves, so
it can **never match** — and an entire `IP-CIDR,...,REJECT,no-resolve` blocklist
(here ~40 ISP ad-injection / hijack IPs) is silently skipped, with the traffic
landing on `GEOIP,CN,DIRECT` and being allowed. ISP hijacks are precisely "port 80 +
a valid Host header", so sniffing always succeeds on them; they must be excluded at
the sniff stage:

```yaml
skip-dst-address:
  - 127.0.0.0/8
  - 10.0.0.0/8
  - 172.16.0.0/12
  - 192.168.0.0/16
  - 100.64.0.0/10          # Tailscale CGNAT
  - fd7a:115c:a1e0::/48    # Tailscale ULA
  - <every IP an IP-CIDR,...,no-resolve rule targets>
```

Transferable rule: **enabling `override-destination` creates an obligation to
re-audit every `no-resolve` rule you have.**

## Gotcha: a YAML list REPLACES mihomo's built-in defaults, and `*` ≠ `+`

Writing `fake-ip-filter:` at all discards the three built-in entries
(`dns.msftnsci.com`, `www.msftnsci.com`, `www.msftconnecttest.com`) — the NCSI /
captive-portal probes then see a fake IP and the OS reports "no internet". Copy them
back, then add everything that needs a *real* IP: `+.home.arpa`, `+.lan`, `+.local`,
`localhost`, `+.ts.net`, the proxy-server domains, and the NTP / captive-portal
probes.

The wildcard form matters as much as the list: **`*` matches exactly ONE label,
`+` matches the apex and every depth.** So `*.ts.net` cannot cover the real MagicDNS
shape `<host>.<tailnet>.ts.net` (two labels) — every genuine Tailscale name gets a
fake IP handed to the application. Rule matching itself still works (fake-ip
populates `Host`, so `DOMAIN-SUFFIX,ts.net,DIRECT` matches on the reverse-mapped
host); what breaks is the real-IP path: `IP-CIDR,100.64.0.0/10,DIRECT,no-resolve`
can never match because `DstIP` was cleared, and anything that bypasses mihomo's
rule engine — ICMP, non-TCP/UDP protocols, apps outside the TUN — is left dialing
`198.18.x.x` instead of the peer.

Generalize it: **any list-valued key you define in mihomo overrides the default list
rather than extending it.** Check the defaults before you override.

## Gotcha: `nameserver-policy` is EXCLUSIVE — a hit never falls through

A domain matching a policy entry is resolved **only** by that entry's servers. It does
not fall through to `nameserver` or `fallback`, and `fallback-filter` is never applied
to a policy answer — so the one sanity check that would catch a Facebook IP for a
Google hostname is bypassed. Verified: a policy whose servers were unreachable
returned `SERVFAIL` for the covered domain while an uncovered control domain resolved
normally.

Audit every policy entry the way you'd audit a single point of failure, because that
is what each one is. In particular, **never point a policy entry at plain UDP
`8.8.8.8` / `1.1.1.1` from inside CN** — that pins the covered domains to the poisoned
path with no rescue. To express "resolve these overseas domains abroad", use
`fallback-filter.domain` (as in the Fix block above) instead.

## Gotcha: `#Name` on a DNS upstream means "node, or else interface" — typos are silent

`https://1.1.1.1/dns-query#<node-name>` pins a DoH upstream to a proxy node. mihomo
looks the name up in `Proxies()` first and, on a miss, **falls through to treating it
as an interface name**. So a misspelled node name is *not* a config error —
`mihomo -t` reports success for a fallback pinned to `#ThisNodeDoesNotExist` — you
just get a silently misrouted, usually dead, DNS upstream. Verify pins by behaviour,
never by the config test.

The same fallthrough, used deliberately, is the fix for Tailscale. With a global
`interface-name: eno1`, **every** mihomo DNS dial is `SO_BINDTODEVICE`'d to `eno1`,
so the obvious MagicDNS policy never reaches MagicDNS:

```yaml
nameserver-policy:
  "+.ts.net": "100.100.100.100"              # SERVFAIL — routed out eno1 via the LAN router
  "+.ts.net": "100.100.100.100#tailscale0"   # NOERROR  — resolved as an interface name
```

Measured: plain → `SERVFAIL`; pinned → `NOERROR`.

## Gotcha: `mihomo -t` passes on every defect in this file

Config-test is not a safety net here — plan the debugging accordingly. Confirmed
silently accepted as "test is successful": `sniffer.enable: true` with no `sniff:`
block; a fallback pinned to a non-existent node name; a `fake-ip-filter` that shadows
the built-in defaults; `fake-ip` with no `store-fake-ip`; and a `0.0.0.0` controller
with no `secret`. **The only reliable signals are runtime ones** — a bare-IP
`match Match using Final` on 443/80 for a domain you have a rule for, and
`fake DNS record 198.18.0.x missing`, which is emitted at **DEBUG level only**
(`log.Debugln("[Metadata PreHandle] error: %s", err)`), so you must set
`log-level: debug` or watch `/logs?level=debug` on the external controller to see it
at all.

## Verify

```sh
mihomo -t -d ~/.config/mihomo                       # -> "test is successful"
dig +short @127.0.0.1 -p 1053 www.google.com        # -> 198.18.0.4  (IDENTICAL on repeat)
curl -sI https://www.google.com | grep -m1 '^HTTP/2'
                                                    # -> HTTP/2 200
                                                    #    (grep, not `head -1`: with
                                                    #     HTTP(S)_PROXY exported, line 1 is
                                                    #     "HTTP/1.1 200 Connection established"
                                                    #     from the CONNECT. Add --noproxy '*'
                                                    #     to test the TUN path instead.)
curl -o /dev/null -s -w '%{http_code} %{time_total}\n' https://www.google.com/generate_204
                                                    # -> 204  0.32s
curl -o /dev/null -s -w '%{http_code} %{time_total}\n' https://www.baidu.com
                                                    # -> 200  0.079s  (still DIRECT)
dig +short @127.0.0.1 -p 1053 <node>.japaneast.cloudapp.azure.com
                                                    # -> a real Azure IP, NOT 198.18.x.x
                                                    #    (proves fake-ip-filter works — the
                                                    #     node hostname is not faked)
ip route get 100.100.100.100                        # -> dev tailscale0 table 52 (intact)
journalctl --user -u mihomo | grep -c 'fake DNS record'
                                                    # -> 0, but ONLY meaningful with
                                                    #    log-level: debug — the message is
                                                    #    Debugln-only, so this grep is
                                                    #    vacuous at the default INFO level
```

`proxy-server-nameserver` is **not** exercised by that `dig`: queries to `dns.listen`
go through the normal resolver pipeline (`dns/middleware.go` → `Resolver.ExchangeContext`
→ `nameserver`/`fallback`), while `proxy-server-nameserver` is exposed as
`resolver.ProxyServerHostResolver` and referenced only from outbound dialing code.
Check it behaviourally instead — cold-start with an empty `cache.db` and confirm the
`*.japaneast.cloudapp.azure.com` node connects, or temporarily point the group at a
dead server and confirm the node fails to dial.

The log must show domains again:

```
--> www.google.com:443 match DomainSuffix(google.com) using PROXY[<node>]
--> www.baidu.com:443  match DomainSuffix(baidu.com)  using DIRECT
```

And the fake IP must be **stable across a restart** — `198.18.0.4` both before and
after `systemctl --user restart mihomo`. If it changes, `store-fake-ip` is not on.

Do **not** use `ping` to verify any of this (see the top of this file).

## Rollback

```sh
systemctl --user stop mihomo
cp config.yaml.bak.dnsfix.<TS> config.yaml
rm -f cache.db          # holds a fakeip bucket the old redir-host config won't use
systemctl --user start mihomo && resolvectl flush-caches
```

## Follow-up

**`clients/mihomo-docker/config.example.yaml` carried the same DNS traps** (client-side
example only — the server deploy path is unaffected). **Fixed in the same change as this
file**: the `nameserver-policy` block that pinned six overseas domains to plain UDP
`[1.1.1.1, 8.8.8.8]` — the exact upstreams verified forged today, and exclusive, so
nothing could rescue a poisoned answer — was replaced by `fallback-filter.domain`;
`fallback` moved off plain UDP onto pinned literal-IP DoH; the `geoip`-only
`fallback-filter` gained the `ipcidr` list above; `profile` (`store-selected` +
`store-fake-ip`), `sniffer` and `proxy-server-nameserver` were added; and the
`fake-ip-filter` — which used single-label `*` wildcards, shadowed the built-ins, and
omitted `+.home.arpa`, `localhost`, the NTP pools and `captive.apple.com` — was rewritten.

Two conditions to keep in mind while auditing that file, because both defects are
currently *dormant*: the policy block is bypassed in the stock topology (those domains
match `DOMAIN-SUFFIX` and are dialed by domain with zero DNS) and goes live the moment
`DIRECT` is selected in the `PROXY` group, `dns.listen` is added, or the file is reused
under TUN — which is exactly how this desktop host got here. And `enhanced-mode: fake-ip`
is inert there (no `dns.listen`, no `tun:`, no redir/tproxy port), so no client can hold
a `198.18.x.x` and the missing-`profile` landmine cannot fire yet; it goes live the
moment `dns.listen` or `tun:` is added. Storage differs per compose file: under
`docker-compose.binary.yaml` the image is bare `alpine:latest`, so `/root/.config/mihomo`
is the container's writable layer — `cache.db` survives `docker restart` but dies on any
recreate; under `docker-compose.yaml` the official `metacubex/mihomo` image declares that
path a `VOLUME`, so `cache.db` lands in an anonymous volume that compose reuses across
recreates but that `--renew-anon-volumes` / `down -v` discards. Either way, mount a named
volume there once `store-fake-ip` is enabled.

The non-DNS findings from the same audit are recorded in [`TODO.md`](../TODO.md) as a
`clients/mihomo-docker` hardening entry rather than here: `external-controller: 0.0.0.0:9091`
with `secret` commented out and published on every interface by both compose files
(plus `allow-lan: true` + `bind-address: "*"` + `7890:7890` with no `authentication:`,
i.e. an open relay — the weakness [`docs/clash/API.md`](../docs/clash/API.md) already
flags); `DOMAIN-KEYWORD,github,PROXY` sitting above `GEOIP,CN`; the dead
`IP-CIDR6,fd7a:115c:a1e0::/48` rule under `ipv6: false`; and the stale claim in
`README.md` / `docker-compose.binary.yaml` that bare alpine cannot do DoH for lack of
`ca-certificates` — verified false (`alpine:latest` ships `ca-certificates-bundle`,
which Go's `crypto/x509` reads directly), and left uncorrected it will talk a future
operator back into plain UDP.

Done in the same commit as this file: the [`pitfalls/README.md`](README.md) intro was
widened, since it previously scoped the directory to "traps hit while operating this
V2Ray server" and this entry is purely client-side.

## References

- mihomo DNS (`enhanced-mode`, `fake-ip-filter`, `nameserver-policy`, `proxy-server-nameserver`, `fallback-filter`): <https://wiki.metacubex.one/config/dns/>
- mihomo sniffer (`override-destination`, `parse-pure-ip`, `skip-dst-address`): <https://wiki.metacubex.one/config/sniffer/>
- mihomo TUN inbound / `auto-route` / `dns-hijack`: <https://wiki.metacubex.one/config/inbound/tun/>
- mihomo `profile` (`store-selected`, `store-fake-ip`): <https://wiki.metacubex.one/config/general/#profile>
- `SO_BINDTODEVICE` pins the output interface: `socket(7)`; policy rules: `ip-rule(8)`
- RFC 5737 (TEST-NET-2 `198.51.100.0/24`): <https://www.rfc-editor.org/rfc/rfc5737>
- RFC 2544 benchmarking range `198.18.0.0/15` (mihomo's fake-ip pool): <https://www.rfc-editor.org/rfc/rfc2544>
- Repo background notes (Traditional Chinese): [`docs/clash/README.md`](../docs/clash/README.md), especially [`Core.md`](../docs/clash/Core.md), [`BestPractice.md`](../docs/clash/BestPractice.md) and [`API.md`](../docs/clash/API.md)
