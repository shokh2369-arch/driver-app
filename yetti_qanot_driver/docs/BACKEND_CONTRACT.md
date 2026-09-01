# YettiQanot driver app ↔ Go API

This Flutter client follows the **Go backend** repo. **Parity checklist:** **`docs/DRIVER_HTTP_API_HANDOFF.md`**. Contract detail: **`docs/DRIVER_CLIENT.md`**, **`docs/AUTH.md`** (driver headers, `POST /driver/location/app` including optional **`timestamp` as Unix seconds**, not ISO-8601), and root **`README.md`**. WebSocket **`ws.Event`** uses **`emitted_at`** as RFC3339 on the server → client envelope; that is separate from the HTTP body’s integer `timestamp`.

## Phone login (unauthenticated)

- **`POST /auth/request-code`** — `{ "phone": "..." }`; **404** if not a registered driver.
- **`POST /auth/verify-code`** — `{ "phone": "...", "code": "..." }`; success body includes **`driver_id`** (or app also accepts `user_id` / `id`). **No** `X-Driver-Id` on these routes — `lib/services/auth_api_client.dart` / `authRepositoryProvider`.

## `dart-define` (build / run)

| Define | Purpose |
|--------|---------|
| `API_BASE_URL` | HTTPS API origin, no trailing slash. **Default in code:** `https://taxi-uksz.onrender.com`. Override with `dart-define` for staging/mock. |
| `DRIVER_ID` | Sent as **`X-Driver-Id`** (native/debug; matches backend default header auth). |
| `TELEGRAM_INIT_DATA` | Sent as **`X-Telegram-Init-Data`**; also appended as **`init_data`** on **`/ws`** when using Telegram WebApp. |
| `WS_URL` | Optional full WebSocket URL override; if unset, **`wss://<host>/ws`** is derived from `API_BASE_URL`. |

The native app posts to **`POST /driver/location/app`** for backend-managed app freshness (`app_last_seen_at`). Backend effective location falls back to Telegram `last_lat/last_lng` when app location is missing/stale.

## Implemented client behavior

- **`GET /driver/available-requests`** — merges queue aliases; shows first offer; applies **`assigned_trip`** when present; hydrates **`GET /trip/:id`** for coordinates when possible.
- **`GET /ws/driver-dispatch`** — driver dispatch “poke” WebSocket. On connect: `{"type":"hello"}`. When offers may have changed: `{"type":"dispatch_changed","emitted_at":"RFC3339 UTC"}`. The app treats this as a **refetch signal** and immediately calls **`GET /driver/available-requests`** (no rider payload in the WS event). **Native (IO)** builds send the same driver auth as HTTP on the WebSocket **upgrade** headers: **`X-Driver-Id`** and, when present, **`X-Driver-Session`** (SMS login); query still includes `driver_id` / `init_data` per `wsUriForTrip` rules. Disable with `--dart-define=ENABLE_DRIVER_DISPATCH_POKE_WS=false`.
- **`GET /driver/trips`** — read-only trip history for **Safarlar tarixi** (wired like **`GET /driver/available-requests`**: **`tryDriverID`**, then **`driverAuth`** per **`docs/AUTH.md`** — **`X-Driver-Id`** / Telegram init data). **401** `{"error":"driver auth required"}` when not authenticated as a driver (same style as available-requests). **200** body **`{ "trips": [ … ] }`**. Query: **`limit`** default **50**, max **100**; **`offset`** default **0**, must be **≥ 0**. Rows are terminal states only (**`FINISHED`**, **`CANCELLED`**, **`CANCELLED_BY_DRIVER`**, **`CANCELLED_BY_RIDER`**); ordered newest-first on the server. Each trip object includes **`trip_id`**, **`id`**, **`uuid`** (same UUID string), **`status`** (DB string), optional RFC3339 UTC **`started_at`** / **`finished_at`** / **`cancelled_at`** when set, integer **`fare_som`** / **`price`** / **`total_som`** (same value as **`fare_amount`**), and **`commission_som`** only when **> 0** (from commission **`payments`** when supported; legacy DBs omit commission). Client parser accepts this shape and optional **`DRIVER_TRIP_HISTORY_HTTP_PATH`** override for the path only.
- **`POST /driver/accept-request`** — sends **`request_id`**; reads **`trip_id`** / nested **`trip`**; connects **`GET /ws?trip_id=…`** (+ `init_data` if set).
- **`POST /driver/location/app`** — **`lat`**, **`lng`**, optional **`accuracy`**, optional **`timestamp`** (Unix seconds, GPS fix). Send **`timestamp` when available**; server freshness fields use server UTC. While **ONLINE** when `API_BASE_URL` is set: ~**30s** / ~**60s** (foreground / background) plus **~40 m** movement (min **15 s** between posts). **Debug:** failed posts log HTTP status / error `code` only (no secrets).
- **`POST /driver/offline`** — Optional body **`{}`**; same auth. On user **OFFLINE** toggle, client **awaits** success before local OFFLINE (so server clears live/active flags). **Debug:** failures log status / `code` only.
- **`POST /trip/arrived|start`** — JSON **`{ "trip_id": "…" }`**. **`POST /trip/cancel/driver`** for driver cancel. This Flutter client **does not** call **`POST /trip/finish`** (completion is server-side).
- **WebSocket** — handles `type`, `trip_status`, `payload` for `trip_arrived`, `trip_started`, `trip_finished`, `trip_cancelled`, `driver_location_update`; `emitted_at` present per `ws.Event` (RFC3339). Outgoing `driver_location` frames use integer `timestamp` (Unix seconds) to align with HTTP location.
