# pitfalls/

Symptom-indexed knowledge base of non-obvious traps hit while operating this
V2Ray server — and the mihomo / Clash clients that reach it. **Title each file by
the observable symptom, not the root cause** — so future-you greps for the error
string they actually see. Paste verbatim error messages; don't paraphrase. Keep
secrets out (use `${DOMAIN}` / `<uuid>` placeholders — these files are not covered
by `scripts/redact_secrets.py`).

| File | Symptom |
|---|---|
| [`long-connections-drop-at-60s-other-side-closed.md`](long-connections-drop-at-60s-other-side-closed.md) | Long-lived proxied requests die at ~60s with `other side closed` / HTTP 500 |
| [`browser-cannot-load-google-match-final-bare-ip.md`](browser-cannot-load-google-match-final-bare-ip.md) | Browser intermittently can't load a site under mihomo TUN; log shows `match Match using Final` against a bare IP |
