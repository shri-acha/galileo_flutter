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

(double lat, double lon) _mercatorToLatLon(double x, double y) {
  const r = 6378137.0;
  final lon = (x / r) * (180 / math.pi);
  final lat = (2 * math.atan(math.exp(y / r)) - math.pi / 2) * (180 / math.pi);
  return (lat, lon);
}

(double x, double y) _latLonToMercator(double lat, double lon) {
  const r = 6378137.0;
  return (
    lon * (math.pi / 180) * r,
    math.log(math.tan(math.pi / 4 + lat * (math.pi / 180) / 2)) * r,
  );
}

Offset _latLonToScreen(
  (double lat, double lon) coord,
  Size size,
  _ViewportBounds vp,
) {
  final (mx, my) = _latLonToMercator(coord.$1, coord.$2);
  return Offset(
    (mx - vp.xMin) / (vp.xMax - vp.xMin) * size.width,
    (vp.yMax - my) / (vp.yMax - vp.yMin) * size.height,
  );
}

(double lat, double lon) _screenToLatLon(
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


/// Draws the editing overlay: polygon highlight, vertex handles (red circles),
/// and edge-midpoint insert handles (yellow + circles).
class _EditOverlayPainter extends CustomPainter {
  final List<(double lat, double lon)> vertices;
  final _ViewportBounds viewport;

  // Visual constants
  static const double _vertexR = 10.0;
  static const double _midpointR = 7.0;

  const _EditOverlayPainter({required this.vertices, required this.viewport});

  @override
  void paint(Canvas canvas, Size size) {
    if (vertices.isEmpty) return;
    final pts =
        vertices.map((v) => _latLonToScreen(v, size, viewport)).toList();

    // ── Polygon highlight ────────────────────────────────────────────────────
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

    // ── Edge-midpoint insert handles ─────────────────────────────────────────
    final midFill =
        Paint()
          ..color = Colors.white.withValues(alpha: 0.92)
          ..style = PaintingStyle.fill;
    final midBorder =
        Paint()
          ..color = const ui.Color(0xFFFFEB3B)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8;
    final plusStroke =
        Paint()
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
        Offset(m.dx - 3.5, m.dy),
        Offset(m.dx + 3.5, m.dy),
        plusStroke,
      );
      canvas.drawLine(
        Offset(m.dx, m.dy - 3.5),
        Offset(m.dx, m.dy + 3.5),
        plusStroke,
      );
    }

    // ── Vertex handles ───────────────────────────────────────────────────────
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

  // real-time vertex drag is reflected immediately.
  @override
  bool shouldRepaint(_EditOverlayPainter _) => true;
}

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

  // Normal-mode tap detection
  Offset? _pointerDownPosition;
  static const _tapThreshold = 10.0;

  int? _selectedPolygonId;
  List<(double lat, double lon)> _editingVertices = [];
  _ViewportBounds? _cachedViewport;

  /// Index into [_editingVertices] that is currently being dragged, or null.
  int? _draggingVertexIndex;

  /// Screen position where the current editing pointer-down occurred.
  Offset? _editPointerDownPos;

  /// Hit-test radii (slightly larger than drawn radii for easier tapping).
  static const _vertexHitR = 14.0;
  static const _midpointHitR = 12.0;

  bool get _isEditing => _selectedPolygonId != null;

  /// GlobalKey on the map Stack so we can look up its rendered size.
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

  Future<void> _refreshViewport() async {
    final vp = await _controller?.getViewport();
    if (vp == null || !mounted) return;
    setState(
      () =>
          _cachedViewport = _ViewportBounds(
            xMin: vp.xMin,
            xMax: vp.xMax,
            yMin: vp.yMin,
            yMax: vp.yMax,
          ),
    );
  }

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

  Future<void> _selectPolygon(int id) async {
    final poly = _managedPolygons[id];
    if (poly == null) return;
    // Get a fresh viewport before entering edit mode.
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


  /// Returns the index of the vertex handle at [pos], or null if none.
  int? _hitVertex(Offset pos, Size size) {
    final vp = _cachedViewport;
    if (vp == null) return null;
    for (int i = 0; i < _editingVertices.length; i++) {
      if ((_latLonToScreen(_editingVertices[i], size, vp) - pos).distance <
          _vertexHitR) {
        return i;
      }
    }
    return null;
  }

  /// Returns the edge index whose midpoint handle was hit, or null.
  /// Inserting after edge [i] places the new vertex between vertex [i] and [i+1].
  int? _hitEdgeMidpoint(Offset pos, Size size) {
    final vp = _cachedViewport;
    if (vp == null) return null;
    for (int i = 0; i < _editingVertices.length; i++) {
      final a = _latLonToScreen(_editingVertices[i], size, vp);
      final b = _latLonToScreen(
        _editingVertices[(i + 1) % _editingVertices.length],
        size,
        vp,
      );
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      if ((mid - pos).distance < _midpointHitR) return i;
    }
    return null;
  }

  /// Returns true if [pos] falls inside the projected body of polygon [id].
  bool _hitPolygonBody(Offset pos, int id, Size size) {
    final poly = _managedPolygons[id];
    final vp = _cachedViewport;
    if (poly == null || vp == null) return false;
    final screenPts =
        poly.points.map((v) => _latLonToScreen(v, size, vp)).toList();
    return _pointInPolygon(pos, screenPts);
  }

  /// Remove the old polygon from Galileo and re-add it with [_editingVertices].
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
      _selectedPolygonId = newId; // ID changes after re-add
      statusMessage = 'Polygon updated — ${_editingVertices.length} vertices';
    });
  }

  Future<void> _removeVertex(int index) async {
    if (_editingVertices.length <= 3) {
      setState(
        () => statusMessage = 'Minimum 3 vertices',
      );
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
    // Determine synchronously whether a vertex handle was pressed.
    _draggingVertexIndex = _hitVertex(e.localPosition, _currentMapSize);
  }

  void _handleEditPointerMove(PointerMoveEvent e) {
    final vi = _draggingVertexIndex;
    final vp = _cachedViewport;
    if (vi == null || vp == null) return;
    // Update vertex position in real-time (only the overlay redraws; Galileo
    // layer updates when the drag ends to avoid excessive remove/add cycles).
    final coord = _screenToLatLon(e.localPosition, _currentMapSize, vp);
    setState(() => _editingVertices[vi] = coord);
  }

  Future<void> _handleEditPointerUp(PointerUpEvent e) async {
    final size = _currentMapSize;
    final down = _editPointerDownPos;
    final vi = _draggingVertexIndex;
    final isTap =
        down == null || (e.localPosition - down).distance < _tapThreshold;

    // Reset early so subsequent rebuilds don't see stale state.
    _draggingVertexIndex = null;
    _editPointerDownPos = null;

    if (vi != null) {
      if (isTap) {
        await _removeVertex(vi);
      } else {
        //persist the moved vertex to Galileo.
        await _commitEditedPolygon();
      }
    } else if (isTap) {
      final ei = _hitEdgeMidpoint(e.localPosition, size);
      if (ei != null) {
        // Insert a vertex.
        await _insertVertexAfterEdge(ei);
      } else {
        // Exit edit mode.
        _deselectPolygon();
      }
    }
    // Non-vertex drag in edit mode: map is locked so this is a no-op.
  }

  Future<void> _addFeatureAtScreenPos(double x, double y, Size size) async {
    final ctrl = _controller;
    if (ctrl == null || !_layerReady) return;

    final viewport = await ctrl.getViewport();
    if (viewport == null) return;

    // Cache the fresh viewport (also used by polygon hit-test below).
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
      // select / edit it polygon.
      final tapPos = Offset(x, y);
      for (final entry in _managedPolygons.entries) {
        if (_hitPolygonBody(tapPos, entry.key, size)) {
          await _selectPolygon(entry.key);
          return;
        }
      }
      //create a new polygon.
      await _addPolygon(ctrl, lat, lon);
    }
  }

  Future<void> _addPoint(
    GalileoMapController ctrl,
    double lat,
    double lon,
  ) async {
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

  Future<void> _addPolygon(
    GalileoMapController ctrl,
    double lat,
    double lon,
  ) async {
    final polygon = Polygon(
      points: [
        (lat, lon),
        (lat + 0.3, lon + 0.8),
        (lat + 0.7, lon + 0.5),
        (lat + 0.5, lon),
      ],
      style: PolygonStyle(
        fillColor: Color(r: 0.2, g: 0.5, b: 0.9, a: 0.8),
        strokeColor: Color(r: 1.0, g: 1.0, b: 1.0, a: 1.0),
        strokeWidth: 2.0,
        strokeOffset: 0.0,
      ),
    );
    final id = await ctrl.addPolygonToLayer(_polygonLayerName, polygon);
    if (mounted) {
      setState(() {
        _managedPolygons[id] = polygon;
        statusMessage =
            'Polygon at (${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}) '
            '— total: ${_managedPolygons.length}';
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
        statusMessage = 'Removed polygon — total: ${_managedPolygons.length}';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Galileo Flutter Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions:
            _isEditing
                ? [
                  TextButton.icon(
                    onPressed: _deselectPolygon,
                    icon: const Icon(Icons.check_circle, color: Colors.white),
                    label: const Text(
                      'Done Editing',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ]
                : null,
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16.0),
            color: _isEditing ? const ui.Color(0xFFFFF9C4) : Colors.grey[100],
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Status: $statusMessage',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isEditing
                            ? 'Map locked while editing · tap outside polygon to exit'
                            : 'Tap to add feature · drag to pan · +/- to zoom',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!_isEditing)
                  DropdownButton<String>(
                    value: _layerConfigString,
                    onChanged: (value) async {
                      if (value == null || value == _layerConfigString) return;
                      setState(() => _layerConfigString = value);
                      switch (value) {
                        case 'osm_tile_layer':
                          await _switchLayer(LayerConfig.osm());
                        case 'vector_tile_layer_1':
                          final style = await rootBundle.loadString(
                            'assets/vt_style.json',
                          );
                          if (!mounted) return;
                          await _switchLayer(
                            LayerConfig.vectorTiles(
                              urlTemplate: MAP_TILER_URL_TEMPLATE,
                              styleJson: style,
                            ),
                          );
                        case 'vector_tile_layer_2':
                          final style = await rootBundle.loadString(
                            'assets/simple_style.json',
                          );
                          if (!mounted) return;
                          await _switchLayer(
                            LayerConfig.vectorTiles(
                              urlTemplate: MAP_TILER_URL_TEMPLATE,
                              styleJson: style,
                            ),
                          );
                      }
                    },
                    items: const [
                      DropdownMenuItem(
                        value: 'osm_tile_layer',
                        child: Text('OSM Tile Layer'),
                      ),
                      DropdownMenuItem(
                        value: 'vector_tile_layer_1',
                        child: Text('Vector Tile Style 1'),
                      ),
                      DropdownMenuItem(
                        value: 'vector_tile_layer_2',
                        child: Text('Vector Tile Style 2'),
                      ),
                    ],
                  ),
              ],
            ),
          ),

          Container(
            color: Colors.grey[200],
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Text(
                  'Draw mode:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 12),
                SegmentedButton<DrawMode>(
                  segments: const [
                    ButtonSegment(
                      value: DrawMode.point,
                      label: Text('Point'),
                      icon: Icon(Icons.location_on),
                    ),
                    ButtonSegment(
                      value: DrawMode.polygon,
                      label: Text('Polygon'),
                      icon: Icon(Icons.pentagon_outlined),
                    ),
                  ],
                  selected: {_drawMode},
                  onSelectionChanged: (s) {
                    if (_isEditing) _deselectPolygon();
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

          Expanded(
            child: Container(
              decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
              child: FutureBuilder(
                future: _controllerFuture,
                builder: (ctx, res) {
                  if (res.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (res.hasError) {
                    return Center(child: Text('Error: ${res.error}'));
                  }
                  final (controller, err) = res.data!;
                  if (err != null) {
                    return Center(child: Text('Error: $err'));
                  }
                  if (_controller == null && controller != null) {
                    Future.microtask(() => _initManagedLayer(controller));
                  }

                  return Stack(
                    key: _mapStackKey,
                    fit: StackFit.expand,
                    children: [
                      // AbsorbPointer prevents the map from receiving pointer
                      // events while a polygon is being edited, so pan/zoom are
                      // locked and only the overlay gesture handler fires.
                      AbsorbPointer(
                        absorbing: _isEditing,
                        child: Builder(
                          builder:
                              (mapCtx) => Listener(
                                onPointerDown:
                                    (e) =>
                                        _pointerDownPosition = e.localPosition,
                                onPointerUp: (e) {
                                  final rb =
                                      mapCtx.findRenderObject() as RenderBox;
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
                                onPointerCancel:
                                    (_) => _pointerDownPosition = null,
                                child: GalileoMapWidget.fromController(
                                  key: ObjectKey(controller),
                                  controller: controller!,
                                  size: _kMapSize,
                                  config: _kMapConfig,
                                  layers: const [],
                                  // Also disable keyboard shortcuts while editing.
                                  enableKeyboard: !_isEditing,
                                  autoDispose: false,
                                  child: Positioned(
                                    top: 10,
                                    right: 10,
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.9,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            _isEditing
                                                ? 'Edit Controls:'
                                                : 'Map Controls:',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          if (_isEditing) ...[
                                            const Text(
                                              '• Map locked (editing)',
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: Colors.orange,
                                              ),
                                            ),
                                            const Text(
                                              '• Drag vertex to move',
                                              style: TextStyle(fontSize: 10),
                                            ),
                                            const Text(
                                              '• Tap vertex to delete',
                                              style: TextStyle(fontSize: 10),
                                            ),
                                            const Text(
                                              '• Tap ＋ to insert vertex',
                                              style: TextStyle(fontSize: 10),
                                            ),
                                            const Text(
                                              '• Tap outside to exit edit',
                                              style: TextStyle(fontSize: 10),
                                            ),
                                          ] else ...[
                                            const Text(
                                              '• Tap to add feature',
                                              style: TextStyle(fontSize: 10),
                                            ),
                                            const Text(
                                              '• Drag to pan',
                                              style: TextStyle(fontSize: 10),
                                            ),
                                            const Text(
                                              '• Pinch to zoom',
                                              style: TextStyle(fontSize: 10),
                                            ),
                                            const Text(
                                              '• Arrow keys to pan',
                                              style: TextStyle(fontSize: 10),
                                            ),
                                            const Text(
                                              '• +/- to zoom',
                                              style: TextStyle(fontSize: 10),
                                            ),
                                          ],
                                          const SizedBox(height: 4),
                                          Text(
                                            'Points: ${_managedPoints.length}',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.red,
                                            ),
                                          ),
                                          Text(
                                            'Polygons: ${_managedPolygons.length}',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.blue,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                        ),
                      ),

                      // Only shown when a polygon is selected. The opaque
                      // Listener here (combined with AbsorbPointer above)
                      // ensures all pointer events go to the editing logic.
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

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.grey[50],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Points row
                Row(
                  children: [
                    const Icon(Icons.location_on, color: Colors.red, size: 18),
                    const SizedBox(width: 6),
                    const Text(
                      'Points:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed:
                          (_layerReady && _managedPoints.isNotEmpty)
                              ? _removeLastPoint
                              : null,
                      icon: const Icon(Icons.wrong_location, size: 16),
                      label: Text('Remove Last (${_managedPoints.length})'),
                      style: ElevatedButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed:
                          (_layerReady && _managedPoints.isNotEmpty)
                              ? _clearAllPoints
                              : null,
                      icon: const Icon(Icons.clear, size: 16),
                      label: const Text('Clear All'),
                      style: ElevatedButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Polygons row
                Row(
                  children: [
                    const Icon(
                      Icons.pentagon_outlined,
                      color: Colors.blue,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Polygons:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      // Disable while editing to avoid removing the active polygon.
                      onPressed:
                          (_layerReady &&
                                  _managedPolygons.isNotEmpty &&
                                  !_isEditing)
                              ? _removeLastPolygon
                              : null,
                      icon: const Icon(Icons.remove_circle_outline, size: 16),
                      label: Text('Remove Last (${_managedPolygons.length})'),
                      style: ElevatedButton.styleFrom(
                        foregroundColor: Colors.blue,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed:
                          (_layerReady &&
                                  _managedPolygons.isNotEmpty &&
                                  !_isEditing)
                              ? _clearAllPolygons
                              : null,
                      icon: const Icon(Icons.clear, size: 16),
                      label: const Text('Clear All'),
                      style: ElevatedButton.styleFrom(
                        foregroundColor: Colors.blue,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed:
            () => showDialog(
              context: context,
              builder:
                  (context) => AlertDialog(
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
