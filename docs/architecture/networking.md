# Networking

Design for the transport, discovery, and reconnection layers.

**Implemented in M1:** mutual TLS 1.3 with pinned keys, framing over TCP, the session
handshake, and mDNS advertisement + browsing. **Not implemented:** automatic reconnection
wiring (M4) and file chunks (M5). Reconnect *policy* and the connection *state machine* exist
and are unit-tested, but nothing drives them against a live peer yet.

## Transport

| Concern | macOS | Android |
| --- | --- | --- |
| Stack | `Network.framework` (`NWListener`, `NWConnection`) | `java.net` + `javax.net.ssl` (`SSLServerSocket`, `SSLSocket`) |
| TLS | `sec_protocol_options_set_min_tls_protocol_version(.TLSv13)` | `SSLContext.getInstance("TLSv1.3")` + `enabledProtocols` |
| Trust | Custom verification block against pinned SPKI fingerprints | Custom `X509TrustManager` against pinned SPKI fingerprints |
| Port | 4 7823, or ephemeral + advertised via mDNS | Same |

One TCP connection carries the whole session. Control messages are JSON envelopes in
length-prefixed frames; file chunks later use a second frame kind on the same connection
(see the [protocol specification](../../protocol/specification/klyndro-protocol-v1.md)).

### Why TCP + TLS rather than UDP/QUIC/WebSocket

- Clipboard text and notification payloads are small, ordered, and must not be dropped.
  TCP gives ordering and retransmission for free.
- TLS 1.3 is available from both platform SDKs, is mutually authenticatable, and requires
  no cryptography of our own. QUIC has no equivalent first-party server API on either
  platform; WebSocket adds a handshake and framing we would then have to bound ourselves.
- A single connection means one trust decision, one heartbeat, one backoff timer.

## Discovery (mDNS)

| Concern | macOS | Android |
| --- | --- | --- |
| API | `NWBrowser` with `NWBrowser.Descriptor.bonjour(type: "_klyndro._tcp", domain: nil)` | `NsdManager` with `_klyndro._tcp.` |
| Permission | Local network prompt (`NSLocalNetworkUsageDescription`) | No runtime permission; needs `CHANGE_WIFI_MULTICAST_STATE` for receiving multicast |
| Multicast lock | n/a | `WifiManager.MulticastLock` held while browsing |

A discovery result is a *hint*, never a trust decision: the TXT record supplies device ID,
display name, protocol version, capability list, and the certificate fingerprint, but
identity is only established by the TLS handshake and the pinned fingerprint from pairing.

Both implementations must survive:

- duplicate advertisements from the same device;
- the same device appearing on a new address (DHCP, Wi-Fi roaming);
- stale records after sleep or airplane mode;
- devices that vanish without sending a goodbye packet.

Manual IP entry is a first-class fallback for networks that block multicast (guest Wi-Fi,
some corporate APs, client isolation). The paired-device record stores the last known
address and port.

## Connection establishment

1. Resolve the peer from discovery or a stored address.
2. Open TCP; enforce a 10 s connect timeout.
3. TLS 1.3 handshake, mutual authentication, certificate fingerprint must match the pinned
   value for the expected device ID. Mismatch → close with `auth.denied` and surface
   "device identity changed" rather than silently retrying.
4. Send `hello` with a random 16-byte nonce; expect `hello.ack` echoing it within 5 s.
5. Capability intersection is computed and reported to the UI.
6. Start the heartbeat.

## Identity, pinning, and what "authenticated" means

Two details from implementation that are easy to get wrong:

1. **Trust is a pinned public key, not a chain.** Both sides present a self-signed P-256
   certificate. `SecTrustEvaluate` is deliberately not consulted on macOS, and the Android
   `X509ExtendedTrustManager` ignores the system chain; both decide solely by comparing the
   presented certificate's SPKI fingerprint against the trust store. See ADR 0008.
2. **The fingerprint is SHA-256 over the DER `SubjectPublicKeyInfo`** (91 bytes for P-256), not
   over the bare EC point and not over the whole certificate. Network.framework reports exactly
   this representation via `sec_protocol_metadata_copy_peer_public_key`, and JSSE exposes the
   same DER through `PublicKey.getEncoded()`. Using the bare point would make the two platforms
   disagree — which the first version of the code did until a loopback test caught it.

"Authenticated" is therefore defined as: TLS completed **and** `hello`/`hello.ack` validated
**and** the peer's claimed identity matches the key TLS observed. TCP/TLS readiness alone is not
sufficient: with TLS 1.3 the client can reach `.ready` before the server has judged its
certificate.

## Heartbeat and failure detection

- `ping` every 15 s, `pong` expected; 45 s of silence marks the peer dead.
- TCP keepalive is not relied upon: the interval is not controllable enough on either
  platform to detect a dead peer quickly.
- A missed heartbeat transitions to `reconnecting` and does not increment the backoff
  counter beyond the failure escalation rule described in
  [architecture overview](overview.md).

## Reconnection and network changes

- Backoff: 1 s, 2 s, 4 s, 8 s, 16 s, 30 s cap, ±20 % jitter.
- **macOS**: `NWPathMonitor` restarts discovery immediately when the path becomes
  satisfied; a path loss cancels timers and marks the device `reconnecting`.
- **Android**: `ConnectivityManager.NetworkCallback` for `onAvailable`/`onLost` with
  `registerDefaultNetworkCallback`. Discovery restarts on `onAvailable`, which also covers
  most Wi-Fi ↔ cellular handovers.
- Sleep/wake: on macOS the app observes `NSWorkspace.didWakeNotification`; on Android, a
  process that was killed simply restarts its service and reconnects (M4).
- Never reconnect in a tight loop. Every attempt goes through the state machine, so an
  invalid transition is a bug rather than a spin.

## Resource and privacy posture

- No polling of discovery: browse while disconnected, stop while connected (mDNS traffic is
  otherwise constant).
- No outbound connection to anything except a paired device's address.
- No telemetry. The only network identifiers logged are device IDs and fingerprints
  (public), never payloads.
- Listener binds only while needed on macOS; Android only connects outbound, so it exposes
  no port to the LAN. This asymmetry is deliberate: it keeps the attack surface on the
  device that is usually on a trusted network.

## Open questions carried forward

- Android 14+ requires a foreground service *type* for a long-lived connection
  (`connectedDevice`). Confirm the notification UX is acceptable in M4.
- Local network privacy prompts: the advertisement was observed working on the development
  machine without an interactive prompt. Whether a *denied* prompt is recoverable via System
  Settings is still unverified.
- Wireless reconnection after sleep/wake has no test yet; there is no peer to reconnect to.
