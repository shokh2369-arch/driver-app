/**
 * YettiQanot haydovchi — Telegram Mini App / web (Leaflet), Flutter driver parity.
 * Query: ?trip_id=&driver_id=&api_base=https://host (optional)
 * Telegram: startParam trip_* → trip id; initData on WebSocket
 */
(function () {
  'use strict';

  const R_EARTH_KM = 6371;
  const PICKUP_ARRIVAL_RADIUS_KM = 0.1;
  const PICKUP_ROUTE_REDRAW_INTERVAL_MS = 5000;
  const LIVE_TRIP_POLL_INTERVAL_MS = 3000;
  const TRIP_REFETCH_INTERVAL_MS = 10000;
  const GPS_MAX_ACCURACY_M = 50;
  const BEARING_MIN_MOVE_M = 5;
  const ROUTE_DEVIATION_M = 50;
  const OSRM_URL = 'https://router.project-osrm.org/route/v1/driving';
  const DEFAULT_CENTER = [41.311081, 69.240562];
  const SMOOTH_LEN = 3;

  const qs = new URLSearchParams(window.location.search);
  const tripIdFromQuery = (qs.get('trip_id') || '').trim();
  const driverIdFromQuery = (qs.get('driver_id') || '').trim();
  const apiBaseOverride = (qs.get('api_base') || '').replace(/\/+$/, '');

  function getTripIdFromTelegram() {
    var tg = window.Telegram && window.Telegram.WebApp;
    if (!tg) return '';
    var sp = (tg.initDataUnsafe && tg.initDataUnsafe.start_param) || '';
    if (!sp && tg.initData) {
      try {
        var p = new URLSearchParams(tg.initData);
        sp = p.get('start_param') || '';
      } catch (e) {}
    }
    if (sp.indexOf('trip_') === 0) return sp.slice(5).trim();
    return '';
  }

  var tripId = tripIdFromQuery || getTripIdFromTelegram();
  var driverId = driverIdFromQuery;

  function apiBase() {
    if (apiBaseOverride) return apiBaseOverride;
    return window.location.origin.replace(/\/+$/, '');
  }

  function wsUrlForTrip(tid) {
    var base = apiBase();
    var u = base.replace(/^http/i, function (m) {
      return m.toLowerCase() === 'https' ? 'wss' : 'ws';
    });
    var path = '/ws?trip_id=' + encodeURIComponent(tid);
    var init =
      window.Telegram &&
      window.Telegram.WebApp &&
      window.Telegram.WebApp.initData;
    if (init) path += '&init_data=' + encodeURIComponent(init);
    return u + path;
  }

  function authHeaders() {
    var h = { 'Content-Type': 'application/json' };
    var did = String(driverId || '').trim();
    if (did) h['X-Driver-Id'] = did;
    var tg = window.Telegram && window.Telegram.WebApp;
    if (tg && tg.initData) h['X-Telegram-Init-Data'] = tg.initData;
    return h;
  }

  /** ---------- Geo ---------- */
  function haversineKm(lat1, lng1, lat2, lng2) {
    var toRad = function (d) {
      return (d * Math.PI) / 180;
    };
    var dLat = toRad(lat2 - lat1);
    var dLng = toRad(lng2 - lng1);
    var a =
      Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
    return 2 * R_EARTH_KM * Math.asin(Math.min(1, Math.sqrt(a)));
  }

  function haversineM(a, b) {
    return haversineKm(a.lat, a.lng, b.lat, b.lng) * 1000;
  }

  function bearingDeg(lat1, lng1, lat2, lng2) {
    var φ1 = (lat1 * Math.PI) / 180;
    var φ2 = (lat2 * Math.PI) / 180;
    var Δλ = ((lng2 - lng1) * Math.PI) / 180;
    var y = Math.sin(Δλ) * Math.cos(φ2);
    var x = Math.cos(φ1) * Math.sin(φ2) - Math.sin(φ1) * Math.cos(φ2) * Math.cos(Δλ);
    var br = (Math.atan2(y, x) * 180) / Math.PI;
    return (br + 360) % 360;
  }

  /** Meters: point P to segment AB (equirectangular approx at P.lat) */
  function distPointToSegmentM(p, a, b) {
    var metersPerDegLat = 111320;
    var metersPerDegLng = 111320 * Math.cos((p.lat * Math.PI) / 180);
    function toXY(ll) {
      return {
        x: (ll.lng - p.lng) * metersPerDegLng,
        y: (ll.lat - p.lat) * metersPerDegLat,
      };
    }
    var A = toXY(a);
    var B = toXY(b);
    var vx = B.x - A.x;
    var vy = B.y - A.y;
    var len2 = vx * vx + vy * vy;
    if (len2 < 1e-9) return Math.sqrt(A.x * A.x + A.y * A.y);
    var t = Math.max(0, Math.min(1, (-A.x * vx - A.y * vy) / len2));
    var px = A.x + t * vx;
    var py = A.y + t * vy;
    return Math.sqrt(px * px + py * py);
  }

  function minDistToPolylineM(p, latlngs) {
    if (!latlngs || latlngs.length < 2) return Infinity;
    var min = Infinity;
    for (var i = 0; i < latlngs.length - 1; i++) {
      var a = { lat: latlngs[i].lat, lng: latlngs[i].lng };
      var b = { lat: latlngs[i + 1].lat, lng: latlngs[i + 1].lng };
      var d = distPointToSegmentM(p, a, b);
      if (d < min) min = d;
    }
    return min;
  }

  /** ---------- Parse trip JSON ---------- */
  function num(v) {
    if (v == null) return null;
    if (typeof v === 'number' && isFinite(v)) return v;
    var x = parseFloat(String(v));
    return isFinite(x) ? x : null;
  }

  function parsePickup(j) {
    var plat = num(j.pickup_lat);
    var plng = num(j.pickup_lng);
    var pu = j.pickup;
    if (pu && typeof pu === 'object' && !Array.isArray(pu)) {
      plat = plat ?? num(pu.lat ?? pu.latitude);
      plng = plng ?? num(pu.lng ?? pu.longitude);
    }
    if (Array.isArray(pu) && pu.length >= 2) {
      var x = num(pu[0]);
      var y = num(pu[1]);
      if (x != null && y != null) {
        if (Math.abs(x) <= 90 && Math.abs(y) <= 180) {
          plat = x;
          plng = y;
        } else if (Math.abs(y) <= 90 && Math.abs(x) <= 180) {
          plat = y;
          plng = x;
        }
      }
    }
    if (plat != null && plng != null) return L.latLng(plat, plng);
    return null;
  }

  function parseFare(j) {
    var nested =
      j.fare && typeof j.fare === 'object'
        ? num(j.fare.amount ?? j.fare.value)
        : null;
    return (
      nested ??
      num(j.fare) ??
      num(j.total_fare) ??
      num(j.amount) ??
      num(j.price) ??
      num(j.trip_fare) ??
      num(j.narx)
    );
  }

  function parseDistanceKm(j) {
    return (
      num(j.distance_km) ??
      num(j.trip_distance) ??
      num(j.distance) ??
      (j.trip && num(j.trip.distance_km))
    );
  }

  function parseRiderPhone(j) {
    var p =
      j.rider_phone ||
      j.passenger_phone ||
      j.customer_phone ||
      (j.rider_info && (j.rider_info.phone || j.rider_info.phone_number));
    return p != null ? String(p).trim() : '';
  }

  function parseRiderName(j) {
    var n =
      j.rider_name ||
      j.passenger_name ||
      (j.rider_info && (j.rider_info.name || j.rider_info.full_name));
    return n != null ? String(n).trim() : '';
  }

  function parsePickupLine(j) {
    return (
      j.pickup_address ||
      j.pickup_name ||
      j.address ||
      j.pickup_line ||
      ''
    )
      .toString()
      .trim();
  }

  function normalizeStatus(s) {
    return (s || '').toString().trim().toUpperCase();
  }

  /** ---------- State ---------- */
  var state = {
    tripJson: null,
    status: '',
    pickupLatLng: null,
    driverPickupPhase: 'TO_PICKUP',
    lastStatus: '',
    smoothBuffer: [],
    lastDriverLatLng: null,
    lastBearingAnchor: null,
    bearingDeg: 0,
    lastOsrmFetch: 0,
    /** @type {L.LatLng[]} */
    pickupRouteLatLngs: [],
    osrmDistanceKm: null,
    osrmDurationMin: null,
    osrmLoading: false,
    tripPath: [],
    livePollTimer: null,
    lastFareRefetchWall: 0,
    ws: null,
    wsReconnect: null,
    wsCloseIntentional: false,
    map: null,
    pickupMarker: null,
    driverMarker: null,
    layerPickupRoute: null,
    layerHelper: null,
    layerTripPath: null,
    previousWaiting: false,
  };

  /** ---------- DOM ---------- */
  var el = {
    missing: document.getElementById('screen-missing'),
    notFound: document.getElementById('screen-not-found'),
    main: document.getElementById('main-ui'),
    banner: document.getElementById('banner'),
    bannerDot: document.getElementById('banner-dot'),
    bannerText: document.getElementById('banner-text'),
    riderCard: document.getElementById('rider-card'),
    riderName: document.getElementById('rider-name'),
    riderPhone: document.getElementById('rider-phone'),
    riderPickup: document.getElementById('rider-pickup'),
    routePanel: document.getElementById('route-panel'),
    statFare: document.getElementById('stat-fare'),
    statDist: document.getElementById('stat-dist'),
    statusLine: document.getElementById('status-line'),
    btnArrived: document.getElementById('btn-arrived'),
    btnStart: document.getElementById('btn-start'),
    btnFinish: document.getElementById('btn-finish'),
    btnCancel: document.getElementById('btn-cancel'),
    finished: document.getElementById('finished-overlay'),
    finishedFare: document.getElementById('finished-fare'),
    finishedDist: document.getElementById('finished-dist'),
  };

  function showMissing(msg) {
    document.getElementById('missing-msg').textContent = msg;
    el.missing.hidden = false;
  }

  function formatSom(f) {
    if (f == null || !isFinite(f)) return '—';
    var rounded = Math.round(f / 100) * 100;
    return (
      new Intl.NumberFormat('uz-UZ', { maximumFractionDigits: 0 }).format(
        rounded
      ) + " so'm"
    );
  }

  function formatKm(km) {
    if (km == null || !isFinite(km) || km <= 0) return '—';
    return km.toFixed(1) + ' km';
  }

  function formatPhone(raw) {
    var d = String(raw).replace(/\D/g, '');
    if (d.length === 12 && d.indexOf('998') === 0) {
      return (
        '+998 ' +
        d.slice(3, 5) +
        ' ' +
        d.slice(5, 8) +
        ' ' +
        d.slice(8, 12)
      );
    }
    return raw;
  }

  /** ---------- HTTP ---------- */
  function apiGet(path) {
    return fetch(apiBase() + path, { headers: authHeaders(), credentials: 'omit' }).then(
      function (r) {
        if (r.status === 401) throw new Error('AUTH');
        if (!r.ok) throw new Error('HTTP_' + r.status);
        return r.json();
      }
    );
  }

  function apiPost(path, body) {
    return fetch(apiBase() + path, {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify(body),
      credentials: 'omit',
    }).then(function (r) {
      if (r.status === 401) throw new Error('AUTH');
      if (!r.ok) throw new Error('HTTP_' + r.status);
      return r.json().catch(function () {
        return {};
      });
    });
  }

  function postDriverLocation(lat, lng, accuracy) {
    var did = parseInt(String(driverId), 10);
    var body = {
      driver_id: did,
      lat: lat,
      lng: lng,
    };
    if (accuracy != null && isFinite(accuracy)) body.accuracy = accuracy;
    try {
      console.log('[yetti_driver] Sending location -> lat:', lat, 'lng:', lng, 'acc_m:', accuracy);
    } catch (e) {}
    return apiPost('/driver/location', body).catch(function () {});
  }

  /** ---------- Map ---------- */
  function initMap() {
    state.map = L.map('map', {
      zoomControl: false,
      scrollWheelZoom: true,
      doubleClickZoom: true,
      touchZoom: true,
      tap: true,
    });
    state.map.setView(DEFAULT_CENTER, 13);
    L.tileLayer(
      'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
      {
        subdomains: 'abcd',
        maxZoom: 19,
        attribution: '© OSM © CARTO',
      }
    ).addTo(state.map);
    L.control.zoom({ position: 'topright' }).addTo(state.map);

    function invalidate() {
      state.map.invalidateSize();
    }
    invalidate();
    setTimeout(invalidate, 100);
    setTimeout(invalidate, 400);
  }

  function pickupIcon() {
    return L.divIcon({
      className: 'pickup-marker-wrap',
      html:
        '<div class="pickup-marker-inner"><img src="img/rider-pin.svg" alt=""/></div>',
      iconSize: [48, 56],
      iconAnchor: [24, 56],
    });
  }

  function driverIcon(deg) {
    var rot = isFinite(deg) ? deg : 0;
    return L.divIcon({
      className: 'driver-marker-wrap',
      html:
        '<div class="driver-marker-inner" style="transform:rotate(' +
        rot +
        'deg)"><img src="img/driver-car.svg" alt=""/></div>',
      iconSize: [76, 76],
      iconAnchor: [38, 38],
    });
  }

  function setDriverMarker(latlng) {
    if (!state.map || !latlng) return;
    if (!state.driverMarker) {
      state.driverMarker = L.marker(latlng, {
        icon: driverIcon(state.bearingDeg),
        zIndexOffset: 1000,
      })
        .addTo(state.map)
        .bindPopup('Haydovchi');
    } else {
      state.driverMarker.setLatLng(latlng);
      state.driverMarker.setIcon(driverIcon(state.bearingDeg));
    }
  }

  function setPickupMarker(latlng) {
    if (!state.map || !latlng) return;
    if (!state.pickupMarker) {
      state.pickupMarker = L.marker(latlng, { icon: pickupIcon() })
        .addTo(state.map)
        .bindPopup('Mijoz / Olib ketish joyi');
    } else {
      state.pickupMarker.setLatLng(latlng);
    }
  }

  function removePickupMarker() {
    if (state.pickupMarker && state.map) {
      state.map.removeLayer(state.pickupMarker);
      state.pickupMarker = null;
    }
  }

  function clearPickupRouteLayers() {
    if (state.layerPickupRoute && state.map) {
      state.map.removeLayer(state.layerPickupRoute);
      state.layerPickupRoute = null;
    }
    if (state.layerHelper && state.map) {
      state.map.removeLayer(state.layerHelper);
      state.layerHelper = null;
    }
  }

  function drawTripPath() {
    if (state.layerTripPath && state.map) {
      state.map.removeLayer(state.layerTripPath);
      state.layerTripPath = null;
    }
    if (state.tripPath.length < 2 || !state.map) return;
    state.layerTripPath = L.polyline(state.tripPath, {
      color: '#16a34a',
      weight: 7,
    }).addTo(state.map);
  }

  function followDriverMapView(driverLatLng) {
    if (!state.map || !driverLatLng) return;
    var map = state.map;
    var st = state.status;
    var inside = map.getBounds().contains(driverLatLng);
    if (inside) {
      map.panTo(driverLatLng, { animate: true, duration: 0.22 });
      return;
    }
    if (st === 'WAITING' && state.pickupLatLng) {
      map.fitBounds(L.latLngBounds([driverLatLng, state.pickupLatLng]), {
        padding: [80, 40, 80, 40],
        maxZoom: 16,
        animate: true,
      });
    } else if (st === 'STARTED') {
      map.setView(driverLatLng, map.getZoom(), { animate: true });
    } else {
      map.panTo(driverLatLng, { animate: true, duration: 0.22 });
    }
  }

  /** ---------- OSRM ---------- */
  function fetchOsrmRoute(from, to, cb) {
    state.osrmLoading = true;
    updateRoutePanel();
    var coord =
      from.lng +
      ',' +
      from.lat +
      ';' +
      to.lng +
      ',' +
      to.lat;
    var url =
      OSRM_URL +
      '/' +
      coord +
      '?overview=full&geometries=geojson';
    fetch(url)
      .then(function (r) {
        return r.json();
      })
      .then(function (data) {
        state.osrmLoading = false;
        var routes = data.routes;
        if (!routes || !routes[0]) {
          state.pickupRouteLatLngs = [];
          state.osrmDistanceKm = null;
          state.osrmDurationMin = null;
          cb(null);
          return;
        }
        var route = routes[0];
        var geom = route.geometry;
        var coords = geom && geom.coordinates;
        var latlngs = [];
        if (Array.isArray(coords)) {
          for (var i = 0; i < coords.length; i++) {
            var c = coords[i];
            if (Array.isArray(c) && c.length >= 2) {
              latlngs.push(L.latLng(c[1], c[0]));
            }
          }
        }
        state.pickupRouteLatLngs = latlngs;
        state.osrmDistanceKm = route.distance ? route.distance / 1000 : null;
        state.osrmDurationMin = route.duration ? route.duration / 60 : null;
        cb(latlngs);
      })
      .catch(function () {
        state.osrmLoading = false;
        state.pickupRouteLatLngs = [];
        cb(null);
      });
  }

  function drawRemainingPickupRoute(latlngs, driverLatLng, pickupLatLng) {
    clearPickupRouteLayers();
    if (!state.map) return;
    if (latlngs && latlngs.length >= 2) {
      state.layerPickupRoute = L.polyline(latlngs, {
        color: '#2563eb',
        weight: 7,
      }).addTo(state.map);
    } else if (driverLatLng && pickupLatLng) {
      state.layerHelper = L.polyline([driverLatLng, pickupLatLng], {
        color: '#60a5fa',
        weight: 4,
        dashArray: '8 8',
      }).addTo(state.map);
    }
  }

  function checkRouteDeviationAndRecalc(driverLatLng) {
    if (state.status !== 'WAITING') return;
    if (!driverLatLng || !state.pickupLatLng) return;
    var route = state.pickupRouteLatLngs;
    if (route && route.length >= 2) {
      var p = { lat: driverLatLng.lat, lng: driverLatLng.lng };
      var d = minDistToPolylineM(p, route);
      if (d > ROUTE_DEVIATION_M) {
        scheduleOsrmRedraw(true);
      }
    }
  }

  var osrmTimer = null;
  function scheduleOsrmRedraw(force) {
    var now = Date.now();
    var delta = now - state.lastOsrmFetch;
    if (!force && delta < PICKUP_ROUTE_REDRAW_INTERVAL_MS) {
      if (osrmTimer) clearTimeout(osrmTimer);
      osrmTimer = setTimeout(function () {
        scheduleOsrmRedraw(true);
      }, PICKUP_ROUTE_REDRAW_INTERVAL_MS - delta);
      return;
    }
    state.lastOsrmFetch = Date.now();
    osrmTimer = null;
    if (state.status !== 'WAITING' || !state.pickupLatLng || !state.lastDriverLatLng)
      return;
    fetchOsrmRoute(state.lastDriverLatLng, state.pickupLatLng, function (ll) {
      drawRemainingPickupRoute(ll, state.lastDriverLatLng, state.pickupLatLng);
      updateRoutePanel();
    });
  }

  /** ---------- Trip update ---------- */
  function updateFromTrip(j) {
    state.tripJson = j;
    var st = normalizeStatus(j.status || j.trip_status || (j.trip && j.trip.status));
    var prev = state.lastStatus;
    state.lastStatus = st;
    state.status = st;

    if (st === 'STARTED' && prev !== 'STARTED') {
      startLivePoll();
    }

    if (st === 'WAITING' && prev !== 'WAITING' && prev !== '') {
      state.driverPickupPhase = 'TO_PICKUP';
    }

    var pu = parsePickup(j);
    if (pu) {
      state.pickupLatLng = pu;
      if (st === 'WAITING' || st === '') {
        setPickupMarker(pu);
      }
    }

    if (st === 'STARTED') {
      removePickupMarker();
      clearPickupRouteLayers();
    }

    syncBanner();
    syncRiderCard(j);
    syncBottom(j);
    syncButtons();

    if (st === 'FINISHED' || st.indexOf('CANCELLED') === 0) {
      stopLivePoll();
      stopGps();
      disconnectWs();
      if (st === 'FINISHED') showFinishedOverlay(j);
    }
  }

  function refreshTrip() {
    return apiGet('/trip/' + encodeURIComponent(tripId))
      .then(updateFromTrip)
      .catch(function () {
        el.bannerText.textContent = 'Maʼlumotni yangilab bo‘lmadi';
        el.banner.classList.add('banner-error');
      });
  }

  /** ---------- UI sync ---------- */
  function syncBanner() {
    el.banner.classList.remove('banner-error');
    var st = state.status;
    if (st === 'WAITING' && state.driverPickupPhase === 'ARRIVED') {
      el.bannerText.textContent = 'Safarni boshlash mumkin';
      return;
    }
    var map = {
      WAITING: "Mijozga yo'lda",
      STARTED: 'Safar boshlandi',
      FINISHED: 'Safar yakunlandi',
      CANCELLED: 'Bekor qilindi',
      CANCELLED_BY_DRIVER: 'Haydovchi bekor qildi',
      CANCELLED_BY_RIDER: 'Yo‘lovchi bekor qildi',
    };
    el.bannerText.textContent = map[st] || st || '…';
  }

  function syncRiderCard(j) {
    el.riderName.textContent = parseRiderName(j) || 'Mijoz';
    var phone = parseRiderPhone(j);
    el.riderPhone.href = phone ? 'tel:' + phone.replace(/\D/g, '') : '#';
    el.riderPhone.textContent = phone ? formatPhone(phone) : '—';
    el.riderPickup.textContent = parsePickupLine(j) || '—';
    el.riderPhone.onclick = function (e) {
      if (!phone) {
        e.preventDefault();
        return;
      }
      var tg = window.Telegram && window.Telegram.WebApp;
      if (tg && tg.openLink) {
        e.preventDefault();
        tg.openLink('tel:' + phone.replace(/\D/g, ''));
      }
    };
  }

  function updateRoutePanel() {
    if (!el.routePanel) return;
    if (state.status !== 'WAITING') {
      el.routePanel.hidden = true;
      return;
    }
    el.routePanel.hidden = false;
    el.routePanel.classList.toggle('loading', state.osrmLoading);
    var h = '';
    if (state.osrmLoading) {
      h = "Yo'nalish hisoblanmoqda…";
    } else if (
      state.osrmDistanceKm != null &&
      state.osrmDurationMin != null
    ) {
      h =
        state.osrmDistanceKm.toFixed(1) +
        ' km · ~' +
        Math.round(state.osrmDurationMin) +
        ' daqiqa';
    } else if (state.lastDriverLatLng && state.pickupLatLng) {
      var km = haversineKm(
        state.lastDriverLatLng.lat,
        state.lastDriverLatLng.lng,
        state.pickupLatLng.lat,
        state.pickupLatLng.lng
      );
      var min = (km / 25) * 60;
      h = '~' + km.toFixed(1) + ' km · ~' + Math.round(min) + ' daqiqa';
    } else {
      h = '—';
    }
    el.routePanel.textContent = h;
  }

  function syncBottom(j) {
    var st = state.status;
    if (st === 'WAITING') {
      el.statFare.textContent = '—';
      el.statDist.textContent = '—';
    } else if (st === 'STARTED') {
      var fare = parseFare(j);
      var dk = parseDistanceKm(j);
      el.statFare.textContent = formatSom(fare);
      el.statDist.textContent = formatKm(dk);
    } else {
      el.statFare.textContent = '—';
      el.statDist.textContent = '—';
    }

    if (st === 'STARTED') {
      el.statusLine.textContent = 'Safar davom etmoqda…';
    } else if (st === 'WAITING' && state.driverPickupPhase === 'TO_PICKUP') {
      el.statusLine.textContent =
        "Mijozga yo'lda. Olib ketish joyiga boring.";
    } else if (st === 'WAITING' && state.driverPickupPhase === 'ARRIVED') {
      el.statusLine.textContent = 'Safarni boshlash mumkin.';
    } else {
      el.statusLine.textContent = '';
    }
  }

  function syncButtons() {
    var st = state.status;
    var phase = state.driverPickupPhase;
    el.btnArrived.hidden = st !== 'WAITING' || phase !== 'TO_PICKUP';
    el.btnStart.hidden = st !== 'WAITING' || phase !== 'ARRIVED';
    el.btnFinish.hidden = st !== 'STARTED';
    el.btnCancel.hidden =
      st !== 'WAITING' && st !== 'STARTED';

    var near =
      state.lastDriverLatLng &&
      state.pickupLatLng &&
      haversineKm(
        state.lastDriverLatLng.lat,
        state.lastDriverLatLng.lng,
        state.pickupLatLng.lat,
        state.pickupLatLng.lng
      ) <= PICKUP_ARRIVAL_RADIUS_KM;
    el.btnArrived.disabled = !near;
  }

  function showFinishedOverlay(j) {
    var fare = parseFare(j);
    var dk = parseDistanceKm(j);
    el.finishedFare.textContent = formatSom(fare);
    el.finishedDist.textContent = formatKm(dk);
    el.finished.hidden = false;
    setTimeout(function () {
      refreshTrip().catch(function () {});
    }, 800);
  }

  el.finished.addEventListener('click', function (e) {
    if (e.target === el.finished) el.finished.hidden = true;
  });

  /** ---------- GPS ---------- */
  var watchId = null;

  function smoothLatLng(raw) {
    state.smoothBuffer.push({ lat: raw.lat, lng: raw.lng });
    while (state.smoothBuffer.length > SMOOTH_LEN) state.smoothBuffer.shift();
    var lat = 0,
      lng = 0,
      n = state.smoothBuffer.length;
    for (var i = 0; i < n; i++) {
      lat += state.smoothBuffer[i].lat;
      lng += state.smoothBuffer[i].lng;
    }
    return L.latLng(lat / n, lng / n);
  }

  function updateBearing(fromAnchor, to) {
    var anchor = fromAnchor || state.lastBearingAnchor;
    if (!anchor) {
      state.lastBearingAnchor = { lat: to.lat, lng: to.lng };
      return;
    }
    var m = haversineM(anchor, { lat: to.lat, lng: to.lng });
    if (m >= BEARING_MIN_MOVE_M) {
      state.bearingDeg = bearingDeg(
        anchor.lat,
        anchor.lng,
        to.lat,
        to.lng
      );
      state.lastBearingAnchor = { lat: to.lat, lng: to.lng };
    }
  }

  function onLocationUpdate(pos, fromWs) {
    if (pos.coords.accuracy > GPS_MAX_ACCURACY_M) return;
    var raw = L.latLng(pos.coords.latitude, pos.coords.longitude);
    var ll = smoothLatLng(raw);
    state.lastDriverLatLng = ll;
    postDriverLocation(ll.lat, ll.lng, pos.coords.accuracy);
    updateBearing(state.lastBearingAnchor, ll);
    setDriverMarker(ll);

    if (state.status === 'WAITING') {
      checkRouteDeviationAndRecalc(ll);
      drawHelperOrRoute(ll);
      followDriverMapView(ll);
      syncWaitingPickupPhaseUi();
      scheduleOsrmRedraw(false);
    } else if (state.status === 'STARTED') {
      appendTripProgressPoint(ll);
      maybeRefetchTripForFare();
      followDriverMapView(ll);
    }
  }

  function drawHelperOrRoute(driverLatLng) {
    if (!state.pickupLatLng) return;
    if (state.pickupRouteLatLngs.length >= 2 && state.layerPickupRoute) {
      return;
    }
    drawRemainingPickupRoute(null, driverLatLng, state.pickupLatLng);
  }

  function appendTripProgressPoint(ll) {
    if (state.tripPath.length === 0) {
      state.tripPath.push(ll);
      return;
    }
    var last = state.tripPath[state.tripPath.length - 1];
    if (haversineM({ lat: last.lat, lng: last.lng }, { lat: ll.lat, lng: ll.lng }) >= 5) {
      state.tripPath.push(ll);
      drawTripPath();
    }
  }

  var lastTripRefetch = 0;
  function maybeRefetchTripForFare() {
    var now = Date.now();
    if (now - lastTripRefetch < TRIP_REFETCH_INTERVAL_MS) return;
    lastTripRefetch = now;
    refreshTrip().catch(function () {});
  }

  function syncWaitingPickupPhaseUi() {
    syncBanner();
    syncBottom(state.tripJson || {});
    syncButtons();
  }

  function startGps() {
    if (!navigator.geolocation) return;
    navigator.geolocation.getCurrentPosition(
      function (pos) {
        onLocationUpdate(pos, false);
      },
      function () {},
      { enableHighAccuracy: true, maximumAge: 5000 }
    );
    watchId = navigator.geolocation.watchPosition(
      function (pos) {
        onLocationUpdate(pos, false);
      },
      function () {},
      { enableHighAccuracy: true, maximumAge: 5000 }
    );
  }

  function stopGps() {
    if (watchId != null) {
      navigator.geolocation.clearWatch(watchId);
      watchId = null;
    }
  }

  /** ---------- WebSocket ---------- */
  function connectWebSocket() {
    state.wsCloseIntentional = false;
    if (state.ws) {
      try {
        state.ws.close();
      } catch (e) {}
      state.ws = null;
    }
    var url = wsUrlForTrip(tripId);
    try {
      state.ws = new WebSocket(url);
    } catch (e) {
      scheduleWsReconnect();
      return;
    }
    state.ws.onmessage = function (ev) {
      var m;
      try {
        m = JSON.parse(ev.data);
      } catch (e) {
        return;
      }
      var type = (m.type || '').toString();
      if (type === 'driver_location_update' || type === 'driver_location') {
        var payload = m.payload || m;
        var lat = num(payload.lat ?? payload.latitude ?? m.lat);
        var lng = num(payload.lng ?? payload.longitude ?? m.lng);
        if (lat == null || lng == null) return;
        onLocationUpdate(
          { coords: { latitude: lat, longitude: lng, accuracy: 20 } },
          true
        );
        return;
      }
      if (
        type.indexOf('trip_started') >= 0 ||
        type.indexOf('trip_finished') >= 0 ||
        type.indexOf('trip_cancelled') >= 0 ||
        type === 'trip_started' ||
        type === 'trip_finished' ||
        type === 'trip_cancelled'
      ) {
        refreshTrip().catch(function () {
          if (m.trip_status) {
            updateFromTrip({ status: m.trip_status });
          }
        });
      }
    };
    state.ws.onclose = function () {
      if (state.wsCloseIntentional) return;
      scheduleWsReconnect();
    };
    state.ws.onerror = function () {
      try {
        state.ws.close();
      } catch (e) {}
    };
  }

  function scheduleWsReconnect() {
    if (state.wsReconnect) clearTimeout(state.wsReconnect);
    state.wsReconnect = setTimeout(function () {
      state.wsReconnect = null;
      if (state.status === 'FINISHED' || state.status.indexOf('CANCELLED') === 0)
        return;
      connectWebSocket();
    }, 3000);
  }

  function disconnectWs() {
    state.wsCloseIntentional = true;
    if (state.wsReconnect) {
      clearTimeout(state.wsReconnect);
      state.wsReconnect = null;
    }
    if (state.ws) {
      try {
        state.ws.close();
      } catch (e) {}
      state.ws = null;
    }
  }

  /** ---------- Live poll ---------- */
  function startLivePoll() {
    stopLivePoll();
    state.livePollTimer = setInterval(function () {
      if (state.status !== 'STARTED') {
        stopLivePoll();
        return;
      }
      refreshTrip().catch(function () {});
    }, LIVE_TRIP_POLL_INTERVAL_MS);
  }

  function stopLivePoll() {
    if (state.livePollTimer) {
      clearInterval(state.livePollTimer);
      state.livePollTimer = null;
    }
  }

  /** ---------- Actions ---------- */
  function errAuth() {
    alert("Kirish rad etildi. Mini ilovani Telegram orqali oching yoki haydovchi ID to‘g‘ri ekanini tekshiring.");
  }

  el.btnArrived.addEventListener('click', function () {
    if (state.status !== 'WAITING' || state.driverPickupPhase !== 'TO_PICKUP')
      return;
    if (!state.lastDriverLatLng || !state.pickupLatLng) return;
    var d = haversineKm(
      state.lastDriverLatLng.lat,
      state.lastDriverLatLng.lng,
      state.pickupLatLng.lat,
      state.pickupLatLng.lng
    );
    if (d > PICKUP_ARRIVAL_RADIUS_KM) return;
    apiPost('/trip/arrived', { trip_id: String(tripId) })
      .then(function () {
        state.driverPickupPhase = 'ARRIVED';
        syncBanner();
        syncBottom(state.tripJson || {});
        syncButtons();
      })
      .catch(function (e) {
        if (e.message === 'AUTH') errAuth();
        else el.bannerText.textContent = 'Yetib kelishni qayd etib bo‘lmadi';
      });
  });

  el.btnStart.addEventListener('click', function () {
    if (state.status !== 'WAITING' || state.driverPickupPhase !== 'ARRIVED')
      return;
    var did = parseInt(String(driverId), 10);
    apiPost('/trip/start', { trip_id: String(tripId), driver_id: did })
      .then(function () {
        if (navigator.vibrate) navigator.vibrate(200);
        state.tripPath = [];
        if (state.lastDriverLatLng) state.tripPath.push(state.lastDriverLatLng);
        state.status = 'STARTED';
        removePickupMarker();
        clearPickupRouteLayers();
        return refreshTrip();
      })
      .then(function () {
        startLivePoll();
      })
      .catch(function (e) {
        if (e.message === 'AUTH') errAuth();
      });
  });

  el.btnFinish.addEventListener('click', function () {
    var did = parseInt(String(driverId), 10);
    apiPost('/trip/finish', { trip_id: String(tripId), driver_id: did })
      .then(function () {
        return refreshTrip();
      })
      .then(function () {
        if (state.lastDriverLatLng) {
          postDriverLocation(
            state.lastDriverLatLng.lat,
            state.lastDriverLatLng.lng,
            null
          );
        } else if (navigator.geolocation) {
          navigator.geolocation.getCurrentPosition(function (pos) {
            postDriverLocation(
              pos.coords.latitude,
              pos.coords.longitude,
              pos.coords.accuracy
            );
          });
        }
      })
      .catch(function (e) {
        if (e.message === 'AUTH') errAuth();
      });
  });

  el.btnCancel.addEventListener('click', function () {
    var did = parseInt(String(driverId), 10);
    apiPost('/trip/cancel/driver', { trip_id: String(tripId), driver_id: did })
      .then(function () {
        return refreshTrip();
      })
      .then(function () {
        stopGps();
        disconnectWs();
      })
      .catch(function (e) {
        if (e.message === 'AUTH') errAuth();
      });
  });

  /** ---------- Boot ---------- */
  function fitInitial() {
    if (!state.map) return;
    if (state.lastDriverLatLng && state.pickupLatLng && state.status === 'WAITING') {
      state.map.fitBounds(
        L.latLngBounds([state.lastDriverLatLng, state.pickupLatLng]),
        { padding: [80, 40, 80, 40], maxZoom: 16 }
      );
    } else if (state.pickupLatLng) {
      state.map.setView(state.pickupLatLng, 14);
    }
  }

  function boot() {
    if (!tripId || !driverId) {
      showMissing("URL da trip_id va driver_id bo'lishi kerak (?trip_id=…&driver_id=…).");
      return;
    }

    if (window.Telegram && window.Telegram.WebApp) {
      window.Telegram.WebApp.ready();
      window.Telegram.WebApp.expand();
    }

    el.main.hidden = false;
    initMap();
    el.bannerText.textContent = 'Yuklanmoqda…';

    connectWebSocket();

    apiGet('/trip/' + encodeURIComponent(tripId))
      .then(function (j) {
        updateFromTrip(j);
        startGps();
        setTimeout(fitInitial, 600);
        if (normalizeStatus(j.status) === 'STARTED') {
          startLivePoll();
        }
        scheduleOsrmRedraw(true);
      })
      .catch(function () {
        el.notFound.hidden = false;
        el.main.hidden = true;
      });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
