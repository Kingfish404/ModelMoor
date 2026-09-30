# SSH data usage

The macOS Usage panel has Models and Data sections. Data provides rolling
1-minute, 1-hour, 24-hour, 7-day and 30-day views, a sent/received chart,
a forwarding-path filter and a per-path breakdown. Selecting a chart time
shows the corresponding bucket's byte counts. Selecting a breakdown row filters
to that path.

All four forwarding modes are metered: local TCP, remote TCP, local SOCKS and
remote SOCKS. Sent and received are relative to the machine running ModelMoor,
including for remote forwards. A loopback TCP relay counts completed writes;
the figures describe forwarded application data, including SOCKS negotiation,
not encrypted SSH wire traffic, keepalives or TCP/IP headers. In particular,
a failed write may have transmitted a partial buffer that is not counted.
The relay preserves TCP half-closure and limits reads to apply backpressure.
Remote SOCKS supports TCP CONNECT using SOCKS4, SOCKS4a and unauthenticated
SOCKS5, including IPv4, IPv6 and domain destinations for SOCKS5. Remote SOCKS
also enforces the effective SSH `PermitRemoteOpen` restrictions; setup fails
if those restrictions cannot be read.

The session samples active paths every five seconds and flushes a final sample
when a tunnel stops or reconnects. Each sample is attributed to its sampling
time; bucket boundaries therefore have five-second sampling precision. A hard
process termination can lose the current unsampled interval. Previously
transferred traffic cannot be reconstructed.

History lives in `data-usage.jsonl` beside the profile's token history, with
owner-only permissions. Records contain a timestamp, the tunnel and mapping
UUIDs, and sent/received byte counts. No payloads, destinations or credentials
are recorded. Path identity follows the mapping UUID: renaming or editing a
mapping retains its history; creating a new mapping starts a separate history.
Deleted mappings remain listed with their UUID prefix. The UI resolves existing
path names and addresses from the current configuration.

The store retains 31 days to cover rolling 30-day queries and compacts hourly.
Both directions are appended in one record and synchronized together. A torn
final record is discarded on reopening; malformed complete records produce a
visible history error. Failed writes remain pending in memory and retry on the
next sample or report query, without stopping the SSH connection. Pending data
cannot survive application exit while storage remains unavailable.

Collection belongs to ModelMoorSession and therefore also runs when the SSH
runtime is hosted by the CLI or TUI. OpenSSH continues to own authentication,
SSH configuration and encrypted transport. The intermediate local ports are
allocated dynamically; the user-facing forwarding ports remain configured as
before. SSH setup failures close all intermediate listeners before retrying.
