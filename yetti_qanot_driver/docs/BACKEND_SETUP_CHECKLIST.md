# Backend readiness checklist for the YettiQanot **driver** app

Prompt for the backend team/agent. Go through every item: **verify it is implemented and
configured; if it is not, implement/set it.** This is exactly what the driver Flutter app
sends and expects — matching it makes the app work end to end. Do not remove endpoints the
app already relies on. Reply with the status of each item and what you changed.

Base URL the app targets: `https://taxi-2r2j.onrender.com` (override in the app via
`--dart-define=API_BASE_URL=`).

---

## 0. Service health / ops (currently failing — fix first)

- [ ] The service returns **`200` on `GET /health`** in <1 s, consistently. It is currently
      returning **502 Bad Gateway** (origin down / crash-loop / suspended). Get the process
      healthy: check Render logs for panic/OOM/port-bind errors; ensure it listens on
      `0.0.0.0:$PORT` (Render injects `$PORT`).
- [ ] **Always-on instance** — the driver app must be reachable for a whole shift. Free-tier
      spin-down + cold starts cause repeated outages (30–60 s stalls, 502s). Move off free
      tier or add a keep-warm.
- [ ] Host **region close to Uzbekistan** (e.g. Frankfurt) — cuts ~40% off every request.
- [ ] **CORS** (the app also runs on Flutter web): allow the app origin, methods
      `GET, POST, OPTIONS`, and headers `Authorization, Content-Type, X-Driver-Id,
      X-Driver-Session, X-Telegram-Init-Data`. Return them on the preflight `OPTIONS`.
- [ ] **Never log query strings** — the WS bearer travels as `?access_token=`.

## 1. Auth — login (OTP)

- [ ] `POST /auth/request-code` body `{ "phone": "+998XXXXXXXXX" }` → **200** and an SMS is
      sent. Validate the number is a real Uzbek mobile (`+998` + 9 digits). Errors with
      stable codes: **`INVALID_PHONE`** (400), **`DRIVER_NOT_REGISTERED`** (403/404) for a
      number with no approved driver.
- [ ] `POST /auth/verify-code` body `{ "phone", "code" }` → **200** with:
      `{ "access_token": "...", "expires_in": <seconds>, "token_type": "Bearer",
      "driver_id": "..." }`. Wrong code → **`INVALID_CODE`**.
- [ ] The **5-attempt lockout is enforced atomically** (concurrent/rapid retries cannot slip
      past it).
- [ ] **Single-session**: issuing a new token on verify-code **revokes** the previous
      device's token.

## 2. Auth — how the app presents the token (accept ALL of these)

The app sends the driver bearer token as:
- **HTTP:** header **`X-Driver-Session: <access_token>`** (plus `X-Driver-Id: <driver_id>`).
- **WebSocket:** query **`?access_token=<access_token>`** on the upgrade URL (all platforms),
  and on native also `Authorization: Bearer <token>` + `X-Driver-Id` upgrade headers.

- [ ] Every driver route accepts the token via **`X-Driver-Session`** (HTTP) — this is what
      the app sends and must keep returning 200. Also accept standard
      **`Authorization: Bearer <token>`**.
- [ ] Every WebSocket route accepts the token via **`?access_token=`** (and `Authorization`
      where present).
- [ ] `X-Driver-Id` / `?driver_id=` must **never be the sole credential** (it's fine as a
      harmless hint). A request with only a driver id and no valid token → **401**.
- [ ] An invalid/expired/revoked token → **401** on HTTP and a **401 rejected upgrade** on WS
      (the app treats 401 as "session dead → log out").

## 3. WebSockets

- [ ] `GET /ws/driver-dispatch?access_token=<token>` → upgrades (101), immediately sends
      `{"type":"hello"}`, then `{"type":"dispatch_changed","emitted_at":"<RFC3339>"}` when the
      dispatch queue changes. Without a valid token → **401** (no infinite tokenless loop).
      *(Production logs currently show `path=/ws/driver-dispatch status=401` — that stops once
      the app sends the token, which it now does.)*
- [ ] `GET /ws?trip_id=<uuid>&access_token=<token>` → streams trip events:
      `driver_location_update`, `trip_arrived`, `trip_started`, `trip_finished`,
      `trip_cancelled`. Each event carries a **per-trip monotonic `seq`** and `emitted_at`.
- [ ] On session revocation, the trip socket may send `{"type":"session_revoked"}` (or code
      `SESSION_REPLACED` / `SESSION_INVALIDATED` / `LOGIN_ELSEWHERE`) so the device logs out.

## 4. Dispatch & trip HTTP

- [ ] `GET /driver/available-requests` → queue rows + `assigned_trip: {trip_id, status}`.
      **Must include** `commission_percent` (int) and `commission_charged` (bool) — see §5.
      Supports **`?wait_sec=25`** long-poll (holds until the queue changes or the timeout;
      waking every waiter). Ideally supports `ETag`/`If-None-Match` → `304`.
- [ ] **Balance fields** on the same response, in soʻm, stable names:
      `total_balance`, `promo_balance`, `cash_balance`.
- [ ] `POST /driver/online` → clears `manual_offline`; **200** `{"ok":true,
      "manual_offline":false}`. (Location pings must NOT clear it — going online is explicit.)
- [ ] `POST /driver/offline` → **200**.
- [ ] `POST /driver/location` and `POST /driver/location/app` → accept `{lat,lng,accuracy?,
      timestamp?}` (`timestamp` = Unix seconds).
- [ ] `POST /driver/accept-request` `{request_id}` → **200** returning the trip **with pickup/
      dropoff coordinates** (`{assigned:true, trip:{id,status,pickup_lat,...,rider_phone}}`).
      Distinct 409s: **`driver_has_active_trip`** `{active_trip_id}` (driver already on a trip)
      vs **`REQUEST_TAKEN`/`REQUEST_UNAVAILABLE`** (someone else took it).
- [ ] `POST /trip/arrived`, `POST /trip/start` `{trip_id, lat?, lng?, accuracy?, timestamp?}`;
      `POST /trip/finish` `{trip_id}`; `POST /trip/cancel/driver` `{trip_id}`.
      **Return the updated trip** `{trip_id, status, fare_som, distance_km}` so the app needs
      no extra fetch. **Read-after-write:** immediately after `finish`/`cancel`, the next
      `available-requests` must **not** still list that trip as `assigned_trip` (it currently
      lingers and the app has to suppress it).
- [ ] `GET /trip/:id` → returns the trip; **includes `rider_phone` only when authenticated**
      (the driver screen shows it to call the rider). Anonymous callers get no phone.
- [ ] `GET /driver/trips?limit&offset` → history rows incl. `fare_som`, `commission_som`,
      timestamps, status. `GET /driver/promo-program`, `GET /driver/referral-status`,
      `GET /driver/referral-link`.
- [ ] `GET /legal/active`, `POST /legal/accept`. A gated route may return **403
      `LEGAL_ACCEPTANCE_REQUIRED`**.

## 5. Commission (admin-editable, must reach the app live)

- [ ] `commission_percent` (integer, e.g. `5`) and `commission_charged` (bool) are returned
      on **`GET /driver/available-requests`** (so a change reflects on the next poll). When an
      admin changes the rate or turns commission off, these values change. `commission_charged:
      false` or `commission_percent: 0` = "no commission". The app renders these directly.

## 6. Approval / registration states

- [ ] Registration is Telegram-bot only — the app routes unregistered numbers there via
      **`DRIVER_NOT_REGISTERED`**. Keep that code.
- [ ] A registered-but-**not-approved** driver → **403** with a code/message containing
      `not_approved` / `approval` (the app treats this as "awaiting approval", NOT a dead
      session). Do not 401 a valid-but-pending token.

## 7. Stable error `code` on every 4xx (no reliance on message text)

Return a machine `code` (plus a localized `message`) for at least:
`INVALID_PHONE`, `INVALID_CODE`, `DRIVER_NOT_REGISTERED`, `DRIVER_NOT_APPROVED`,
`driver_has_active_trip` (+ `active_trip_id`), `REQUEST_TAKEN`/`REQUEST_UNAVAILABLE`,
`NOT_FOUND`, `LEGAL_ACCEPTANCE_REQUIRED`, `DRIVER_LOCATION_STALE`,
`LIVE_LOCATION_INACTIVE`, `PICKUP_TOO_FAR` (if proximity is enforced), and the
session-revocation codes (`SESSION_REPLACED` / `SESSION_INVALIDATED` / `LOGIN_ELSEWHERE` /
`AUTH_SESSION_EXPIRED`).

## Verify at the end

```
curl -s -o /dev/null -w "%{http_code}\n" https://taxi-2r2j.onrender.com/health          # 200, <1s
# with a valid driver token in $T:
curl -s -H "X-Driver-Session: $T" https://taxi-2r2j.onrender.com/driver/available-requests \
  | grep -o 'commission_percent'                                                         # present
# WS upgrade without token → 401; with ?access_token=$T → 101 + {"type":"hello"}
```
- Log in on a 2nd device → the 1st device's next call returns 401.
- Change the commission in admin → the app's row updates within one poll.
