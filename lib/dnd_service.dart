// ── dnd_service.dart ───────────────────────────────────────────────────────────
// Thin wrapper around the native "nav_study/dnd" MethodChannel.
//
// The native side (Android Kotlin / iOS Swift) handles the actual system calls:
//   Android: NotificationManager.setInterruptionFilter() — needs MANAGE_DND permission.
//   iOS:     Programmatic DND is not allowed by Apple; we open the Focus settings
//            page so the user can enable it themselves.
//
// All methods are no-ops on the wrong platform and swallow exceptions silently
// because DND is a nice-to-have — a crash would be far worse than a missed toggle.

import 'dart:io';
import 'package:flutter/services.dart'; // MethodChannel

/// Manages Do-Not-Disturb during a study session.
/// Android: uses NotificationManager interruption filter (requires policy access).
/// iOS: DND cannot be set programmatically; caller should show a tip instead.
class DndService {
  // The channel name must exactly match the one registered in MainActivity.kt
  // (Android) and AppDelegate.swift (iOS).
  static const _ch = MethodChannel('nav_study/dnd');

  // ── Android permission helpers ─────────────────────────────────────────────────

  /// Returns true if the app has notification policy access (Android only).
  // This is the MANAGE_NOTIFICATION_POLICY permission — without it,
  // calling enable() would silently fail on Android 6+.
  static Future<bool> hasPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false; // Native side threw — treat as no permission
    }
  }

  /// Opens the system notification policy settings so the user can grant access.
  // On Android this launches the "Do not disturb access" settings screen.
  static Future<void> requestPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('requestPermission');
    } catch (_) {} // Ignore — worst case user sees nothing
  }

  // ── DND toggle ─────────────────────────────────────────────────────────────────

  /// Enable DND (silences all interruptions). No-op if permission not granted.
  // Called at the start of a study session on Android.
  static Future<void> enable() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('enable');
    } catch (_) {}
  }

  /// Restore normal interruptions.
  // Called when the session ends (timer done or user taps Stop).
  static Future<void> disable() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('disable');
    } catch (_) {}
  }

  // ── iOS Focus settings ─────────────────────────────────────────────────────────

  /// iOS only: opens the Focus / Do Not Disturb settings screen.
  // Since iOS doesn't allow apps to toggle DND programmatically, we redirect
  // the user to the system settings where they can enable Focus themselves.
  static Future<void> openFocusSettings() async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod('openFocusSettings');
    } catch (_) {}
  }
}
