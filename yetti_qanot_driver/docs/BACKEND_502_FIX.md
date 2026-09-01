# Backend down — 502 Bad Gateway on every route (prompt for the backend team)

The YettiQanot Go API on Render (`taxi-2r2j.onrender.com`) is returning **502 Bad Gateway
on every request**. This is a backend/deploy problem — the driver app is healthy and
already degrades gracefully (shows "server busy, retry"). Fix the origin service.

## Symptoms (observed from the driver app + an external host)

- `POST /auth/request-code` → **502 Bad Gateway**, ~15 s per request, repeated. Drivers
  cannot log in (no SMS code).
- `GET /health` → **502 / connection reset** (~15 s), so it's not route-specific.
- Persistent for many minutes — not a single cold-start blip.
- DNS resolves fine (`taxi-2r2j.onrender.com` → `216.24.57.7`).
- From the same external host, general internet and `https://render.com` load in <1 s —
  so egress and Render itself are fine. **Only this service's origin is unreachable.**

A 502 from Render means its edge proxy got no valid HTTP response from your web service:
**the app process is not running, not listening on the right port, crash-looping, or the
instance is suspended.**

## Diagnose (Render dashboard → this service)

1. **Service status & events** — is it `Live`, `Deploy failed`, `Suspended`, or
   `Restarting`? Free-tier services spin down when idle and **suspend when the monthly
   free hours are exhausted** — a suspended service 502s until you upgrade or the quota
   resets. Check the "Events" tab.
2. **Runtime logs** — look for a panic/stack trace, `exit status 1`, OOM
   (`Ran out of memory`, exit 137), or a boot error. A crash-loop shows repeated
   start→exit lines.
3. **Port binding** — Render injects `$PORT` and expects the app to listen on it at
   `0.0.0.0:$PORT`. If the app hardcodes `:8080`/`localhost`, Render's health probe fails
   and every request 502s. Confirm the server reads `PORT` from env and binds `0.0.0.0`.
4. **Startup dependencies** — if the app connects to Postgres/Redis/an SMS provider at
   boot and that connection fails, it may crash before serving. Check DB env vars and that
   the DB/Redis is reachable and not itself suspended.
5. **Deploy** — did the latest deploy build succeed? A failed deploy can leave the edge
   pointing at a dead instance.

## Fix

- Get the origin healthy again: resolve the crash/OOM/port issue from the logs, or restart
  the service if it's merely suspended/hung.
- **Move off the free tier to an always-on instance.** Free-tier spin-down + cold starts
  are the recurring cause of these outages for a driver app that must be reachable during a
  whole shift (this is `BACKEND_ASKS.md` #7).
- If it's OOM: bump the instance size or fix the leak.
- If it's the monthly-hours suspension: upgrade the plan.

## Verify

- `curl -s -o /dev/null -w "%{http_code}\n" https://taxi-2r2j.onrender.com/health` → **200**
  (`OK`), consistently, in <1 s.
- `POST /auth/request-code {"phone":"+998..."}` → **200** (or a clean 4xx like
  `INVALID_PHONE`), never 502; an SMS is delivered.
- Render logs show the service `Live` with no restart loop.

## Not the client

The app already handles this: any 5xx on login shows a localized "server temporarily busy —
try again" with a Retry button (no fabricated status code), and dispatch/WS back off. No
client change will make a 502 go away — the origin has to serve requests.
