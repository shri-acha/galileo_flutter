import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:galileo_flutter/galileo_flutter.dart';
import 'package:galileo_flutter/src/galileo_map_controller.dart';
import 'package:galileo_flutter/src/galileo_layer_controller.dart';


class ViewportBounds {
  final double xMin, xMax, yMin, yMax;
  const ViewportBounds({
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
  });
}

abstract final class MapProjection {
  static const double _r = 6378137.0;

  static (double, double) latLonToMercator(double lat, double lon) => (
    lon * (math.pi / 180) * _r,
    math.log(math.tan(math.pi / 4 + lat * (math.pi / 180) / 2)) * _r,
  );

  static (double, double) mercatorToLatLon(double x, double y) => (
    (2 * math.atan(math.exp(y / _r)) - math.pi / 2) * (180 / math.pi),
    (x / _r) * (180 / math.pi),
  );

  static Offset latLonToScreen(
    (double, double) coord,
    Size size,
    ViewportBounds vp,
  ) {
    final (mx, my) = latLonToMercator(coord.$1, coord.$2);
    return Offset(
      (mx - vp.xMin) / (vp.xMax - vp.xMin) * size.width,
      (vp.yMax - my) / (vp.yMax - vp.yMin) * size.height,
    );
  }

  static (double, double) screenToLatLon(
    Offset pos,
    Size size,
    ViewportBounds vp,
  ) {
    final mx = vp.xMin + (pos.dx / size.width) * (vp.xMax - vp.xMin);
    final my = vp.yMax - (pos.dy / size.height) * (vp.yMax - vp.yMin);
    return mercatorToLatLon(mx, my);
  }

  static bool pointInPolygon(Offset p, List<Offset> poly) {
    int crossings = 0;
    for (int i = 0; i < poly.length; i++) {
      final a = poly[i];
      final b = poly[(i + 1) % poly.length];
      if ((a.dy <= p.dy && b.dy > p.dy) || (b.dy <= p.dy && a.dy > p.dy)) {
        if (p.dx < a.dx + (p.dy - a.dy) / (b.dy - a.dy) * (b.dx - a.dx)) {
          crossings++;
        }
      }
    }
    return crossings.isOdd;
  }
}

class EditOverlayPainter extends CustomPainter {
  final List<(double, double)> vertices;
  final ViewportBounds viewport;

  static const double _vertexR = 10.0;
  static const double _midpointR = 7.0;

  const EditOverlayPainter({required this.vertices, required this.viewport});

  @override
  void paint(Canvas canvas, Size size) {
    if (vertices.isEmpty) return;
    final pts =
        vertices
            .map((v) => MapProjection.latLonToScreen(v, size, viewport))
            .toList();

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
  bool shouldRepaint(EditOverlayPainter old) =>
      old.vertices != vertices || old.viewport != viewport;
}

/// Draws the live preview of a polygon being drawn vertex-by-vertex.
/// Vertices are shown as blue dots; edges as dashed lines; if 3+ vertices
/// exist a translucent fill closes the shape.
class PendingPolygonPainter extends CustomPainter {
  final List<(double, double)> vertices;
  final ViewportBounds viewport;

  const PendingPolygonPainter({required this.vertices, required this.viewport});

  @override
  void paint(Canvas canvas, Size size) {
    if (vertices.isEmpty) return;
    final pts =
        vertices
            .map((v) => MapProjection.latLonToScreen(v, size, viewport))
            .toList();

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
      final edgePaint =
          Paint()
            ..color = const ui.Color(0xFF0288D1)
            ..strokeWidth = 2.0
            ..style = PaintingStyle.stroke;
      for (int i = 0; i < pts.length - 1; i++) {
        canvas.drawLine(pts[i], pts[i + 1], edgePaint);
      }
      // Closing dashed preview line back to first vertex.
      final dashPaint =
          Paint()
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
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pts[i] - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(PendingPolygonPainter old) =>
      old.vertices != vertices || old.viewport != viewport;
}

class CountChip extends StatelessWidget {
  const CountChip({
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

class FeatureLayerManager {
  static const _pointLayerName   = 'managed-points';
  static const _polygonLayerName = 'managed-polygons';

  final LayerController layerController;
  final PolygonEditor?  _polygonEditor;

  final List<int> _pointIds = [];

  // Polygons: ID -> Polygon so the editor can look up geometry by ID,
  // and so hit-testing can iterate current shapes.
  final Map<int, Polygon> _polygons = {};

  FeatureLayerManager({
    required this.layerController,
    PolygonEditor? polygonEditor,
  }) : _polygonEditor = polygonEditor;

  int get pointCount   => _pointIds.length;
  int get polygonCount => _polygons.length;

  Map<int, Polygon>       get polygons     => Map.unmodifiable(_polygons);

  Future<void> initialize() async {
    await layerController.addPointFeatureLayer(_pointLayerName);
    await layerController.addPolygonFeatureLayer(_polygonLayerName);

    _polygonEditor?.attach(this);
  }

  void dispose() {
    _polygonEditor?.detach();
    _pointIds.clear();
    _polygons.clear();
  }

  Future<void> addPoint(Point point) async {
    final id = await layerController.addPointToLayer(_pointLayerName, point);
    if (id >= 0) {
      _pointIds.add(id);
    } else {
      if (kDebugMode) debugPrint('addPoint: rust returned invalid id $id');
    }
  }

  Future<void> removeLastPoint() async {
    if (_pointIds.isEmpty) return;
    final id      = _pointIds.last;
    final removed = await layerController.removePointFromLayer(_pointLayerName, id);
    if (removed) {
      _pointIds.removeLast();
    } else {
      if (kDebugMode) debugPrint('removeLastPoint: rust could not remove id $id');
    }
  }

  Future<void> clearPoints() async {
    for (final id in List<int>.from(_pointIds)) {
      await layerController.removePointFromLayer(_pointLayerName, id);
    }
    _pointIds.clear();
  }

  Future<void> addPolygon(Polygon polygon) async {
    final id = await layerController.addPolygonToLayer(_polygonLayerName, polygon);
    if (id >= 0) {
      _polygons[id] = polygon;
    } else {
      if (kDebugMode) debugPrint('addPolygon: rust returned invalid id $id');
    }
  }

  Future<int> updatePolygon(int oldId, Polygon updated) async {
    final removed = await layerController.removePolygonFromLayer(
        _polygonLayerName, oldId);
    if (!removed) {
      if (kDebugMode) {
        debugPrint('updatePolygon: could not remove old id $oldId');
      }
    }
    _polygons.remove(oldId);

    final newId = await layerController.addPolygonToLayer(
        _polygonLayerName, updated);
    if (newId >= 0) {
      _polygons[newId] = updated;
    } else {
      if (kDebugMode) debugPrint('updatePolygon: rust returned invalid id $newId');
    }
    return newId;
  }

  Future<void> removeLastPolygon() async {
    if (_polygons.isEmpty) return;
    final id      = _polygons.keys.last;
    final removed = await layerController.removePolygonFromLayer(
        _polygonLayerName, id);
    if (removed) {
      _polygons.remove(id);
    } else {
      if (kDebugMode) debugPrint('removeLastPolygon: rust could not remove id $id');
    }
  }

  Future<void> clearPolygons() async {
    for (final id in List<int>.from(_polygons.keys)) {
      await layerController.removePolygonFromLayer(_polygonLayerName, id);
    }
    _polygons.clear();
  }
}
