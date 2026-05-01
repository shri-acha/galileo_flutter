// ignore_for_file: constant_identifier_names

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:galileo_flutter/galileo_flutter.dart';
import 'package:galileo_flutter/src/galileo_map_controller.dart';
import 'dart:math' as math;

const MAP_TILER_API_KEY = '';
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


(double lat, double lon) _mercatorToLatLon(double x, double y) {
  const earthRadius = 6378137.0;
  final lon = (x / earthRadius) * (180 / math.pi);
  final lat = (2 * math.atan(math.exp(y / earthRadius)) - math.pi / 2) *
      (180 / math.pi);
  return (lat, lon);
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
  LayerConfig _layerConfig = LayerConfig.osm();

  GalileoMapController? _controller;
  final Future<(GalileoMapController?, String?)> _controllerFuture =
      GalileoMapController.create(
    size: _kMapSize,
    config: _kMapConfig,
    layers: [LayerConfig.osm()],
  );

  static const _pointLayerName = 'points';
  bool _layerReady = false;
  final Map<int, Point> _managedPoints = {};

  // Track pointer down position to distinguish tap vs drag
  Offset? _pointerDownPosition;
  static const _tapThreshold = 10.0; // pixels of movement allowed for a tap

  Future<void> _initManagedLayer(GalileoMapController controller) async {
    setState(() => _controller = controller);
    await controller.addPointFeatureLayer(_pointLayerName);
    setState(() {
      _layerReady = true;
      statusMessage = 'Tap map to add points';
    });
  }

  Future<void> _addPointAtScreenPos(double x, double y, Size size) async {
    final controller = _controller;
    if (controller == null || !_layerReady) return;

    final viewport = await controller.getViewport();
    if (viewport == null) return;

    final mx = viewport.xMin +
        (x / size.width) * (viewport.xMax - viewport.xMin);

    final my = viewport.yMax -
        (y / size.height) * (viewport.yMax - viewport.yMin);

    final (lat, lon) = _mercatorToLatLon(mx, my);

    print("Widget size: ${size.width} x ${size.height}");
    print("Configured size: ${_kMapSize.width} x ${_kMapSize.height}");

    final point = Point(
      coordinate: (lat, lon),
      style: PointStyle(fillColor: Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)),
    );

    final featureId = await controller.addPointToLayer(_pointLayerName, point);

    if (mounted) {
      setState(() {
        _managedPoints[featureId] = point;
        statusMessage =
            'Point at (${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}) — total: ${_managedPoints.length}';
      });
    }
  }

  Future<void> _removeLastPoint() async {
    final controller = _controller;
    if (controller == null || _managedPoints.isEmpty) return;

    final lastId = _managedPoints.keys.last;
    final removed =
        await controller.removePointFromLayer(_pointLayerName, lastId);

    if (removed && mounted) {
      setState(() {
        _managedPoints.remove(lastId);
        statusMessage =
            'Removed point — total: ${_managedPoints.length}';
      });
    }
  }

  Future<void> _clearAllPoints() async {
    final controller = _controller;
    if (controller == null || _managedPoints.isEmpty) return;

    for (final id in _managedPoints.keys.toList()) {
      await controller.removePointFromLayer(_pointLayerName, id);
      _managedPoints.remove(id);
    }
    if (mounted) setState(() => statusMessage = 'Cleared all points');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Galileo Flutter Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          // Status bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16.0),
            color: Colors.grey[100],
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
                      const Text(
                        'Tap to add points · Arrow keys to pan · +/- to zoom',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                DropdownButton<String>(
                  value: _layerConfigString,
                  onChanged: (value) async {
                    switch (value) {
                      case 'osm_tile_layer':
                        setState(() {
                          _layerConfig = LayerConfig.osm();
                          _layerConfigString = 'osm_tile_layer';
                        });
                      case 'vector_tile_layer_1':
                        setState(() => statusMessage = 'Loading...');
                        final style = await rootBundle
                            .loadString('assets/vt_style.json');
                        if (mounted) {
                          setState(() {
                            _layerConfig = LayerConfig.vectorTiles(
                              urlTemplate: MAP_TILER_URL_TEMPLATE,
                              styleJson: style,
                            );
                            _layerConfigString = 'vector_tile_layer_1';
                            statusMessage = 'Tap map to add points';
                          });
                        }
                      case 'vector_tile_layer_2':
                        setState(() {
                          statusMessage = 'Loading...';
                          _layerConfigString = 'vector_tile_layer_2';
                        });
                        final style = await rootBundle
                            .loadString('assets/simple_style.json');
                        if (mounted) {
                          setState(() {
                            _layerConfig = LayerConfig.vectorTiles(
                              urlTemplate: MAP_TILER_URL_TEMPLATE,
                              styleJson: style,
                            );
                            _layerConfigString = 'vector_tile_layer_2';
                            statusMessage = 'Tap map to add points';
                          });
                        }
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

          // Map widget — wrap with our own Listener to detect tap vs drag
          Expanded(
            child: Container(
              decoration:
                  BoxDecoration(border: Border.all(color: Colors.grey)),
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

                  if (_controller == null) {
                    Future.microtask(() => _initManagedLayer(controller!));
                  }

                  // Wrap map in a Listener to distinguish tap from drag
                    return Builder(
                      builder: (ctx) {
                        return Listener(
                          onPointerDown: (e) {
                            _pointerDownPosition = e.localPosition;
                          },
                          onPointerUp: (e) {
                            final renderBox = ctx.findRenderObject() as RenderBox;
                            final size = renderBox.size;

                            final down = _pointerDownPosition;
                            if (down == null) return;

                            final delta = (e.localPosition - down).distance;
                            if (delta < _tapThreshold) {
                              _addPointAtScreenPos(
                                e.localPosition.dx,
                                e.localPosition.dy,
                                size,
                              );
                            }

                            _pointerDownPosition = null;
                          },
                          onPointerCancel: (_) => _pointerDownPosition = null,
                          child: GalileoMapWidget.fromController(
                            key: ValueKey(_layerConfigString),
                            controller: controller!,
                            size: _kMapSize,
                            config: _kMapConfig,
                            layers: [_layerConfig],
                            enableKeyboard: true,
                            autoDispose: false,
                            child: Positioned(
                              top: 10,
                              right: 10,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.9),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      'Map Controls:',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text('• Tap to add point', style: TextStyle(fontSize: 10)),
                                    const Text('• Drag to pan', style: TextStyle(fontSize: 10)),
                                    const Text('• Pinch to zoom', style: TextStyle(fontSize: 10)),
                                    const Text('• Arrow keys to pan', style: TextStyle(fontSize: 10)),
                                    const Text('• +/- to zoom', style: TextStyle(fontSize: 10)),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Points: ${_managedPoints.length}',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                },
              ),
            ),
          ),

          // Control panel
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16.0),
            color: Colors.grey[50],
            child: Wrap(
              spacing: 8.0,
              runSpacing: 8.0,
              children: [
                ElevatedButton.icon(
                  onPressed: (_layerReady && _managedPoints.isNotEmpty)
                      ? _removeLastPoint
                      : null,
                  icon: const Icon(Icons.wrong_location),
                  label: Text('Remove Last (${_managedPoints.length})'),
                ),
                ElevatedButton.icon(
                  onPressed: (_layerReady && _managedPoints.isNotEmpty)
                      ? _clearAllPoints
                      : null,
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear All'),
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
              'Points on map: ${_managedPoints.length}',
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
