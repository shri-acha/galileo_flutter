import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:galileo_flutter/galileo_flutter.dart';
import 'package:galileo_flutter/src/galileo_map_controller.dart';
import 'package:galileo_flutter/src/galileo_feature_editor.dart';
import 'package:galileo_flutter/src/rust/api/galileo_api.dart' as rlib;
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

/// Have to control the layers through the controller
/// helps in isolation of control of the layers
/// Make it possible for a polygon to be editable, through the public api.
/// Being editable implies that, there is a boolean field deciding if a polygon is
/// editable or not, and if editable, there overlays a widget `PolygonOverlay` when tapped.
/// NOTES:
/// - The polygon overlay shall not freeze the map during its exisitence.
/// - The polygon overlay must resized for each event occurence in the MapWidget such that the overlay size/position retains.

class LayerController {
  final Map<String, int> _layer_names = {};
  final Map<String, FeatureEditor> _editors = {};
  final List<LayerConfig> layers;
  final int sessionId;

  T? editorFor<T extends FeatureEditor>(String layerName) {
    final e = _editors[layerName];
    return e is T ? e : null;
  }

  LayerController({required this.sessionId, required this.layers});

  /// Add a layer to the map
  Future<void> addLayer(LayerConfig layer) async {
    try {
      await rlib.addSessionLayer(sessionId: sessionId, layerConfig: layer);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error adding layer: $e');
      }
    }
  }

  /// creates a managed point layer on the rust side and stores the handle under name.
  Future<int?> addPointFeatureLayer(
    String name, {
    List<Point> initialPoints = const [],
  }) async {
    try {
      final id = await rlib.addPointFeatureLayer(
        sessionId: sessionId,
        initialPoints: initialPoints,
      );
      _layer_names[name] = id;
      return id;
    } catch (e) {
      if (kDebugMode) debugPrint('Error creating point layer "$name": $e');
      return null;
    }
  }

  /// Creates a managed polygon layer on the rust side and stores the handle under name.
  Future<int?> addPolygonFeatureLayer(
    String name, {
    List<Polygon> initialPolygons = const [],
    PolygonEditor? editor,
  }) async {
    try {
      final id = await rlib.addPolygonFeatureLayer(
        sessionId: sessionId,
        initialPolygons: initialPolygons,
      );
      _layer_names[name] = id;

      if (editor != null) {
        _editors[name] = editor;
      }

      return id;
    } catch (e) {
      if (kDebugMode) debugPrint('Error creating polygon layer "$name": $e');
      return null;
    }
  }

  Future<int> addPointToLayer(String layerName, Point point) async {
    final id = _layer_names[layerName];
    if (id == null) {
      if (kDebugMode) debugPrint('No point layer named "$layerName"');
      return -1;
    }
    try {
      return await rlib.addPointToLayer(
        sessionId: sessionId,
        layerId: id,
        point: point,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Error adding point to "$layerName": $e');
      return -1;
    }
  }

  Future<bool> removePointFromLayer(String layerName, int index) async {
    final id = _layer_names[layerName];
    if (id == null) return false;
    try {
      return await rlib.removePointFromLayer(
        sessionId: sessionId,
        layerId: id,
        index: index,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Error removing point from "$layerName": $e');
      return false;
    }
  }

  Future<int> addPolygonToLayer(String layerName, Polygon polygon) async {
    final id = _layer_names[layerName];
    if (id == null) {
      if (kDebugMode) debugPrint('No point layer named "$layerName"');
      return -1;
    }
    try {
      return await rlib.addPolygonToLayer(
        sessionId: sessionId,
        layerId: id,
        polygon: polygon,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Error adding point to "$layerName": $e');
      return -1;
    }
  }

  Future<bool> removePolygonFromLayer(String layerName, int index) async {
    final id = _layer_names[layerName];
    if (id == null) return false;
    try {
      return await rlib.removePolygonFromLayer(
        sessionId: sessionId,
        layerId: id,
        index: index,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Error removing point from "$layerName": $e');
      return false;
    }
  }
  @override
  void dispose() {
    for (final editor in _editors.values) {
      editor.dispose();
    }
    _editors.clear();
  }
}

abstract class FeatureEditor extends ChangeNotifier {
  bool get isActive;
  void updateViewport(ViewportBounds viewport);
  void handlePointerDown(PointerDownEvent event, Size mapSize);
  void handlePointerMove(PointerMoveEvent event, Size mapSize);
  Future<void> handlePointerUp(PointerUpEvent event, Size mapSize);
}

class PolygonEditor extends FeatureEditor {
  // config editor 
  static const _tapThreshold   = 10.0;
  static const _vertexHitR     = 14.0;
  static const _midpointHitR   = 12.0;

  // callbacks 
  final void Function(String message)? onStatusMessage;

  final void Function(int? polygonId)? onSelectionChanged;

  FeatureLayerManager? _features;

  int? _selectedPolygonId;
  List<(double,double)> _editingVertices = [];
  ViewportBounds? _viewport;
  int? _draggingVertexIndex;
  Offset? _pointerDownPos;

  PolygonEditor({this.onStatusMessage, this.onSelectionChanged});


  @override
  bool get isActive => _selectedPolygonId != null;

  int? get selectedPolygonId => _selectedPolygonId;
  List<(double,double)> get editingVertices => List.unmodifiable(_editingVertices);
  ViewportBounds? get viewport => _viewport;


  void attach(FeatureLayerManager features) => _features = features;

  void detach() {
    _features = null;
    _deselect(notify: false);
  }

  @override
  void updateViewport(ViewportBounds viewport) {
    _viewport = viewport;
    notifyListeners();
  }

  /// the widget calls this in its main tap dispatcher when in polygon draw mode
  /// and not currently drawing.
  Future<bool> trySelectAt(Offset screenPos, Size mapSize, ViewportBounds vp) async {
    _viewport = vp;
    final features = _features;
    if (features == null) return false;

    for (final id in features.polygons.keys) {
      if (_hitPolygonBody(screenPos, id, mapSize)) {
        await _selectPolygon(id);
        return true;
      }
    }
    return false;
  }

  void deselect() => _deselect();

  Future<void> _selectPolygon(int id) async {
    final poly = _features?.polygons[id];
    if (poly == null) return;
    _selectedPolygonId = id;
    _editingVertices   = List.from(poly.points);
    onSelectionChanged?.call(id);
    onStatusMessage?.call(
      'Editing polygon — drag vertex to move · tap vertex to delete · tap ＋ to insert',
    );
    notifyListeners();
  }

  void _deselect({bool notify = true}) {
    final hadSelection = _selectedPolygonId != null;
    _selectedPolygonId    = null;
    _editingVertices      = [];
    _draggingVertexIndex  = null;
    _pointerDownPos       = null;
    if (hadSelection) onSelectionChanged?.call(null);
    onStatusMessage?.call('Tap map to add features');
    if (notify) notifyListeners();
  }

  @override
  void handlePointerDown(PointerDownEvent event, Size mapSize) {
    if (!isActive) return;
    _pointerDownPos      = event.localPosition;
    _draggingVertexIndex = _hitVertex(event.localPosition, mapSize);
  }

  @override
  void handlePointerMove(PointerMoveEvent event, Size mapSize) {
    final vi = _draggingVertexIndex;
    final vp = _viewport;
    if (vi == null || vp == null || !isActive) return;
    _editingVertices[vi] =
        MapProjection.screenToLatLon(event.localPosition, mapSize, vp);
    notifyListeners(); // live vertex drag
  }

  @override
  Future<void> handlePointerUp(PointerUpEvent event, Size mapSize) async {
    if (!isActive) return;

    final down  = _pointerDownPos;
    final vi    = _draggingVertexIndex;
    final isTap = down == null ||
        (event.localPosition - down).distance < _tapThreshold;

    _draggingVertexIndex = null;
    _pointerDownPos      = null;

    if (vi != null) {
      isTap ? await _removeVertex(vi) : await _commitEdits();
    } else if (isTap) {
      final ei = _hitEdgeMidpoint(event.localPosition, mapSize);
      if (ei != null) {
        await _insertVertexAfterEdge(ei);
      } else {
        _deselect();
      }
    }
  }

  Future<void> _commitEdits() async {
    final features = _features;
    final id       = _selectedPolygonId;
    if (features == null || id == null || _editingVertices.length < 3) return;

    final updated = Polygon(
      points: List.from(_editingVertices),
      style: PolygonStyle(
        fillColor:   Color(r: 0.2, g: 0.5, b: 0.9, a: 0.8),
        strokeColor: Color(r: 1.0, g: 1.0, b: 1.0, a: 1.0),
        strokeWidth: 2.0,
        strokeOffset: 0.0,
      ),
    );

    final newId = await features.updatePolygon(id, updated);
    _selectedPolygonId = newId;
    onStatusMessage?.call('Polygon updated — ${_editingVertices.length} vertices');
    notifyListeners();
  }

  Future<void> _removeVertex(int index) async {
    if (_editingVertices.length <= 3) {
      onStatusMessage?.call('Minimum 3 vertices');
      return;
    }
    _editingVertices.removeAt(index);
    notifyListeners();
    await _commitEdits();
  }

  Future<void> _insertVertexAfterEdge(int edgeIndex) async {
    final a   = _editingVertices[edgeIndex];
    final b   = _editingVertices[(edgeIndex + 1) % _editingVertices.length];
    final mid = ((a.$1 + b.$1) / 2, (a.$2 + b.$2) / 2);
    _editingVertices.insert(edgeIndex + 1, mid);
    notifyListeners();
    await _commitEdits();
  }

  int? _hitVertex(Offset pos, Size size) {
    final vp = _viewport;
    if (vp == null) return null;
    for (int i = 0; i < _editingVertices.length; i++) {
      if ((MapProjection.latLonToScreen(_editingVertices[i], size, vp) - pos)
              .distance < _vertexHitR) return i;
    }
    return null;
  }

  int? _hitEdgeMidpoint(Offset pos, Size size) {
    final vp = _viewport;
    if (vp == null) return null;
    for (int i = 0; i < _editingVertices.length; i++) {
      final a = MapProjection.latLonToScreen(_editingVertices[i], size, vp);
      final b = MapProjection.latLonToScreen(
        _editingVertices[(i + 1) % _editingVertices.length], size, vp,
      );
      if ((Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2) - pos).distance
          < _midpointHitR) return i;
    }
    return null;
  }

  bool _hitPolygonBody(Offset pos, int id, Size size) {
    final poly = _features?.polygons[id];
    final vp   = _viewport;
    if (poly == null || vp == null) return false;
    return MapProjection.pointInPolygon(
      pos,
      poly.points.map((t) => MapProjection.latLonToScreen(t, size, vp)).toList(),
    );
  }

  @override
  void dispose() {
    _features = null;
    super.dispose();
  }
}
