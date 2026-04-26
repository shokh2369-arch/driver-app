# YettiQanot native driver app (Flutter)

This client mirrors the **Telegram driver bot + driver HTTP API** documented in the **Go backend** repo. **Start here for parity:** `docs/DRIVER_HTTP_API_HANDOFF.md` (checklist: routes, WS, CORS, flags, verification). Detail: `docs/DRIVER_CLIENT.md`, `docs/AUTH.md`, root `README.md`. This app does not invent parallel protocols.

## Base URL & build flags

| `dart-define` | Role |
|---------------|------|
| `API_BASE_URL` | HTTPS origin, no trailing slash. Default: `https://taxi-2r2j.onrender.com`. |
| `DRIVER_ID` | Optional fixed `X-Driver-Id` (skips in-app ID setup). |
| `TELEGRAM_INIT_DATA` | Mini App / WebView: `X-Telegram-Init-Data`; also `init_data` on `/ws` when set. |
| `WS_URL` | Optional full WebSocket URL; otherwise `wss://<API host>/ws`. |
| `DRIVER_WALLET_HTTP_PATH` | Optional **documented** extra `GET` on the same API host when wallet fields are **not** in `available-requests`. Must start with `/`, no `..`. Do not invent paths the server does not register. |
| `OSRM_ROUTING_BASE_URL` | OSRM **routing** API origin (default public demo). Drives pickup→destination **road** polylines on the trip map; empty disables (straight segment only). |
| `ENABLE_DRIVER_HTTP_LIVE_LOCATION` | **Client default `true`** — must match the Go deployment. When **`true`** (or unset on server), native **`POST /driver/location/app`** should refresh `live_location_active` / `last_live_location_at` (~**90s** server guard). When **`false`** on server, trip pickup/start may require Telegram live share; set the same **`false`** here so in-app copy tells drivers to use Telegram (see *Server flags*). |

Native primary auth: **`X-Driver-Id`** = internal `users.id` or Telegram `telegram_id` (approved driver), per `docs/AUTH.md`.

## Maps: this Flutter app vs Telegram Mini App HTML

| | **This driver app (Flutter)** | **Mini App (`/webapp/` HTML)** |
|--|------------------------------|--------------------------------|
| **What `API_BASE_URL` is for** | **JSON HTTP + WebSocket only** (`Dio`, `GET /trip/:id`, `POST /driver/location/app`, `/ws?trip_id=…`). | Not used to “open the map page” in a browser. |
| **Where the map comes from** | In-app **flutter_map** + **HTTPS** OpenStreetMap tiles (`tile.openstreetmap.org`). | Static pages such as **`index.html`** (driver) or **`rider-map.html`** (rider), served under e.g. **`/webapp/`**, with **`trip_id`** / **`driver_id`** query params (or Telegram **`start_param`**). |
| **Wrong URL symptom** | N/A — you configure the API origin in `dart-define`. | Opening the **bare API host** often shows **`404 NOT_FOUND`** JSON (backend error body), not HTML. Use the **webapp URL** your bot sends. |
| **Unknown / missing trip** | **`GET /trip/:id`** **404** or JSON **`NOT_FOUND`** → in-app **`trip_plan_not_found`** (“Reja topilmadi”) banner / snackbar (same idea as the Mini App). | In-app copy: “Reja topilmadi” when the trip does not exist. |
| **401 on trip actions** | Ensure **`X-Telegram-Init-Data`** (Telegram) **or** server **`ENABLE_DRIVER_ID_HEADER=true`** + **`X-Driver-Id`**. See backend **`AUTH.md`** / **`BACKEND_FIX_401.md`**. | Same backend rules. |

## CORS (Flutter **web** only)

Ensure the API allows browser requests with headers the app sends:

- `Content-Type: application/json`
- `X-Driver-Id` and/or `X-Telegram-Init-Data`
- `Authorization` — only if your deployment adds JWT; the stock driver flow uses the headers above.

Mobile (iOS/Android) uses normal HTTP and is not limited by browser CORS.

## Screens → HTTP / WS

| Area | Endpoint / channel | When |
|------|-------------------|------|
| Connectivity (optional) | `GET /health` | Plain text (e.g. `OK`); not required for normal flow. |
| Phone login | `POST /auth/request-code` `{ phone }`, `POST /auth/verify-code` `{ phone, code }` | When **no** `DRIVER_ID` dart-define, **no** saved id, **no** `TELEGRAM_INIT_DATA`: **unauthenticated** Dio (no `X-Driver-Id`). **404** on request-code → “not registered as driver”. **INVALID_CODE** on verify → snackbar. On success, response must include **`driver_id`** (or `user_id` / `id`) — saved via [driverIdProvider] like manual ID. **3 min** code TTL UI; **resend** enabled after **30s**. |
| Manual driver id (legacy) | — | Removed from the native app flow. Use phone + SMS login (OTP) only. |
| Legal gate | `GET /legal/active`, `POST /legal/accept` | After any call returns **403** with `LEGAL_ACCEPTANCE_REQUIRED` (e.g. `POST /driver/location/app`). |
| ONLINE + GPS | `POST /driver/location/app` body `{ lat, lng, accuracy?, timestamp? }` — `timestamp` is **Unix seconds** (integer) from the GPS fix (`Position.timestamp`), not ISO-8601. Send **`timestamp` whenever available**; the server records freshness from **its** UTC time (`app_last_seen_at`), not from the client clock in the DB fields. Typical success: **HTTP 200** with `{"ok":true}`. **Debug:** success logs `[yetti_driver] POST /driver/location/app HTTP ok`. | Only while **ONLINE** (with **`X-Driver-Id`** / session): timer cadence stays **under the ~90s** backend stale window — **~22s** foreground / **~50s** background idle; **~16s** / **~40s** while an **assigned or in-flight** trip needs continuous live (`TripState.requiresContinuousLiveLocation`). Minimum gap between posts **~12s** (idle) or **~8s** (trip-heavy), movement **≥ ~40 m** triggers an extra post, plus an immediate post on the first fix after going ONLINE. **`POST /trip/arrived`** and **`POST /trip/start`** pre-flush a fresh coordinate. Stops when **OFFLINE** (after **`POST /driver/offline`** succeeds). |
| Dispatch poll | `GET /driver/available-requests` | While **ONLINE**; ~8s foreground, ~45s background. Promo-program / referral-status / referral-link run **about once per 60s** (staggered from dispatch) to limit traffic. Merges queue aliases; dedupes by `request_id`. Lifecycle-driven timer resets are **debounced** so web visibility events don’t cause poll bursts. |
| OFFLINE toggle | **`POST /driver/offline`** | **Required** when the user switches to **OFFLINE** (with HTTP API + driver auth): **`POST /driver/offline`** with optional body **`{}`**, same headers as other driver routes (**`X-Driver-Id`** / **`X-Telegram-Init-Data`**). Typical **200** `{"ok":true}`. Clears server online/live flags (Telegram “stop live” equivalent). The app **awaits** this call **before** flipping local OFFLINE; on failure the toggle stays **ONLINE** and a short error is shown (no secrets logged). Polling and HTTP location stop once OFFLINE succeeds. **Waiting** dispatch UI is cleared; **arrived** / **started** trips stay until finished. Going **ONLINE** again: **no** `/driver/offline` call; resume location cadence + `GET /driver/available-requests` as today. |
| Queue / assign | `GET /trip/:id` | Hydrate coords for `assigned_trip` or after accept. |
| Accept | `POST /driver/accept-request` `{ request_id }` (+ optional `trip_id`) | User accepts offer; **409** / **403** / **404** mapped to user-visible messages. |
| Trip actions | `POST /trip/arrived`, `/trip/start` each `{ trip_id }` | In-trip buttons; server message surfaced on failure. **No `POST /trip/finish`** in this client — trip completion is driven by the server (e.g. WS `trip_finished` / dispatch). |
| Driver cancel | `POST /trip/cancel/driver` `{ trip_id }` | Driver-initiated cancel (parity with bot). |
| Promo / referral UI | `GET /driver/promo-program`, `GET /driver/referral-status`, `GET /driver/referral-link` | Polled with dispatch; balance-shaped keys merged into wallet UI; referral link shown when returned. |
| Realtime | `WebSocket` `/ws?trip_id=...` — query `init_data` if Telegram Mini App is used, else `driver_id`; HTTP uses the same auth via headers. | Active trip; JSON frames: `type`, `trip_id`, `trip_status`, `emitted_at`, `payload`. Handled: `trip_arrived`, `trip_started`, `trip_finished`, `trip_cancelled`, `driver_location_update`; unknown `type` ignored. Outgoing driver location uses `snake_case` + `timestamp` (Unix seconds). |
| Balance UI | `GET /driver/available-requests` (+ optional documented `DRIVER_WALLET_HTTP_PATH`) + promo / referral JSON above | Dispatch may omit wallet fields — UI shows `—`. Parser looks for snake_case wallet keys on the root and under nested maps (`stats`, `wallet`, `assigned_trip`, …). |

### Time fields (do not mix these up)

- **`POST /driver/location/app`** — optional **`timestamp`**: **Unix seconds** as a JSON **integer** (`docs/AUTH.md`). Not ISO-8601. Same auth headers as other driver HTTP routes.
- **WebSocket `ws.Event` (server → client)** — envelope field **`emitted_at`** is **RFC3339** strings in the Go type; the client does not treat that as app-location `timestamp`.
- **Outgoing `driver_location` over WS (client → server)** — this app sends **`timestamp`** as **Unix seconds** (integer), matching the HTTP location rule unless `DRIVER_CLIENT.md` specifies a different shape for that message.

## Backward compatibility (backend effective location)

Backend read-side uses an **effective location**:

- If app location is active and **fresh (≤90s)** → uses `drivers.app_lat/app_lng`
- Else falls back to Telegram `drivers.last_lat/last_lng`

If the native app does not send `/driver/location/app` (or those fields are empty), backend behavior remains the same via Telegram fields.

## Server flags & deployment (Render / prod)

- **Go `ENABLE_DRIVER_HTTP_LIVE_LOCATION`**: When **`true`** or **unset**, HTTP **`/driver/location/app`** updates should count toward **`live_location_active`** / **`last_live_location_at`** (trip guards in `trip_service.go`, errors surfaced via `trip.go` as stale/inactive live). When **`false`**, the server may still require **Telegram live location** for pickup/start — align the Flutter **`dart-define=ENABLE_DRIVER_HTTP_LIVE_LOCATION=false`** so snackbars tell drivers to enable Telegram, not only “keep GPS on.”
- **Production checklist:** In the taxi service env on Render (or elsewhere), leave **`ENABLE_DRIVER_HTTP_LIVE_LOCATION` unset or `true`** unless you intentionally run Telegram-only drivers. Mismatch (server `false`, client default `true`) produces confusing localized errors about Telegram while the driver uses the native app.

## Android: permissions & background (manual QA)

- **While-in-use location** is required (`ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` in manifest — already present). Grant **“While using the app”** or **“Allow all the time”** per OEM.
- **Battery optimization:** On many devices, disable battery restrictions for **YettiQanot Driver** so timers are not deferred for minutes after the screen is off. True **background** tracking every ~40s with the screen off may still be limited without a **foreground service** (not implemented in this app); drivers should keep the app **foreground** or return to it periodically during active trips.
- **Auto-offline:** After ~8s in background the app used to call **`POST /driver/offline`**, which **clears** server live flags. That is now **skipped** while **`TripState.requiresContinuousLiveLocation`** (assigned / arrived / started trip) so brief switches to Maps/phone do not break the ~90s live pipeline.

### If the driver never gets offers (verification)

1. Run **`flutter analyze`** (clean client).
2. DevTools / logs: confirm **`POST /driver/location/app`** returns **2xx** (look for **`HTTP ok`** in debug). Failures log status/`code` without secrets.
3. Server: confirm **`ENABLE_DRIVER_HTTP_LIVE_LOCATION`** matches client `dart-define`, and that the driver meets approval / legal / balance / profile rules in **`docs/DRIVER_CLIENT.md`** (~90s live freshness). Use server **`DISPATCH_DEBUG`** only when investigating matching.

## Secrets & logging

Do not log `X-Telegram-Init-Data`, tokens, or full auth headers. Client avoids printing those in debug paths.

## Related (Go backend repository)

- **`docs/DRIVER_HTTP_API_HANDOFF.md`** — Single-file parity checklist for Flutter + backend (routes, WS, CORS, flags, dispatch eligibility, verification); linked from backend `README.md` and `docs/DRIVER_CLIENT.md` (*Related*).
- **`docs/DRIVER_CLIENT.md`**, **`docs/AUTH.md`** — Full HTTP/WS contract and auth.

## Code map

- `lib/services/driver_api_client.dart` — Dio, interceptors, legal 403 → gate.
- `lib/data/repositories/driver_repository.dart` — thin HTTP facade.
- `lib/features/driver/presentation/driver_location_sync_controller.dart` — ONLINE location POST + WS driver position during trip.
- `lib/features/trip/presentation/trip_controller.dart` — poll, accept, trip FSM, WebSocket.
- `lib/features/legal/presentation/legal_acceptance_screen.dart` — legal flow.
