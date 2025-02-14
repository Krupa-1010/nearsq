import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_heatmap/flutter_map_heatmap.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'firebase_options.dart';
import 'package:rxdart/rxdart.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:provider/provider.dart';

class SOSRequest {
  final LatLng location;
  final String msg;
  final String name;
  final String url; // Changed from phone to url for scrap data
  final String
      source; // Add source to differentiate between online/offline/scrap
  String status; // Make this mutable

  SOSRequest({
    required this.location,
    required this.msg,
    required this.name,
    required this.url,
    required this.source,
    this.status = 'pending',
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    // If Firebase is already initialized, catch the exception
    if (e is! FirebaseException || e.code != 'duplicate-app') {
      rethrow;
    }
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => RescuerLocationProvider(),
      child: MaterialApp(
        title: 'Kochi Disaster Severity Map',
        theme: ThemeData(
          primarySwatch: Colors.red,
        ),
        home: const MyHomePage(),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late DatabaseReference databaseRef;
  Timer? _locationTimer; // Keep this for the timer

  @override
  void initState() {
    super.initState();
    databaseRef = FirebaseDatabase.instance.ref();
  }

  // Remove these fields:
  // final _rescuerLocationNotifier = ValueNotifier<LatLng?>(null);
  // Timer? _locationTimer;
  // Position? _currentPosition;
  // LatLng? _rescuerLocation;
  // late DatabaseReference databaseRef;

  // Remove the static data points
  List<WeightedLatLng> _getHeatmapData(List<SOSRequest> requests) {
    List<WeightedLatLng> heatmapData = [];

    for (var request in requests) {
      // Assign weights based on status and source
      double weight = _getRequestWeight(request);

      heatmapData.add(WeightedLatLng(request.location, weight));
    }

    return heatmapData;
  }

  // Helper method to determine weight based on request properties
  double _getRequestWeight(SOSRequest request) {
    // Base weight
    double weight = 50.0;

    // Adjust weight based on status
    switch (request.status) {
      case 'pending':
        weight *= 2.0; // Higher weight for pending requests
        break;
      case 'responding':
        weight *= 1.5; // Medium weight for responding
        break;
      case 'rescued':
        weight *= 0.5; // Lower weight for rescued
        break;
    }

    // Adjust weight based on source
    switch (request.source) {
      case 'online':
        weight *= 1.2; // Higher priority for real-time requests
        break;
      case 'offline':
        weight *= 1.0; // Normal priority
        break;
      case 'scrap':
        weight *= 0.8; // Lower priority for scraped data
        break;
    }

    return weight;
  }

  // Keep the existing gradients
  final Map<double, MaterialColor> gradients = {
    0.0: Colors.green, // Safe areas (0-0.33)
    0.34: Colors.yellow, // Warning areas (0.34-0.66)
    0.67: Colors.red, // Danger areas (0.67-1.0)
  };

  int index = 0;

  String _selectedLayer = 'Both'; // Default to show both layers
  final List<String> _layerOptions = ['Both', 'Heatmap Only', 'Markers Only'];

  // Add this method to fetch online SOS requests
  Stream<List<SOSRequest>> _getOnlineSOSRequests() {
    return FirebaseFirestore.instance
        .collection('sos')
        .doc('online')
        .snapshots()
        .map((doc) {
      if (!doc.exists) {
        print('Online document does not exist');
        return [];
      }

      try {
        final data = doc.data();
        if (data == null) return [];

        final sosArray = data['sos'] as List?;
        if (sosArray == null) return [];

        return sosArray.where((sosData) {
          try {
            final lat = double.tryParse(sosData['lat'].toString());
            final lon = double.tryParse(sosData['lon'].toString());
            return lat != null && lon != null;
          } catch (e) {
            print('Invalid location data in online: $e');
            return false;
          }
        }).map<SOSRequest>((sosData) {
          return SOSRequest(
            location: LatLng(
              double.parse(sosData['lat'].toString()),
              double.parse(sosData['lon'].toString()),
            ),
            msg: sosData['msg']?.toString() ?? 'No message',
            name: sosData['name']?.toString() ?? 'No name',
            url: sosData['phone']?.toString() ?? '',
            source: 'online',
            status: sosData['status']?.toString() ?? 'pending',
          );
        }).toList();
      } catch (e) {
        print('Error processing online document: $e');
        return [];
      }
    });
  }

  // Rename existing _getSOSRequests to _getOfflineSOSRequests
  Stream<List<SOSRequest>> _getOfflineSOSRequests() {
    return FirebaseFirestore.instance
        .collection('sos')
        .doc('offline')
        .snapshots()
        .map((doc) {
      if (!doc.exists) {
        print('Document does not exist');
        return [];
      }

      try {
        final data = doc.data();
        if (data == null) {
          print('Document data is null');
          return [];
        }

        final sosArray = data['sos'] as List?;
        if (sosArray == null) {
          print('SOS array is null');
          return [];
        }

        return sosArray.where((sosData) {
          // Filter out invalid data
          try {
            final lat = double.tryParse(sosData['lat'].toString());
            final lon = double.tryParse(sosData['lon'].toString());
            return lat != null && lon != null;
          } catch (e) {
            print('Invalid location data: $e');
            return false;
          }
        }).map<SOSRequest>((sosData) {
          // Convert valid data to SOSRequest
          return SOSRequest(
            location: LatLng(
              double.parse(sosData['lat'].toString()),
              double.parse(sosData['lon'].toString()),
            ),
            msg: sosData['msg']?.toString() ?? 'No message',
            name: sosData['name']?.toString() ?? 'No name',
            url: sosData['phone']?.toString() ?? '',
            source: 'offline',
            status: sosData['status']?.toString() ?? 'pending',
          );
        }).toList();
      } catch (e) {
        print('Error processing document: $e');
        return [];
      }
    });
  }

  // Add this method to fetch scrap SOS requests
  Stream<List<SOSRequest>> _getScrapSOSRequests() {
    return FirebaseFirestore.instance
        .collection('sos')
        .doc('scrap')
        .snapshots()
        .map((doc) {
      if (!doc.exists) {
        print('Scrap document does not exist');
        return [];
      }

      try {
        final data = doc.data();
        if (data == null) return [];

        final searchAndRescue = data['search_and_rescue'] as List?;
        if (searchAndRescue == null) return [];

        return searchAndRescue.where((sosData) {
          try {
            final lat = double.tryParse(sosData['lat'].toString());
            final lon = double.tryParse(sosData['lon'].toString());
            return lat != null && lon != null;
          } catch (e) {
            print('Invalid location data in scrap: $e');
            return false;
          }
        }).map<SOSRequest>((sosData) {
          return SOSRequest(
            location: LatLng(
              double.parse(sosData['lat'].toString()),
              double.parse(sosData['lon'].toString()),
            ),
            msg: sosData['message']?.toString() ?? 'No message',
            name: sosData['user']?.toString() ?? 'No name',
            url: sosData['url']?.toString() ?? '',
            source: 'scrap',
            status: sosData['status']?.toString() ?? 'pending',
          );
        }).toList();
      } catch (e) {
        print('Error processing scrap document: $e');
        return [];
      }
    });
  }

  // Add this method to combine all SOS requests
  Stream<List<SOSRequest>> _getAllSOSRequests() {
    return Rx.combineLatest3(
      _getOnlineSOSRequests(),
      _getOfflineSOSRequests(),
      _getScrapSOSRequests(),
      (List<SOSRequest> online, List<SOSRequest> offline,
          List<SOSRequest> scrap) {
        return [...online, ...offline, ...scrap];
      },
    );
  }

  // Update the _updateSOSStatus method
  void _updateSOSStatus(SOSRequest sos, String newStatus) {
    setState(() {
      sos.status = newStatus;
      print('Status updated to: $newStatus'); // Debug print
    });
  }

  // Update the _showSOSDetails method
  void _showSOSDetails(BuildContext context, SOSRequest sos) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              sos.source == 'scrap' ? Icons.crisis_alert : Icons.warning_amber,
              color: sos.source == 'scrap' ? Colors.blue : Colors.red,
            ),
            const SizedBox(width: 8),
            Text(sos.source == 'scrap' ? 'Search and Rescue' : 'SOS Request'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sos.name.isNotEmpty) Text('User: ${sos.name}'),
            const SizedBox(height: 8),
            Text('Message: ${sos.msg}'),
            const SizedBox(height: 8),
            if (sos.source == 'scrap' && sos.url.isNotEmpty)
              Text('Source URL: ${sos.url}'),
            if (sos.source != 'scrap') ...[
              const SizedBox(height: 8),
              Text(
                'Status: ${_getStatusMessage(sos.status)}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          if (sos.source != 'scrap') ...[
            ElevatedButton(
              onPressed: () {
                setState(() {
                  sos.status = 'responding';
                });
                _startLocationTracking(sos);
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.yellow,
              ),
              child: const Text('Respond'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  sos.status = 'rescued';
                });
                _stopLocationTracking();
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
              ),
              child: const Text('Rescued'),
            ),
          ],
        ],
      ),
    );
  }

  // Add helper methods for status colors and messages
  Color _getStatusColor(String status) {
    switch (status) {
      case 'responding':
        return Colors.yellow[700]!;
      case 'rescued':
        return Colors.green;
      default:
        return Colors.red;
    }
  }

  String _getStatusMessage(String status) {
    switch (status) {
      case 'responding':
        return 'Rescue team is on the way';
      case 'rescued':
        return 'Rescued';
      default:
        return 'Pending';
    }
  }

  Future<bool> _handleLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Location services are disabled. Please enable the services')));
      return false;
    }
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permissions are denied')));
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Location permissions are permanently denied')));
      return false;
    }
    return true;
  }

  // Update _startLocationTracking method
  void _startLocationTracking(SOSRequest sos) async {
    final hasPermission = await _handleLocationPermission();
    if (!hasPermission) return;

    _locationTimer?.cancel();

    _locationTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      try {
        final position = await Geolocator.getCurrentPosition();

        // Update realtime database with rescuer's location
        await databaseRef.set({
          'frLat': position.latitude,
          'frLon': position.longitude,
          'toLat': sos.location.latitude,
          'toLon': sos.location.longitude,
          'status': 'responding'
        });

        Provider.of<RescuerLocationProvider>(context, listen: false)
            .startTracking(sos);
      } catch (e) {
        print('Error updating location: $e');
      }
    });
  }

  void _stopLocationTracking() {
    context.read<RescuerLocationProvider>().stopTracking();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kochi Disaster Severity Heatmap'),
        backgroundColor: Colors.red,
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: DropdownButton<String>(
                value: _selectedLayer,
                dropdownColor: Colors.white,
                style: const TextStyle(color: Colors.black),
                icon: const Icon(Icons.layers, color: Colors.white),
                underline: Container(),
                items: _layerOptions.map((String value) {
                  return DropdownMenuItem<String>(
                    value: value,
                    child: Text(value),
                  );
                }).toList(),
                onChanged: (String? newValue) {
                  if (newValue != null) {
                    setState(() {
                      _selectedLayer = newValue;
                    });
                  }
                },
              ),
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<SOSRequest>>(
        stream: _getAllSOSRequests(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Error loading data'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final sosRequests = snapshot.data ?? [];
          final heatmapData = _getHeatmapData(sosRequests);

          return FlutterMap(
            options: MapOptions(
              initialCenter: const LatLng(9.9312, 76.2673),
              initialZoom: 12.0,
            ),
            children: [
              TileLayer(
                urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
              ),
              if (_selectedLayer == 'Both' || _selectedLayer == 'Heatmap Only')
                HeatMapLayer(
                  heatMapDataSource:
                      InMemoryHeatMapDataSource(data: heatmapData),
                  heatMapOptions: HeatMapOptions(
                    gradient: gradients,
                    minOpacity: 1,
                    radius: 90,
                  ),
                ),
              if (_selectedLayer == 'Both' || _selectedLayer == 'Markers Only')
                MarkerLayer(
                  markers: [
                    ...List.generate(sosRequests.length, (index) {
                      final sos = sosRequests[index];
                      return Marker(
                        point: sos.location,
                        width: 30,
                        height: 30,
                        child: GestureDetector(
                          onTap: () => _showSOSDetails(context, sos),
                          child: Container(
                            decoration: BoxDecoration(
                              color: sos.source == 'scrap'
                                  ? Colors.blue
                                  : Colors.red,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              sos.source == 'scrap'
                                  ? Icons.crisis_alert
                                  : Icons.warning_amber,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      );
                    }),
                    // Rescuer marker
                    if (Provider.of<RescuerLocationProvider>(context,
                                listen: true)
                            .location !=
                        null)
                      Marker(
                        point: Provider.of<RescuerLocationProvider>(context,
                                listen: false)
                            .location!,
                        width: 30,
                        height: 30,
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.green,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.directions_run,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  LatLng _offsetLatLng(LatLng original, int index) {
    // Create a small offset for markers with same coordinates
    // Each subsequent marker will be shifted slightly
    const double offsetBase = 0.0001; // About 11 meters
    double latOffset = (index % 3 - 1) * offsetBase;
    double lngOffset = ((index ~/ 3) % 3 - 1) * offsetBase;
    return LatLng(
      original.latitude + latOffset,
      original.longitude + lngOffset,
    );
  }
}

// Add this new class for location state management
class RescuerLocationProvider extends ChangeNotifier {
  LatLng? _location;
  Timer? _locationTimer;
  late DatabaseReference databaseRef;

  LatLng? get location => _location;

  RescuerLocationProvider() {
    databaseRef = FirebaseDatabase.instance.ref();
  }

  void startTracking(SOSRequest sos) async {
    _locationTimer?.cancel();
    _locationTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      try {
        final position = await Geolocator.getCurrentPosition();
        _location = LatLng(position.latitude, position.longitude);

        await databaseRef.set({
          'frLat': position.latitude,
          'frLon': position.longitude,
          'toLat': sos.location.latitude,
          'toLon': sos.location.longitude,
          'status': 'responding'
        });

        notifyListeners();
      } catch (e) {
        print('Error updating location: $e');
      }
    });
  }

  void stopTracking() async {
    _locationTimer?.cancel();
    await databaseRef.update({
      'status': 'rescued',
      'frLat': null,
      'frLon': null,
      'toLat': null,
      'toLon': null
    });
    _location = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _locationTimer?.cancel();
    super.dispose();
  }
}
