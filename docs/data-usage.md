# SSH data usage

In **Usage > Data**, choose a rolling interval from one minute to 30 days, select a chart bucket, or filter by forwarding path. Token estimates are documented in the [user guide](usage.md#usage-and-budgets).

## What is counted

All four forwarding modes are metered. Sent/received directions are relative to the machine running ModelMoor, even for remote forwards. Counts measure completed relay writes, including SOCKS negotiation, but exclude encrypted SSH overhead, keepalives, and TCP/IP headers. Partial failed writes may be undercounted.

Samples are taken every five seconds, with a final flush on clean stop or reconnect. Hard termination can lose unsampled data; historical traffic cannot be reconstructed. Collection runs with GUI, CLI, or TUI runtimes.

Remote SOCKS supports TCP CONNECT via SOCKS4, SOCKS4a, and unauthenticated SOCKS5. It enforces effective SSH `PermitRemoteOpen` restrictions and fails setup if they cannot be read. Relays preserve TCP half-closure and backpressure; OpenSSH retains authentication and encryption duties.

## History

`data-usage.jsonl` sits beside the profile's token history with owner-only permissions. It retains 31 days and compacts hourly. Records contain timestamps, tunnel/mapping UUIDs, and byte counts, without payloads, destinations, or credentials.

Renaming or editing a mapping preserves its history; a new UUID starts new history. Deleted mappings display their UUID prefix. Current names and addresses come from configuration.

## Storage failures

A torn final record is discarded on reopening; malformed complete records produce a visible error. Failed writes remain in memory and retry on the next sample or query without stopping SSH. Pending data is lost if the app exits while storage remains unavailable.
