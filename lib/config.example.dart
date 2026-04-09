// ── config.example.dart ────────────────────────────────────────────────────────
// Template for API keys. Copy this file to config.dart and fill in your keys.
//
//   cp lib/config.example.dart lib/config.dart
//
// Then edit config.dart with your real keys. config.dart is gitignored.

class Config {
  // Foursquare Places — forward geocoding (businesses, POIs)
  // Get a free key (no credit card) at https://foursquare.com/developer
  static const foursquareKey = 'YOUR_FOURSQUARE_KEY_HERE';

  // Mapbox — turn-by-turn routing + directions
  // Get a free key at https://account.mapbox.com
  static const mapboxToken = 'YOUR_MAPBOX_TOKEN_HERE';
}
