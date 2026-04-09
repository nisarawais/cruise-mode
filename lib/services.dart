// ── services.dart ──────────────────────────────────────────────────────────────
// All network calls to external APIs are centralised here in ApiService.
// Nothing in this file touches Flutter widgets — it is pure Dart + http.
//
// External APIs used:
//   Foursquare (geocoding, primary)  — https://api.foursquare.com/v3  (free key)
//   Nominatim  (geocoding, fallback) — https://nominatim.openstreetmap.org  (free)
//   Photon     (geocoding, fallback) — https://photon.komoot.io  (free, no key)
//   Nominatim  (reverse-geo)         — https://nominatim.openstreetmap.org
//   Mapbox     (routing)             — https://api.mapbox.com/directions  (free key)
//   Open-Meteo (weather)             — https://api.open-meteo.com  (free, no key)

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'config.dart';
import 'models.dart';

class ApiService {
  // ── Base URLs ──────────────────────────────────────────────────────────────────

  // Nominatim: reverse geocoding + address forward-search fallback.
  static const _nominatim = 'https://nominatim.openstreetmap.org';

  // Foursquare Places: primary forward geocoder — 200M+ curated venues worldwide,
  // excellent for POIs (businesses, gyms, restaurants, malls, etc.).
  // Free tier: 100k API calls / month. No credit card required.
  static const _fsq    = 'https://api.foursquare.com/v3';
  static const _fsqKey = Config.foursquareKey; // set in lib/config.dart (gitignored)

  // Mapbox Directions: best-in-class navigation instructions, 100k req/month free.
  static const _mapboxToken = Config.mapboxToken; // set in lib/config.dart (gitignored)
  static const _mapbox = 'https://api.mapbox.com';

  // Open-Meteo: free weather API — no key needed, returns WMO codes + sunrise/sunset.
  static const _openMeteo = 'https://api.open-meteo.com';

  // A single shared HTTP client reuses the TCP connection across requests.
  static final _client = http.Client();

  // Headers sent with every request: prefer English results, identify our app.
  static const _headers = {'Accept-Language': 'en', 'User-Agent': 'NavStudy/1.0'};

  // ── Geocoding ─────────────────────────────────────────────────────────────────
  // Primary:  Foursquare Places — 200M+ venues, best free POI database.
  //           Handles businesses, gyms, malls, restaurants etc. perfectly.
  // Fallback: Nominatim — same OSM server used for reverse geocoding.
  //           Better for raw address queries ("49 Livingstone St W").
  //           Triggered automatically when the query looks address-like (contains
  //           digits) AND Foursquare returned fewer than 3 results.
  // Final:    Photon — always-free OSM geocoder as last resort.
  //
  // After every call the results are re-sorted by straight-line distance to
  // [near] so the closest option is always first regardless of API ranking.

  static const _photon = 'https://photon.komoot.io';

  /// Returns true if the query looks like a street address (has a digit).
  /// Used to decide whether to also run Nominatim alongside Foursquare.
  static bool _looksLikeAddress(String q) => RegExp(r'\d').hasMatch(q);

  /// Geocode [query]. Strategy:
  ///   1. Foursquare Places (primary — best POI coverage)
  ///   2. If < 3 results AND query has digits → also run Nominatim and merge
  ///   3. If still empty → Photon
  ///   4. Sort everything by distance to [near]
  static Future<List<Place>> geocode(String query, {LatLng? near}) async {
    List<Place> places = await _geocodeFoursquare(query, near: near);

    // For address-like queries, supplement with Nominatim so street numbers work
    if (places.length < 3 && _looksLikeAddress(query)) {
      final nomPlaces = await _geocodeNominatim(query, near: near);
      for (final p in nomPlaces) {
        // Deduplicate: skip if another result is already within ~100 m
        final isDup = places.any((e) => _sqDist(e.position, p.position) < 1e-6);
        if (!isDup) places.add(p);
      }
    }

    if (places.isEmpty) {
      debugPrint('[Geocode] Foursquare + Nominatim empty, falling back to Photon');
      places = await _geocodePhoton(query, near: near);
    }

    // Re-sort by straight-line distance so the closest result is always #1
    if (near != null && places.length > 1) {
      places.sort((a, b) =>
          _sqDist(near, a.position).compareTo(_sqDist(near, b.position)));
    }

    return places;
  }

  // ── Foursquare Places geocoder ────────────────────────────────────────────
  // Uses the /places/search endpoint with a 50 km radius around [near].
  // Returns up to 10 results ranked by Foursquare's relevance + proximity score.
  static Future<List<Place>> _geocodeFoursquare(String query,
      {LatLng? near}) async {
    final ll = near != null ? '&ll=${near.latitude},${near.longitude}&radius=50000' : '';
    final url = Uri.parse(
      '$_fsq/places/search?query=${Uri.encodeComponent(query)}&limit=10$ll',
    );
    try {
      final res = await _client.get(url, headers: {
        ..._headers,
        'Authorization': _fsqKey,
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 8));

      if (res.statusCode != 200) {
        debugPrint('[Geocode] Foursquare status ${res.statusCode}');
        return [];
      }
      final data    = jsonDecode(res.body) as Map<String, dynamic>;
      final results = data['results'] as List? ?? [];
      return results
          .map((f) => _parseFoursquarePlace(f as Map<String, dynamic>))
          .whereType<Place>()
          .toList();
    } catch (e) {
      debugPrint('[Geocode] Foursquare error: $e');
      return [];
    }
  }

  /// Parse a single Foursquare place result into our [Place] model.
  static Place? _parseFoursquarePlace(Map<String, dynamic> f) {
    // Coordinates live under geocodes.main
    final geo  = (f['geocodes'] as Map<String, dynamic>?)?['main']
                     as Map<String, dynamic>?;
    final lat  = (geo?['latitude']  as num?)?.toDouble();
    final lon  = (geo?['longitude'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;

    final name = f['name']?.toString() ?? '';
    if (name.isEmpty) return null;

    final loc         = (f['location'] as Map<String, dynamic>?) ?? {};
    final address     = loc['address']?.toString() ?? '';
    final city        = loc['locality']?.toString() ?? '';
    final state       = loc['region']?.toString() ?? '';
    final country     = loc['country']?.toString() ?? '';
    final countryCode = loc['country_code']?.toString().toLowerCase() ?? '';

    // Detail line shown below the place name: "123 Main St, Barrie, Ontario"
    final detail = [address, city, state]
        .where((s) => s.isNotEmpty)
        .join(', ');

    return Place(
      position: LatLng(lat, lon),
      name: name,
      detail: detail,
      address: {
        'city': city,
        'state': state,
        'country': country,
        'country_code': countryCode,
      },
    );
  }

  /// Squared lat/lng delta — fast proxy for distance, good enough for sorting.
  /// (No need for full Haversine; we just want relative order.)
  static double _sqDist(LatLng a, LatLng b) {
    final dlat = a.latitude  - b.latitude;
    final dlng = a.longitude - b.longitude;
    return dlat * dlat + dlng * dlng;
  }

  /// Nominatim forward geocoding — same server as reverse geocoding, free, no key.
  /// A ±0.5° viewbox (~55 km each direction) biases results toward [near] when
  /// provided; bounded=0 means results outside the box are still returned.
  static Future<List<Place>> _geocodeNominatim(String query,
      {LatLng? near}) async {
    String viewbox = '';
    if (near != null) {
      const d = 0.5; // half-degree ≈ 55 km
      final minLon = near.longitude - d;
      final maxLon = near.longitude + d;
      final minLat = near.latitude  - d;
      final maxLat = near.latitude  + d;
      // viewbox format: left,top,right,bottom → minLon,maxLat,maxLon,minLat
      viewbox = '&viewbox=$minLon,$maxLat,$maxLon,$minLat&bounded=0';
    }
    final url = Uri.parse(
      '$_nominatim/search?q=${Uri.encodeComponent(query)}'
      '&format=json&addressdetails=1&limit=8&accept-language=en$viewbox',
    );
    try {
      final res = await _client.get(url, headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        debugPrint('[Geocode] Nominatim status ${res.statusCode}');
        return [];
      }
      final data = jsonDecode(res.body) as List;
      return data
          .map((f) => _parseNominatimSearchPlace(f as Map<String, dynamic>))
          .whereType<Place>()
          .toList();
    } catch (e) {
      debugPrint('[Geocode] Nominatim error: $e');
      return [];
    }
  }

  /// Parse a Nominatim forward-search result into a Place.
  /// The address fields are identical to the reverse-geocoding response.
  static Place? _parseNominatimSearchPlace(Map<String, dynamic> f) {
    final lat = double.tryParse(f['lat']?.toString() ?? '');
    final lon = double.tryParse(f['lon']?.toString() ?? '');
    if (lat == null || lon == null) return null;

    final a        = (f['address'] as Map<String, dynamic>?) ?? {};
    final rawName  = f['name']?.toString() ?? '';

    // Best display name: named place → road → suburb
    final placeName = rawName.isNotEmpty
        ? rawName
        : (a['road'] ?? a['suburb'] ?? a['neighbourhood'] ?? '').toString();
    if (placeName.isEmpty) return null;

    // Prefix house number when result is a specific address
    final houseNum    = a['house_number']?.toString() ?? '';
    final displayName = houseNum.isNotEmpty ? '$houseNum $placeName' : placeName;

    final city        = (a['city'] ?? a['town'] ?? a['village'] ?? '').toString();
    final state       = (a['state'] ?? '').toString();
    final country     = (a['country'] ?? '').toString();
    final countryCode = (a['country_code'] ?? '').toString().toLowerCase();

    final detail = [city, state, country].where((s) => s.isNotEmpty).join(', ');

    return Place(
      position: LatLng(lat, lon),
      name: displayName,
      detail: detail,
      address: {
        'city': city,
        'state': state,
        'country': country,
        'country_code': countryCode,
      },
    );
  }


  /// Photon geocoding — free, no API key, backed by OpenStreetMap/Nominatim data.
  /// Supports proximity bias via lat/lon params. Results quality is comparable
  /// to Mapbox for most addresses and city-level searches.
  static Future<List<Place>> _geocodePhoton(String query, {LatLng? near}) async {
    final proximity = near != null
        ? '&lat=${near.latitude}&lon=${near.longitude}'
        : '';
    final url = Uri.parse(
      '$_photon/api/?q=${Uri.encodeComponent(query)}&limit=8&lang=en$proximity',
    );
    try {
      final res = await _client.get(url, headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final features = data['features'] as List? ?? [];
      return features
          .map((f) => _parsePhotonPlace(f as Map<String, dynamic>))
          .whereType<Place>()   // filter out any nulls from malformed entries
          .toList();
    } catch (e) {
      debugPrint('[Geocode] Photon error: $e');
      return [];
    }
  }

  /// Parse a Photon GeoJSON feature into a Place.
  static Place? _parsePhotonPlace(Map<String, dynamic> f) {
    final coords = (f['geometry']?['coordinates']) as List?;
    if (coords == null || coords.length < 2) return null;
    final lng = (coords[0] as num).toDouble();
    final lat = (coords[1] as num).toDouble();

    final p           = (f['properties'] as Map<String, dynamic>?) ?? {};
    final name        = p['name']?.toString() ?? '';
    final street      = p['street']?.toString() ?? '';
    final housenumber = p['housenumber']?.toString() ?? '';
    final city        = p['city']?.toString() ?? p['town']?.toString() ?? p['village']?.toString() ?? '';
    final state       = p['state']?.toString() ?? '';
    final country     = p['country']?.toString() ?? '';
    final countryCode = p['countrycode']?.toString().toLowerCase() ?? '';

    // Build primary display name: prefer the place name; fall back to street
    final displayName = name.isNotEmpty
        ? (housenumber.isNotEmpty ? '$housenumber $name' : name)
        : (housenumber.isNotEmpty ? '$housenumber $street' : street);
    if (displayName.isEmpty) return null;

    // Build context detail line: city, state, country
    final detail = [city, state, country]
        .where((s) => s.isNotEmpty)
        .join(', ');

    return Place(
      position: LatLng(lat, lng),
      name: displayName,
      detail: detail,
      address: {
        'city': city,
        'state': state,
        'country': country,
        'country_code': countryCode,
      },
    );
  }


  // ── Reverse geocoding (Nominatim — better street-level address detail) ──────────
  // Given a LatLng (usually from a map tap), asks Nominatim what place / road
  // is at that position. Returns null on network error or unknown location.

  static Future<Place?> reverseGeocode(LatLng pos) async {
    final url = Uri.parse(
      '$_nominatim/reverse?format=json&lon=${pos.longitude}&lat=${pos.latitude}&addressdetails=1&zoom=16',
    );
    final res = await _client.get(url, headers: _headers);
    if (res.statusCode != 200) return null;
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (data['error'] != null) return null; // Nominatim returns {"error": "..."} for unknown spots

    final a = (data['address'] as Map<String, dynamic>?) ?? {};

    // Pick the best available name: named POI → street → suburb
    final name = data['name']?.toString() ?? a['road']?.toString() ?? a['suburb']?.toString() ?? '';

    // Build a city, state, country summary for the detail line
    final parts = [
      a['city'] ?? a['town'] ?? a['village'] ?? '',
      a['state'] ?? '',
      a['country'] ?? '',
    ].where((s) => s.toString().isNotEmpty).toList();

    return Place(
      position: LatLng(
        double.parse(data['lat'].toString()),
        double.parse(data['lon'].toString()),
      ),
      name: name,
      detail: parts.join(', '),
      address: a, // Keep the full map so callers can extract country_code, etc.
    );
  }

  // ── Address formatting helpers ─────────────────────────────────────────────────
  // These helpers format the raw Nominatim address map into display strings.
  // They're used by AppShell._navTick() to update the bottom-bar location text.

  // Combines the two parts into a single comma-separated string for simple use.
  static String formatLocationText(Map<String, dynamic>? a) {
    final parts = formatLocationParts(a);
    return [parts.$1, parts.$2].where((s) => s.isNotEmpty).join(', ');
  }

  /// Returns (mainLine, state) separately so callers can put state on its own row.
  /// mainLine = "Neighbourhood, City"   state = "Ontario" (or '' if unknown)
  // The bottom bar in NavOverlay shows mainLine on the first row and state
  // on the second row, which is cleaner than squashing them together.
  static (String, String) formatLocationParts(Map<String, dynamic>? a) {
    if (a == null) return ('Unknown location', '');
    final hood  = a['suburb'] ?? a['neighbourhood'] ?? a['hamlet'] ?? '';
    final city  = a['city']   ?? a['town']          ?? a['village'] ?? '';
    final state = a['state']  ?? '';
    final main  = [hood, city]
        .where((s) => s.toString().isNotEmpty)
        .join(', ');
    return (main.isNotEmpty ? main : 'Unknown location', state.toString());
  }

  /// Current road / freeway name at this position, e.g. "Interstate 95 (I-95)"
  // Combines road name and road reference when both are available.
  static String formatRoadName(Map<String, dynamic>? a) {
    if (a == null) return '';
    final road = a['road']?.toString() ?? '';
    final ref  = a['road_ref']?.toString() ?? '';          // sometimes present
    if (road.isNotEmpty && ref.isNotEmpty) return '$road ($ref)';
    return road;
  }

  /// ISO 3166-1 alpha-2 country code from Nominatim address, lowercased ("us", "ca", …)
  // Used by AppShell to detect border crossings and switch imperial/metric units.
  static String countryCode(Map<String, dynamic>? a) =>
      a?['country_code']?.toString().toLowerCase() ?? '';

  // ── Routing (Mapbox Directions) ───────────────────────────────────────────────
  // Mapbox returns an OSRM-compatible response — same structure as router.project-osrm.org.
  // It includes proper road names, ref numbers (I-90, ON-400), and bannerInstructions
  // so highway shields work out of the box.
  static Future<RouteData?> getRoute(LatLng origin, LatLng dest) async {
    final url = Uri.parse(
      '$_mapbox/directions/v5/mapbox/driving-traffic'
      '/${origin.longitude},${origin.latitude}'
      ';${dest.longitude},${dest.latitude}'
      '?access_token=$_mapboxToken'
      '&geometries=geojson&steps=true&overview=full'
      '&annotations=maxspeed',
    );
    final http.Response res;
    try {
      res = await _client.get(url, headers: _headers)
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      debugPrint('[Mapbox] exception: $e');
      return null;
    }
    debugPrint('[Mapbox] status: ${res.statusCode}');
    if (res.statusCode != 200) {
      debugPrint('[Mapbox] error: ${res.body.length > 300 ? res.body.substring(0, 300) : res.body}');
      return null;
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (data['code'] != 'Ok') return null;

    final route = data['routes'][0] as Map<String, dynamic>;

    // GeoJSON coordinates are [lng, lat] — swap to LatLng
    final coords = (route['geometry']['coordinates'] as List)
        .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();

    // Mapbox steps — same structure as OSRM
    final steps = <RouteStep>[];
    for (final leg in route['legs'] as List) {
      for (final s in leg['steps'] as List) {
        final m    = s['maneuver'] as Map<String, dynamic>? ?? {};
        // Mapbox puts the ref in intersections or voiceInstructions; simplest
        // source is the step name itself which already includes "I-90", "ON-400" etc.
        final name = s['name']?.toString() ?? '';
        final ref  = s['ref']?.toString() ?? '';
        steps.add(RouteStep(
          type:         m['type']?.toString() ?? '',
          modifier:     m['modifier']?.toString() ?? '',
          name:         name,
          ref:          ref,
          bearingAfter: (m['bearing_after'] as num?)?.toDouble() ?? -1,
          distance:     (s['distance'] as num).toDouble(),
          duration:     (s['duration'] as num).toDouble(),
          destinations: s['destinations']?.toString() ?? '',
          exits:        s['exits']?.toString() ?? '',
        ));
      }
    }

    return RouteData(
      coordinates: coords,
      distance: (route['distance'] as num).toDouble(),
      duration: (route['duration'] as num).toDouble(),
      steps: steps,
    );
  }

  // ── Weather ────────────────────────────────────────────────────────────────────

  // Fetches current conditions and today's sunrise/sunset at [pos].
  // Uses timezone=auto so Open-Meteo returns utc_offset_seconds for the
  // local timezone at that position — no need for a separate timezone API.
  static Future<WeatherData?> getWeather(LatLng pos) async {
    final url = Uri.parse(
      '$_openMeteo/v1/forecast?latitude=${pos.latitude}&longitude=${pos.longitude}'
      '&current=temperature_2m,weather_code&daily=sunrise,sunset&timezone=auto&forecast_days=1',
    );
    final res = await _client.get(url);
    if (res.statusCode != 200) return null;
    final data = jsonDecode(res.body);

    // utc_offset_seconds is always present in Open-Meteo responses when timezone=auto
    final utcOffset = (data['utc_offset_seconds'] as num?)?.toInt() ?? 0;

    return WeatherData(
      temp: (data['current']['temperature_2m'] as num).toDouble(),
      code: (data['current']['weather_code'] as num).toInt(),
      // Sunrise and sunset come back as ISO 8601 strings like "2024-01-15T07:23"
      sunrise: DateTime.parse(data['daily']['sunrise'][0]),
      sunset: DateTime.parse(data['daily']['sunset'][0]),
      utcOffsetSeconds: utcOffset,
    );
  }
}
