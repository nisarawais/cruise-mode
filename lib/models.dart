// ── models.dart ────────────────────────────────────────────────────────────────
// Pure data models — no Flutter widgets, no network calls.
// Defines the three core data types that flow through the app:
//   • Place       — a geocoded location (name + coordinates + address map)
//   • RouteData   — the full driving route returned by OSRM
//   • RouteStep   — one maneuver within a route (turn, merge, etc.)
//   • WeatherData — current conditions from Open-Meteo

import 'package:latlong2/latlong.dart'; // LatLng, Distance utility

// ── Place ──────────────────────────────────────────────────────────────────────
// Represents a geocoded search result or a reverse-geocoded map tap.
// The [address] map contains raw fields from Nominatim (city, state, road …)
// so other parts of the app can format them however they like.

class Place {
  final LatLng position; // Latitude/longitude on the map
  final String name;     // Primary display text (POI name or street number + street)
  final String detail;   // Secondary text (city, state, country)
  final Map<String, dynamic> address; // Raw Nominatim address fields

  Place({
    required this.position,
    required this.name,
    this.detail = '',
    this.address = const {},
  });

  // Full label shown in the search-result list: "Starbucks, 123 Main St, NYC"
  // Falls back to just the detail string if no primary name is set.
  String get label => name.isNotEmpty ? '$name, $detail' : detail;

  // Short one-word version used in the collapsed bottom-sheet summary bar.
  // For plain address results, picks only the first part before the first comma.
  String get shortName => name.isNotEmpty ? name : detail.split(',').first;
}

// ── RouteData ──────────────────────────────────────────────────────────────────
// Holds everything returned by the OSRM routing API for a single driving route.
// The [coordinates] list is the full polyline (hundreds of LatLng points).
// [steps] are the individual turn-by-turn maneuvers.

class RouteData {
  final List<LatLng> coordinates; // Full route polyline
  final double distance;          // Total route length in metres
  final double duration;          // Estimated travel time in seconds
  final List<RouteStep> steps;    // Ordered list of maneuver steps

  // Populated lazily by computeCumulativeDistances() — stores the total metres
  // travelled to reach each coordinate index, enabling fast interpolation.
  List<double>? cumulativeDistances;

  RouteData({
    required this.coordinates,
    required this.distance,
    required this.duration,
    required this.steps,
  });

  // ── Cumulative distance pre-computation ──────────────────────────────────────
  // Walks the polyline once and records the running total distance (in metres)
  // at every point. This is called once after route fetch and then reused by
  // interpolate() and indexAtProgress() on every animation frame.
  void computeCumulativeDistances() {
    const dist = Distance(); // latlong2 haversine calculator
    final d = <double>[0];   // index 0 is always at 0 metres from the start
    for (int i = 1; i < coordinates.length; i++) {
      // Add the segment length (metres) to the running total
      d.add(d[i - 1] + dist.as(LengthUnit.Meter, coordinates[i - 1], coordinates[i]));
    }
    cumulativeDistances = d;
  }

  // ── Position interpolation ────────────────────────────────────────────────────
  // Given a progress value t in [0, 1], returns the exact LatLng the car should
  // be at. 0 = start of route, 1 = destination.
  // Uses cumulative distances to find the right segment, then linearly
  // interpolates latitude/longitude within that segment.
  LatLng interpolate(double t) {
    if (t <= 0) return coordinates.first;
    if (t >= 1) return coordinates.last;

    // Lazily compute cumulative distances if not done yet
    cumulativeDistances ??= () { computeCumulativeDistances(); return cumulativeDistances!; }();
    final cd = cumulativeDistances!;
    final totalDist = cd.last;
    final target = t * totalDist; // How many metres into the route we want to be

    // Walk forward until we find the segment that contains [target]
    int i = 0;
    while (i < cd.length - 1 && cd[i + 1] < target) {
      i++;
    }

    // How far along this specific segment (0–1)?
    final segLen = cd[i + 1] - cd[i];
    final segT = segLen > 0 ? (target - cd[i]) / segLen : 0.0;

    // Linearly blend lat/lng between the two endpoints of the segment
    return LatLng(
      coordinates[i].latitude  + (coordinates[i + 1].latitude  - coordinates[i].latitude)  * segT,
      coordinates[i].longitude + (coordinates[i + 1].longitude - coordinates[i].longitude) * segT,
    );
  }

  // ── Polyline index at progress ────────────────────────────────────────────────
  // Returns the index into [coordinates] that corresponds to progress t.
  // Used to split the polyline into "driven" (faded) and "remaining" (bright)
  // segments for the map layers.
  int indexAtProgress(double t) {
    cumulativeDistances ??= () { computeCumulativeDistances(); return cumulativeDistances!; }();
    final cd = cumulativeDistances!;
    final target = t * cd.last;
    int i = 0;
    while (i < cd.length - 1 && cd[i + 1] < target) {
      i++;
    }
    return i;
  }
}

// ── RouteStep ──────────────────────────────────────────────────────────────────
// One maneuver in the turn-by-turn directions, mapped from OSRM's step objects.
// Each step describes what to do (type + modifier), on which road (name + ref),
// and how far until the next step (distance).

class RouteStep {
  final String type;       // OSRM maneuver type: "turn", "merge", "depart", etc.
  final String modifier;   // Direction qualifier: "left", "right", "straight"
  final String name;       // Road / street name, e.g. "Main Street"

  /// Highway/road reference e.g. "I-95", "US-1", "ON-401"
  final String ref;

  /// Bearing (degrees 0-360) right after executing this maneuver.
  /// -1 means unknown / not provided.
  final double bearingAfter;

  final double distance;   // Metres from this step to the next
  final double duration;   // Seconds for this step

  /// Where this exit/ramp leads, e.g. "Downtown;Airport" (OSRM `destinations`)
  final String destinations;

  /// Exit number/letter, e.g. "15A" (OSRM `exits`)
  final String exits;

  RouteStep({
    required this.type,
    required this.modifier,
    required this.name,
    this.ref = '',
    this.bearingAfter = -1,
    required this.distance,
    required this.duration,
    this.destinations = '',
    this.exits = '',
  });

  // ── Road label helpers ────────────────────────────────────────────────────────

  /// Plain road label: "Name (Ref)", "Name", "Ref", or "the road"
  // Priority: combined → ref-only → name-only → generic fallback
  String get roadLabel {
    if (name.isNotEmpty && ref.isNotEmpty) return '$name ($ref)';
    if (ref.isNotEmpty) return ref;
    if (name.isNotEmpty) return name;
    return 'the road';
  }

  /// Road label with cardinal direction appended for numbered highways.
  /// e.g. "I-95 South", "Highway 400 North", "Main St" (no dir for local roads)
  // We only add a direction when the road has a ref number — local streets
  // don't have reliable bearings and "Main Street North" would look odd.
  String get roadLabelDir {
    // Only add direction when road has a reference number
    if (ref.isEmpty || bearingAfter < 0) return roadLabel;
    final dir = cardinal(bearingAfter);
    if (name.isNotEmpty) return '$name ($ref) $dir';
    return '$ref $dir';
  }

  // ── Cardinal direction ────────────────────────────────────────────────────────

  /// 8-point cardinal direction from a bearing in degrees.
  // Divides the 360° compass into 8 × 45° slices.
  // The +22.5 offset centres each slice on a direction name.
  static String cardinal(double bearing) {
    const dirs = [
      'North', 'Northeast', 'East', 'Southeast',
      'South', 'Southwest', 'West', 'Northwest'
    ];
    return dirs[((bearing + 22.5) / 45).floor() % 8];
  }

  // ── Icon for the maneuver type ────────────────────────────────────────────────
  // Returns a simple emoji that matches the type of maneuver.
  // The icon is shown on the left side of the turn banner.
  String get icon {
    if (type == 'arrive') return '🏁';
    if (type == 'depart') return '🚀';
    if (type == 'roundabout' || type == 'rotary') return '🔄';
    if (type == 'on ramp' || type == 'off ramp') return '↗️';
    if (modifier.contains('left')) return '↰';
    if (modifier.contains('right')) return '↱';
    return '⬆️'; // Default: continue straight
  }

  // ── Off-ramp / exit instruction builder ──────────────────────────────────────

  /// Friendly exit instruction, e.g.:
  ///   "Take Exit 15A toward Downtown"          (exits + destinations)
  ///   "Take Exit 15A onto I-95 South"          (exits + road)
  ///   "Take exit toward Downtown"              (destinations only)
  ///   "Take exit onto I-95 South"             (road ref/name)
  ///   "Take exit"                              (fallback)
  // Builds the most informative sentence possible from the available OSRM fields.
  String _offRampInstruction() {
    // First priority: destinations (most human-readable)
    final dest = destinations.isNotEmpty
        ? destinations.split(';').first.trim()
        : '';
    // Second: use exits number if present
    final exitLabel = exits.isNotEmpty ? 'Exit $exits' : 'exit';

    if (dest.isNotEmpty && (name.isNotEmpty || ref.isNotEmpty)) {
      return 'Take $exitLabel onto $roadLabel toward $dest';
    }
    if (dest.isNotEmpty) return 'Take $exitLabel toward $dest';
    if (name.isNotEmpty || ref.isNotEmpty) return 'Take $exitLabel onto $roadLabel';
    return 'Take $exitLabel';
  }

  // ── Human-readable instruction string ────────────────────────────────────────
  // Produces the sentence shown inside the turn banner, e.g.
  // "Turn left onto Main Street" or "Take Exit 15A toward Downtown".
  // Whether this step has a meaningful road identifier to mention
  bool get _hasRoad => name.isNotEmpty || ref.isNotEmpty;

  String get instruction {
    switch (type) {
      case 'depart':
        return _hasRoad ? 'Head out on $roadLabel' : 'Depart';
      case 'arrive':
        return 'Arrive at destination';
      case 'merge':
        return _hasRoad ? 'Merge onto $roadLabel' : 'Merge';
      case 'on ramp':
        return _hasRoad ? 'Take ramp onto $roadLabel' : 'Take the ramp';
      case 'off ramp':
        return _offRampInstruction();
      case 'fork':
        return _hasRoad ? 'Keep $modifier on $roadLabel' : 'Keep $modifier';
      case 'new name':
        return _hasRoad ? 'Continue onto $roadLabel' : 'Continue straight';
      case 'turn':
        return _hasRoad ? 'Turn $modifier onto $roadLabel' : 'Turn $modifier';
      case 'end of road':
        return _hasRoad ? 'Turn $modifier at end of $roadLabel' : 'Turn $modifier';
      case 'roundabout':
      case 'rotary':
        return 'Enter roundabout${name.isNotEmpty ? " onto $name" : ""}';
      default:
        return _hasRoad ? 'Continue on $roadLabel' : 'Continue straight';
    }
  }
}

// ── WeatherData ────────────────────────────────────────────────────────────────
// Current weather conditions at the car's position, fetched from Open-Meteo.
// Includes temperature, a WMO weather code, and today's sunrise/sunset times
// so the UI can show a day-progress bar.

class WeatherData {
  final double temp;           // Celsius temperature from Open-Meteo
  final int code;              // WMO weather code (0 = clear, 95 = thunderstorm, …)
  final DateTime sunrise;      // Today's sunrise at the current location
  final DateTime sunset;       // Today's sunset at the current location
  // Seconds offset from UTC for the car's current position timezone
  final int utcOffsetSeconds;

  WeatherData({
    required this.temp,
    required this.code,
    required this.sunrise,
    required this.sunset,
    required this.utcOffsetSeconds,
  });

  // ── Weather presentation helpers ──────────────────────────────────────────────

  // Looks up the WMO code in _wxMap and returns the emoji portion.
  // Falls back to a thermometer if the code isn't in our map.
  String get emoji {
    final map = _wxMap[code];
    return map?.split(' ').first ?? '🌡️';
  }

  // Returns the plain-English condition text (everything after the first space).
  String get condition {
    final map = _wxMap[code];
    if (map == null) return 'Unknown';
    return map.substring(map.indexOf(' ') + 1);
  }

  // Converts the stored Celsius temperature to Fahrenheit when [celsius] is false.
  double tempIn(bool celsius) => celsius ? temp : (temp * 9 / 5 + 32);

  // ── Local time helpers ────────────────────────────────────────────────────────

  /// Current local time at the car's position
  // Open-Meteo gives us utc_offset_seconds for the timezone the car is in,
  // so we convert UTC now → local by adding that offset.
  DateTime get localNow =>
      DateTime.now().toUtc().add(Duration(seconds: utcOffsetSeconds));

  // How far through the daylight hours are we? 0.0 = just after sunrise,
  // 1.0 = just after sunset. Used to drive the linear progress bar in the
  // weather card.
  double get dayProgress {
    final now = localNow;
    if (now.isBefore(sunrise)) return 0;
    if (now.isAfter(sunset)) return 1;
    return now.difference(sunrise).inSeconds / sunset.difference(sunrise).inSeconds;
  }

  // ── WMO weather code → emoji + label lookup table ────────────────────────────
  // Keys are WMO weather interpretation codes as returned by Open-Meteo.
  // Each value is "EMOJI Label" — split on the first space to get either part.
  static const _wxMap = {
    0: '☀️ Clear', 1: '🌤️ Mostly Clear', 2: '⛅ Partly Cloudy', 3: '☁️ Overcast',
    45: '🌫️ Foggy', 48: '🌫️ Rime Fog', 51: '🌦️ Light Drizzle', 53: '🌦️ Drizzle',
    55: '🌧️ Heavy Drizzle', 61: '🌧️ Light Rain', 63: '🌧️ Rain', 65: '🌧️ Heavy Rain',
    71: '🌨️ Light Snow', 73: '🌨️ Snow', 75: '❄️ Heavy Snow', 77: '❄️ Sleet',
    80: '🌦️ Showers', 81: '🌧️ Showers', 82: '⛈️ Heavy Showers',
    85: '🌨️ Snow Showers', 86: '❄️ Heavy Snow', 95: '⛈️ Thunderstorm',
    96: '⛈️ Hail Storm', 99: '⛈️ Severe Storm',
  };
}
