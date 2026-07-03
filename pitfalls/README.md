# pitfalls/

Symptom-indexed knowledge base of non-obvious traps hit while operating this
V2Ray server. **Title each file by the observable symptom, not the root cause** —
so future-you greps for the error string they actually see. Paste verbatim error
messages; don't paraphrase. Keep secrets out (use `${DOMAIN}` / `<uuid>`
placeholders — these files are not covered by `scripts/redact_secrets.py`).

| File | Symptom |
|---|---|
| [`long-connections-drop-at-60s-other-side-closed.md`](long-connections-drop-at-60s-other-side-closed.md) | Long-lived proxied requests die at ~60s with `other side closed` / HTTP 500 |
