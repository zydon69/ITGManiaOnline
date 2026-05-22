# ITG Online client setup

Simply Love's online lobby screen is wired to the ITG Online Laravel server.

## Local account configuration

The login screen creates and updates `Save/ITGOnline.ini`. You can also edit it manually:

```ini
[ITGOnline]
ApiBaseUrl=https://itgonline.fr/api/v1
WebSocketUrl=wss://ws.itgonline.fr
Email=player@example.com
DeviceName=itgmania-client
```

The file is local to the machine. Do not commit it. The password is entered through the login screen and kept in memory for the current session only.

Until production mail is enabled on the server, accounts must be created and verified from the server side before the game can log in.

## Network allow-list

The engine default `HttpAllowHosts` now permits:

- `itgonline.fr`
- `*.itgonline.fr`
- the existing GrooveStats/ITGmania hosts

For a self-hosted server, update `HttpAllowHosts`, `ApiBaseUrl`, and `WebSocketUrl` to match the deployed domain. `HttpAllowHosts` is an immutable preference, so distribution builds should set it through their own `Data/Static.ini` or source default.

## TLS public-key pinning

The distributed client pins the SPKI SHA-256 public key for `itgonline.fr` and `*.itgonline.fr` in `src/NetworkManager.cpp`. Before rotating the production certificate key pair, update both pins with:

```bash
openssl s_client -servername itgonline.fr -connect itgonline.fr:443 </dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform DER 2>/dev/null \
  | openssl dgst -sha256
```

Certificate renewals that keep the same public key do not require a client update. Key rotations do.

## Current flow

- The normal play flow now adds a Local / Online choice after Standard / Marathon.
- Local continues to the usual offline profile/song flow.
- Online opens the ITG Online login screen, then sends the player to Online Lobbies.
- The login screen logs in with `/api/v1/auth/login`.
- It requests a WebSocket ticket from `/api/v1/websocket/tickets`.
- It connects to the WebSocket using the `Sec-WebSocket-Protocol: itgmania-ticket.<ticket>` handshake.
- Lobby creation maps to a public server room.
- Joining a public room creates a join request; the room manager client auto-accepts pending requests while connected.
- On reconnect, the client fetches the current room/lobby state from HTTP instead of relying on missed realtime events.

Password-protected lobbies are not implemented on the server and are intentionally hidden in the game UI.
Two local players with two distinct ITG Online accounts are not wired yet; the first in-game login pass connects one account for the cabinet/session.
