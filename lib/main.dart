import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FallCareApp());
}

class FallCareApp extends StatelessWidget {
  const FallCareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FallCare Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const FallMonitorPage(),
    );
  }
}

class FallMonitorPage extends StatefulWidget {
  const FallMonitorPage({super.key});

  @override
  State<FallMonitorPage> createState() => _FallMonitorPageState();
}

class _FallMonitorPageState extends State<FallMonitorPage> {
  static final Guid serviceUuid = Guid('00000000-0001-11e1-9ab4-0002a5d5c51b');
  static final Guid charUuid = Guid('00000001-0001-11e1-ac36-0002a5d5c51b');

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _fallChar;
  StreamSubscription<List<int>>? _charSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<Position>? _gpsSub;

  Timer? _alarmTimer;
  Timer? _countdownTimer;

  bool _isScanning = false;
  bool _isConnected = false;
  bool _isFallActive = false;
  int _countdown = 15;
  DateTime? _fallTime;
  String _lastByteText = 'Sensor: --';
  String _statusText = 'Presiona "Conectar SensorTile" para iniciar.';
  String _gpsText = 'GPS: Esperando ubicación...';
  String _mapsUrl = '';

  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _bloodCtrl = TextEditingController();
  final _allergiesCtrl = TextEditingController();
  final _medsCtrl = TextEditingController();

  List<dynamic> _history = [];

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _loadSavedData();
    _startGpsTracking();
  }

  Future<void> _initNotifications() async {
    const initSettings = InitializationSettings(
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      ),
    );
    await _notifications.initialize(initSettings);
    await _notifications
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  Future<void> _showBackgroundFallNotification(String timeStr) async {
    const details = NotificationDetails(
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
    await _notifications.show(
      1,
      '⚠️ ¡CAÍDA DETECTADA!',
      'Se detectó una caída a las $timeStr. Toca para responder.',
      details,
    );
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _nameCtrl.text = prefs.getString('fc_name') ?? '';
      _phoneCtrl.text = prefs.getString('fc_phone') ?? '';
      _bloodCtrl.text = prefs.getString('fc_blood') ?? '';
      _allergiesCtrl.text = prefs.getString('fc_allergies') ?? '';
      _medsCtrl.text = prefs.getString('fc_meds') ?? '';
      final rawHist = prefs.getString('fc_history');
      if (rawHist != null) {
        final decoded = jsonDecode(rawHist) as List;
        _history = decoded.map((e) => Map<String, String>.from(e)).toList();
      }
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final cleanPhone = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    _phoneCtrl.text = cleanPhone;
    await prefs.setString('fc_name', _nameCtrl.text.trim());
    await prefs.setString('fc_phone', cleanPhone);
    await prefs.setString('fc_blood', _bloodCtrl.text.trim());
    await prefs.setString('fc_allergies', _allergiesCtrl.text.trim());
    await prefs.setString('fc_meds', _medsCtrl.text.trim());

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Configuración y ficha médica guardadas.')),
    );
  }

  Future<void> _startGpsTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => _gpsText = 'GPS: Activa la ubicación en Ajustes.');
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      setState(() => _gpsText = 'GPS: Permiso denegado.');
      return;
    }

    _gpsSub?.cancel();
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((pos) {
      final lat = pos.latitude.toStringAsFixed(6);
      final lon = pos.longitude.toStringAsFixed(6);
      setState(() {
        _mapsUrl = 'https://maps.google.com/?q=$lat,$lon';
        _gpsText = 'Ubicación actual: $lat, $lon';
      });
    });
  }

  Future<void> _scanAndConnect() async {
    if (_isScanning) return;
    setState(() {
      _isScanning = true;
      _statusText = 'Buscando SensorTile (AM1V420)...';
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      late StreamSubscription<List<ScanResult>> scanSub;
      scanSub = FlutterBluePlus.scanResults.listen((results) async {
        for (final r in results) {
          final name = r.device.platformName;
          final hasService = r.advertisementData.serviceUuids
              .any((u) => u.toString().toLowerCase() == serviceUuid.toString().toLowerCase());
          if (name.contains('AM1V') || hasService) {
            await FlutterBluePlus.stopScan();
            await scanSub.cancel();
            await _connectToDevice(r.device);
            return;
          }
        }
      });

      await Future.delayed(const Duration(seconds: 10));
      if (!_isConnected && mounted) {
        setState(() {
          _isScanning = false;
          _statusText = 'No se encontró AM1V420. Verifica que esté encendido.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isScanning = false;
          _statusText = 'Error Bluetooth: $e';
        });
      }
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      setState(() => _statusText = 'Conectando a ${device.platformName}...');
      await device.connect(autoConnect: false);
      _connectedDevice = device;

      _connSub?.cancel();
      _connSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          _stopAlarm();
          _countdownTimer?.cancel();
          setState(() {
            _isConnected = false;
            _isScanning = false;
            _isFallActive = false;
            _lastByteText = 'Sensor: Desconectado';
            _statusText = 'Sensor desconectado. Presiona para reconectar.';
          });
        }
      });

      final services = await device.discoverServices();
      for (final s in services) {
        if (s.uuid == serviceUuid) {
          for (final c in s.characteristics) {
            if (c.uuid == charUuid) {
              _fallChar = c;
              await c.setNotifyValue(true);
              _charSub?.cancel();
              _charSub = c.onValueReceived.listen((value) {
                if (value.isEmpty) return;
                final byteVal = value[0];
                setState(() => _lastByteText = 'Sensor: 0x0${byteVal.toRadixString(16)}');
                if (byteVal == 1) {
                  _triggerFallAlert();
                }
              });
            }
          }
        }
      }

      setState(() {
        _isConnected = true;
        _isScanning = false;
        _lastByteText = 'Sensor: 0x00 (Listo)';
        _statusText = 'Monitoreando en primer y segundo plano (${device.platformName})';
      });
    } catch (e) {
      setState(() {
        _isScanning = false;
        _isConnected = false;
        _statusText = 'Error al conectar: $e';
      });
    }
  }

  void _triggerFallAlert() {
    if (_isFallActive) return;
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final dateStr = '${now.day}/${now.month}/${now.year}';

    setState(() {
      _isFallActive = true;
      _fallTime = now;
      _countdown = 15;
    });

    _addHistory(dateStr, timeStr, 'Alerta activa (sin confirmar)');
    _showBackgroundFallNotification(timeStr);
    _startAlarmSound();

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_countdown <= 1) {
        timer.cancel();
        setState(() => _countdown = 0);
        _updateLatestHistory('Alerta confirmada (sin respuesta tras 15s)');
      } else {
        setState(() => _countdown--);
      }
    });
  }

  void _startAlarmSound() {
    _stopAlarm();
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
    _alarmTimer = Timer.periodic(const Duration(milliseconds: 1100), (_) {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
    });
  }

  void _stopAlarm() {
    _alarmTimer?.cancel();
    _alarmTimer = null;
  }

  Future<void> _acknowledgeFall() async {
    _stopAlarm();
    _countdownTimer?.cancel();
    final elapsed = _fallTime != null
        ? DateTime.now().difference(_fallTime!).inSeconds
        : 0;
    await _updateLatestHistory('Confirmada bien en ${elapsed}s');

    if (_fallChar != null) {
      try {
        await _fallChar!.write(
          [0x00],
          withoutResponse: _fallChar!.properties.writeWithoutResponse,
        );
      } catch (_) {}
    }

    setState(() {
      _isFallActive = false;
      _statusText = _isConnected
          ? 'Monitoreando en primer y segundo plano'
          : 'Presiona "Conectar SensorTile" para iniciar.';
    });
  }

  Future<void> _openWhatsApp() async {
    final phone = _phoneCtrl.text.trim();
    if (phone.isEmpty) return;
    final name = _nameCtrl.text.trim().isEmpty ? 'el usuario' : _nameCtrl.text.trim();
    final msg =
        '🚨 ALERTA DE CAÍDA (FallCare) 🚨\nPaciente: $name\n🩺 RH/EPS: ${_bloodCtrl.text} | Alergias: ${_allergiesCtrl.text}\n📍 Ubicación: $_mapsUrl';
    final uri = Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _callEmergency() async {
    final phone = _phoneCtrl.text.trim();
    if (phone.isEmpty) return;
    await launchUrl(Uri.parse('tel:+$phone'));
  }

  Future<void> _addHistory(String date, String time, String status) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _history.insert(0, {'date': date, 'time': time, 'status': status});
      if (_history.length > 20) _history.removeLast();
    });
    await prefs.setString('fc_history', jsonEncode(_history));
  }

  Future<void> _updateLatestHistory(String status) async {
    if (_history.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    setState(() => _history[0]['status'] = status);
    await prefs.setString('fc_history', jsonEncode(_history));
  }

  @override
  void dispose() {
    _stopAlarm();
    _countdownTimer?.cancel();
    _charSub?.cancel();
    _connSub?.cancel();
    _gpsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = _isFallActive
        ? const Color(0xFFB91C1C)
        : (_isConnected ? const Color(0xFF00695C) : const Color(0xFF1E293B));

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              Chip(label: Text(_lastByteText)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    Text(_gpsText, textAlign: TextAlign.center),
                    if (_mapsUrl.isNotEmpty)
                      TextButton(
                        onPressed: () => launchUrl(
                          Uri.parse(_mapsUrl),
                          mode: LaunchMode.externalApplication,
                        ),
                        child: const Text('Ver en Google Maps'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Icon(
                _isFallActive
                    ? Icons.warning_amber_rounded
                    : (_isConnected ? Icons.shield : Icons.bluetooth_searching),
                size: 72,
                color: Colors.white,
              ),
              const SizedBox(height: 8),
              Text(
                _isFallActive
                    ? '¡CAÍDA DETECTADA!'
                    : (_isConnected ? 'TODO NORMAL' : 'SIN CONEXIÓN'),
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              Text(_statusText, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              if (_isFallActive) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white),
                  ),
                  child: Column(
                    children: [
                      const Text('Tiempo para cancelar alerta:'),
                      Text(
                        _countdown > 0 ? '${_countdown}s' : '🚨 ALERTA ACTIVA',
                        style: const TextStyle(
                            fontSize: 34, fontWeight: FontWeight.w900),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: DefaultTextStyle(
                    style: const TextStyle(color: Colors.black87, fontSize: 13),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '🩺 FICHA MÉDICA DE EMERGENCIA',
                          style: TextStyle(
                              color: Color(0xFFB91C1C),
                              fontWeight: FontWeight.bold),
                        ),
                        const Divider(),
                        Text('Paciente: ${_nameCtrl.text}'),
                        Text('RH / EPS: ${_bloodCtrl.text}'),
                        Text('Alergias: ${_allergiesCtrl.text}'),
                        Text('Medicamentos: ${_medsCtrl.text}'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFFB91C1C),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: _acknowledgeFall,
                    child: const Text('CONFIRMAR QUE ESTOY BIEN',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _openWhatsApp,
                    child: const Text('📲 Enviar WhatsApp con ubicación'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFEF08A),
                      foregroundColor: Colors.black87,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _callEmergency,
                    child: const Text('📞 Llamar a contacto de emergencia'),
                  ),
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black87,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: _isConnected
                        ? () => _connectedDevice?.disconnect()
                        : _scanAndConnect,
                    child: Text(
                      _isConnected
                          ? 'Desconectar'
                          : (_isScanning
                              ? 'Buscando...'
                              : 'Conectar SensorTile'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _triggerFallAlert,
                  child: const Text('🔔 Simular caída y probar alerta',
                      style: TextStyle(color: Colors.white)),
                ),
              ],
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('CONTACTO Y FICHA MÉDICA',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(labelText: 'Nombre'),
                    ),
                    TextField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                          labelText: 'WhatsApp / Teléfono (ej. 573001234567)'),
                    ),
                    TextField(
                      controller: _bloodCtrl,
                      decoration:
                          const InputDecoration(labelText: 'RH y EPS'),
                    ),
                    TextField(
                      controller: _allergiesCtrl,
                      decoration: const InputDecoration(labelText: 'Alergias'),
                    ),
                    TextField(
                      controller: _medsCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Medicamentos'),
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      onPressed: _saveSettings,
                      child: const Text('Guardar configuración'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('HISTORIAL DE CAÍDAS',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    if (_history.isEmpty)
                      const Text('Sin eventos registrados.')
                    else
                      ..._history.map((h) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                                '⚠️ ${h['date']} ${h['time']} — ${h['status']}'),
                          )),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
