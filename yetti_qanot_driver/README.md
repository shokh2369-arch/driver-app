# YettiQanot Driver

Native **Flutter** driver client for **YettiQanot**. It follows the same **HTTP + WebSocket** contract as the Telegram driver bot and driver Mini App. **Canonical parity checklist** (routes, WS, CORS, flags, verification): backend repo **`docs/DRIVER_HTTP_API_HANDOFF.md`** (with **`docs/DRIVER_CLIENT.md`**, **`docs/AUTH.md`**, root **`README.md`**). This app does not implement a parallel protocol.

**Platforms:** Android, iOS, Web (Chrome), and desktop targets supported by Flutter.

---

## Features

- **Auth:** `X-Driver-Id` (internal `users.id` or Telegram user id) as the primary mode; optional `X-Telegram-Init-Data` for Mini App / WebView builds.
- **Online / offline:** Toggle controls dispatch polling and **HTTP** live location. While **ONLINE**, the native app sends `POST /driver/location/app` on a **~30s / ~60s** (foreground / background) cadence and when the device moves **~40 m** (min **15 s** between posts), with `{ lat, lng, accuracy?, timestamp? }` and **`timestamp` as Unix seconds** from the GPS fix. Switching **OFFLINE** **`await`s `POST /driver/offline`** (same auth) so the server clears live/active flags; only then does local OFFLINE apply (see `docs/DRIVER_APP.md`). While **OFFLINE**, location posts stop.
- **Dispatch:** Polls `GET /driver/available-requests` (foreground ~8s, background ~45s). **`GET /driver/promo-program`**, **`referral-status`**, and **`referral-link`** run at most about **once per 60s** (not every dispatch tick) to avoid request storms on web. Merges queue aliases, dedupes by `request_id`, handles `assigned_trip`, hydrates trips via `GET /trip/:id` when needed. App **lifecycle** changes debounce (~450ms) so visibility flips don’t reset timers in a tight loop.
- **Accept:** `POST /driver/accept-request` with `request_id` (and optional `trip_id`). User-facing errors for common HTTP statuses (e.g. 409).
- **Trip lifecycle:** `POST /trip/arrived`, `/trip/start`, **`POST /trip/finish`** with `{ trip_id }`; driver cancel via `POST /trip/cancel/driver`. The in-app **Safarni tugatish** button calls **`/trip/finish`** (backend must implement this route).
- **Realtime:** WebSocket `/ws?trip_id=…` with `init_data` or `driver_id` query when appropriate; handles trip status events and `driver_location_update`.
- **Legal:** On **403** with `LEGAL_ACCEPTANCE_REQUIRED`, routes to `GET /legal/active` and `POST /legal/accept`.
- **Balance / dashboard:** Wallet-shaped JSON from `GET /driver/available-requests`, optional documented `DRIVER_WALLET_HTTP_PATH`, plus `GET /driver/promo-program` and `GET /driver/referral-status` (merged into balance/stats UI); `GET /driver/referral-link` when shown. No fake numbers if the API omits fields.
- **QA:** Native drivers are dispatch-eligible over HTTP when the server accepts **`POST /driver/location/app`**. If offers are missing, see **verification** in [`docs/DRIVER_APP.md`](docs/DRIVER_APP.md) (`flutter analyze`, `/driver/location/app` errors).
- **Localization:** Uzbek (Latin + Cyrillic) via ARB; theme and locale preferences persisted.

---

## Requirements

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart **^3.11.4** per `pubspec.yaml`)
- For **iOS:** Xcode and CocoaPods as usual for Flutter
- For **Android:** Android SDK / Studio
- A running **YettiQanot API** (or staging URL) and a valid **driver id** from your admin / bot onboarding

---

## Quick start

```bash
cd yetti_qanot_driver
flutter pub get
flutter gen-l10n   # if you change ARB files
flutter run
```

Pick a device (e.g. `flutter devices` then `flutter run -d chrome`).

**Navigation:** `lib/app.dart` wires **legal gate** → **phone + SMS login** (if no `DRIVER_ID` / `TELEGRAM_INIT_DATA` / saved id) → **location gate** → `HomeScreen`.

### First launch (HTTP mode)

If `API_BASE_URL` is set (default is production), you have **no** `TELEGRAM_INIT_DATA`, and **no** `DRIVER_ID` dart-define / saved id, the app runs **`PhoneLoginScreen`**: `POST /auth/request-code` → `POST /auth/verify-code`, then saves **`driver_id`** to `SharedPreferences` (used as **`X-Driver-Id`** for later calls). Pass **`--dart-define=DRIVER_ID=...`** to skip phone login and fix the id at build time.

Location permission is required for maps and live location when online.

---

## Configuration (`dart-define`)

All optional overrides are compile-time flags:

| Define | Description |
|--------|-------------|
| `API_BASE_URL` | HTTPS origin, **no** trailing slash. Default: `https://taxi-2r2j.onrender.com`. |
| `DRIVER_ID` | Fixed `X-Driver-Id`; skips the in-app ID screen when non-empty. |
| `TELEGRAM_INIT_DATA` | Sends `X-Telegram-Init-Data` and appends `init_data` on `/ws` when set. |
| `WS_URL` | Full WebSocket URL override; if empty, derived as `wss://<API host>/ws`. |
| `DRIVER_WALLET_HTTP_PATH` | Optional **documented** `GET` on the same host (must start with `/`, no `..`) when balances are not in `available-requests`. |
| `OSRM_ROUTING_BASE_URL` | OSRM-compatible **routing** origin (no path), default `https://router.project-osrm.org`. Set **empty** to skip routing HTTP and use a straight pickup→drop line. Use your own host if the demo blocks **web** CORS. |

**Examples**

```bash
# Staging API + fixed driver id
flutter run -d chrome \
  --dart-define=API_BASE_URL=https://staging.example.com \
  --dart-define=DRIVER_ID=123456789

# Production + Mini App auth (WebView)
flutter run -d chrome \
  --dart-define=TELEGRAM_INIT_DATA=query_string_from_telegram

# Extra wallet endpoint — use only a path your backend actually serves, e.g.:
# flutter run -d chrome --dart-define=DRIVER_WALLET_HTTP_PATH=/driver/wallet
```

Release / profile builds use the same `--dart-define=...` arguments.

---

## Documentation in this repo

| File | Contents |
|------|----------|
| [docs/DRIVER_APP.md](docs/DRIVER_APP.md) | Screen → endpoint matrix, CORS for web, `ENABLE_DRIVER_HTTP_LIVE_LOCATION` note, code map. |
| [docs/BACKEND_CONTRACT.md](docs/BACKEND_CONTRACT.md) | High-level pointer to the Go API and this client’s behavior. |

In the **Go backend** repository: **`docs/DRIVER_HTTP_API_HANDOFF.md`** — single-file Flutter/backend parity checklist (commit **ef04aa9+** on `main`); **`docs/DRIVER_CLIENT.md`**, **`docs/AUTH.md`**, and root **`README.md`** remain the detailed contract.

---

## Driver Mini App (Leaflet, parity)

Static **Telegram Mini App–style** page (vanilla JS + Leaflet 1.9): [`webapp/driver/index.html`](webapp/driver/index.html). Open with **`?trip_id=`** and **`?driver_id=`** (required). Optional **`?api_base=https://your-api`** (no trailing slash) when the HTML is not served from the API origin (local `file://` always needs `api_base`).

```
cd webapp/driver && npx --yes serve -p 8080
# http://localhost:8080/index.html?trip_id=…&driver_id=…&api_base=https://…
```

---

## Google Play release (Android)

### 1) Set package name (applicationId)

Android package id is set to **`com.yettiqanot.driver`** in `android/app/build.gradle.kts`.
If you already reserved a different id in Play Console, change both:
- `android/app/build.gradle.kts`: `namespace` and `applicationId`
- `android/app/src/main/kotlin/.../MainActivity.kt`: `package ...`

### 2) Create upload keystore (one-time)

Windows example:

```powershell
keytool -genkeypair -v -keystore "$env:USERPROFILE\\yettiqanot-upload.jks" -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Copy `android/key.properties.example` → `android/key.properties` and fill it:

```text
storeFile=C:\\Users\\YOU\\yettiqanot-upload.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

`android/key.properties` and `.jks` are ignored by git.

### 3) Build AAB

```powershell
cd "D:\\driver app\\yetti_qanot_driver"
flutter build appbundle --release
```

Output:
- `build\\app\\outputs\\bundle\\release\\app-release.aab`

Note: if you hit “failed to strip debug symbols”, ensure Android NDK is installed (see `flutter doctor`). This repo also disables stripping via Gradle `doNotStrip("**/*.so")` to avoid that failure on Windows.

### 4) Upload to Play Console

- Upload `app-release.aab` to an internal testing track first
- Fill **Data safety** (location + network)

---

## Project layout

```
lib/
  app.dart                 # MaterialApp, lifecycle binding, legal gate, location gate
  main.dart                # ProviderScope + SharedPreferences
  core/                    # geo, formatting, localization, storage, theme
  data/repositories/       # DriverRepository (HTTP facade)
  features/
    driver/                # online status, driver id, GPS → HTTP/WS sync
    home/                  # dashboard, map, drawers, ID / location gates
    legal/                 # LEGAL_ACCEPTANCE_REQUIRED flow
    trip/                  # trip state machine, map, WS handling
  services/                # Dio client, dispatch parser, WebSocket, config
docs/
  DRIVER_APP.md
  BACKEND_CONTRACT.md
```

State management: **Riverpod 2** (`NotifierProvider`, `Provider`).

HTTP: **Dio** with interceptors (auth headers, legal 403 handling).  
Maps: **flutter_map** + **CARTO Voyager** raster tiles (OpenStreetMap data, CDN-friendly for web); trip line follows roads via **OSRM** (`lib/services/osrm_route_client.dart`, overridable with `OSRM_ROUTING_BASE_URL`).

---

## Tests & analysis

```bash
flutter analyze
flutter test
```

---

## Flutter web & CORS

On **web**, the browser enforces CORS. The API must allow your web origin and headers such as `Content-Type`, `X-Driver-Id`, and/or `X-Telegram-Init-Data` (and `Authorization` if you add JWT). **iOS/Android** are not affected by CORS.

---

## Troubleshooting

| Symptom | What to check |
|---------|----------------|
| **`404 NOT_FOUND` / JSON error in a browser** | You are on the **API base URL** (e.g. `https://api.example.com`), which returns JSON — not the **Mini App HTML**. This Flutter app uses **`API_BASE_URL` for API calls only**; maps are drawn in-app (**flutter_map** + HTTPS tile URLs). For the **Telegram Mini App** map pages, open the hosted HTML (e.g. `https://your-domain.com/webapp/index.html?trip_id=…&driver_id=…` for driver, or `…/webapp/rider-map.html?trip_id=…` for rider), not the bare API origin. |
| **“Reja topilmadi” / trip not found** | **`GET /trip/:id`** returned **404** or `NOT_FOUND`. The app shows the localized **`trip_plan_not_found`** string on the dashboard and for accept failures when applicable. Fix trip id / server data. |
| **Mini App: “Reja va haydovchi bilan oching” / missing params** | HTML Mini App links need **`trip_id`** and **`driver_id`** (or bot **`start_param`**) in the URL. This native app loads trips from **`GET /driver/available-requests`** + **`GET /trip/:id`** instead of query params. |
| **401 / “Haydovchi tasdiqlanmadi” on trip actions** | Backend must recognize the driver: open from **Telegram** so **`initData`** is sent, **or** enable **`ENABLE_DRIVER_ID_HEADER`** on the server and use **`X-Driver-Id`**. See backend **`AUTH.md`** / **`BACKEND_FIX_401.md`** (if present in the Go repo). |
| **Map or route not loading (this app)** | **HTTPS** (especially on web), OSM tile reachability, and **`GET /trip/:id`** / dispatch responses; browser **DevTools → Network** for failed requests. |
| **Trip line stays straight (web)** | Road geometry comes from **OSRM** (`OSRM_ROUTING_BASE_URL`). If the browser blocks the request (**CORS**), set the define to an OSRM (or proxy) URL that allows your web origin, or leave routing off with `OSRM_ROUTING_BASE_URL=` (straight segment only). |
| **Qo‘ng‘iroq / `tel:` does nothing** | **Web / in-app browsers** may block `tel:`; on mobile, allow phone intents. Rider call buttons need **`rider_phone`** (or equivalent) from the API if you add that UI later. |
| **“Yetib keldim” shows “hali yetib bormagansiz…”** | This message is returned by the backend when `POST /trip/arrived` is rejected (typically a proximity rule). The app UI does not gate arrival by distance; it proceeds to ARRIVED locally even if the server replies with a proximity-style error. |
| **Fare or distance wrong** | **`GET /trip/:id`** (and server pricing config such as **`PRICE_PER_KM`**) — verify the JSON; the client does not recompute fare. |
| **Balance shows "—"** | Normal if dispatch, promo-program, and referral-status responses omit wallet-shaped fields. Fix on the API (embed balances) or set a documented `DRIVER_WALLET_HTTP_PATH`. |
| **401 / unknown driver** | `X-Driver-Id` must be a valid internal or Telegram id from your DB / admin. |
| **No dispatch / no offers** | **ONLINE**, location permission, **`POST /driver/location/app`** succeeding (see DevTools); driver approval, legal, balance; server freshness (~90s). Backend falls back to Telegram location if app-location is missing/stale. |
| **OFFLINE toggle snaps back / error snackbar** | **`POST /driver/offline`** must succeed before the app shows OFFLINE (server clears live flags). Check network, CORS (web), and **403** legal; retry the toggle. |
| **Legal screen stuck** | Complete `POST /legal/accept` or fix server response; ensure `GET /legal/active` matches backend. |

---

## License

`publish_to: 'none'` — private / internal use unless you change publishing settings.

---

## Contributing / backend changes

When the Go API changes, update:

1. Backend **`docs/DRIVER_HTTP_API_HANDOFF.md`** (checklist) and **`docs/DRIVER_CLIENT.md`** / **`docs/AUTH.md`** (detail).
2. This client’s `DriverApiClient`, parsers, and [docs/DRIVER_APP.md](docs/DRIVER_APP.md) as needed.

Do not log `X-Telegram-Init-Data` or other secrets.
