// ── widgets.dart ───────────────────────────────────────────────────────────────
// Reusable, stateless-or-lightly-stateful UI building blocks shared across
// multiple screens. Organised into sections:
//
//  1. GlassContainer   — frosted-glass card with blur + border
//  2. Pill             — small coloured badge/tag
//  3. CompletionOverlay — end-of-session card with confetti animation
//  4. Highway sign widgets — paints US Interstate, US Route, Canadian, State signs
//  5. Search helpers   — SearchDot, MapPickButton, StyledSearchField

import 'dart:math' as math;
import 'dart:ui';           // ImageFilter (for blur)
import 'package:flutter/material.dart';
import 'theme.dart';

// ══════════════════════════════════════════════════════════════════════════════
// SECTION 1 — GLASS CONTAINER
// A frosted-glass effect card. Clips the child to rounded corners, applies a
// Gaussian blur to whatever is behind it, then draws a semi-transparent fill
// and a thin white border on top.
// ══════════════════════════════════════════════════════════════════════════════

class GlassContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final BorderRadius borderRadius;
  final Color? color;       // Override fill; defaults to C.glass (~75% dark blue)
  final Color? borderColor; // Override border; defaults to C.glassBorder (~8% white)
  final double blur;        // Backdrop blur radius in logical pixels

  const GlassContainer({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.color,
    this.borderColor,
    this.blur = 20,
  });

  @override
  Widget build(BuildContext context) {
    // ClipRRect enforces the rounded corners so the blur doesn't spill outside.
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        // sigmaX/Y = how many pixels to blur in each direction.
        // Higher values = stronger frosted effect, but slightly more GPU cost.
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: color ?? C.glass,
            borderRadius: borderRadius,
            border: Border.all(color: borderColor ?? C.glassBorder),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// SECTION 2 — PILL BADGE
// A small rounded-rectangle label used for ETA, distance remaining, etc.
// ══════════════════════════════════════════════════════════════════════════════

class Pill extends StatelessWidget {
  final String text;
  final Color bg; // Background fill colour
  final Color fg; // Text / foreground colour

  const Pill({super.key, required this.text, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20), // Fully rounded sides
      ),
      child: Text(text, style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

// ── Completion overlay: map stays visible, confetti falls, small popup ────────

// ══════════════════════════════════════════════════════════════════════════════
// SECTION 3 — COMPLETION OVERLAY
// Shown when the study timer reaches zero. The map remains visible underneath.
// Confetti particles fall continuously while a glass card slides up from the
// bottom with a congratulations message and a "Start New Session" button.
// ══════════════════════════════════════════════════════════════════════════════

class CompletionOverlay extends StatefulWidget {
  final int studyMinutes; // How many minutes the session lasted (for display)
  final VoidCallback onDone; // Called when the user taps "Start New Session"

  const CompletionOverlay(
      {super.key, required this.studyMinutes, required this.onDone});

  @override
  State<CompletionOverlay> createState() => _CompletionOverlayState();
}

class _CompletionOverlayState extends State<CompletionOverlay>
    with SingleTickerProviderStateMixin {
  // AnimationController drives the repeating confetti fall (0 → 1, loops).
  late final AnimationController _ctrl;
  // Pre-generated list of particle descriptors — positions, speeds, colours.
  late final List<_ConfettiParticle> _particles;

  @override
  void initState() {
    super.initState();
    // Use a fixed seed so the confetti pattern is always the same.
    final rng = math.Random(42);
    // 72 particles is enough for a dense but not overwhelming shower.
    _particles = List.generate(72, (_) => _ConfettiParticle.random(rng));
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(); // Loops forever until disposed
  }

  @override
  void dispose() {
    _ctrl.dispose(); // Always cancel the animation to avoid memory leaks
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pad  = MediaQuery.of(context).padding;
    final size = MediaQuery.of(context).size;
    // On wide screens (tablet/landscape) cap the card width and centre it.
    final isWide     = size.shortestSide >= 600 || size.width > size.height;
    final cardWidth  = isWide ? (size.width * 0.55).clamp(360.0, 520.0) : size.width - 40;
    final cardLeft   = isWide ? (size.width - cardWidth) / 2 : 20.0;

    return Stack(
      children: [
        // ── Confetti (no background — map shows through) ──────────────────
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => CustomPaint(
            painter: _ConfettiPainter(_particles, _ctrl.value),
            size: Size.infinite,
          ),
        ),

        // ── Centred popup card ────────────────────────────────────────────
        Positioned(
          left: cardLeft,
          width: cardWidth,
          bottom: pad.bottom + 20,
          child: TweenAnimationBuilder<double>(
            // Scale from 82% → 100% with an elastic overshoot so the card
            // "bounces in" rather than just fading.
            tween: Tween(begin: 0.82, end: 1.0),
            duration: const Duration(milliseconds: 650),
            curve: Curves.elasticOut,
            builder: (_, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: GlassContainer(
              borderColor: C.accent.withValues(alpha: 0.3),
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🎉', style: TextStyle(fontSize: 52)),
                  const SizedBox(height: 10),
                  const Text(
                    'Study Session Complete!',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: C.accent),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  // Dynamic text: correctly pluralises "minute" / "minutes"
                  Text(
                    'You crushed ${widget.studyMinutes} minute${widget.studyMinutes != 1 ? "s" : ""} '
                    'of focused work. Keep it up! 🚀',
                    style: const TextStyle(
                        fontSize: 14, color: C.textDim, height: 1.6),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: widget.onDone,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: C.accent,
                        foregroundColor: C.bg,
                        padding:
                            const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13)),
                        textStyle: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      child: const Text('Start New Session'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Confetti particle model ───────────────────────────────────────────────────

// Describes one confetti rectangle's properties. All values are normalised
// (0–1 scale) so they work regardless of screen size.
class _ConfettiParticle {
  final double startX;      // 0–1 normalised screen width
  final double phase;       // stagger offset 0–1 (shifts when this particle starts falling)
  final double fallSpeed;   // screen-heights per animation cycle
  final double swayAmp;     // normalised horizontal sway amplitude
  final double size;        // px
  final double aspect;      // width/height of the rectangle (< 1 = tall and thin)
  final double rotSpeed;    // full rotations per animation cycle
  final Color color;

  const _ConfettiParticle({
    required this.startX,
    required this.phase,
    required this.fallSpeed,
    required this.swayAmp,
    required this.size,
    required this.aspect,
    required this.rotSpeed,
    required this.color,
  });

  // Randomises all properties within hand-tuned ranges to look natural.
  factory _ConfettiParticle.random(math.Random rng) {
    const colors = [
      Color(0xFFFF6B6B), // red
      Color(0xFFFFD93D), // yellow
      Color(0xFF6BCB77), // green
      Color(0xFF4D96FF), // blue
      Color(0xFFFF922B), // orange
      Color(0xFFC084FC), // purple
      Color(0xFFF9A8D4), // pink
    ];
    return _ConfettiParticle(
      startX:    rng.nextDouble(),
      phase:     rng.nextDouble(),
      fallSpeed: 0.25 + rng.nextDouble() * 0.35, // Varies so particles fall at different rates
      swayAmp:   0.02 + rng.nextDouble() * 0.04, // Gentle left-right wiggle
      size:      6 + rng.nextDouble() * 8,        // 6–14 px wide
      aspect:    0.35 + rng.nextDouble() * 0.35,  // 0.35–0.70 height ratio (flat rectangles)
      rotSpeed:  1 + rng.nextDouble() * 3,        // 1–4 full rotations per cycle
      color:     colors[rng.nextInt(colors.length)],
    );
  }
}

// ── Confetti painter ──────────────────────────────────────────────────────────

// CustomPainter that draws all confetti rectangles each frame.
// t is the repeating animation value [0, 1].
class _ConfettiPainter extends CustomPainter {
  final List<_ConfettiParticle> particles;
  final double t; // animation value 0–1 (repeating)

  const _ConfettiPainter(this.particles, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in particles) {
      // Normalised y: starts above screen, falls through, wraps around
      // The modulo keeps it cycling; the -0.08/+0.08 offsets let particles
      // appear just above the top and disappear just below the bottom.
      final ny = (p.phase + t * p.fallSpeed) % 1.15 - 0.08;
      if (ny < -0.1 || ny > 1.1) continue; // off-screen — skip drawing

      // Slight sinusoidal sway left/right to look more realistic
      final nx = p.startX +
          math.sin(p.phase * 20 + t * math.pi * 4) * p.swayAmp;

      final x   = nx * size.width;
      final y   = ny * size.height;
      final rot = (p.phase + t * p.rotSpeed) * math.pi * 2; // Continuous rotation
      final w   = p.size;
      final h   = p.size * p.aspect; // Flat rectangle (aspect < 1)

      paint.color = p.color;
      // Save/translate/rotate/restore pattern so each particle rotates around
      // its own centre without affecting other particles.
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(rot);
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: w, height: h),
        paint,
      );
      canvas.restore();
    }
  }

  // Only repaint when the animation value has changed (every frame during animation)
  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}

// ══════════════════════════════════════════════════════════════════════════════
// SECTION 4 — HIGHWAY SIGN WIDGETS
// Renders US Interstate shields, US Route pentagons, State ovals, and
// Canadian provincial rectangles as custom-painted widgets.
//
// Usage flow:
//   HighwaySign(ref: step.ref)
//     → HighwayRefData.parse(ref)   (classify + extract number)
//     → _ShieldWidget               (size box + CustomPaint)
//       → _InterstateShieldPainter / _USRoutePainter / etc.
// ══════════════════════════════════════════════════════════════════════════════

// Internal enum: the kind of road sign to render.
enum _HwyType { interstate, usRoute, state, canadian, generic }

/// Parsed highway reference (e.g. "I 95" → type=interstate, number="95").
// Encapsulates the result of parsing an OSRM ref string so the shield painter
// gets clean inputs without any regex logic in the widget.
class HighwayRefData {
  final _HwyType type;
  final String number; // Just the digits (and optional letter suffix) e.g. "95", "15A"
  final String prefix; // State / province abbreviation e.g. "ON", "CA"

  const HighwayRefData._(this.type, this.number, [this.prefix = '']);

  /// Parse an OSRM `ref` string such as "I 95", "US-1", "ON-400", "CA 1".
  /// Multiple refs separated by ";" are ranked: Interstate > US > Canadian > State.
  // OSRM sometimes returns multiple refs for the same road (e.g. "I-95;US-1").
  // We pick the most "prestigious" one to display.
  static HighwayRefData? parse(String ref) {
    if (ref.isEmpty) return null;
    final candidates = ref
        .split(';')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map(_parseSingle)
        .whereType<HighwayRefData>() // Drop nulls (unrecognised formats)
        .toList();
    if (candidates.isEmpty) return null;
    // Prefer in order: interstate → us → canadian → state → generic
    // _HwyType.index gives the natural priority order defined in the enum.
    candidates.sort((a, b) => a.type.index.compareTo(b.type.index));
    return candidates.first;
  }

  // Tries each regex pattern in priority order and returns the first match.
  static HighwayRefData? _parseSingle(String s) {
    // Interstate: "I 95", "I-95", "I95"
    var m = RegExp(r'^I[\s\-]?(\d+[A-Z]?)$', caseSensitive: false).firstMatch(s);
    if (m != null) return HighwayRefData._(_HwyType.interstate, m.group(1)!);

    // US Route: "US 1", "US-101"
    m = RegExp(r'^US[\s\-](\d+[A-Z]?)$', caseSensitive: false).firstMatch(s);
    if (m != null) return HighwayRefData._(_HwyType.usRoute, m.group(1)!);

    // Canadian provincial: "ON-400", "QC 20", "BC-1", "AB 2"
    m = RegExp(
            r'^(AB|BC|MB|NB|NL|NS|NT|NU|ON|PE|QC|SK|YT)[\s\-](\d+[A-Z]?)$',
            caseSensitive: false)
        .firstMatch(s);
    if (m != null) {
      return HighwayRefData._(
          _HwyType.canadian, m.group(2)!, m.group(1)!.toUpperCase());
    }

    // State route: "CA 1", "NY-9", "TX-35"
    // Two-letter prefix that didn't match the Canadian list is treated as a US state.
    m = RegExp(r'^([A-Z]{2})[\s\-](\d+[A-Z]?)$', caseSensitive: false)
        .firstMatch(s);
    if (m != null) {
      return HighwayRefData._(
          _HwyType.state, m.group(2)!, m.group(1)!.toUpperCase());
    }

    // Generic numbered road (e.g. "400", "A1") — no country-specific styling
    m = RegExp(r'^[A-Z]?(\d+[A-Z]?)$', caseSensitive: false).firstMatch(s);
    if (m != null) return HighwayRefData._(_HwyType.generic, m.group(1)!);

    return null; // Unrecognised format — caller will skip rendering
  }
}

/// Renders the appropriate highway shield for a given OSRM `ref` string.
///
/// Usage:
///   HighwaySign(ref: step.ref, height: 32)
// If the ref can't be parsed, renders a zero-size box (SizedBox.shrink).
class HighwaySign extends StatelessWidget {
  final String ref;    // Raw OSRM ref string, e.g. "I 95" or "ON-400;CA 400"
  final double height; // Desired height in logical pixels; width is computed from aspectRatio

  const HighwaySign({super.key, required this.ref, this.height = 34});

  @override
  Widget build(BuildContext context) {
    final data = HighwayRefData.parse(ref);
    if (data == null) return const SizedBox.shrink(); // Nothing to draw

    // Dispatch to the correct painter based on road type.
    // Each painter has a hardcoded aspectRatio that matches the real sign's proportions.
    switch (data.type) {
      case _HwyType.interstate:
        return _ShieldWidget(
          height: height,
          aspectRatio: 0.82, // Slightly taller than wide (classic shield shape)
          painter: _InterstateShieldPainter(data.number),
        );
      case _HwyType.usRoute:
        return _ShieldWidget(
          height: height,
          aspectRatio: 0.84,
          painter: _USRoutePainter(data.number),
        );
      case _HwyType.canadian:
        return _ShieldWidget(
          height: height,
          aspectRatio: 1.1, // Slightly wider than tall (rectangular sign)
          painter: _CanadianPainter(data.number, data.prefix),
        );
      case _HwyType.state:
      case _HwyType.generic:
        return _ShieldWidget(
          height: height,
          aspectRatio: 1.1,
          painter: _StateRoutePainter(data.number, data.prefix),
        );
    }
  }
}

// Internal helper: wraps a CustomPainter in a correctly-sized SizedBox.
class _ShieldWidget extends StatelessWidget {
  final double height;
  final double aspectRatio; // width = height * aspectRatio
  final CustomPainter painter;

  const _ShieldWidget(
      {required this.height,
      required this.aspectRatio,
      required this.painter});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: height * aspectRatio,
      height: height,
      child: CustomPaint(painter: painter),
    );
  }
}

// ── US Interstate Shield ──────────────────────────────────────────────────────
// Classic blue/red pentagon shield shape.
// Layers from back to front:
//   1. White outline path (slightly larger than the fill)
//   2. Blue fill clipped to shield path
//   3. Red cap at the top (curves down at the bottom edge)
//   4. "INTERSTATE" text in the red zone
//   5. Route number in the blue zone

class _InterstateShieldPainter extends CustomPainter {
  final String number;
  const _InterstateShieldPainter(this.number);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Shield path (white outline, slightly enlarged)
    canvas.drawPath(_shieldPath(w, h), Paint()..color = Colors.white);

    // Blue body (inset 1.5 px to show the white border around it)
    final inset = 1.8;
    canvas.save();
    canvas.translate(inset, inset);
    // Clip subsequent drawing to the inset shield shape
    canvas.clipPath(_shieldPath(w - inset * 2, h - inset * 2));

    // Blue fill — dark navy, matches the real US Interstate sign colour
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF003087));

    // Red top cap (top ~30% with curved bottom edge that matches real signs)
    final redH = h * 0.30;
    final redPath = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(w, redH * 0.8)
      ..quadraticBezierTo(w * 0.75, redH * 1.05, w * 0.5, redH * 1.08)
      ..quadraticBezierTo(w * 0.25, redH * 1.05, 0, redH * 0.8)
      ..close();
    canvas.drawPath(redPath, Paint()..color = const Color(0xFFBF0A30));

    canvas.restore();

    // "INTERSTATE" label (tiny, white, in red zone)
    _drawCentredText(canvas, 'INTERSTATE', w,
        y: h * 0.055,
        fontSize: h * 0.115,
        fontWeight: FontWeight.w900,
        color: Colors.white,
        letterSpacing: 0.3);

    // Route number (large, white, in blue zone) — font size shrinks for 3-4 digit numbers
    final numFontSize =
        number.length <= 2 ? h * 0.38 : number.length == 3 ? h * 0.30 : h * 0.24;
    _drawCentredText(canvas, number, w,
        y: h * 0.33,
        fontSize: numFontSize,
        fontWeight: FontWeight.w900,
        color: Colors.white);
  }

  /// Classic Interstate shield: wide top, tapering sides, pointed bottom.
  // Built with quadratic bezier curves to get smooth rounded corners at the
  // top and a gentle taper to the bottom point.
  static Path _shieldPath(double w, double h) {
    final path = Path();
    path.moveTo(w * 0.12, 0);
    path.lineTo(w * 0.88, 0);
    path.quadraticBezierTo(w, 0, w, h * 0.12);          // Top-right corner
    path.lineTo(w * 0.98, h * 0.58);
    path.quadraticBezierTo(w * 0.85, h * 0.80, w * 0.65, h * 0.92);
    path.quadraticBezierTo(w * 0.5, h, w * 0.35, h * 0.92); // Bottom point
    path.quadraticBezierTo(w * 0.15, h * 0.80, w * 0.02, h * 0.58);
    path.lineTo(0, h * 0.12);
    path.quadraticBezierTo(0, 0, w * 0.12, 0);          // Top-left corner
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(_InterstateShieldPainter old) => old.number != number;
}

// ── US Route Pentagon ─────────────────────────────────────────────────────────
// White pentagon with black outline, "US" label + number.
// The pentagon shape (flat top, angled sides, pointed bottom) is the
// traditional US Route marker shape.

class _USRoutePainter extends CustomPainter {
  final String number;
  const _USRoutePainter(this.number);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Pentagon: flat top, angled sides meeting at a bottom point
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h * 0.55)
      ..quadraticBezierTo(w * 0.75, h * 0.82, w * 0.5, h) // Bottom-right slope
      ..quadraticBezierTo(w * 0.25, h * 0.82, 0, h * 0.55) // Bottom-left slope
      ..close();

    // White fill + black stroke (thick border is part of the official design)
    canvas.drawPath(path, Paint()..color = Colors.white);
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = h * 0.07);

    // "US" label — small, centered in the upper portion
    _drawCentredText(canvas, 'US', w,
        y: h * 0.04,
        fontSize: h * 0.20,
        fontWeight: FontWeight.w900,
        color: Colors.black);

    // Route number — large, centered below "US"
    final numFontSize =
        number.length <= 2 ? h * 0.38 : number.length == 3 ? h * 0.28 : h * 0.22;
    _drawCentredText(canvas, number, w,
        y: h * 0.24,
        fontSize: numFontSize,
        fontWeight: FontWeight.w900,
        color: Colors.black);
  }

  @override
  bool shouldRepaint(_USRoutePainter old) => old.number != number;
}

// ── Canadian Provincial ───────────────────────────────────────────────────────
// White rectangle, green border, province code + number.
// Matches the distinctive green-and-white look of Canadian provincial signs.

class _CanadianPainter extends CustomPainter {
  final String number;
  final String province; // Two-letter province code e.g. "ON"
  const _CanadianPainter(this.number, this.province);

  // Official Canadian highway sign green
  static const _green = Color(0xFF006B3F);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // Rounded rectangle — Canadian signs have slightly rounded corners
    final rr = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, w, h), Radius.circular(h * 0.10));

    // White background fill
    canvas.drawRRect(rr, Paint()..color = Colors.white);
    // Green border (thick, matches real sign proportions)
    canvas.drawRRect(
        rr,
        Paint()
          ..color = _green
          ..style = PaintingStyle.stroke
          ..strokeWidth = h * 0.08);

    // Province abbreviation (small, green) — sits above the route number
    _drawCentredText(canvas, province, w,
        y: h * 0.04,
        fontSize: h * 0.18,
        fontWeight: FontWeight.w700,
        color: _green);

    // Route number (large, black)
    final numFontSize =
        number.length <= 2 ? h * 0.42 : number.length == 3 ? h * 0.33 : h * 0.26;
    _drawCentredText(canvas, number, w,
        y: h * 0.22,
        fontSize: numFontSize,
        fontWeight: FontWeight.w900,
        color: Colors.black);
  }

  @override
  bool shouldRepaint(_CanadianPainter old) =>
      old.number != number || old.province != province;
}

// ── State Route ───────────────────────────────────────────────────────────────
// Dark-blue rounded rectangle with state code + number in white.
// Used for US state routes and any unrecognised numbered roads.

class _StateRoutePainter extends CustomPainter {
  final String number;
  final String state; // Two-letter state code e.g. "CA", or empty for generic roads
  const _StateRoutePainter(this.number, this.state);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rr = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, w, h), Radius.circular(h * 0.12));

    // Dark navy fill — matches the common "dark blue" state sign aesthetic
    canvas.drawRRect(rr, Paint()..color = const Color(0xFF1A3A6B));
    // Faint white border for definition
    canvas.drawRRect(
        rr,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = h * 0.06);

    // State abbreviation above the number (only if we have one)
    if (state.isNotEmpty) {
      _drawCentredText(canvas, state, w,
          y: h * 0.04,
          fontSize: h * 0.18,
          fontWeight: FontWeight.w700,
          color: Colors.white70);
    }

    // Route number — y position shifts up when there's no state label
    final numFontSize =
        number.length <= 2 ? h * 0.40 : number.length == 3 ? h * 0.30 : h * 0.24;
    _drawCentredText(canvas, number, w,
        y: state.isNotEmpty ? h * 0.22 : h * 0.20,
        fontSize: numFontSize,
        fontWeight: FontWeight.w900,
        color: Colors.white);
  }

  @override
  bool shouldRepaint(_StateRoutePainter old) =>
      old.number != number || old.state != state;
}

// ── Shared text helper ────────────────────────────────────────────────────────
// All highway sign painters use this function to draw horizontally-centred text.
// It uses TextPainter directly (rather than a Text widget) because we're inside
// a CustomPainter.paint() call where we have access only to a Canvas.

void _drawCentredText(
  Canvas canvas,
  String text,
  double containerWidth, {
  required double y,           // Top-left Y offset of the text
  required double fontSize,
  required FontWeight fontWeight,
  required Color color,
  double letterSpacing = 0,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight,
        letterSpacing: letterSpacing,
        height: 1, // No extra line-height — we position manually
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: containerWidth); // Measure the text width

  // X offset: centre the measured text within the container width
  tp.paint(canvas, Offset((containerWidth - tp.width) / 2, y));
}

// ══════════════════════════════════════════════════════════════════════════════
// SECTION 5 — SEARCH HELPER WIDGETS
// Small reusable pieces used inside HomeOverlay's search bar rows.
// ══════════════════════════════════════════════════════════════════════════════

// ── SearchDot ─────────────────────────────────────────────────────────────────
// A coloured circle that indicates whether this row is the origin or destination.
// Green = origin, Red = destination — matches the map marker colours.
class SearchDot extends StatelessWidget {
  final bool isOrigin;
  const SearchDot({super.key, required this.isOrigin});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: isOrigin ? C.accent : C.red, // Green for origin, red for dest
        shape: BoxShape.circle,
      ),
    );
  }
}

// ── MapPickButton ─────────────────────────────────────────────────────────────
// A square icon button used to activate map-tap-to-pick mode for either the
// origin or destination. Highlights in blue when active.
class MapPickButton extends StatelessWidget {
  final bool active;       // Whether this pick mode is currently enabled
  final String emoji;      // The icon to display (📍 for origin, 🏁 for dest)
  final VoidCallback onTap;

  const MapPickButton({super.key, required this.active, required this.emoji, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          // Highlight with C.blue when active, otherwise nearly invisible
          color: active ? C.blue : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? C.blue : Colors.white.withValues(alpha: 0.08)),
        ),
        alignment: Alignment.center,
        child: Text(emoji, style: const TextStyle(fontSize: 18)),
      ),
    );
  }
}

// ── StyledSearchField ─────────────────────────────────────────────────────────
// A dark-themed TextField that expands to fill available width (Expanded).
// Shows an ✕ clear button inside the field whenever there is text, so the
// user can wipe the field mid-typing without losing keyboard focus.
class StyledSearchField extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final FocusNode focusNode;
  final ValueChanged<String>? onChanged; // Called on every keystroke (triggers search)
  final VoidCallback? onTap;            // Called when the user taps the field

  const StyledSearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.focusNode,
    this.onChanged,
    this.onTap,
  });

  @override
  State<StyledSearchField> createState() => _StyledSearchFieldState();
}

class _StyledSearchFieldState extends State<StyledSearchField> {
  // Tracks whether the field has text so we know when to show the clear button
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.isNotEmpty;
    // Listen to controller changes so the ✕ appears/disappears reactively
    widget.controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    final hasText = widget.controller.text.isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        onChanged: widget.onChanged,
        onTap: widget.onTap,
        style: const TextStyle(color: C.text, fontSize: 15),
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: const TextStyle(color: C.textDim),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.06),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          // ✕ clear button — only shown when the field has text
          suffixIcon: _hasText
              ? GestureDetector(
                  onTap: () {
                    widget.controller.clear();
                    // Notify the parent so it clears search results too
                    widget.onChanged?.call('');
                    // Intentionally no unfocus — keyboard stays open so the
                    // user can immediately start typing a new query
                  },
                  child: const Icon(
                    Icons.close_rounded,
                    color: C.textDim,
                    size: 18,
                  ),
                )
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.blue),
          ),
        ),
      ),
    );
  }
}
