// ── app_shell.dart ─────────────────────────────────────────────────────────────
// The central "controller" widget that owns ALL mutable app state.
// It renders the MapLibre map and conditionally overlays one of three screens:
//
//   1. HomeOverlay  — when _navigating == false && _completed == false
//      (search, route planning, "Start Focus" button)
//
//   2. NavOverlay   — when _navigating == true
//      (turn banner, weather card, bottom bar, stop button)
//
//   3. CompletionOverlay — when _completed == true
//      (confetti, congratulations card, "Start New Session" button)
//
// Map layers managed here (all GeoJSON sources):
//   src-route-remain  — polyline ahead of the car (bright blue)
//   src-route-driven  — polyline behind the car (faded)
//   src-origin        — green circle marker at the starting point
//   src-dest          — red circle marker at the destination
//   src-car           — blue glow + dot at the car's current position

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' as ll;      // latlong2 LatLng (used for route maths)
import 'package:maplibre_gl/maplibre_gl.dart';     // MapLibre LatLng + map controller
import 'models.dart';
import 'services.dart';
import 'theme.dart';
import 'home_overlay.dart';
import 'nav_overlay.dart';
import 'widgets.dart';
import 'dnd_service.dart';

// ── Coordinate conversion helper ──────────────────────────────────────────────
// The app uses two different LatLng types:
//   ll.LatLng   — from latlong2 package, used for distance maths + route data
//   LatLng      — from maplibre_gl package, used for camera and GeoJSON
// This one-liner converts between them wherever needed.
LatLng _ml(ll.LatLng p) => LatLng(p.latitude, p.longitude);

// ── Map style URLs ─────────────────────────────────────────────────────────────
// Day  : OpenFreeMap Liberty — detailed OSM-based style: building footprints,
//         granular road hierarchy, parks, POIs, transit lines. No API key needed.
// Night: CartoDB Dark Matter — high-contrast dark style, easy to read while driving.
// Map styles: OpenFreeMap (day) + CartoDB Dark Matter (night)
// maplibre_gl cannot resolve mapbox:// URLs — keep these as plain HTTPS.
const _styleDay   = 'https://tiles.openfreemap.org/styles/liberty';
const _styleNight = 'https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json';

// ── GeoJSON source IDs ─────────────────────────────────────────────────────────
// Constant strings used as keys when registering/updating MapLibre data sources.
const _srcRouteRemain = 'src-route-remain';
const _srcRouteDriven = 'src-route-driven';
const _srcOrigin      = 'src-origin';
const _srcDest        = 'src-dest';
const _srcCar         = 'src-car';

// Empty FeatureCollection as a Map (not a String) — iOS MapLibre requires Map
// We use this to "clear" a source without removing it from the style.
Map<String, dynamic> get _emptyFC => {'type': 'FeatureCollection', 'features': <dynamic>[]};

// ── AppShell ───────────────────────────────────────────────────────────────────

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

// TickerProviderStateMixin is required because AppShell hosts AnimationControllers
// indirectly via WidgetsBinding timers. Even without explicit controllers here,
// the mixin is kept for forward compatibility with future animated elements.
class _AppShellState extends State<AppShell> with TickerProviderStateMixin {

  // ── Map controller ─────────────────────────────────────────────────────────
  MapLibreMapController? _mapCtrl; // Null until onMapCreated fires
  bool _layersReady = false;        // True after all GeoJSON sources + layers are added
  bool _styleLoading = false;       // Guard against re-entrant _setupLayers calls

  // ── Route planning state ───────────────────────────────────────────────────
  Place? _origin;           // Selected starting location
  Place? _dest;             // Selected destination
  RouteData? _route;        // Fetched route polyline + steps + distance/duration
  String? _pickMode;        // 'origin' or 'dest' when map-tap-to-pin is active
  bool _routeLoading = false; // True while OSRM fetch is in-flight
  int _routeGen = 0;          // Incremented on every new request; stale responses are dropped

  // ── Navigation / session state ─────────────────────────────────────────────
  bool _navigating = false;     // True while a session is in progress
  bool _completed = false;      // True after the timer reaches zero
  int _studyMinutes = 25;       // Duration chosen by the user
  DateTime? _studyStartTime;    // Wall-clock time the session began
  double _progress = 0;         // 0.0 → 1.0: fraction of route driven

  // ── Vehicle simulation state ───────────────────────────────────────────────
  ll.LatLng _carPos = const ll.LatLng(40.748, -73.985); // Default: Manhattan
  double _carBearing = 0; // Current heading in degrees (0 = north, 90 = east)

  // ── Weather & units state ──────────────────────────────────────────────────
  WeatherData? _weather;
  bool _useCelsius = true;       // Toggle by tapping the weather card
  bool _useImperial = false;     // Auto-switched at US/Canada border
  String _countryCode = '';      // ISO code of current car position ("us", "ca", …)

  // ── Location display state ─────────────────────────────────────────────────
  String _locationText  = 'Locating...'; // "Neighbourhood, City" — bottom bar row 1
  String _locationState = '';            // "State/Province" — bottom bar row 2
  String _countryName   = '';            // Full country name shown in the country chip

  // ── Display state ──────────────────────────────────────────────────────────
  bool _nightMode = true; // Mirrors system dark/light mode; drives map style URL

  // ── Timers ────────────────────────────────────────────────────────────────
  Timer? _navTimer;     // Fires every 50ms during navigation to advance the car
  Timer? _weatherTimer; // Fires every 5s during navigation to refresh weather

  // ── Internal counters ──────────────────────────────────────────────────────
  DateTime? _lastLocUpdate; // Throttles reverse-geocode calls (max 1 req/s — Nominatim limit)
  int _tickCount = 0;       // Counts nav ticks; used to throttle route redraws

  // Guard flags — prevent concurrent GeoJSON writes crashing the native layer
  // MapLibre's native layer can crash (especially on iOS) if two coroutines
  // try to update the same source at the same time.
  bool _updatingCar     = false;
  bool _updatingRoute   = false;
  bool _updatingMarkers = false;

  // ── didChangeDependencies ──────────────────────────────────────────────────
  // Called whenever the inherited widgets (like MediaQuery) change.
  // We use this to detect system theme changes (light ↔ dark) and swap the
  // map style accordingly.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isDark = MediaQuery.of(context).platformBrightness == Brightness.dark;
    if (isDark != _nightMode) {
      setState(() {
        _nightMode = isDark;
        _layersReady = false; // force layer rebuild on new style
      });
    }
  }

  @override
  void dispose() {
    // Always cancel timers to avoid callbacks firing after the widget is unmounted
    _navTimer?.cancel();
    _weatherTimer?.cancel();
    super.dispose();
  }

  // ═══════════════════════════════════════
  // MAP LIFECYCLE
  // ═══════════════════════════════════════

  // Called by MapLibre once the map widget has been created and the native
  // map view is ready. We store the controller so other methods can use it.
  void _onMapCreated(MapLibreMapController ctrl) {
    _mapCtrl = ctrl;
  }

  // CRITICAL: _onStyleLoaded must never throw — iOS SIGABRT on uncaught
  // exceptions inside MapLibre callbacks. Wrapped in try/catch + mounted guard.
  // Called every time the map loads a new style (on startup and on day/night switch).
  Future<void> _onStyleLoaded() async {
    // Re-entrant guard: if we're already in the middle of setup, skip this call
    if (_styleLoading || _layersReady) return;
    _styleLoading = true;
    try {
      await _setupLayers();
    } catch (e) {
      debugPrint('MapLibre style setup error: $e');
      _layersReady = false; // Will retry on next style load
    } finally {
      _styleLoading = false;
    }
  }

  // ── Layer setup ───────────────────────────────────────────────────────────
  // Adds all GeoJSON sources and their visual layers to the map style.
  // Must be called after the style has loaded — sources don't survive style changes.
  // Each mounted check after an await prevents crashes when the widget is disposed
  // mid-setup (e.g. user kills the app during startup).
  Future<void> _setupLayers() async {
    final ctrl = _mapCtrl;
    if (ctrl == null || !mounted) return;

    // ── Add GeoJSON sources (all empty Maps, not JSON strings) ──
    // Each source is registered once; we update its data later with setGeoJsonSource.
    await ctrl.addSource(_srcRouteRemain, GeojsonSourceProperties(data: _emptyFC));
    if (!mounted) return;
    await ctrl.addSource(_srcRouteDriven, GeojsonSourceProperties(data: _emptyFC));
    if (!mounted) return;
    await ctrl.addSource(_srcOrigin, GeojsonSourceProperties(data: _emptyFC));
    if (!mounted) return;
    await ctrl.addSource(_srcDest, GeojsonSourceProperties(data: _emptyFC));
    if (!mounted) return;
    await ctrl.addSource(_srcCar, GeojsonSourceProperties(data: _emptyFC));
    if (!mounted) return;

    // Choose colours based on map style (night = dark bg, day = light bg)
    // Route colours: night = blue glow + white core (dark map)
    //                day  = solid navy + bright blue core (light Voyager map)
    final glowColor   = _nightMode ? C.blue.toHex()  : '#1D4ED8';
    final coreColor   = _nightMode ? '#FFFFFF'        : '#2563EB';
    final haloOpacity = _nightMode ? 0.07             : 0.10;
    final glowOpacity = _nightMode ? 0.30             : 0.22;
    final strokeColor = _nightMode ? '#FFFFFF'        : '#1A1A2E';

    // ── Route remaining: glow stack ──
    // Three overlapping line layers create a glowing effect:
    //   halo  — very wide, almost transparent (outer glow corona)
    //   glow  — medium, semi-transparent (inner glow)
    //   core  — narrow, near-opaque (the visible route line)
    await ctrl.addLineLayer(_srcRouteRemain, 'route-halo', LineLayerProperties(
      lineColor: glowColor, lineWidth: 24.0,
      lineOpacity: haloOpacity, lineCap: 'round', lineJoin: 'round',
    ));
    if (!mounted) return;
    await ctrl.addLineLayer(_srcRouteRemain, 'route-glow', LineLayerProperties(
      lineColor: glowColor, lineWidth: 10.0,
      lineOpacity: glowOpacity, lineCap: 'round', lineJoin: 'round',
    ));
    if (!mounted) return;
    await ctrl.addLineLayer(_srcRouteRemain, 'route-core', LineLayerProperties(
      lineColor: coreColor, lineWidth: 4.0, lineOpacity: 0.95,
      lineCap: 'round', lineJoin: 'round',
    ));
    if (!mounted) return;

    // ── Route driven: faded ──
    // A single low-opacity line shows the path already travelled.
    await ctrl.addLineLayer(_srcRouteDriven, 'route-driven', LineLayerProperties(
      lineColor: glowColor, lineWidth: 4.0,
      lineOpacity: 0.18, lineCap: 'round', lineJoin: 'round',
    ));
    if (!mounted) return;

    // ── Origin marker — green circle with white/dark stroke ──
    await ctrl.addCircleLayer(_srcOrigin, 'marker-origin', CircleLayerProperties(
      circleRadius: 10.0, circleColor: C.accent.toHex(),
      circleStrokeWidth: 3.0, circleStrokeColor: strokeColor,
    ));
    if (!mounted) return;

    // ── Dest marker — red circle with white/dark stroke ──
    await ctrl.addCircleLayer(_srcDest, 'marker-dest', CircleLayerProperties(
      circleRadius: 10.0, circleColor: C.red.toHex(),
      circleStrokeWidth: 3.0, circleStrokeColor: strokeColor,
    ));
    if (!mounted) return;

    // ── Car: glow ring + core dot ─────────────────────────────────────────────
    await ctrl.addCircleLayer(_srcCar, 'car-glow', CircleLayerProperties(
      circleRadius: 22.0,
      circleColor: C.blue.toHex(),
      circleOpacity: 0.2,
    ));
    if (!mounted) return;
    await ctrl.addCircleLayer(_srcCar, 'car-dot', CircleLayerProperties(
      circleRadius: 10.0, circleColor: C.blue.toHex(),
      circleStrokeWidth: 3.0, circleStrokeColor: '#FFFFFF',
    ));
    if (!mounted) return;

    _layersReady = true;
    _redrawAll(); // Populate sources with whatever data we already have
  }

  // ═══════════════════════════════════════
  // GEOJSON HELPERS
  // ═══════════════════════════════════════

  // Build a GeoJSON FeatureCollection containing a single LineString.
  // coords are in latlong2 format; we swap to [lng, lat] as GeoJSON requires.
  static Map<String, dynamic> _lineFC(List<ll.LatLng> coords) => {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'geometry': {
              'type': 'LineString',
              'coordinates': coords.map((c) => [c.longitude, c.latitude]).toList(),
            },
            'properties': <String, dynamic>{},
          }
        ],
      };

  // Build a GeoJSON FeatureCollection containing a single Point (for markers).
  static Map<String, dynamic> _pointFC(ll.LatLng pos) => {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [pos.longitude, pos.latitude],
            },
            'properties': <String, dynamic>{},
          }
        ],
      };

  // ═══════════════════════════════════════
  // SOURCE UPDATES — always called on main thread via setState/Timer
  // ═══════════════════════════════════════

  // Convenience: refresh all five sources at once.
  void _redrawAll() {
    _updateMarkers();
    _updateRoute();
    _updateCar();
  }

  // Push the latest origin/dest marker positions to the map.
  // Uses Future.wait so both sources update in parallel (faster on iOS).
  void _updateMarkers() {
    final ctrl = _mapCtrl;
    if (ctrl == null || !_layersReady || _updatingMarkers || !mounted) return;
    _updatingMarkers = true;
    Future.wait([
      ctrl.setGeoJsonSource(_srcOrigin,
          _origin != null ? _pointFC(_origin!.position) : _emptyFC),
      ctrl.setGeoJsonSource(_srcDest,
          _dest != null ? _pointFC(_dest!.position) : _emptyFC),
    ]).whenComplete(() => _updatingMarkers = false);
  }

  // Push the current route polyline (split into driven + remaining) to the map.
  // During navigation: splits at the car's current position index.
  // Pre-navigation: the full route goes into "remaining", "driven" is empty.
  void _updateRoute() {
    final ctrl = _mapCtrl;
    if (ctrl == null || !_layersReady || _updatingRoute || _route == null || !mounted) return;
    _updatingRoute = true;

    if (_navigating) {
      // Find the index in the coordinates list that the car is at
      final idx = _route!.indexAtProgress(_progress);
      // "Driven" = everything from the start up to (and including) the car
      final driven = List<ll.LatLng>.from(_route!.coordinates.sublist(0, idx + 1))
        ..add(_carPos); // Append car's current interpolated position for smooth join
      // "Remaining" = car's position forward to the destination
      final remain = [_carPos, ..._route!.coordinates.sublist(idx + 1)];
      Future.wait([
        ctrl.setGeoJsonSource(_srcRouteRemain, _lineFC(remain)),
        ctrl.setGeoJsonSource(_srcRouteDriven, _lineFC(driven)),
      ]).whenComplete(() => _updatingRoute = false);
    } else {
      // Pre-navigation: show the full route as "remaining", no driven segment
      Future.wait([
        ctrl.setGeoJsonSource(_srcRouteRemain, _lineFC(_route!.coordinates)),
        ctrl.setGeoJsonSource(_srcRouteDriven, _emptyFC),
      ]).whenComplete(() => _updatingRoute = false);
    }
  }

  // Push the car marker to the map. Hidden when not navigating.
  void _updateCar() {
    final ctrl = _mapCtrl;
    if (ctrl == null || !_layersReady || _updatingCar || !mounted) return;
    _updatingCar = true;
    ctrl
        .setGeoJsonSource(_srcCar, _navigating ? _pointFC(_carPos) : _emptyFC)
        .whenComplete(() => _updatingCar = false);
  }

  // ═══════════════════════════════════════
  // CAMERA
  // ═══════════════════════════════════════

  // Smoothly fly the camera to a single point (used when a location is chosen).
  void _flyTo(ll.LatLng pos, {double zoom = 14}) {
    _mapCtrl?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: _ml(pos), zoom: zoom)),
      duration: const Duration(milliseconds: 700),
    );
  }

  // Zoom-to-fit the entire route polyline with comfortable padding on all sides.
  // The bottom padding (330) leaves room for the HomeOverlay sheet.
  void _fitToRoute() {
    if (_route == null || _mapCtrl == null) return;
    final coords = _route!.coordinates;
    // Compute bounding box of all route coordinates
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final c in coords) {
      minLat = min(minLat, c.latitude);
      maxLat = max(maxLat, c.latitude);
      minLng = min(minLng, c.longitude);
      maxLng = max(maxLng, c.longitude);
    }
    _mapCtrl!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        left: 60, top: 100, right: 60, bottom: 330,
      ),
      duration: const Duration(milliseconds: 900),
    );
  }

  // During navigation: keep the camera locked behind the car with a 45° tilt and
  // heading in the direction of travel. Called every ~50ms from _navTick.
  void _navCamera() {
    _mapCtrl?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(
        target: _ml(_carPos),
        zoom: 16.5,  // Closer in — shows street-level detail and building faces
        tilt: 60,    // Steeper forward tilt — more "driving down the road" feel
        bearing: _carBearing,
      )),
      duration: const Duration(milliseconds: 300),
    );
  }

  // ═══════════════════════════════════════
  // MAP TAP
  // ═══════════════════════════════════════

  // Called whenever the user taps the map.
  // In map-pick mode: reverse-geocodes the tapped point and assigns it as
  // origin or destination, then attempts to fetch a route.
  void _onMapTap(Point<double> screenPt, LatLng latlng) async {
    // Always dismiss the keyboard when the user taps the map
    FocusManager.instance.primaryFocus?.unfocus();

    // Ignore taps outside of map-pick mode or while navigation is active
    if (_pickMode == null || _navigating) return;

    final which = _pickMode!; // Capture before setState clears it
    // Clear the previous route immediately — the map tap starts a new pin,
    // so stale route data and its map layers should not linger.
    setState(() {
      _pickMode     = null;
      _route        = null;
      _routeLoading = false;
    });
    if (_mapCtrl != null && _layersReady) {
      _mapCtrl!.setGeoJsonSource(_srcRouteRemain, _emptyFC);
      _mapCtrl!.setGeoJsonSource(_srcRouteDriven, _emptyFC);
    }

    final pos = ll.LatLng(latlng.latitude, latlng.longitude);
    // Reverse-geocode to get a human-readable place name for the tapped spot
    final place = await ApiService.reverseGeocode(pos);
    if (place == null || !mounted) return;

    if (which == 'origin') {
      setState(() => _origin = place);
    } else {
      setState(() => _dest = place);
    }
    _updateMarkers();
    _tryRoute(); // Automatically fetch a route if both points are now set
  }

  // ═══════════════════════════════════════
  // ROUTING
  // ═══════════════════════════════════════

  // Fetches a route from OSRM between _origin and _dest.
  // Does nothing if either point is missing.
  // A generation counter (_routeGen) is incremented on every call so that if
  // the user changes origin/dest while a fetch is in-flight, the stale response
  // is silently discarded and only the latest request takes effect.
  void _tryRoute() async {
    if (_origin == null || _dest == null) return;
    final gen = ++_routeGen; // Capture generation for this request
    debugPrint('[Route] _tryRoute called gen=$gen origin=${_origin!.position} dest=${_dest!.position}');
    setState(() => _routeLoading = true);
    RouteData? route;
    try {
      route = await ApiService.getRoute(_origin!.position, _dest!.position);
    } catch (e) {
      debugPrint('[Route] exception: $e');
      route = null;
    }
    if (!mounted) return;
    debugPrint('[Route] response received gen=$gen currentGen=$_routeGen route=${route == null ? "null" : "ok"}');
    // Always clear the spinner — prevents stuck loading state regardless of outcome.
    setState(() => _routeLoading = false);
    // Drop stale result if a newer request has since been issued.
    if (gen != _routeGen) {
      debugPrint('[Route] dropping stale response gen=$gen != currentGen=$_routeGen');
      return;
    }

    if (route == null) {
      _showNoRouteDialog();
      return;
    }

    route.computeCumulativeDistances();
    setState(() => _route = route);
    _updateRoute();
    _fitToRoute();
  }

  // ── Focus Mode dialog (iOS) ────────────────────────────────────────────────
  // iOS doesn't allow programmatic DND, so we show a manual instruction dialog.
  // ── No Route dialog ────────────────────────────────────────────────────────
  // Shown when OSRM can't find a drivable path (ocean crossing, etc.).
  void _showNoRouteDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF0E111C),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        title: const Text('🌊 No Route Found',
            style: TextStyle(color: C.text, fontSize: 18, fontWeight: FontWeight.w700)),
        content: const Text(
          "We couldn't find a drivable route between those two points.\n\n"
          "Ocean crossings and intercontinental routes aren't supported — "
          "try two locations in the same region.",
          style: TextStyle(color: C.textDim, fontSize: 14, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it', style: TextStyle(color: C.blue, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ── Clear all state ────────────────────────────────────────────────────────
  // Resets origin, dest, route, and pickMode and wipes the corresponding map layers.
  void _clear() {
    debugPrint('[Route] _clear() bumping routeGen $_routeGen → ${_routeGen + 1}');
    _routeGen++; // Cancel any in-flight OSRM fetch
    setState(() {
      _origin       = null;
      _dest         = null;
      _route        = null;
      _routeLoading = false;
      _pickMode = null;
    });
    if (_mapCtrl != null && _layersReady) {
      _mapCtrl!.setGeoJsonSource(_srcOrigin, _emptyFC);
      _mapCtrl!.setGeoJsonSource(_srcDest, _emptyFC);
      _mapCtrl!.setGeoJsonSource(_srcRouteRemain, _emptyFC);
      _mapCtrl!.setGeoJsonSource(_srcRouteDriven, _emptyFC);
    }
  }

  // ═══════════════════════════════════════
  // NAVIGATION
  // ═══════════════════════════════════════

  // Called when the user taps "Start Focus" in HomeOverlay.
  // Sets up all navigation state and starts the animation + weather timers.
  void _startNavigation(int minutes) {
    if (_route == null) return;

    // Apply units immediately from origin country so the very first frame is correct.
    // Border-crossing logic in _navTick will refine this as the car moves.
    final originCC   = ApiService.countryCode(_origin?.address);
    final originName = _origin?.address['country']?.toString() ?? '';
    if (originCC.isNotEmpty) {
      _countryCode = originCC;
      _countryName = originName;
      _useImperial = (originCC == 'us');
      _useCelsius  = (originCC != 'us');
    }

    setState(() {
      _studyMinutes  = minutes;
      _studyStartTime = DateTime.now();
      _navigating    = true;
      _completed     = false;
      _progress      = 0;
      _carPos        = _route!.coordinates.first; // Start at origin
      _carBearing    = 0;
      _tickCount     = 0;
    });

    // Short delay so the setState above settles before we animate the camera —
    // avoids the camera trying to move to the route start while the map is still
    // adjusting from the "fit to route" view.
    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      _mapCtrl?.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(
          target: _ml(_route!.coordinates.first),
          zoom: 16.5, tilt: 60, bearing: 0,
        )),
        duration: const Duration(milliseconds: 1000),
      );
    });

    _updateCar();

    // Fetch weather immediately at session start, then every 5 seconds.
    _fetchWeatherAtCar();
    _weatherTimer = Timer.periodic(const Duration(seconds: 5), (_) => _fetchWeatherAtCar());

    // Main simulation tick: advances the car along the route every 50ms (≈ 20fps).
    _navTimer = Timer.periodic(const Duration(milliseconds: 50), (_) => _navTick());

    // Ask for / enable DND so notifications don't interrupt the study session.
    _enableDnd();
  }

  // ── Enable Do Not Disturb ──────────────────────────────────────────────────
  // Android: checks for permission; enables DND if granted, else shows a snackbar.
  // iOS: handled separately by the Focus Mode dialog (not called here).
  Future<void> _enableDnd() async {
    if (Platform.isAndroid) {
      final granted = await DndService.hasPermission();
      if (granted) {
        await DndService.enable();
      } else if (mounted) {
        // Show a non-blocking snackbar with an "Allow" action that opens settings
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Allow NavStudy to enable Do Not Disturb during study sessions.'),
            action: SnackBarAction(
              label: 'Allow',
              onPressed: DndService.requestPermission,
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    }
  }

  // ── Weather fetch ──────────────────────────────────────────────────────────
  // Captures the current car position at the moment of the call to avoid
  // stale closures (the car will have moved by the time the HTTP response arrives).
  void _fetchWeatherAtCar() {
    // Capture pos so it doesn't change by the time the future resolves
    final pos = _carPos;
    ApiService.getWeather(pos).then((w) {
      if (mounted && w != null) setState(() => _weather = w);
    });
  }

  // ── Navigation tick ────────────────────────────────────────────────────────
  // Called every 50ms by _navTimer. Each tick:
  //   1. Computes progress based on elapsed wall-clock time vs study duration.
  //   2. Interpolates the car's position along the route polyline.
  //   3. Smoothly blends the heading toward the next segment's bearing.
  //   4. Updates the car marker on the map (every tick).
  //   5. Updates the route split (every 4th tick — ~5fps is enough).
  //   6. Moves the camera to follow the car.
  //   7. Every 10 seconds: reverse-geocodes the car's position to update the
  //      location text and detect border crossings.
  //   8. When progress reaches 1.0: ends the session and shows CompletionOverlay.
  void _navTick() {
    if (!_navigating || _route == null || _studyStartTime == null || !mounted) return;

    // ── Progress calculation ──
    final totalMs = _studyMinutes * 60 * 1000;
    final elapsed = DateTime.now().difference(_studyStartTime!).inMilliseconds;
    final progress = (elapsed / totalMs).clamp(0.0, 1.0);

    // ── Car position ──
    final pos   = _route!.interpolate(progress); // Exact lat/lng at this progress
    // Look slightly ahead on the route to get the direction of travel
    final ahead = _route!.interpolate((progress + 0.008).clamp(0.0, 1.0));
    final targetBearing = _calcBearing(pos, ahead);

    // ── Smooth heading ──
    // Linearly interpolate 12% toward the target bearing each tick so the map
    // rotation feels gradual rather than snapping on curves.
    final smoothBearing = _lerpBearing(_carBearing, targetBearing, 0.12);

    setState(() {
      _progress   = progress;
      _carPos     = pos;
      _carBearing = smoothBearing;
      _tickCount++;
    });

    _updateCar();
    // Redraw route split every 4 ticks (~200ms) — more than fast enough visually
    if (_tickCount % 4 == 0) _updateRoute();
    _navCamera(); // Follow the car

    // ── Reverse-geocode (throttled to 1 req/s — Nominatim's hard rate limit) ──
    // 1-second cadence means border crossings, country name, and units all
    // update within ~1 second of the car actually crossing the line.
    if (_lastLocUpdate == null ||
        DateTime.now().difference(_lastLocUpdate!).inMilliseconds > 1000) {
      _lastLocUpdate = DateTime.now();
      ApiService.reverseGeocode(pos).then((p) {
        if (!mounted || p == null) return;
        final cc = ApiService.countryCode(p.address);
        setState(() {
          // ── Border crossing: auto-switch measurement & temperature units ──
          // US uses imperial (miles, °F); everywhere else (incl. Canada) metric.
          final parts = ApiService.formatLocationParts(p.address);
          _locationText  = parts.$1; // "Neighbourhood, City"
          _locationState = parts.$2; // "State / Province"

          // ── Border crossing: auto-switch measurement & temperature units ──
          // US uses imperial (miles, °F); everywhere else (incl. Canada) metric.
          if (cc.isNotEmpty && cc != _countryCode) {
            _countryCode = cc;
            _countryName = p.address['country']?.toString() ?? _countryName;
            _useImperial = (cc == 'us');
            _useCelsius  = (cc != 'us');
          }
        });
      });
    }

    // ── Session complete ──
    if (progress >= 1) {
      _navTimer?.cancel();
      _weatherTimer?.cancel();
      DndService.disable(); // Restore normal notifications
      setState(() {
        _navigating = false;
        _completed  = true;  // Switch to CompletionOverlay
      });
      // Zoom out and level the camera so the completion card is visible
      _mapCtrl?.animateCamera(
        CameraUpdate.newCameraPosition(
            CameraPosition(target: _ml(_carPos), zoom: 13, tilt: 0, bearing: 0)),
        duration: const Duration(milliseconds: 800),
      );
    }
  }

  // ── Stop navigation early ──────────────────────────────────────────────────
  // Triggered by the red stop button in NavOverlay.
  // Clears the route immediately so no stale preview appears, then delays
  // clearing origin/dest to let the camera animation finish first.
  void _stopNavigation() {
    _navTimer?.cancel();
    _weatherTimer?.cancel();
    DndService.disable();

    // Snap the camera back to the start of the route before clearing
    final snapPos = _route?.coordinates.first ?? _carPos;

    // Clear route and all session state immediately so nothing lingers
    setState(() {
      _navigating    = false;
      _progress      = 0;
      _route         = null;
      _weather       = null;
      _locationText  = 'Locating...';
      _locationState = '';
      _countryName   = '';
      _carBearing    = 0;
      _tickCount     = 0;
      _lastLocUpdate = null;
    });

    // Wipe map layers right away too
    if (_mapCtrl != null && _layersReady) {
      _mapCtrl!.setGeoJsonSource(_srcRouteRemain, _emptyFC);
      _mapCtrl!.setGeoJsonSource(_srcRouteDriven, _emptyFC);
      _mapCtrl!.setGeoJsonSource(_srcOrigin, _emptyFC);
      _mapCtrl!.setGeoJsonSource(_srcDest, _emptyFC);
    }
    _updateCar(); // Hide the car dot

    _mapCtrl?.animateCamera(
      CameraUpdate.newCameraPosition(
          CameraPosition(target: _ml(snapPos), zoom: 12, tilt: 0, bearing: 0)),
      duration: const Duration(milliseconds: 800),
    );
    _clear(); // Reset origin, dest, route and all map layers
  }

  // ── Session completed callback ─────────────────────────────────────────────
  // Called when the user taps "Start New Session" in CompletionOverlay.
  // Same logic as _stopNavigation but starts from _completed=true state.
  void _onComplete() {
    final snapPos = _route?.coordinates.first ?? _carPos;

    setState(() {
      _completed     = false;
      _weather       = null;
      _locationText  = 'Locating...';
      _locationState = '';
      _countryName   = '';
      _carBearing    = 0;
      _tickCount     = 0;
      _lastLocUpdate = null;
    });

    _updateCar();

    _mapCtrl?.animateCamera(
      CameraUpdate.newCameraPosition(
          CameraPosition(target: _ml(snapPos), zoom: 12, tilt: 0, bearing: 0)),
      duration: const Duration(milliseconds: 800),
    );
    _clear(); // Reset origin, dest, route and all map layers
  }

  // ═══════════════════════════════════════
  // MATH
  // ═══════════════════════════════════════

  // ── Bearing calculation ────────────────────────────────────────────────────
  // Computes the forward azimuth (bearing in degrees) from point a to point b
  // using the standard spherical trigonometry formula.
  // Result is normalised to [0, 360).
  double _calcBearing(ll.LatLng a, ll.LatLng b) {
    final dLon = (b.longitude - a.longitude) * pi / 180;
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  // ── Bearing interpolation ─────────────────────────────────────────────────
  // Linearly interpolates from [cur] toward [target] by fraction t, handling
  // the 0°/360° wrap-around correctly (e.g. 350° → 10° goes the short way).
  double _lerpBearing(double cur, double target, double t) {
    // Map the difference into [-180, +180] so we always turn the short way
    final diff = ((target - cur + 540) % 360) - 180;
    return (cur + diff * t + 360) % 360;
  }

  // ═══════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── Layer 0: MapLibre map (always present, fills the screen) ──
          _buildMap(),

          // ── Layer 1: HomeOverlay — shown before/after a session ──
          // Hidden while navigating or showing the completion screen.
          if (!_navigating && !_completed)
            HomeOverlay(
              origin: _origin,
              dest: _dest,
              route: _route,
              isLoadingRoute: _routeLoading,
              pickMode: _pickMode,
              carPos: _carPos,
              onOriginSet: (p) {
                setState(() => _origin = p);
                _updateMarkers();
                _flyTo(p.position); // Pan the map to the chosen location
                _tryRoute();
              },
              onDestSet: (p) {
                setState(() => _dest = p);
                _updateMarkers();
                _flyTo(p.position);
                _tryRoute();
              },
              onClear: _clear,
              onGetRoute: _tryRoute,
              onPickModeChanged: (m) => setState(() => _pickMode = m),
              onStartNavigation: _startNavigation,
            ),

          // ── Layer 2: NavOverlay — shown during an active session ──
          if (_navigating && _route != null)
            NavOverlay(
              route: _route!,
              progress: _progress,
              studyMinutes: _studyMinutes,
              studyStartTime: _studyStartTime!,
              weather: _weather,
              useCelsius: _useCelsius,
              useImperial: _useImperial,
              locationText: _locationText,
              locationState: _locationState,
              countryCode: _countryCode,
              countryName: _countryName,
              // Prefer the full label; fall back to short name; ultimate fallback = "Destination"
              destName: _dest?.label ?? _dest?.shortName ?? 'Destination',
              onStop: _stopNavigation,
              onToggleTemp: () => setState(() => _useCelsius = !_useCelsius),
            ),

          // ── Layer 3: CompletionOverlay — shown after the timer ends ──
          if (_completed)
            CompletionOverlay(
              studyMinutes: _studyMinutes,
              onDone: _onComplete,
            ),

        ],
      ),
    );
  }

  // ── Map widget builder ─────────────────────────────────────────────────────
  // Configures the MapLibre widget. Note:
  //   - All gesture inputs are disabled during navigation so the user can't
  //     accidentally pan/zoom the auto-following camera.
  //   - myLocationEnabled is false — we use our own simulated car position.
  Widget _buildMap() {
    return MapLibreMap(
      // Switch between dark and light tile set based on system theme
      styleString: _nightMode ? _styleNight : _styleDay,
      initialCameraPosition: const CameraPosition(
        target: LatLng(40.748, -73.985), // Default: Midtown Manhattan
        zoom: 12,
      ),
      onMapCreated: _onMapCreated,
      onStyleLoadedCallback: _onStyleLoaded,
      onMapClick: _onMapTap,
      compassEnabled: false,           // We handle direction in the nav banner
      myLocationEnabled: false,        // No real GPS — using simulated position
      // Lock all gestures during navigation so the auto-follow camera isn't interrupted
      rotateGesturesEnabled: !_navigating,
      tiltGesturesEnabled: !_navigating,
      scrollGesturesEnabled: !_navigating,
      zoomGesturesEnabled: !_navigating,
      doubleClickZoomEnabled: !_navigating,
      trackCameraPosition: false,      // We don't need the camera to report back
    );
  }
}

// ── Color → hex string extension ──────────────────────────────────────────────
// MapLibre layer properties expect colour as a CSS hex string like "#4A9CFF".
// This extension converts a Flutter Color to that format without any dependency.
extension _ColorHex on Color {
  String toHex() =>
      '#${(r * 255).round().toRadixString(16).padLeft(2, '0')}'
      '${(g * 255).round().toRadixString(16).padLeft(2, '0')}'
      '${(b * 255).round().toRadixString(16).padLeft(2, '0')}';
}
