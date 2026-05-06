//ignore_for_file: constant_identifier_names

import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:galileo_flutter/galileo_flutter.dart';
import 'package:galileo_flutter/src/galileo_map_controller.dart';

const MAP_TILER_API_KEY = 'nZPCm3UgMuXzMO7ifrjI';
const MAP_TILER_URL_TEMPLATE =
    'https://api.maptiler.com/tiles/v3-openmaptiles/{z}/{x}/{y}.pbf?key=$MAP_TILER_API_KEY';

const _kMapSize = MapSize(width: 800, height: 600);
const _kMapConfig = MapInitConfig(
  backgroundColor: (0.1, 0.1, 0, 0.5),
  enableMultisampling: true,
  latlon: (0.0, 0.0),
  mapSize: _kMapSize,
  zoomLevel: 10,
);

/// Which feature type the tap gesture will place.
enum DrawMode { point, polygon }

class _ViewportBounds {
  final double xMin, xMax, yMin, yMax;
  const _ViewportBounds({
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
  });
}


(double, double) _mercatorToLatLon(double x, double y) {
  const r = 6378137.0;
  final lon = (x / r) * (180 / math.pi);
  final lat =
      (2 * math.atan(math.exp(y / r)) - math.pi / 2) * (180 / math.pi);
  return (lat, lon);
}

(double, double) _latLonToMercator(double lat, double lon) {
  const r = 6378137.0;
  return (
    lon * (math.pi / 180) * r,
    math.log(math.tan(math.pi / 4 + lat * (math.pi / 180) / 2)) * r,
  );
}

Offset _latLonToScreen(
  (double, double) coord,
  Size size,
  _ViewportBounds vp,
) {
  final (mx, my) = _latLonToMercator(coord.$1, coord.$2);
  return Offset(
    (mx - vp.xMin) / (vp.xMax - vp.xMin) * size.width,
    (vp.yMax - my) / (vp.yMax - vp.yMin) * size.height,
  );
}

(double, double) _screenToLatLon(
  Offset pos,
  Size size,
  _ViewportBounds vp,
) {
  final mx = vp.xMin + (pos.dx / size.width) * (vp.xMax - vp.xMin);
  final my = vp.yMax - (pos.dy / size.height) * (vp.yMax - vp.yMin);
  return _mercatorToLatLon(mx, my);
}

bool _pointInPolygon(Offset p, List<Offset> poly) {
  int c = 0;
  for (int i = 0; i < poly.length; i++) {
    final a = poly[i], b = poly[(i + 1) % poly.length];
    if ((a.dy <= p.dy && b.dy > p.dy) || (b.dy <= p.dy && a.dy > p.dy)) {
      if (p.dx < a.dx + (p.dy - a.dy) / (b.dy - a.dy) * (b.dx - a.dx)) c++;
    }
  }
  return c.isOdd;
}

// Edit overlay
class _EditOverlayPainter extends CustomPainter {
  final List<(double, double)> vertices;
  final _ViewportBounds viewport;

  static const double _vertexR = 10.0;
  static const double _midpointR = 7.0;

  const _EditOverlayPainter({required this.vertices, required this.viewport});

  @override
  void paint(Canvas canvas, Size size) {
    if (vertices.isEmpty) return;
    final pts =
        vertices.map((v) => _latLonToScreen(v, size, viewport)).toList();

    if (pts.length >= 3) {
      final path = Path()..moveTo(pts[0].dx, pts[0].dy);
      for (int i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = const ui.Color(0x55FFEB3B)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = const ui.Color(0xFFFFEB3B)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }

    final midFill = Paint()
      ..color = Colors.white.withValues(alpha: 0.92)
      ..style = PaintingStyle.fill;
    final midBorder = Paint()
      ..color = const ui.Color(0xFFFFEB3B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    final plusStroke = Paint()
      ..color = const ui.Color(0xFFFF8F00)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;

    for (int i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      final m = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      canvas.drawCircle(m, _midpointR, midFill);
      canvas.drawCircle(m, _midpointR, midBorder);
      canvas.drawLine(
          Offset(m.dx - 3.5, m.dy), Offset(m.dx + 3.5, m.dy), plusStroke);
      canvas.drawLine(
          Offset(m.dx, m.dy - 3.5), Offset(m.dx, m.dy + 3.5), plusStroke);
    }

    for (final p in pts) {
      canvas.drawCircle(p, _vertexR, Paint()..color = Colors.red);
      canvas.drawCircle(
        p,
        _vertexR,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }
  }

  @override
  bool shouldRepaint(_EditOverlayPainter _) => true;
}

/// Draws the live preview of a polygon being drawn vertex-by-vertex.
/// Vertices are shown as blue dots; edges as dashed lines; if 3+ vertices
/// exist a translucent fill closes the shape.
class _PendingPolygonPainter extends CustomPainter {
  final List<(double, double)> vertices;
  final _ViewportBounds viewport;

  const _PendingPolygonPainter(
      {required this.vertices, required this.viewport});

  @override
  void paint(Canvas canvas, Size size) {
    if (vertices.isEmpty) return;
    final pts =
        vertices.map((v) => _latLonToScreen(v, size, viewport)).toList();

    // Translucent fill + dashed border when closed (3+ pts).
    if (pts.length >= 3) {
      final path = Path()..moveTo(pts[0].dx, pts[0].dy);
      for (int i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = const ui.Color(0x4400BFFF)
          ..style = PaintingStyle.fill,
      );
    }

    // Edge lines (open polyline).
    if (pts.length >= 2) {
      final edgePaint = Paint()
        ..color = const ui.Color(0xFF0288D1)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;
      for (int i = 0; i < pts.length - 1; i++) {
        canvas.drawLine(pts[i], pts[i + 1], edgePaint);
      }
      // Closing dashed preview line back to first vertex.
      final dashPaint = Paint()
        ..color = const ui.Color(0x880288D1)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      canvas.drawLine(pts.last, pts.first, dashPaint);
    }

    // Vertex dots — last one highlighted to distinguish it.
    for (int i = 0; i < pts.length; i++) {
      final isLast = i == pts.length - 1;
      canvas.drawCircle(
        pts[i],
        isLast ? 9.0 : 7.0,
        Paint()..color = isLast ? Colors.deepOrange : Colors.blue,
      );
      canvas.drawCircle(
        pts[i],
        isLast ? 9.0 : 7.0,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
      // Vertex index label.
      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.bold),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        pts[i] - Offset(tp.width / 2, tp.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(_PendingPolygonPainter _) => true;
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (FlutterErrorDetails details) {
    if (details.exception is AssertionError &&
        details.exception.toString().contains('KeyDownEvent is dispatched')) {
      return;
    }
    FlutterError.dumpErrorToConsole(details);
  };
  await initGalileo();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Galileo Flutter Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const GalileoMapPage(),
    );
  }
}

class GalileoMapPage extends StatefulWidget {
  const GalileoMapPage({super.key});
  @override
  State<GalileoMapPage> createState() => _GalileoMapPageState();
}

class _GalileoMapPageState extends State<GalileoMapPage> {
  String statusMessage = 'Loading...';
  String _layerConfigString = 'osm_tile_layer';

  GalileoMapController? _controller;
  late Future<(GalileoMapController?, String?)> _controllerFuture;

  static const _pointLayerName = 'points';
  static const _polygonLayerName = 'polygons';
  bool _layerReady = false;

  final Map<int, Point> _managedPoints = {};
  final Map<int, Polygon> _managedPolygons = {};

  DrawMode _drawMode = DrawMode.point;

  // Normal-mode tap detection.
  Offset? _pointerDownPosition;
  static const _tapThreshold = 10.0;

  // ── Edit-mode state ────────────────────────────────────────────────────────
  int? _selectedPolygonId;
  List<(double, double)> _editingVertices = [];
  _ViewportBounds? _cachedViewport;

  int? _draggingVertexIndex;
  Offset? _editPointerDownPos;

  static const _vertexHitR = 14.0;
  static const _midpointHitR = 12.0;

  bool get _isEditing => _selectedPolygonId != null;

  // ── Pending-polygon draw state ─────────────────────────────────────────────
  /// Vertices collected so far while the user draws a new polygon.
  List<(double, double)> _pendingVertices = [];

  bool get _isDrawingPolygon => _pendingVertices.isNotEmpty;

  // ── Layout key ────────────────────────────────────────────────────────────
  final _mapStackKey = GlobalKey();

  Size get _currentMapSize {
    final rb = _mapStackKey.currentContext?.findRenderObject() as RenderBox?;
    return rb?.size ?? const Size(800, 600);
  }

  @override
  void initState() {
    super.initState();
    _controllerFuture = GalileoMapController.create(
      size: _kMapSize,
      config: _kMapConfig,
      layers: [LayerConfig.osm()],
    );
  }

  // ── Viewport helpers ──────────────────────────────────────────────────────

  Future<void> _refreshViewport() async {
    final vp = await _controller?.getViewport();
    if (vp == null || !mounted) return;
    setState(
      () => _cachedViewport = _ViewportBounds(
        xMin: vp.xMin,
        xMax: vp.xMax,
        yMin: vp.yMin,
        yMax: vp.yMax,
      ),
    );
  }

  // ── Layer management ──────────────────────────────────────────────────────

  Future<void> _switchLayer(LayerConfig newLayer) async {
    setState(() {
      _layerReady = false;
      statusMessage = 'Loading...';
    });
    _controller?.dispose();
    _controller = null;
    _managedPoints.clear();
    _managedPolygons.clear();
    _selectedPolygonId = null;
    _editingVertices = [];
    _pendingVertices = [];

    final f = GalileoMapController.create(
      size: _kMapSize,
      config: _kMapConfig,
      layers: [newLayer],
    );
    setState(() => _controllerFuture = f);

    final (ctrl, err) = await f;
    if (!mounted) return;
    if (err != null || ctrl == null) {
      setState(() => statusMessage = 'Error: ${err ?? "unknown"}');
      return;
    }
    await _initManagedLayer(ctrl);
  }

  Future<void> _initManagedLayer(GalileoMapController ctrl) async {
    setState(() => _controller = ctrl);
    await ctrl.addPointFeatureLayer(_pointLayerName);
    await ctrl.addPolygonFeatureLayer(_polygonLayerName);
    setState(() {
      _layerReady = true;
      statusMessage = 'Tap map to add features';
    });
  }

  // ── Edit-mode helpers ─────────────────────────────────────────────────────

  Future<void> _selectPolygon(int id) async {
    final poly = _managedPolygons[id];
    if (poly == null) return;
    await _refreshViewport();
    if (!mounted) return;
    setState(() {
      _selectedPolygonId = id;
      _editingVertices = List.from(poly.points);
      statusMessage =
          'Editing polygon — drag vertex to move · tap vertex to delete · tap ＋ to insert';
    });
  }

  void _deselectPolygon() {
    setState(() {
      _selectedPolygonId = null;
      _editingVertices = [];
      _draggingVertexIndex = null;
      _editPointerDownPos = null;
      statusMessage = 'Tap map to add features';
    });
  }

  int? _hitVertex(Offset pos, Size size) {
    final vp = _cachedViewport;
    if (vp == null) return null;
    for (int i = 0; i < _editingVertices.length; i++) {
      if ((_latLonToScreen(_editingVertices[i], size, vp) - pos).distance <
          _vertexHitR) return i;
    }
    return null;
  }

  int? _hitEdgeMidpoint(Offset pos, Size size) {
    final vp = _cachedViewport;
    if (vp == null) return null;
    for (int i = 0; i < _editingVertices.length; i++) {
      final a = _latLonToScreen(_editingVertices[i], size, vp);
      final b = _latLonToScreen(
          _editingVertices[(i + 1) % _editingVertices.length], size, vp);
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      if ((mid - pos).distance < _midpointHitR) return i;
    }
    return null;
  }

  bool _hitPolygonBody(Offset pos, int id, Size size) {
    final poly = _managedPolygons[id];
    final vp = _cachedViewport;
    if (poly == null || vp == null) return false;
    final screenPts = poly.points
        .map((t) => _latLonToScreen(t, size, vp))
        .toList();
    return _pointInPolygon(pos, screenPts);
  }

  Future<void> _commitEditedPolygon() async {
    final ctrl = _controller;
    final id = _selectedPolygonId;
    if (ctrl == null || id == null || _editingVertices.length < 3) return;

    await ctrl.removePolygonFromLayer(_polygonLayerName, id);
    _managedPolygons.remove(id);

    final poly = Polygon(
      points: List.from(_editingVertices),
      style: PolygonStyle(
        fillColor: Color(r: 0.2, g: 0.5, b: 0.9, a: 0.8),
        strokeColor: Color(r: 1.0, g: 1.0, b: 1.0, a: 1.0),
        strokeWidth: 2.0,
        strokeOffset: 0.0,
      ),
    );
    final newId = await ctrl.addPolygonToLayer(_polygonLayerName, poly);
    if (!mounted) return;
    setState(() {
      _managedPolygons[newId] = poly;
      _selectedPolygonId = newId;
      statusMessage = 'Polygon updated — ${_editingVertices.length} vertices';
    });
  }

  Future<void> _removeVertex(int index) async {
    if (_editingVertices.length <= 3) {
      setState(() => statusMessage = 'Minimum 3 vertices');
      return;
    }
    setState(() => _editingVertices.removeAt(index));
    await _commitEditedPolygon();
  }

  Future<void> _insertVertexAfterEdge(int edgeIndex) async {
    final a = _editingVertices[edgeIndex];
    final b = _editingVertices[(edgeIndex + 1) % _editingVertices.length];
    final mid = ((a.$1 + b.$1) / 2, (a.$2 + b.$2) / 2);
    setState(() => _editingVertices.insert(edgeIndex + 1, mid));
    await _commitEditedPolygon();
  }

  void _handleEditPointerDown(PointerDownEvent e) {
    _editPointerDownPos = e.localPosition;
    _draggingVertexIndex = _hitVertex(e.localPosition, _currentMapSize);
  }

  void _handleEditPointerMove(PointerMoveEvent e) {
    final vi = _draggingVertexIndex;
    final vp = _cachedViewport;
    if (vi == null || vp == null) return;
    final coord = _screenToLatLon(e.localPosition, _currentMapSize, vp);
    setState(() => _editingVertices[vi] = coord);
  }

  Future<void> _handleEditPointerUp(PointerUpEvent e) async {
    final size = _currentMapSize;
    final down = _editPointerDownPos;
    final vi = _draggingVertexIndex;
    final isTap =
        down == null || (e.localPosition - down).distance < _tapThreshold;

    _draggingVertexIndex = null;
    _editPointerDownPos = null;

    if (vi != null) {
      if (isTap) {
        await _removeVertex(vi);
      } else {
        await _commitEditedPolygon();
      }
    } else if (isTap) {
      final ei = _hitEdgeMidpoint(e.localPosition, size);
      if (ei != null) {
        await _insertVertexAfterEdge(ei);
      } else {
        _deselectPolygon();
      }
    }
  }

  // ── Pending-polygon helpers ───────────────────────────────────────────────

  /// Called when the user taps in polygon draw mode and no existing polygon
  /// was hit.  Accumulates vertices one tap at a time.
  Future<void> _addPendingVertex(double lat, double lon) async {
    // Make sure we have a fresh viewport for the overlay painter.
    if (_cachedViewport == null) await _refreshViewport();
    if (!mounted) return;
    setState(() {
      _pendingVertices.add((lat, lon));
      final n = _pendingVertices.length;
      if (n < 3) {
        statusMessage =
            'Vertex $n placed — tap ${3 - n} more to enable finishing';
      } else {
        statusMessage =
            '$n vertices — tap "Finish" to create polygon or keep adding';
      }
    });
  }

  /// Commits the pending vertices as a real Galileo polygon.
  Future<void> _finishPendingPolygon() async {
    final ctrl = _controller;
    if (ctrl == null || _pendingVertices.length < 3) return;

    final polygon = Polygon(
      points: List.from(_pendingVertices),
      style: PolygonStyle(
        fillColor: Color(r: 0.2, g: 0.5, b: 0.9, a: 0.8),
        strokeColor: Color(r: 1.0, g: 1.0, b: 1.0, a: 1.0),
        strokeWidth: 2.0,
        strokeOffset: 0.0,
      ),
    );
    final id = await ctrl.addPolygonToLayer(_polygonLayerName, polygon);
    if (!mounted) return;
    setState(() {
      _managedPolygons[id] = polygon;
      _pendingVertices = [];
      statusMessage =
          'Polygon created — total: ${_managedPolygons.length}  (tap polygon to edit)';
    });
  }

  /// Discards the pending vertices without creating a polygon.
  void _cancelPendingPolygon() {
    setState(() {
      _pendingVertices = [];
      statusMessage = 'Tap map to add features';
    });
  }

  /// Removes the last pending vertex (undo last tap).
  void _undoLastPendingVertex() {
    if (_pendingVertices.isEmpty) return;
    setState(() {
      _pendingVertices.removeLast();
      final n = _pendingVertices.length;
      statusMessage = n == 0
          ? 'Tap map to start drawing a polygon'
          : n < 3
              ? 'Vertex $n placed — tap ${3 - n} more to enable finishing'
              : '$n vertices — tap "Finish" to create polygon or keep adding';
    });
  }

  // ── Main tap dispatcher ───────────────────────────────────────────────────

  Future<void> _addFeatureAtScreenPos(double x, double y, Size size) async {
    final ctrl = _controller;
    if (ctrl == null || !_layerReady) return;

    final viewport = await ctrl.getViewport();
    if (viewport == null) return;

    final vp = _ViewportBounds(
      xMin: viewport.xMin,
      xMax: viewport.xMax,
      yMin: viewport.yMin,
      yMax: viewport.yMax,
    );
    if (mounted) setState(() => _cachedViewport = vp);

    final mx = vp.xMin + (x / size.width) * (vp.xMax - vp.xMin);
    final my = vp.yMax - (y / size.height) * (vp.yMax - vp.yMin);
    final (lat, lon) = _mercatorToLatLon(mx, my);

    if (_drawMode == DrawMode.point) {
      await _addPoint(ctrl, lat, lon);
    } else {
      // In polygon draw mode:
      // 1. If already accumulating vertices, just add another one.
      if (_isDrawingPolygon) {
        await _addPendingVertex(lat, lon);
        return;
      }
      // 2. Check if an existing polygon body was tapped → enter edit mode.
      final tapPos = Offset(x, y);
      for (final entry in _managedPolygons.entries) {
        if (_hitPolygonBody(tapPos, entry.key, size)) {
          await _selectPolygon(entry.key);
          return;
        }
      }
      // 3. Otherwise start a new polygon with this first vertex.
      await _addPendingVertex(lat, lon);
    }
  }

  // ── Point helpers (unchanged) ─────────────────────────────────────────────

  Future<void> _addPoint(
      GalileoMapController ctrl, double lat, double lon) async {
    final point = Point(
      coordinate: (lat, lon),
      style: PointStyle(
        fillColor: Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0),
        size: 8.0,
      ),
    );
    final id = await ctrl.addPointToLayer(_pointLayerName, point);
    if (mounted) {
      setState(() {
        _managedPoints[id] = point;
        statusMessage =
            'Point at (${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}) '
            '— total: ${_managedPoints.length}';
      });
    }
  }

  Future<void> _removeLastPoint() async {
    final ctrl = _controller;
    if (ctrl == null || _managedPoints.isEmpty) return;
    final id = _managedPoints.keys.last;
    if (await ctrl.removePointFromLayer(_pointLayerName, id) && mounted) {
      setState(() {
        _managedPoints.remove(id);
        statusMessage = 'Removed point — total: ${_managedPoints.length}';
      });
    }
  }

  Future<void> _clearAllPoints() async {
    final ctrl = _controller;
    if (ctrl == null || _managedPoints.isEmpty) return;
    for (final id in _managedPoints.keys.toList()) {
      await ctrl.removePointFromLayer(_pointLayerName, id);
    }
    if (mounted) {
      setState(() {
        _managedPoints.clear();
        statusMessage = 'Cleared all points';
      });
    }
  }

  Future<void> _removeLastPolygon() async {
    final ctrl = _controller;
    if (ctrl == null || _managedPolygons.isEmpty) return;
    final id = _managedPolygons.keys.last;
    if (id == _selectedPolygonId) _deselectPolygon();
    if (await ctrl.removePolygonFromLayer(_polygonLayerName, id) && mounted) {
      setState(() {
        _managedPolygons.remove(id);
        statusMessage =
            'Removed polygon — total: ${_managedPolygons.length}';
      });
    }
  }

  Future<void> _clearAllPolygons() async {
    final ctrl = _controller;
    if (ctrl == null || _managedPolygons.isEmpty) return;
    if (_isEditing) _deselectPolygon();
    for (final id in _managedPolygons.keys.toList()) {
      await ctrl.removePolygonFromLayer(_polygonLayerName, id);
    }
    if (mounted) {
      setState(() {
        _managedPolygons.clear();
        statusMessage = 'Cleared all polygons';
      });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bool mapLocked = _isEditing;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Galileo Flutter Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: _isEditing
            ? [
                TextButton.icon(
                  onPressed: _deselectPolygon,
                  icon:
                      const Icon(Icons.check_circle, color: Colors.white),
                  label: const Text(
                    'Done Editing',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ]
            : null,
      ),
      body: Column(
        children: [
          // ── Status bar ──────────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16.0),
            color: _isEditing
                ? const ui.Color(0xFFFFF9C4)
                : _isDrawingPolygon
                    ? const ui.Color(0xFFE3F2FD)
                    : Colors.grey[100],
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Status: $statusMessage',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isEditing
                            ? 'Map locked while editing · tap outside polygon to exit'
                            : _isDrawingPolygon
                                ? 'Keep tapping to add vertices — use the buttons to finish or cancel'
                                : 'Tap to add feature · drag to pan · +/− to zoom',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                if (!_isEditing && !_isDrawingPolygon)
                  DropdownButton<String>(
                    value: _layerConfigString,
                    onChanged: (value) async {
                      if (value == null || value == _layerConfigString)
                        return;
                      setState(() => _layerConfigString = value);
                      switch (value) {
                        case 'osm_tile_layer':
                          await _switchLayer(LayerConfig.osm());
                        case 'vector_tile_layer_1':
                          final style = await rootBundle.loadString(
                              'assets/vt_style.json');
                          if (!mounted) return;
                          await _switchLayer(LayerConfig.vectorTiles(
                              urlTemplate: MAP_TILER_URL_TEMPLATE,
                              styleJson: style));
                        case 'vector_tile_layer_2':
                          final style = await rootBundle.loadString(
                              'assets/simple_style.json');
                          if (!mounted) return;
                          await _switchLayer(LayerConfig.vectorTiles(
                              urlTemplate: MAP_TILER_URL_TEMPLATE,
                              styleJson: style));
                      }
                    },
                    items: const [
                      DropdownMenuItem(
                          value: 'osm_tile_layer',
                          child: Text('OSM Tile Layer')),
                      DropdownMenuItem(
                          value: 'vector_tile_layer_1',
                          child: Text('Vector Tile Style 1')),
                      DropdownMenuItem(
                          value: 'vector_tile_layer_2',
                          child: Text('Vector Tile Style 2')),
                    ],
                  ),
              ],
            ),
          ),

          // ── Draw-mode toolbar ───────────────────────────────────────────
          Container(
            color: Colors.grey[200],
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Text('Draw mode:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 12),
                SegmentedButton<DrawMode>(
                  segments: const [
                    ButtonSegment(
                        value: DrawMode.point,
                        label: Text('Point'),
                        icon: Icon(Icons.location_on)),
                    ButtonSegment(
                        value: DrawMode.polygon,
                        label: Text('Polygon'),
                        icon: Icon(Icons.pentagon_outlined)),
                  ],
                  selected: {_drawMode},
                  onSelectionChanged: (s) {
                    if (_isEditing) _deselectPolygon();
                    if (_isDrawingPolygon) _cancelPendingPolygon();
                    setState(() => _drawMode = s.first);
                  },
                ),
                const Spacer(),
                _CountChip(
                  icon: Icons.location_on,
                  color: const ui.Color(0xFFF44336),
                  count: _managedPoints.length,
                  label: 'pts',
                ),
                const SizedBox(width: 8),
                _CountChip(
                  icon: Icons.pentagon_outlined,
                  color: const ui.Color(0xFF2196F3),
                  count: _managedPolygons.length,
                  label: 'poly',
                ),
              ],
            ),
          ),

          // ── Pending-polygon action bar (shown only while drawing) ────────
          if (_isDrawingPolygon)
            Container(
              color: const ui.Color(0xFFBBDEFB),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.draw, size: 18, color: Colors.blue),
                  const SizedBox(width: 8),
                  Text(
                    'Drawing polygon — ${_pendingVertices.length} vertices',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  // Undo last vertex.
                  IconButton(
                    tooltip: 'Undo last vertex',
                    icon: const Icon(Icons.undo, size: 20),
                    onPressed: _pendingVertices.isNotEmpty
                        ? _undoLastPendingVertex
                        : null,
                    color: Colors.blueGrey,
                  ),
                  const SizedBox(width: 4),
                  // Cancel drawing.
                  OutlinedButton.icon(
                    onPressed: _cancelPendingPolygon,
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('Cancel'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red),
                  ),
                  const SizedBox(width: 8),
                  // Finish — only enabled with 3+ vertices.
                  ElevatedButton.icon(
                    onPressed: _pendingVertices.length >= 3
                        ? _finishPendingPolygon
                        : null,
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Finish Polygon'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),

          // ── Map area ────────────────────────────────────────────────────
          Expanded(
            child: Container(
              decoration:
                  BoxDecoration(border: Border.all(color: Colors.grey)),
              child: FutureBuilder(
                future: _controllerFuture,
                builder: (ctx, res) {
                  if (res.connectionState == ConnectionState.waiting) {
                    return const Center(
                        child: CircularProgressIndicator());
                  }
                  if (res.hasError) {
                    return Center(child: Text('Error: ${res.error}'));
                  }
                  final (controller, err) = res.data!;
                  if (err != null) {
                    return Center(child: Text('Error: $err'));
                  }
                  if (_controller == null && controller != null) {
                    Future.microtask(
                        () => _initManagedLayer(controller));
                  }

                  return Stack(
                    key: _mapStackKey,
                    fit: StackFit.expand,
                    children: [
                      // Base map — locked while editing a polygon.
                      AbsorbPointer(
                        absorbing: mapLocked || _isDrawingPolygon,
                        child: Builder(
                          builder: (mapCtx) => Listener(
                            onPointerDown: (e) =>
                                _pointerDownPosition =
                                    e.localPosition,
                            onPointerUp: (e) {
                              final rb = mapCtx.findRenderObject()
                                  as RenderBox;
                              final size = rb.size;
                              final down = _pointerDownPosition;
                              if (down != null &&
                                  (e.localPosition - down).distance <
                                      _tapThreshold) {
                                _addFeatureAtScreenPos(
                                  e.localPosition.dx,
                                  e.localPosition.dy,
                                  size,
                                );
                              }
                              _pointerDownPosition = null;
                            },
                            onPointerCancel: (_) =>
                                _pointerDownPosition = null,
                            child: GalileoMapWidget.fromController(
                              key: ObjectKey(controller),
                              controller: controller!,
                              size: _kMapSize,
                              config: _kMapConfig,
                              layers: const [],
                              enableKeyboard: !mapLocked && !_isDrawingPolygon,
                              autoDispose: false,
                              child: Positioned(
                                top: 10,
                                right: 10,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.white
                                        .withValues(alpha: 0.9),
                                    borderRadius:
                                        BorderRadius.circular(8),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _isEditing
                                            ? 'Edit Controls:'
                                            : _isDrawingPolygon
                                                ? 'Drawing Polygon:'
                                                : 'Map Controls:',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight:
                                                FontWeight.bold),
                                      ),
                                      const SizedBox(height: 4),
                                      if (_isEditing) ...[
                                        const Text(
                                            '• Map locked (editing)',
                                            style: TextStyle(
                                                fontSize: 10,
                                                color: Colors.orange)),
                                        const Text(
                                            '• Drag vertex to move',
                                            style:
                                                TextStyle(fontSize: 10)),
                                        const Text(
                                            '• Tap vertex to delete',
                                            style:
                                                TextStyle(fontSize: 10)),
                                        const Text(
                                            '• Tap ＋ to insert vertex',
                                            style:
                                                TextStyle(fontSize: 10)),
                                        const Text(
                                            '• Tap outside to exit edit',
                                            style:
                                                TextStyle(fontSize: 10)),
                                      ] else if (_isDrawingPolygon) ...[
                                        const Text('• Tap to add vertex',
                                            style:
                                                TextStyle(fontSize: 10)),
                                        const Text(
                                            '• Need ≥3 to finish',
                                            style: TextStyle(
                                                fontSize: 10,
                                                color: Colors.blue)),
                                        const Text(
                                            '• Drag to pan while drawing',
                                            style:
                                                TextStyle(fontSize: 10)),
                                        const Text(
                                            '• Use toolbar to finish/cancel',
                                            style:
                                                TextStyle(fontSize: 10)),
                                      ] else ...[
                                        const Text('• Tap to add feature',
                                            style:
                                                TextStyle(fontSize: 10)),
                                        const Text('• Drag to pan',
                                            style:
                                                TextStyle(fontSize: 10)),
                                        const Text('• Pinch to zoom',
                                            style:
                                                TextStyle(fontSize: 10)),
                                        const Text('• Arrow keys to pan',
                                            style:
                                                TextStyle(fontSize: 10)),
                                        const Text('• +/- to zoom',
                                            style:
                                                TextStyle(fontSize: 10)),
                                      ],
                                      const SizedBox(height: 4),
                                      Text('Points: ${_managedPoints.length}',
                                          style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.red)),
                                      Text(
                                          'Polygons: ${_managedPolygons.length}',
                                          style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.blue)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Pending-polygon preview overlay.
                      // The map is AbsorbPointer-locked while drawing, so we
                      // need our own Listener here to catch vertex-placement taps.
                      if (_isDrawingPolygon && _cachedViewport != null)
                        Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: (e) =>
                              _pointerDownPosition = e.localPosition,
                          onPointerUp: (e) {
                            final down = _pointerDownPosition;
                            _pointerDownPosition = null;
                            if (down != null &&
                                (e.localPosition - down).distance <
                                    _tapThreshold) {
                              _addFeatureAtScreenPos(
                                e.localPosition.dx,
                                e.localPosition.dy,
                                _currentMapSize,
                              );
                            }
                          },
                          onPointerCancel: (_) => _pointerDownPosition = null,
                          child: CustomPaint(
                            painter: _PendingPolygonPainter(
                              vertices: _pendingVertices,
                              viewport: _cachedViewport!,
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),

                      // Edit-mode overlay (existing polygon vertex handles).
                      if (_isEditing && _cachedViewport != null)
                        Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: _handleEditPointerDown,
                          onPointerMove: _handleEditPointerMove,
                          onPointerUp: _handleEditPointerUp,
                          child: CustomPaint(
                            painter: _EditOverlayPainter(
                              vertices: _editingVertices,
                              viewport: _cachedViewport!,
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),

          // ── Bottom controls ─────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.grey[50],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.location_on,
                        color: Colors.red, size: 18),
                    const SizedBox(width: 6),
                    const Text('Points:',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: (_layerReady && _managedPoints.isNotEmpty)
                          ? _removeLastPoint
                          : null,
                      icon:
                          const Icon(Icons.wrong_location, size: 16),
                      label: Text(
                          'Remove Last (${_managedPoints.length})'),
                      style: ElevatedButton.styleFrom(
                          foregroundColor: Colors.red),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: (_layerReady && _managedPoints.isNotEmpty)
                          ? _clearAllPoints
                          : null,
                      icon: const Icon(Icons.clear, size: 16),
                      label: const Text('Clear All'),
                      style: ElevatedButton.styleFrom(
                          foregroundColor: Colors.red),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.pentagon_outlined,
                        color: Colors.blue, size: 18),
                    const SizedBox(width: 6),
                    const Text('Polygons:',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: (_layerReady &&
                              _managedPolygons.isNotEmpty &&
                              !_isEditing &&
                              !_isDrawingPolygon)
                          ? _removeLastPolygon
                          : null,
                      icon: const Icon(Icons.remove_circle_outline,
                          size: 16),
                      label: Text(
                          'Remove Last (${_managedPolygons.length})'),
                      style: ElevatedButton.styleFrom(
                          foregroundColor: Colors.blue),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: (_layerReady &&
                              _managedPolygons.isNotEmpty &&
                              !_isEditing &&
                              !_isDrawingPolygon)
                          ? _clearAllPolygons
                          : null,
                      icon: const Icon(Icons.clear, size: 16),
                      label: const Text('Clear All'),
                      style: ElevatedButton.styleFrom(
                          foregroundColor: Colors.blue),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('About'),
            content: Text(
              'Galileo Flutter Demo\n'
              'Session ID: ${_controller?.sessionId ?? "none"}\n'
              'Points on map: ${_managedPoints.length}\n'
              'Polygons on map: ${_managedPolygons.length}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        ),
        child: const Icon(Icons.info),
      ),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------

class _CountChip extends StatelessWidget {
  const _CountChip({
    required this.icon,
    required this.color,
    required this.count,
    required this.label,
  });

  final IconData icon;
  final ui.Color color;
  final int count;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, color: color, size: 16),
      label: Text(
        '$count $label',
        style: TextStyle(color: color, fontWeight: FontWeight.bold),
      ),
      padding: EdgeInsets.zero,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
