// ── home_overlay.dart ──────────────────────────────────────────────────────────
// The pre-navigation UI that sits on top of the map. Allows the user to:
//   • Type a starting point and destination (with live geocode search)
//   • Tap the map to pin a point (map-pick mode)
//   • See the calculated route summary (duration, distance, ETA)
//   • Set a study timer and start the navigation session
//
// Layout adapts to screen size:
//   • Phone  → collapsible bottom sheet (GestureDetector for swipe-to-collapse)
//   • Tablet → fixed left side panel (340 px wide)

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'models.dart';
import 'services.dart';
import 'theme.dart';
import 'widgets.dart';

// ── HomeOverlay widget ────────────────────────────────────────────────────────

// HomeOverlay is stateful because it owns:
//   - Text controllers and focus nodes for the two search fields
//   - The live search-results list (updated as the user types)
//   - The collapsed/expanded state of the bottom sheet on phones

class HomeOverlay extends StatefulWidget {
  // Data passed down from AppShell — reflects current app state
  final Place? origin;
  final Place? dest;
  final RouteData? route;
  final bool isLoadingRoute;
  final String? pickMode;
  final LatLng? carPos;        // Car position — used as proximity bias when origin isn't set yet

  // Callbacks that bubble state changes back up to AppShell
  final ValueChanged<Place> onOriginSet;
  final ValueChanged<Place> onDestSet;
  final VoidCallback onClear;
  final VoidCallback onGetRoute;          // Manual "Calculate Route" button tap
  final ValueChanged<String?> onPickModeChanged;
  final void Function(int studyMinutes) onStartNavigation;

  const HomeOverlay({
    super.key,
    this.origin,
    this.dest,
    this.route,
    this.isLoadingRoute = false,
    this.pickMode,
    this.carPos,
    required this.onOriginSet,
    required this.onDestSet,
    required this.onClear,
    required this.onGetRoute,
    required this.onPickModeChanged,
    required this.onStartNavigation,
  });

  @override
  State<HomeOverlay> createState() => _HomeOverlayState();
}

class _HomeOverlayState extends State<HomeOverlay> {
  // ── Controllers & focus nodes ──────────────────────────────────────────────
  // Each search field needs a controller (to read/write text) and a focus node
  // (to detect when the user taps the field so we set _activeSearch).
  final _originCtrl = TextEditingController();
  final _destCtrl = TextEditingController();
  final _originFocus = FocusNode();
  final _destFocus = FocusNode();

  // Default study time matches the classic Pomodoro interval
  final _studyCtrl = TextEditingController(text: '25');

  // ── Local state ────────────────────────────────────────────────────────────
  List<Place> _searchResults = []; // Geocode results (used by the overlay, not in the tree)
  String? _activeSearch;           // Which field is currently being searched: 'origin' or 'dest'
  Timer? _debounce;                // Debounce timer — delays geocode until user pauses typing
  bool _sheetExpanded = true;      // Whether the bottom sheet is fully open (phone only)

  // ── Floating results overlay ───────────────────────────────────────────────
  // Results are rendered in an Overlay (floating above everything) rather than
  // inline in the panel. This means:
  //   • The panel layout never shifts when results appear → no jarring jump
  //   • The SingleChildScrollView never reacts → keyboard stays open
  // Each search field has its own LayerLink so the overlay can anchor to the
  // currently active field via CompositedTransformFollower.
  final _originLayerLink = LayerLink();
  final _destLayerLink   = LayerLink();
  OverlayEntry? _resultsEntry;   // null = overlay not showing
  double _overlayWidth = 280;    // updated from LayoutBuilder in _buildSearchFields

  // ── initState ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    // When both search fields lose focus (user taps the map, etc.) dismiss
    // the results overlay automatically.
    _originFocus.addListener(_onFocusChanged);
    _destFocus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!_originFocus.hasFocus && !_destFocus.hasFocus) {
      _hideResults();
    }
  }

  // ── didUpdateWidget ────────────────────────────────────────────────────────
  // Called whenever AppShell rebuilds and passes new props to HomeOverlay.
  // We keep the text fields in sync with the parent's state here, rather than
  // inside setState, so we don't lose focus or trigger extra rebuilds.
  @override
  void didUpdateWidget(HomeOverlay old) {
    super.didUpdateWidget(old);

    // Sync text field when origin is set externally (e.g. from a map tap)
    if (widget.origin != old.origin && widget.origin != null) {
      _originCtrl.text = widget.origin!.label;
    }
    // Sync text field when destination is set externally
    if (widget.dest != old.dest && widget.dest != null) {
      _destCtrl.text = widget.dest!.label;
    }
    // Clear text fields when the corresponding place is removed
    if (widget.origin == null && old.origin != null) _originCtrl.clear();
    if (widget.dest == null && old.dest != null) _destCtrl.clear();

    // Auto-expand and show route card when route arrives or updates
    if (widget.route != old.route && widget.route != null) {
      setState(() => _sheetExpanded = true);
    }

    // When pick mode ends (user tapped the map to pin a location), dismiss any
    // open results overlay — they belong to the previous typing session.
    if (old.pickMode != null && widget.pickMode == null) {
      _debounce?.cancel();
      _hideResults();
      setState(() => _activeSearch = null);
    }
  }

  // ── Geocode search (debounced) ─────────────────────────────────────────────
  // Called on every keystroke. Waits 400 ms after the user stops typing before
  // hitting the network, so we don't spam the geocoding API.
  void _onSearch(String query, String target) {
    _activeSearch = target;
    _debounce?.cancel(); // Reset the timer every keystroke
    if (query.length < 2) {
      // Not enough characters to produce useful results — hide overlay
      _hideResults();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      // Destination search: bias toward the origin address so nearby places
      // show up first. If origin isn't set yet, fall back to car position so
      // there's always a proximity anchor instead of returning global results.
      // Origin search: bias toward car position (current location).
      final LatLng? bias = target == 'dest'
          ? (widget.origin?.position ?? widget.carPos)
          : widget.carPos;
      final results = await ApiService.geocode(query, near: bias);
      // Guard: only update if the widget is still mounted AND this is still
      // the active search (user might have switched fields mid-request)
      if (!mounted || _activeSearch != target) return;
      _searchResults = results; // update WITHOUT setState — overlay handles its own rebuild
      _showResults();
    });
  }

  // ── Handle result selection ────────────────────────────────────────────────
  // Called when the user taps a result in the floating overlay.
  void _selectResult(Place place) {
    if (_activeSearch == 'origin') {
      _originCtrl.text = place.label; // Fill the text field with the chosen place
      widget.onOriginSet(place);       // Notify AppShell
    } else {
      _destCtrl.text = place.label;
      widget.onDestSet(place);
    }
    _hideResults();                   // Remove overlay and clear results list
    setState(() => _activeSearch = null);
    FocusScope.of(context).unfocus(); // Dismiss the keyboard
  }

  // ── Collapse the bottom sheet (phone only) ─────────────────────────────────
  void _collapse() {
    FocusScope.of(context).unfocus();
    _hideResults(); // Remove any open results overlay
    setState(() => _sheetExpanded = false);
  }

  // ── Cleanup ────────────────────────────────────────────────────────────────
  @override
  void dispose() {
    // Remove focus listeners before disposing the nodes
    _originFocus.removeListener(_onFocusChanged);
    _destFocus.removeListener(_onFocusChanged);
    // Remove any open overlay entry so it doesn't dangle after the widget is gone
    _resultsEntry?.remove();
    // Always dispose controllers and focus nodes to avoid memory leaks
    _originCtrl.dispose();
    _destCtrl.dispose();
    _originFocus.dispose();
    _destFocus.dispose();
    _studyCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  // ── Floating results overlay management ───────────────────────────────────
  // Results are shown in an Overlay entry that floats above the entire widget
  // tree, anchored to whichever search field is currently active via
  // CompositedTransformFollower. The panel layout is completely unaffected.

  /// Show (or refresh) the floating results dropdown.
  void _showResults() {
    if (_searchResults.isEmpty) { _hideResults(); return; }

    // Overlay already open — just signal it to rebuild with fresh results
    if (_resultsEntry != null) {
      _resultsEntry!.markNeedsBuild();
      return;
    }

    _resultsEntry = OverlayEntry(builder: (_) {
      // Anchor to the currently active field's LayerLink
      final link = (_activeSearch == 'origin') ? _originLayerLink : _destLayerLink;
      return Positioned(
        left: 0, top: 0,           // required when using CompositedTransformFollower
        child: CompositedTransformFollower(
          link: link,
          showWhenUnlinked: false,   // hide if anchor scrolls off-screen
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 10), // 10 px gap between field bottom and dropdown top
          child: SizedBox(
            width: _overlayWidth,    // matches the search-fields column width
            child: Material(
              color: Colors.transparent,
              child: GlassContainer(
                borderRadius: BorderRadius.circular(14),
                padding: EdgeInsets.zero,
                child: _buildResultsList(),
              ),
            ),
          ),
        ),
      );
    });

    Overlay.of(context).insert(_resultsEntry!);
  }

  /// Remove the floating results dropdown and clear the results list.
  void _hideResults() {
    _resultsEntry?.remove();
    _resultsEntry = null;
    _searchResults = [];
  }

  // ── build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isTablet    = size.shortestSide >= 600;
    final isLandscape = size.width > size.height;
    // Bottom sheet only for portrait phones; everything else uses the side panel.
    return (isTablet || isLandscape)
        ? _buildSidePanel(context)
        : _buildBottomSheet(context);
  }

  // ─── Side panel (tablet portrait, tablet landscape, landscape phone) ──────
  // Rebuilds fully on every rotation because size/pad come from MediaQuery,
  // which Flutter updates automatically when the device rotates.
  //
  // Panel width by orientation:
  //   Tablet portrait  → 340 px  (wide screen, generous panel)
  //   Tablet landscape → 320 px  (shorter height, give map more breathing room)
  //   Phone landscape  → 280 px  (compact)
  //
  // Max height is computed exactly from available space so the card never
  // overflows the screen in any orientation.
  // Content always scrolls — no overflow in portrait or landscape.

  Widget _buildSidePanel(BuildContext context) {
    final size        = MediaQuery.of(context).size;
    final pad         = MediaQuery.of(context).padding;
    final isTablet    = size.shortestSide >= 600;
    final isLandscape = size.width > size.height;

    // Panel width adapts to device type + orientation
    final panelWidth = isTablet
        ? (isLandscape ? 320.0 : 340.0)
        : 280.0;

    // Top offset: status bar height + small gap
    const topOffset = 12.0;
    const bottomMargin = 16.0;
    final panelTop    = pad.top + topOffset;
    // Exact available height so the card never runs off the bottom of the screen
    final maxHeight   = size.height - panelTop - bottomMargin;

    const cardPad = EdgeInsets.all(18.0);

    // Card content — results float in an Overlay (not inline), so this column
    // never shifts when results appear and the keyboard is never disturbed.
    final cardChild = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSearchFields(),

        if (widget.pickMode != null) _buildPickHint(),
        if (widget.isLoadingRoute && widget.route == null) _buildLoadingRow(),
        if (widget.route != null) ...[
          const SizedBox(height: 14),
          _buildRouteCard(widget.route!),
        ],
      ],
    );

    return Positioned(
      left: 16,
      top: panelTop,
      width: panelWidth,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: GlassContainer(
          borderRadius: BorderRadius.circular(20),
          padding: cardPad,
          // Always scrollable — handles portrait with a long route card
          // AND landscape with less vertical space equally well
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            // Never dismiss the keyboard on scroll — user may still be typing
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
            child: cardChild,
          ),
        ),
      ),
    );
  }

  // ─── Phone: top search bar + sliding bottom route card ───────────────────
  //
  // Layout:
  //   • Search fields live at the TOP — results overlay drops downward so the
  //     keyboard (which rises from the bottom) never covers them.
  //   • A "Calculate Route" button appears in the top card when both addresses
  //     are filled but no route exists yet.
  //   • Once a route is ready it slides up from the bottom as a route preview
  //     card. Swiping it down dismisses it; a small blue chip brings it back.
  //
  // _sheetExpanded controls whether the bottom route card is visible.

  Widget _buildBottomSheet(BuildContext context) {
    final pad       = MediaQuery.of(context).padding;
    final bottomPad = pad.bottom;

    return Stack(
      children: [

        // ── TOP SEARCH CARD ──────────────────────────────────────────────────
        // Floats below the status bar. Results overlay drops downward from the
        // active field — keyboard rising from the bottom won't cover them.
        Positioned(
          top: pad.top + 8,
          left: 12,
          right: 12,
          child: GlassContainer(
            borderRadius: BorderRadius.circular(20),
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSearchFields(),

                // "Calculate Route" — visible when both addresses are set
                // but no route has been fetched yet.
                if (widget.origin != null &&
                    widget.dest != null &&
                    widget.route == null &&
                    !widget.isLoadingRoute) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: widget.onGetRoute,
                      icon: const Icon(Icons.directions_rounded, size: 18),
                      label: const Text('Calculate Route'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: C.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],

                // Spinner while the route is being fetched
                if (widget.isLoadingRoute && widget.route == null)
                  _buildLoadingRow(),

                // Map-tap instruction when pick mode is active
                if (widget.pickMode != null) _buildPickHint(),
              ],
            ),
          ),
        ),

        // ── BOTTOM ROUTE PREVIEW CARD ────────────────────────────────────────
        // Slides up from the bottom when a route is ready.
        // Swiping down fast hides it (_sheetExpanded = false).
        if (widget.route != null)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            left: 0, right: 0,
            // Slide off the bottom when dismissed; slide back when expanded.
            bottom: _sheetExpanded ? 0 : -(500 + bottomPad),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) > 300) _collapse();
              },
              child: GlassContainer(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(26)),
                padding:
                    EdgeInsets.fromLTRB(20, 10, 20, 20 + bottomPad),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Drag handle — visual affordance for swipe-to-dismiss
                    Center(
                      child: Container(
                        width: 36, height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _buildRouteCard(widget.route!),
                  ],
                ),
              ),
            ),
          ),

        // ── "SHOW ROUTE" CHIP ────────────────────────────────────────────────
        // Appears at the bottom after the user swipes the route card away.
        // Tapping it slides the card back up.
        if (widget.route != null && !_sheetExpanded)
          Positioned(
            bottom: bottomPad + 16,
            left: 0, right: 0,
            child: Center(
              child: GestureDetector(
                onTap: () => setState(() => _sheetExpanded = true),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 9),
                  decoration: BoxDecoration(
                    color: C.blue,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                          color: C.blue.withValues(alpha: 0.45),
                          blurRadius: 14)
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.expand_less_rounded,
                          color: Colors.white, size: 18),
                      SizedBox(width: 4),
                      Text('Show route',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
          ),

      ], // Stack children
    ); // Stack
  }

  // ─── Shared content ───────────────────────────────────────────────────────
  // The following _build* methods are used by both the tablet and phone layouts.

  // ── Origin + Destination rows ──────────────────────────────────────────────
  // CompositedTransformTarget is placed ON the text field (inside Expanded),
  // not on the whole row. This means:
  //   • The overlay anchors to the bottom of the input box itself
  //   • _overlayWidth is the exact width of the text field → dropdown matches it
  // LayoutBuilder inside Expanded captures the field's rendered width.
  Widget _buildSearchFields() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Origin row
        Row(
          children: [
            const SearchDot(isOrigin: true),
            const SizedBox(width: 10),
            // Anchor + width-capture live on the StyledSearchField itself
            Expanded(
              child: CompositedTransformTarget(
                link: _originLayerLink,
                child: LayoutBuilder(builder: (_, c) {
                  _overlayWidth = c.maxWidth; // always up-to-date field width
                  return StyledSearchField(
                    key: const ValueKey('origin-field'),
                    controller: _originCtrl,
                    hint: 'Starting point',
                    focusNode: _originFocus,
                    onTap: () {
                      _activeSearch = 'origin';
                      if (!_sheetExpanded) setState(() => _sheetExpanded = true);
                    },
                    onChanged: (q) => _onSearch(q, 'origin'),
                  );
                }),
              ),
            ),
            const SizedBox(width: 10),
            MapPickButton(
              active: widget.pickMode == 'origin',
              emoji: '📍',
              onTap: () => widget.onPickModeChanged(
                  widget.pickMode == 'origin' ? null : 'origin'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Destination row — same pattern
        Row(
          children: [
            const SearchDot(isOrigin: false),
            const SizedBox(width: 10),
            Expanded(
              child: CompositedTransformTarget(
                link: _destLayerLink,
                child: LayoutBuilder(builder: (_, c) {
                  _overlayWidth = c.maxWidth;
                  return StyledSearchField(
                    key: const ValueKey('dest-field'),
                    controller: _destCtrl,
                    hint: 'Where to?',
                    focusNode: _destFocus,
                    onTap: () {
                      _activeSearch = 'dest';
                      if (!_sheetExpanded) setState(() => _sheetExpanded = true);
                    },
                    onChanged: (q) => _onSearch(q, 'dest'),
                  );
                }),
              ),
            ),
            const SizedBox(width: 10),
            MapPickButton(
              active: widget.pickMode == 'dest',
              emoji: '🏁',
              onTap: () => widget.onPickModeChanged(
                  widget.pickMode == 'dest' ? null : 'dest'),
            ),
          ],
        ),
      ],
    );
  }

  // ── Route-fetch progress indicator ────────────────────────────────────────
  // Shown between the search fields and the route card while OSRM is loading.
  Widget _buildLoadingRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(C.blue),
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'Calculating route…',
            style: TextStyle(color: C.textDim, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ── Map-pick hint ──────────────────────────────────────────────────────────
  // Shown below the search fields when map-pick mode is active.
  Widget _buildPickHint() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'Tap anywhere on the map to set the point',
        style: TextStyle(color: C.textDim, fontSize: 12),
      ),
    );
  }

  // ── Geocode results dropdown ───────────────────────────────────────────────
  // A constrained ListView capped at 220px tall. When there are more than 3
  // results a gradient + chevron hint makes it obvious the list is scrollable.
  Widget _buildResultsList() {
    // Show a scroll hint when results overflow the visible area (~4 tiles at 52px each)
    final canScroll = _searchResults.length > 3;
    return Stack(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            // Never let the list dismiss the keyboard — user is still typing
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
            itemCount: _searchResults.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
            itemBuilder: (_, i) {
              final p = _searchResults[i];
              return ListTile(
                dense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                // Primary: place name (bolded slightly with w500)
                title: Text(
                  p.name,
                  style: const TextStyle(
                      color: C.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // Secondary: city, state context
                subtitle: p.detail.isNotEmpty
                    ? Text(
                        p.detail,
                        style:
                            const TextStyle(color: C.textDim, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : null,
                onTap: () => _selectResult(p),
              );
            },
          ),
        ),
        // Gradient fade + chevron hints that more results are below
        if (canScroll)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              // IgnorePointer prevents the gradient overlay from absorbing taps
              child: Container(
                height: 38,
                decoration: BoxDecoration(
                  // Fade from transparent at top to near-opaque at bottom —
                  // visually "hides" the bottom of the list without hard-clipping.
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF0E111C).withValues(alpha: 0),
                      const Color(0xFF0E111C).withValues(alpha: 0.92),
                    ],
                  ),
                ),
                alignment: Alignment.bottomCenter,
                child: const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Icon(Icons.keyboard_arrow_down_rounded,
                      color: C.textDim, size: 18),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ─── Route card ───────────────────────────────────────────────────────────
  // Displayed below the search fields once a route has been fetched.
  // Shows: duration | distance | arrival time, a study-timer picker,
  // and Clear / Start Focus buttons.

  Widget _buildRouteCard(RouteData route) {
    // ── Format duration ──
    final dur = route.duration; // seconds
    final hrs = (dur / 3600).floor();
    final mins = ((dur % 3600) / 60).ceil();
    final durText = hrs > 0 ? '${hrs}h ${mins}m' : '$mins min';

    // ── Format distance (always metric in the planning view) ──
    final dist = route.distance; // metres
    final distText = dist >= 1000
        ? '${(dist / 1000).round()} km'
        : '${dist.round()} m';

    // ── Estimated arrival ──
    final arrival = DateTime.now().add(Duration(seconds: dur.round()));
    final h       = arrival.hour % 12 == 0 ? 12 : arrival.hour % 12;
    final m       = arrival.minute.toString().padLeft(2, '0');
    final suffix  = arrival.hour >= 12 ? 'PM' : 'AM';
    final arrText = '$h:$m $suffix';

    // Use a subtle transparent container so it blends with the sheet glass
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          // ── Stats row: Duration | Distance | Arrival ──
          Row(
            children: [
              _stat(durText, 'DURATION'),
              _divider(),
              _stat(distText, 'DISTANCE'),
              _divider(),
              _stat(arrText, 'ARRIVAL'),
            ],
          ),
          const SizedBox(height: 14),

          // ── Study timer row ──
          // The user types how many minutes they want to study.
          // The default is 25 (classic Pomodoro), but they can change it.
          Row(
            children: [
              const Text('⏱️', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              const Text('Study timer',
                  style: TextStyle(color: C.textDim, fontSize: 13)),
              const SizedBox(width: 12),
              // Numeric input capped at 480 minutes (8 hours) in _startNavigation
              SizedBox(
                width: 80,
                child: TextField(
                  controller: _studyCtrl,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: C.gold,
                      fontSize: 18,
                      fontWeight: FontWeight.w700),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: C.gold),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text('minutes',
                  style: TextStyle(color: C.textDim, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 16),

          // ── Action buttons row ──
          Row(
            children: [
              // Clear — wipes the origin, dest, and route; returns to blank map
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.onClear,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: C.textDim,
                    side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.08)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Clear'),
                ),
              ),
              const SizedBox(width: 10),
              // Start Focus — hands control to AppShell._startNavigation()
              // clamped to 1–480 minutes so invalid input is handled gracefully
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: () {
                    final mins = int.tryParse(_studyCtrl.text) ?? 25;
                    widget.onStartNavigation(mins.clamp(1, 480));
                  },
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('Start Focus'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: C.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Stat column helper ─────────────────────────────────────────────────────
  // A big value (e.g. "42 min") with a small ALL-CAPS label below it.
  // Wrapped in Expanded so all three stat columns share equal width.
  Widget _stat(String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: C.text)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  fontSize: 11, color: C.textDim, letterSpacing: 0.5)),
        ],
      ),
    );
  }

  // ── Vertical divider between stat columns ──────────────────────────────────
  Widget _divider() {
    return Container(
        width: 1, height: 36, color: Colors.white.withValues(alpha: 0.08));
  }
}
