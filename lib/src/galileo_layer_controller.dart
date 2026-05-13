import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:galileo_flutter/galileo_flutter.dart';
import 'package:galileo_flutter/src/galileo_map_controller.dart';
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
  final List<LayerConfig> layers;
  final int sessionId;

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
  }) async {
    try {
      final id = await rlib.addPolygonFeatureLayer(
        sessionId: sessionId,
        initialPolygons: initialPolygons,
      );
      _layer_names[name] = id;
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
}
