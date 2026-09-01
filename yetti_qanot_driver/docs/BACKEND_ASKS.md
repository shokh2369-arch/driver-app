# Backend changes requested by the driver app

Audience: the Go backend team (or an agent working the Go repo). Written against the
live deploy `https://taxi-2r2j.onrender.com` and the Flutter client in this repo.

Every endpoint the client uses already exists on the deploy (probed: all return 401 when
unauthenticated, none 404). Nothing below is a missing route — these are **behavior,
response-shape, and ops** changes. Each item lists the symptom, the current behavior, the
exact ask, and how to verify it.

Auth context (unchanged, for reference): driver requests carry `X-Driver-Id`, optionally
`X-Driver-Session` (SMS-login session), optionally `X-Telegram-Init-Data`. HTTP body
timestamps are **Unix seconds**; WebSocket `emitted_at` is **RFC3339**.

---

## P0 — fixes the two problems drivers actually report

### 1. Trip-action endpoints must return the updated trip

**Symptom:** trip buttons feel slow (~1–2 s before anything happens).
**Now:** `POST /trip/arrived`, `/trip/start`, `/trip/finish` return little/nothing, so the
client makes a **second** call, `GET /trip/:id`, just to learn the new status and fare.
Two sequential round trips per tap.

**Ask:** each of these returns the full, updated trip in the 200 body:

```
POST /trip/arrived        { "trip_id": "<uuid>", "lat"?, "lng"?, "accuracy"?, "timestamp"? }
POST /trip/start          { "trip_id": "<uuid>", "lat"?, "lng"?, "accuracy"?, "timestamp"? }
POST /trip/finish         { "trip_id": "<uuid>" }
POST /trip/cancel/driver  { "trip_id": "<uuid>" }

200 →
{
  "trip_id": "<uuid>",
  "status": "ARRIVED" | "STARTED" | "FINISHED" | "CANCELLED",
  "pickup_lat": 41.31, "pickup_lng": 69.24,
  "dropoff_lat": 41.35, "dropoff_lng": 69.29,   // when known
  "fare_som": 24000,                            // integer soʻm, when known
  "distance_km": 7.4,                            // when known
  "rider_phone": "+998..."                       // when policy allows
}
```

**Result:** one call instead of two on every trip button; the fare popup becomes exact
instead of best-effort.
**Verify:** `POST /trip/finish` response alone contains the final `status` and `fare_som`;
no `GET /trip/:id` needed afterward.

### 2. Read-after-write consistency on `assigned_trip.status`

**Symptom:** a button changes, then reverts a few seconds later ("tap twice").
**Now:** after `POST /trip/arrived` returns 200, the dispatch poll
`GET /driver/available-requests` still reports the **previous** status
(`assigned_trip.status`) for several seconds — a read-after-write gap, most likely the
write and the poll hitting different replicas or a cached read. The client currently masks
this (holds the tapped status until the server catches up), but that is a workaround.

**Ask:** once a trip action returns 200, the **next** `GET /driver/available-requests`
(and `GET /trip/:id`) for that driver must reflect the new `status`. No stale window.

**Verify:** `POST /trip/arrived` → immediately `GET /driver/available-requests` →
`assigned_trip.status == "ARRIVED"` on the first read, every time.

> #1 and #2 together remove both the latency and the flip-flop at the source. If only one
> can be done, do #2 — it is the actual bug; #1 is the speedup.

### 3. `POST /driver/accept-request` returns the full trip (with coordinates)

**Symptom:** accepting an order is slow / occasionally shows "order no longer available"
on an order that was actually assigned.
**Now:** the client reads `trip_id` from the accept response, then calls `GET /trip/:id`
for coordinates. Extra round trip, and a second chance to race.

**Ask:** the accept 200 body always includes the trip object with pickup/dropoff coords:

```
POST /driver/accept-request { "request_id": "<id>" }
200 →
{ "assigned": true,
  "trip": { "id": "<uuid>", "status": "WAITING",
            "pickup_lat":…, "pickup_lng":…, "dropoff_lat":…, "dropoff_lng":…,
            "fare_som":…, "rider_phone":… } }
```

The client already prefers an inline `trip` when it carries coordinates and only falls back
to `GET /trip/:id` when they are missing — so guaranteeing coords here drops the fallback.
**Verify:** Accept → the trip renders on the map with no follow-up `GET /trip/:id`.

---

## P1 — removes fragility (latent bugs waiting to trigger)

### 4. Every 4xx must carry a stable machine `code` — never rely on message text

**Now:** the client detects "too far from pickup" and "live location inactive" by
**string-matching localized Uzbek/Russian sentences**. Rewording one backend message
silently breaks client behavior.

**Ask:** every 4xx returns a documented, stable `code` (in addition to a human `message`).
Minimum enum the client already keys on:

| Situation | `code` | HTTP |
|---|---|---|
| Not close enough to pickup | `PICKUP_TOO_FAR` | 4xx |
| Live location stale/inactive | `LIVE_LOCATION_INACTIVE`, `DRIVER_LOCATION_STALE` | 4xx |
| Offer already taken | `REQUEST_TAKEN` / `REQUEST_UNAVAILABLE` | 409 |
| Trip/offer gone | `NOT_FOUND` | 404 |
| Legal acceptance needed | `LEGAL_ACCEPTANCE_REQUIRED` | 403 |
| Session revoked (see #6) | `SESSION_REPLACED` etc. | 401/403 |

Shape: `{ "code": "PICKUP_TOO_FAR", "message": "<localized>" }`.
**Verify:** the client stops calling `parseDriverApiErrorMessage` for control flow;
`code` alone is sufficient.

### 5. Decide the pickup-proximity gate explicitly

**Now:** the app **deliberately ignores** proximity rejections on Arrived/Start so the
driver is never blocked. If the backend enforces proximity, the app shows ARRIVED while the
server stays WAITING — and, because nothing ever confirms it, the app holds ARRIVED
indefinitely. The two sides silently disagree.

**Ask:** pick one and document it:
- (preferred, matches product intent) do **not** gate `/trip/arrived` by proximity; or
- keep the gate but return `PICKUP_TOO_FAR` (see #4) so the client can honor it instead of
  swallowing it.

### 6. Confirm session-revocation is actually emitted

**Now:** the client logs the device out when it sees, over the trip WebSocket **or** as an
HTTP 401/403 `code`, one of: `session_revoked`, `auth_session_revoked`, `SESSION_REPLACED`,
`SESSION_INVALIDATED`, `LOGIN_ELSEWHERE`, `AUTH_SESSION_EXPIRED`.

**Ask:** confirm the backend emits one of these when a driver logs in on a second device.
If it does not, "logged in elsewhere" currently does nothing and two devices post location
for the same driver.
**Verify:** log in as the same driver on device B → device A receives the event (WS) or its
next request returns 401 with one of the codes → device A returns to the login screen.

---

## P2 — reliability & cost

### 7. Eliminate cold starts (biggest single latency win, ops-only)

`server: cloudflare` + `x-render-origin-server: Render`. Free/starter tiers spin down after
~15 min idle → the next request pays a 30–60 s cold start. This is almost certainly the
"app froze / order didn't come through" reports and is **not fixable in the client**.
**Ask:** run an always-on instance (or a keep-warm ping), so no request pays cold start.

### 8. Move the origin closer to Uzbekistan

Measured warm RTT to the edge ~117 ms; edge→origin adds ~150 ms (total warm TTFB ~270 ms,
occasional 700 ms). If the origin is in the US, a Frankfurt region cuts ~40% off every warm
call.

### 9. ETag / `304` on `GET /driver/available-requests`

It is heavy and polled every 4–12 s per online driver. Support `If-None-Match` →
`304 Not Modified` so idle polls are near-free. Meaningful at fleet scale.

### 10. Confirm `GET /ws/driver-dispatch` actually pushes `dispatch_changed`

Route exists (401 on unauth). The client connects, expects `{"type":"hello"}` on connect
and `{"type":"dispatch_changed","emitted_at":"<RFC3339>"}` when offers change, and treats
the latter as "refetch available-requests now". If it silently never emits, the app falls
back to the heavier 4 s poll. **Verify:** create an order near an online driver → that
driver's dispatch socket receives `dispatch_changed` within ~1 s.

---

## P3 — hygiene

### 11. Commit to a stable balance shape

**Now:** the client scrapes ~30 key aliases (`total_balance`, `balance`, `balance_tiyin`,
nested `wallet`/`driver`/`balances`, …) to find the balance.
**Ask:** return a documented, stable object on `GET /driver/available-requests`:
`{ "total_balance": <soʻm int>, "promo_balance": <soʻm int>, "cash_balance": <soʻm int> }`
(soʻm, not tiyin). The client keeps the fallbacks but will prefer these.

### 12. Fix stale contract docs (this repo)

`docs/BACKEND_CONTRACT.md` says the default `API_BASE_URL` is `taxi-uksz.onrender.com`
(code uses `taxi-2r2j.onrender.com`) and claims "the client does **not** call
`POST /trip/finish`" — it does now (driver-initiated finish). Align the doc so the contract
is trustworthy.

### 13. Expose the commission RATE (admin changes don't reach drivers)

**Symptom (reported):** an admin changes the commission % but the driver app keeps showing
the old value.
**Now:** the commission rate is exposed on **no** driver endpoint — verified by probing
`/driver/available-requests`, `/driver/promo-program`, `/driver/referral-status`,
`/driver/profile|status|me|home|dashboard|config|commission|tariff`, `/config`, `/settings`
(all 404 or no rate field). The only commission signal is per-trip `commission_som` /
`fare_som`. So the app can only *infer* the rate from a finished trip (e.g. 240/4000 = 6%),
which means an admin change is invisible until the driver completes another trip. There is
no way for the client to reflect the admin setting promptly.

**Ask:** include the current rate on `GET /driver/available-requests` (polled while online):

```
{ ..., "commission_pct": 6 }        // whole percent; a fraction like 0.06 is also accepted
```

The client **already reads this** (`parseCommissionRatePctFromJson`) and prefers it over the
trip-derived fallback, so the app will show an admin change within one poll (seconds) the
moment the field is present — no further app change needed. Accepted key names:
`commission_pct` / `commission_percent` / `commission_rate` (also under a nested
`config`/`driver`/`settings`). **Verify:** change the rate in admin → an online driver's
strip updates within a few seconds without reopening the app.

---

## Priority summary

| # | Ask | Why | Type |
|---|---|---|---|
| 1 | Actions return updated trip | button latency | contract |
| 2 | Read-after-write on assigned status | **the flip-flop bug** | consistency |
| 3 | Accept returns trip + coords | accept latency | contract |
| 4 | Stable error `code` on all 4xx | brittleness | contract |
| 5 | Decide proximity gate | silent client/server disagreement | policy |
| 6 | Emit session-revocation | multi-device safety | behavior |
| 7 | No cold starts | "app froze" reports | ops |
| 8 | Region near UZ | ~40% latency | ops |
| 9 | ETag/304 on available-requests | poll cost | perf |
| 10 | Verify dispatch_changed | falls back to polling | verify |
| 11 | Stable balance shape | client guesswork | contract |
| 12 | Fix stale docs | trust | docs |
| 13 | Expose `commission_pct` | **admin % change doesn't reach drivers** | contract |

**If you do only one thing: #2** (and ideally #1 with it). That eliminates both the button
latency and the revert-after-tap at the source, so the client-side hold becomes a safety
net rather than load-bearing.
