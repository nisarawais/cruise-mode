// ── theme.dart ─────────────────────────────────────────────────────────────────
// Central colour palette for the entire app.
//
// All colours are defined as static const values inside the class C so they
// can be referenced anywhere with just "C.blue", "C.accent", etc. — no import
// of this file is needed beyond the one import line.
//
// Colour format: Color(0xAARRGGBB)
//   AA = alpha (00 = fully transparent, FF = fully opaque)
//   RR GG BB = red, green, blue hex components

import 'package:flutter/material.dart';

class C {
  // ── Background / glass surfaces ────────────────────────────────────────────

  // Semi-transparent dark blue — used as the frosted-glass fill on cards and
  // overlays. The BF alpha (~75%) lets the map bleed through subtly.
  static const glass = Color(0xBF0E111C);

  // Very faint white border on glass cards — just enough to separate layers
  // without looking harsh. 0x14 alpha ≈ 8% opaque.
  static const glassBorder = Color(0x14FFFFFF);

  // ── Accent colours ─────────────────────────────────────────────────────────

  // Primary blue — used for the route line, turn banner, pills, and buttons.
  static const blue = Color(0xFF4A9CFF);

  // Translucent version of blue — used for glow rings and pill backgrounds.
  // 0x59 alpha ≈ 35% opaque.
  static const blueGlow = Color(0x594A9CFF);

  // Teal/green accent — origin marker, completion card, some success states.
  static const accent = Color(0xFF00E4A5);

  // Red — destination marker, stop button, off-ramp states.
  static const red = Color(0xFFFF4B6E);

  // ── Text colours ───────────────────────────────────────────────────────────

  // Near-white — primary readable text on dark backgrounds.
  static const text = Color(0xFFF0F2F8);

  // Dimmed version of text — secondary labels, captions, placeholders.
  // 0x8C alpha ≈ 55% opaque.
  static const textDim = Color(0x8CF0F2F8);

  // Gold/amber — used for the study timer field and the day-progress bar.
  static const gold = Color(0xFFFFB347);

  // ── App background ─────────────────────────────────────────────────────────

  // Deep near-black with a slight blue tint — the Scaffold background and the
  // Android system navigation bar colour.
  static const bg = Color(0xFF0A0C14);
}
