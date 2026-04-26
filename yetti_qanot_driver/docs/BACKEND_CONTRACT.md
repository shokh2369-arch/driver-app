# YettiQanot driver app ↔ Go API

This Flutter client follows the **Go backend** repo. **Parity checklist:** **`docs/DRIVER_HTTP_API_HANDOFF.md`**. Contract detail: **`docs/DRIVER_CLIENT.md`**, **`docs/AUTH.md`** (driver headers, `POST /driver/location/app` including optional **`timestamp` as Unix seconds**, not ISO-8601), and root **`README.md`**. WebSocket **`ws.Event`** uses **`emitted_at`** as RFC3339 on the server → client envelope; that is separate from the HTTP body’s integer `timestamp`.

## Phone login (unauthenticated)

- **`POST /auth/request-code`** — `{ "phone": "..." }`; **404** if not a registered driver.
- **`POST /auth/verify-code`** — `{ "phone": "...", "code": "..." }`; success body includes **`driver_id`** (or app also accepts `user_id` / `id`). **No** `X-Driver-Id` on these routes — `lib/services/auth_api_client.dart` / `authRepositoryProvider`.

## `dart-define` (build / run)

| Define | Purpose |
|--------|---------|
| `API_BASE_URL` | HTTPS API origin, no trailing slash. **Default in code:** `https://taxi-2r2j.onrender.com`. Override with `dart-define` for staging/mock. |
| `DRIVER_ID` | Sent as **`X-Driver-Id`** (native/debug; matches backend default header auth). |
| `TELEGRAM_INIT_DATA` | Sent as **`X-Telegram-Init-Data`**; also appended as **`init_data`** on **`/ws`** when using Telegram WebApp. |
| `WS_URL` | Optional full WebSocket URL override; if unset, **`wss://<host>/ws`** is derived from `API_BASE_URL`. |

The native app posts to **`POST /driver/location/app`** for backend-managed app freshness (`app_last_seen_at`). Backend effective location falls back to Telegram `last_lat/last_lng` when app location is missing/stale.

## Implemented client behavior

- **`GET /driver/available-requests`** — merges queue aliases; shows first offer; applies **`assigned_trip`** when present; hydrates **`GET /trip/:id`** for coordinates when possible.
- **`POST /driver/accept-request`** — sends **`request_id`**; reads **`trip_id`** / nested **`trip`**; connects **`GET /ws?trip_id=…`** (+ `init_data` if set).
- **`POST /driver/location/app`** — **`lat`**, **`lng`**, optional **`accuracy`**, optional **`timestamp`** (Unix seconds, GPS fix). Send **`timestamp` when available**; server freshness fields use server UTC. While **ONLINE** when `API_BASE_URL` is set: ~**30s** / ~**60s** (foreground / background) plus **~40 m** movement (min **15 s** between posts). **Debug:** failed posts log HTTP status / error `code` only (no secrets).
- **`POST /driver/offline`** — Optional body **`{}`**; same auth. On user **OFFLINE** toggle, client **awaits** success before local OFFLINE (so server clears live/active flags). **Debug:** failures log status / `code` only.
- **`POST /trip/arrived|start`** — JSON **`{ "trip_id": "…" }`**. **`POST /trip/cancel/driver`** for driver cancel. This Flutter client **does not** call **`POST /trip/finish`** (completion is server-side).
- **WebSocket** — handles `type`, `trip_status`, `payload` for `trip_arrived`, `trip_started`, `trip_finished`, `trip_cancelled`, `driver_location_update`; `emitted_at` present per `ws.Event` (RFC3339). Outgoing `driver_location` frames use integer `timestamp` (Unix seconds) to align with HTTP location.
