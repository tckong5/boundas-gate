# Secure Access: local DNS failure with an active embedded Gate

## Confirmed incident, 2026-10-08

The embedded Tailscale device was signed in, its Funnel route was running, and
the local Gate health endpoint returned 200. The Mac still could not resolve
the Gate's public hostname.

Comparison established:

| Probe | External Tailscale active | External Tailscale paused |
| --- | --- | --- |
| Mac system DNS | Host not found | Public relay addresses returned |
| External Tailscale DNS (`100.100.100.100`) | NXDOMAIN | No longer used by the Mac |
| Google / Cloudflare public DNS | Valid public records | Valid public records |
| Surfshark DNS | Valid public records | Valid public records |
| Public HTTPS with normal certificate verification | Worked through a public resolved address | Both relay addresses and normal system resolution returned matching Gate health, 200 |

Surfshark remained connected throughout the comparison. No account sign-out,
OAuth reset, Folder change, or Gate identity change was needed.

This establishes interference from the external Tailscale DNS path for this
incident. It does not establish that every historical timeout has this cause.
One initial TLS probe also timed out; subsequent probes to both relay addresses
succeeded. The initial TLS timeout alone cannot identify a relay or VPN fault.

## Why the UI kept checking

The reconnect policy treated failed public health checks as a reason to rebuild
an otherwise running Tunnel. A local DNS failure therefore triggered repeated
route rebuilds and visible checking states, although rebuilding the route could
not fix the Mac's resolver.

When local service and local MCP checks pass, the endpoint addresses match, and
the Tunnel is running, a public DNS failure now:

- Leaves the running route intact and continues normal status observations.
- Explains the Mac DNS problem in Secure Access and offers rechecking.
- Keeps generic/manual Gate repair as a recheck rather than rebuilding a
  healthy route. The Secure Access Repair button now offers a separate,
  explicitly confirmed system DNS cache refresh.
- Records redacted per-layer diagnostic transitions as `connection-check` in
  the current profile's `diagnostics/gateway-command.log`.

Genuine stopped routes, local failures, and endpoint mismatches retain their
existing repair handling. DNS failure never counts as a passed public check.

## Next occurrence

For a confirmed Local/MCP/endpoint match with a running route and a DNS lookup
failure, Main and Side Gates offer Repair in Secure Access. The user confirms
Refresh Network Cache, then macOS authorizes the fixed cache-refresh command
using its own administrator dialog. The App does not collect or store a
password. No caller-provided URL, path or command enters the privileged script.
Successful command completion triggers the normal HTTPS/MCP check; it does not
itself make Secure Access complete. Cancel/failure and overlapping Gate repairs
are handled without signing out or restarting any Gate. Background polling
never invokes this privileged action, and no third-party DNS fallback is added.

### Side Gate follow-up, 2026-10-08

After the Sign In retry fix, the Side Gate helper reported Running and its
Funnel listener was active. Google and Cloudflare DNS, queried with the user's
explicit permission, returned the same two public IPv4 relay addresses. Direct
queries to both DNS servers already configured by the Mac's VPN also returned
valid A records. Nevertheless, fresh system `getaddrinfo` calls failed with
ENOTFOUND, while `dscacheutil` initially showed only IPv6 records. The current
failure is therefore in the Mac system resolver/cache path; it is not evidence
that the VPN's upstream DNS lacks the record or that the account hit a quota.

HTTPS probes using those verified relay addresses retained normal certificate
and hostname verification. After initial timeout/reset responses, both relays
returned health 200 with the correct Side Gate identity; MCP returned 401
without credentials, as expected. These probes establish a working public
endpoint, but do not count as a pass for the App's normal system-resolver check.

Do not mark Secure Access ready from listener state alone, substitute hardcoded
relay addresses, silently switch DNS providers, or persist a third-party DNS
fallback based on permission for a one-off diagnostic query. Clearing Mac DNS
cache is a separate user-approved troubleshooting action; keep VPN settings,
Gate identity, Folder permissions and MCP authorizations intact.

The user subsequently flushed the system cache and sent HUP to mDNSResponder
with administrator privileges. Fresh system resolution then returned both IPv4
relay addresses. Normal HTTPS health/MCP checks passed without a DNS override,
and the running App automatically showed Secure Access complete (Tailscale ·
Connected) and advanced to the AI app selection step. No VPN setting, account,
Gate identity or authorization was changed. This confirms the stale system DNS
cache as the blocker in this occurrence; it does not establish why the initial
negative result was produced.

Compare system resolution with public DNS and verify Gate health over HTTPS.
Do not sign out or re-pair merely because this Mac cannot resolve the address.
If using the embedded Gate exclusively, the external Tailscale VPN need not
remain connected. Pausing it may affect other services that use that device;
confirm the intended scope before changing the connection.

Reference: [Tailscale with other VPNs](https://tailscale.com/docs/reference/faq/other-vpns),
[DNS in Tailscale](https://tailscale.com/docs/reference/dns-in-tailscale).
