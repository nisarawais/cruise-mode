// ── nav_overlay.dart ───────────────────────────────────────────────────────────
// The active-navigation HUD that floats on top of the map during a study session.
// Rendered by AppShell when _navigating is true.
//
// Layout (all positioned over the map via a Stack):
//   ┌────────────────────────────────────────┐
//   │ [Turn banner — top]       [Weather]    │
//   │                                        │
//   │   (map visible behind everything)      │
//   │                                        │
//   │ [Road chip]                            │
//   │ [Bottom bar — ETA, location, stop btn] │
//   └────────────────────────────────────────┘
//
// NavOverlay is StateLESS — all mutable data (progress, weather, location) is
// owned by AppShell and passed in as constructor parameters. This keeps the widget
// simple and avoids double-state issues.

import 'dart:async';
import 'package:flutter/material.dart';
import 'models.dart';
import 'theme.dart';
import 'widgets.dart';

class NavOverlay extends StatelessWidget {
  final RouteData route;         // Full route object (steps + polyline)
  final double progress;         // 0.0 → 1.0 fraction of the route driven so far
  final int studyMinutes;        // Total study session length (for the countdown)
  final DateTime studyStartTime; // Wall-clock time when "Start Focus" was tapped
  final WeatherData? weather;    // Null while the first weather fetch is in-flight
  final bool useCelsius;         // True = °C display, False = °F display
  final bool useImperial;        // true = miles/°F zone (auto-set at US border)
  final String locationText;     // neighbourhood + city — first row of bottom bar
  final String locationState;    // state / province — shown on its own row when set
  final String countryCode;      // ISO alpha-2 code for the flag emoji ("us", "ca", …)
  final String countryName;      // Full country name shown in the chip next to the road
  final String destName;         // Destination label shown in the bottom bar
  final VoidCallback onStop;     // Called when user taps the red stop button
  final VoidCallback onToggleTemp; // Called when user taps the weather card (°C↔°F)

  const NavOverlay({
    super.key,
    required this.route,
    required this.progress,
    required this.studyMinutes,
    required this.studyStartTime,
    required this.weather,
    required this.useCelsius,
    required this.useImperial,
    required this.locationText,
    this.locationState = '',
    this.countryCode = '',
    this.countryName = '',
    required this.destName,
    required this.onStop,
    required this.onToggleTemp,
  });

  @override
  Widget build(BuildContext context) {
    final pad         = MediaQuery.of(context).padding;
    final size        = MediaQuery.of(context).size;
    final isLandscape = size.width > size.height;
    // isWide: tablet or any landscape device → switch to fixed-width panels
    final isWide      = size.width > 600 || isLandscape;
    // Width used for the turn banner and the bottom cluster so they align.
    // isWide covers both landscape (any rotation) and portrait tablet.
    final panelW      = isWide
        ? (size.width * 0.44).clamp(300.0, 460.0)
        : size.width - 28; // full-width minus margins on portrait phone

    // Centre the bottom cluster on tablet/landscape; full-width on portrait phone
    final bottomLeft  = isWide ? (size.width - panelW) / 2 : 14.0;
    final bottomRight = isWide ? null                      : 14.0;

    return Stack(
      children: [
        // ── Vignette gradients ────────────────────────────────────────────
        // Top: helps the turn banner text contrast against any map background.
        // Bottom: blends the HUD panel into the map so it feels less "pasted on".
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.32],
                  colors: const [Color(0xB0000000), Colors.transparent],
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  stops: const [0.0, 0.38],
                  colors: const [Color(0x99000000), Colors.transparent],
                ),
              ),
            ),
          ),
        ),

        // ── Turn banner ───────────────────────────────────────────────────
        // Portrait phone : full-width below the status bar.
        // Tablet / landscape : fixed-width panel anchored top-left.
        Positioned(
          top: pad.top + 12,
          left: 14,
          right: isWide ? null : 14,
          child: isWide
              ? SizedBox(width: panelW, child: _buildTurnBanner())
              : _buildTurnBanner(),
        ),

        // ── Weather card ──────────────────────────────────────────────────
        // Landscape / tablet : top-right, level with the turn banner.
        // Portrait phone     : floats at 38% down the screen.
        Positioned(
          right: 14,
          top: isWide ? pad.top + 12 : size.height * 0.38,
          child: _buildWeatherCard(),
        ),

        // ── Road chip + bottom bar ────────────────────────────────────────
        // Landscape : centred, same width as the turn banner.
        // Portrait  : full-width along the bottom edge.
        Positioned(
          left: bottomLeft,
          right: bottomRight,
          bottom: pad.bottom + 14,
          child: SizedBox(
            width: isWide ? panelW : null,
            child: Column(
            mainAxisSize: MainAxisSize.min,
            // Centre chip on tablet/landscape; left-align on portrait phone
            crossAxisAlignment: isWide
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              // Road name chip (left) + country chip (right) — both float above the
              // bottom bar. Country chip shakes when the car crosses a border.
              Builder(builder: (context) {
                final roadStep  = _currentRoadStep();
                final chipLabel = roadStep.roadLabel;
                final showRoad    = chipLabel != 'the road';
                final showCountry = countryName.isNotEmpty;

                // Nothing to show — hide the whole row
                if (!showRoad && !showCountry) return const SizedBox.shrink();

                return Padding(
                  padding: EdgeInsets.only(left: isWide ? 0 : 4, right: isWide ? 0 : 4, bottom: 6),
                  // IntrinsicHeight forces both chips to match the tallest one
                  // (road chip can be taller when it shows a highway shield).
                  child: IntrinsicHeight(
                  child: Row(
                    mainAxisSize: MainAxisSize.max,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Road chip ──────────────────────────────────────
                      if (showRoad)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xCC0A0C14),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.08)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (roadStep.ref.isNotEmpty)
                                HighwaySign(ref: roadStep.ref, height: 26)
                              else
                                const Text('🛣️',
                                    style: TextStyle(fontSize: 12)),
                              const SizedBox(width: 6),
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 160),
                                child: Text(
                                  chipLabel,
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 11),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      // Spacer pushes country chip to the far right
                      const Spacer(),
                      // ── Country chip — shakes on border crossing ────────
                      if (showCountry)
                        _CountryChip(
                          countryCode: countryCode,
                          countryName: countryName,
                        ),
                    ],
                  ),
                  ), // IntrinsicHeight
                );
              }),    // Builder
              _buildBottomBar(),
            ],
          ),
          ), // SizedBox
        ),
      ],
    );
  }

  // ── Turn banner ───────────────────────────────────────────────────────────
  // Shows the NEXT maneuver (not the current road — that's the road chip).
  // Content: turn icon | instruction text | optional highway shield + direction | distance

  Widget _buildTurnBanner() {
    final step       = _currentStep();
    final distToTurn = _distanceToNextTurn();
    final distText   = _fmtDist(distToTurn);
    final hasSign    = step.ref.isNotEmpty;

    // Split "1.2 mi" → num="1.2", unit="mi" for two-line hero display
    final spaceIdx = distText.indexOf(' ');
    final distNum  = spaceIdx > 0 ? distText.substring(0, spaceIdx) : distText;
    final distUnit = spaceIdx > 0 ? distText.substring(spaceIdx + 1) : '';

    return GlassContainer(
      color: const Color(0xD0101828), // Deep dark navy — more contrast against map
      borderColor: Colors.white.withValues(alpha: 0.07),
      blur: 28,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Maneuver arrow — larger, immediately scannable
          Text(step.icon, style: const TextStyle(fontSize: 46)),
          const SizedBox(width: 14),
          // Instruction text + optional highway shield
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  step.instruction,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600, color: C.text),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (hasSign) ...[
                  const SizedBox(height: 6),
                  HighwaySign(ref: step.ref, height: 30),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Distance — hero number on the right for instant glance
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(distNum,
                  style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      color: C.blue)),
              if (distUnit.isNotEmpty)
                Text(distUnit,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: C.blue)),
            ],
          ),
        ],
      ),
    );
  }

  // ── Weather card ──────────────────────────────────────────────────────────
  // Tapping the card toggles between °C and °F.
  // While weather is loading, shows a placeholder with a thermometer emoji.

  Widget _buildWeatherCard() {
    if (weather == null) {
      // Placeholder shown during the initial weather fetch
      return GlassContainer(
        color: const Color(0x660E111C),
        padding: const EdgeInsets.all(12),
        child: const SizedBox(
          width: 96,
          child: Column(
            children: [
              Text('🌡️', style: TextStyle(fontSize: 28)),
              SizedBox(height: 6),
              Text('Loading…',
                  style: TextStyle(color: C.textDim, fontSize: 11)),
            ],
          ),
        ),
      );
    }

    final w    = weather!;
    final temp = w.tempIn(useCelsius); // Convert from stored Celsius if needed
    final unit = useCelsius ? 'C' : 'F';

    // Format sunrise/sunset in 12-hr time for the weather card footer
    final sunriseText = _fmt12(w.sunrise);
    final sunsetText  = _fmt12(w.sunset);

    // Local time at car's position (no seconds)
    final localNow = w.localNow;
    final timeText = _fmt12(localNow);

    // GestureDetector makes the whole card tappable to toggle °C/°F
    return GestureDetector(
      onTap: onToggleTemp,
      child: GlassContainer(
        color: const Color(0x730E111C), // Slightly less transparent than default
        blur: 16,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: SizedBox(
          width: 122,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // WMO condition emoji (e.g. ☀️ 🌧️ ❄️)
              Text(w.emoji, style: const TextStyle(fontSize: 32)),
              const SizedBox(height: 4),
              // Temperature — large and easy to read at a glance
              Text(
                '${temp.round()}°$unit',
                style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: C.text),
              ),
              const SizedBox(height: 3),
              // Human-readable condition string e.g. "Partly Cloudy"
              Text(
                w.condition,
                style: const TextStyle(fontSize: 11, color: C.textDim),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 9),
              // Sunrise and sunset times on the same row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('🌅 $sunriseText',
                      style: const TextStyle(fontSize: 10, color: C.text)),
                  Text('🌇 $sunsetText',
                      style: const TextStyle(fontSize: 10, color: C.text)),
                ],
              ),
              const SizedBox(height: 7),
              // Day-progress bar: left = sunrise, right = sunset; gold fill = current time
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: w.dayProgress,
                  minHeight: 5,
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  valueColor: const AlwaysStoppedAnimation(C.gold),
                ),
              ),
              const SizedBox(height: 6),
              // Current local time at the car's GPS position (updates with weather)
              Text(
                timeText,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: C.textDim),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Bottom bar ────────────────────────────────────────────────────────────
  // Dashboard-style HUD with two rows:
  //   Top row  : Speed  |  ETA  |  Distance remaining
  //   Divider
  //   Info row : Location + destination  |  Study countdown + Stop button

  Widget _buildBottomBar() {
    // ── Timing ──
    final totalMs  = studyMinutes * 60 * 1000;
    final elapsed  = DateTime.now().difference(studyStartTime).inMilliseconds;
    final remainMs = (totalMs - elapsed).clamp(0, totalMs);

    // ETA in local timezone
    final localBase = weather?.localNow ?? DateTime.now();
    final eta       = localBase.add(Duration(milliseconds: remainMs));
    final etaText   = _fmt12(eta);

    // Study countdown (mm:ss)
    final timerMins = (remainMs / 60000).floor();
    final timerSecs = ((remainMs % 60000) / 1000).floor();
    final timerStr  =
        '${timerMins.toString().padLeft(2, '0')}:${timerSecs.toString().padLeft(2, '0')}';

    // ── Distance remaining — split into number + unit for two-line display ──
    final remainDist  = route.distance * (1 - progress);
    final distRaw     = _fmtDist(remainDist);
    final distSpace   = distRaw.indexOf(' ');
    final distNum     = distSpace > 0 ? distRaw.substring(0, distSpace) : distRaw;
    final distUnit    = distSpace > 0 ? distRaw.substring(distSpace + 1) : '';

    return GlassContainer(
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [

          // ── Dashboard row ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // ETA — left
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(etaText,
                        style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: C.text)),
                    const SizedBox(height: 2),
                    const Text('ETA',
                        style: TextStyle(
                            fontSize: 10,
                            color: C.textDim,
                            letterSpacing: 0.8)),
                  ],
                ),
                const Spacer(),
                // Distance remaining — right
                _dashStat(distNum, distUnit),
              ],
            ),
          ),

          // ── Divider ─────────────────────────────────────────────────────
          Container(
              height: 1, color: Colors.white.withValues(alpha: 0.07)),

          // ── Info row ────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [

                // Left: location + destination
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('📍 $locationText',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: C.text),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      if (locationState.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(locationState,
                            style: const TextStyle(
                                fontSize: 11, color: C.textDim),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                      const SizedBox(height: 5),
                      Row(children: [
                        const Text('🏁  ',
                            style:
                                TextStyle(fontSize: 11, color: C.textDim)),
                        Expanded(
                          child: _AutoScrollText(
                            text: destName,
                            style: const TextStyle(
                                fontSize: 11, color: C.textDim),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
                const SizedBox(width: 12),

                // Right: study timer + stop button
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Study countdown in gold
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('⏱️ ',
                            style: TextStyle(fontSize: 12)),
                        Text(timerStr,
                            style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: C.gold)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Stop button
                    GestureDetector(
                      onTap: onStop,
                      child: Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: C.red,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                                color: C.red.withValues(alpha: 0.4),
                                blurRadius: 18),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.stop_rounded,
                            color: Colors.white, size: 22),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Dashboard stat helper ─────────────────────────────────────────────────
  // Large value on top, small unit label below — used for Speed and Distance.
  Widget _dashStat(String value, String unit) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w900,
                color: C.text)),
        if (unit.isNotEmpty)
          Text(unit,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: C.textDim,
                  letterSpacing: 0.4)),
      ],
    );
  }

  // ── Step logic ────────────────────────────────────────────────────────────

  /// The UPCOMING maneuver step (shown in the turn banner).
  // Walks through the steps accumulating distance until we find the segment
  // the car hasn't reached yet, then returns the NEXT step after that.
  RouteStep _currentStep() {
    final steps = route.steps;
    if (steps.isEmpty) {
      // Fallback: an empty depart step so the UI never crashes
      return RouteStep(
          type: 'depart', modifier: '', name: '', distance: 0, duration: 0);
    }
    final drivenDist = progress * route.distance; // metres driven so far
    double cumDist   = 0;
    for (int i = 0; i < steps.length; i++) {
      cumDist += steps[i].distance;
      if (cumDist > drivenDist) {
        // We're inside step i — show step i+1 as the upcoming turn
        return (i + 1 < steps.length) ? steps[i + 1] : steps[i];
      }
    }
    return steps.last; // At or past the destination
  }

  /// The step the car is currently TRAVELLING ON (used for the road-name chip).
  /// Updates every rebuild (~50 ms) — no network call needed.
  // Unlike _currentStep(), this returns the CURRENT step (not the next one).
  RouteStep _currentRoadStep() {
    final steps = route.steps;
    if (steps.isEmpty) {
      return RouteStep(
          type: 'depart', modifier: '', name: '', distance: 0, duration: 0);
    }
    final drivenDist = progress * route.distance;
    double cumDist   = 0;
    for (int i = 0; i < steps.length; i++) {
      cumDist += steps[i].distance;
      if (cumDist > drivenDist) return steps[i]; // the road we're on right now
    }
    return steps.last;
  }

  // Returns metres remaining until the next maneuver from the car's current position.
  double _distanceToNextTurn() {
    final steps = route.steps;
    if (steps.isEmpty) return 0;
    final drivenDist = progress * route.distance;
    double cumDist   = 0;
    for (final step in steps) {
      cumDist += step.distance;
      // The first step boundary beyond the driven distance is the next turn
      if (cumDist > drivenDist) return cumDist - drivenDist;
    }
    return 0;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Format a distance for display.
  /// Imperial : < 500 ft → "350 ft"  |  ≥ 500 ft → "0.3 mi" / "1.2 mi" / "12 mi"
  /// Metric   : < 1 km  → "350 m"   |  ≥ 1 km   → "1.2 km"
  // Rounds to the nearest 10 in short-distance mode (feet/metres) so values
  // don't jitter while the car moves slowly.
  String _fmtDist(double metres) {
    if (useImperial) {
      final feet  = metres * 3.28084;
      final miles = metres / 1609.34;
      if (feet < 500) {
        // Round to nearest 10 ft, clamp between 10 and 490
        return '${((feet / 10).round() * 10).clamp(10, 490)} ft';
      }
      if (miles >= 10) return '${miles.round()} mi';   // e.g. "12 mi"
      return '${miles.toStringAsFixed(1)} mi';          // e.g. "1.2 mi"
    } else {
      if (metres >= 1000) {
        return '${(metres / 1000).round()} km'; // e.g. "2 km"
      }
      // Round to nearest 10 m, clamp between 10 and 990
      return '${((metres / 10).round() * 10).clamp(10, 990)} m';
    }
  }

  /// Format DateTime as 12-hr "8:05 AM"
  // Midnight (hour 0) maps to 12, not 0.
  static String _fmt12(DateTime dt) {
    final h      = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m      = dt.minute.toString().padLeft(2, '0'); // Always two digits
    final suffix = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $suffix';
  }
}

// ── Country chip ──────────────────────────────────────────────────────────────
// Shows a flag emoji + country name in a dark pill.
// When [countryCode] changes (border crossing), the chip shakes left-right to
// alert the driver without being distracting.

class _CountryChip extends StatefulWidget {
  final String countryCode; // ISO alpha-2 (lowercase), e.g. "us", "ca", "de"
  final String countryName; // Full country name, e.g. "United States"

  const _CountryChip({required this.countryCode, required this.countryName});

  @override
  State<_CountryChip> createState() => _CountryChipState();
}

class _CountryChipState extends State<_CountryChip>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _shake;

  @override
  void initState() {
    super.initState();
    // Animation plays for 600ms — 3 left-right oscillations then snaps back
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    // TweenSequence creates a smooth shake: 0 → −8 → +8 → −8 → +8 → 0
    _shake = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -8.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8.0, end: -8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8.0, end: 0.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _ctrl, curve: Curves.linear));
  }

  @override
  void didUpdateWidget(_CountryChip old) {
    super.didUpdateWidget(old);
    // Trigger shake whenever the country code changes (border crossing)
    if (old.countryCode != widget.countryCode && widget.countryCode.isNotEmpty) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // Convert ISO alpha-2 country code to a flag emoji.
  // Each letter maps to a Regional Indicator Symbol by offsetting from 'A' (0x41)
  // to the base code point 0x1F1E6. Two such symbols combine into a flag.
  static String _flagEmoji(String cc) {
    if (cc.length != 2) return '🌍';
    return String.fromCharCodes(
      cc.toUpperCase().codeUnits.map((c) => c - 0x41 + 0x1F1E6),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) => Transform.translate(
        offset: Offset(_shake.value, 0),
        child: child,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xCC0A0C14),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Flag emoji derived from ISO code — no image asset needed
            Text(_flagEmoji(widget.countryCode),
                style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                widget.countryName,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Auto-scrolling text ───────────────────────────────────────────────────────
// Scrolls horizontally when text overflows, pauses, then resets. No package needed.
//
// Used for the destination name in the bottom bar — it can be long (e.g. a full
// address) but the available width is small. The animation:
//   1. Waits 2 s (let the user read the start of the text)
//   2. Scrolls to the end at ~50 px/s
//   3. Pauses 1 s at the end
//   4. Snaps back to the start
//   5. Waits 3 s then repeats

class _AutoScrollText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _AutoScrollText({required this.text, required this.style});

  @override
  State<_AutoScrollText> createState() => _AutoScrollTextState();
}

class _AutoScrollTextState extends State<_AutoScrollText> {
  final _ctrl  = ScrollController();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // addPostFrameCallback: run after the first layout so we know the scroll extent
    WidgetsBinding.instance.addPostFrameCallback((_) => _schedule());
  }

  @override
  void didUpdateWidget(_AutoScrollText old) {
    super.didUpdateWidget(old);
    // When the destination name changes (e.g. after a stop), reset to start
    if (old.text != widget.text) {
      _ctrl.jumpTo(0);      // Instantly snap to beginning
      _timer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) => _schedule());
    }
  }

  // Schedule the first scroll after an initial 2-second pause
  void _schedule() {
    _timer?.cancel();
    // Wait 2 s before first scroll attempt
    _timer = Timer(const Duration(seconds: 2), _scroll);
  }

  // The scroll animation sequence
  Future<void> _scroll() async {
    if (!mounted || !_ctrl.hasClients) return;
    final max = _ctrl.position.maxScrollExtent;
    if (max <= 0) return; // text fits — nothing to do

    // Scroll to end (~50 px/s — duration proportional to content length)
    await _ctrl.animateTo(
      max,
      duration: Duration(milliseconds: (max * 20).round()),
      curve: Curves.linear,
    );
    if (!mounted) return;
    await Future.delayed(const Duration(seconds: 1)); // Pause at the end
    if (!mounted) return;

    // Snap back to start quickly
    await _ctrl.animateTo(0,
        duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
    if (!mounted) return;

    // Repeat after a 3-second pause
    _timer = Timer(const Duration(seconds: 3), _scroll);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _ctrl,
      scrollDirection: Axis.horizontal,
      // User can't scroll manually — only auto-driven by the timer above
      physics: const NeverScrollableScrollPhysics(),
      child: Text(widget.text, style: widget.style, softWrap: false),
    );
  }
}
