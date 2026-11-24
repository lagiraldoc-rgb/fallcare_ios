import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

typedef FallEvent = Map<String, String>;

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

class _FallMonitorPageState extends State<FallMonitorPage>
    with WidgetsBindingObserver {
  static final Guid serviceUuid = Guid('00000000-0001-11e1-9ab4-0002a5d5c51b');
  static final Guid charUuid = Guid('00000001-0001-11e1-ac36-0002a5d5c51b');

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final AudioPlayer _audioPlayer = AudioPlayer();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _fallChar;
  StreamSubscription<List<int>>? _charSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<Position>? _gpsSub;

  Timer? _hapticTimer;
  Timer? _countdownTimer;
  Timer? _autoResetTimer;
  Timer? _saveDebounce;

  bool _isScanning = false;
  bool _isConnected = false;
  bool _isFallActive = false;
  int _countdown = 15;
  DateTime? _fallTime;
  String _lastByteText = 'Sensor: --';
  String _statusText = 'Presiona "Conectar SensorTile" para iniciar.';
  String _gpsText = 'GPS: Esperando ubicación...';
  String _mapsUrl = '';
  String _autoAlertStatus = '';
  List<ScanResult> _foundDevices = [];

  final _nameCtrl = TextEditingController();
  final _contactNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _bloodCtrl = TextEditingController();
  final _allergiesCtrl = TextEditingController();

  List<FallEvent> _history = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initNotifications();
    _initAudio();
    _loadSavedData();
    _startGpsTracking();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _persistAllNow(showBanner: false);
    }
  }

  File? _getBackupFile() {
    try {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return null;
      final docsDir = Directory('$home/Documents');
      if (!docsDir.existsSync()) {
        docsDir.createSync(recursive: true);
      }
      return File('${docsDir.path}/fallcare_profile.json');
    } catch (_) {
      return null;
    }
  }

  Future<void> _initAudio() async {
    try {
      await _audioPlayer.setAudioContext(
        AudioContext(
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: const {AVAudioSessionOptions.mixWithOthers},
          ),
        ),
      );
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
    } catch (_) {}
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
        sound: 'alarma_caida.wav',
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
    String name = '';
    String contactName = '';
    String phone = '';
    String blood = '';
    String allergies = '';
    List<FallEvent> loadedHistory = [];

    try {
      final file = _getBackupFile();
      if (file != null && file.existsSync()) {
        final raw = file.readAsStringSync();
        final data = jsonDecode(raw);
        if (data is Map) {
          name = (data['fc_name'] ?? '').toString();
          contactName = (data['fc_contact_name'] ?? '').toString();
          phone = (data['fc_phone'] ?? '').toString();
          blood = (data['fc_blood'] ?? '').toString();
          allergies = (data['fc_allergies'] ?? '').toString();
          final rawList = data['fc_history'];
          if (rawList is Iterable) {
            for (final item in rawList) {
              if (item is Map) {
                loadedHistory.add({
                  'date': (item['date'] ?? '').toString(),
                  'time': (item['time'] ?? '').toString(),
                  'status': (item['status'] ?? '').toString(),
                });
              }
            }
          }
        }
      }
    } catch (_) {}

    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getString('fc_phone') ?? '').isNotEmpty ||
          (prefs.getString('fc_name') ?? '').isNotEmpty) {
        name = prefs.getString('fc_name') ?? name;
        contactName = prefs.getString('fc_contact_name') ?? contactName;
        phone = prefs.getString('fc_phone') ?? phone;
        blood = prefs.getString('fc_blood') ?? blood;
        allergies = prefs.getString('fc_allergies') ?? allergies;
      }
      final rawHist = prefs.getString('fc_history');
      if (rawHist != null && loadedHistory.isEmpty) {
        final decoded = jsonDecode(rawHist);
        if (decoded is Iterable) {
          for (final item in decoded) {
            if (item is Map) {
              loadedHistory.add({
                'date': (item['date'] ?? '').toString(),
                'time': (item['time'] ?? '').toString(),
                'status': (item['status'] ?? '').toString(),
              });
            }
          }
        }
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _nameCtrl.text = name;
      _contactNameCtrl.text = contactName;
      _phoneCtrl.text = phone;
      _bloodCtrl.text = blood;
      _allergiesCtrl.text = allergies;
      _history = loadedHistory;
    });
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () {
      _persistAllNow(showBanner: false);
    });
  }

  Future<void> _persistAllNow({bool showBanner = true}) async {
    final cleanPhone = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    final name = _nameCtrl.text.trim();
    final contactName = _contactNameCtrl.text.trim();
    final blood = _bloodCtrl.text.trim();
    final allergies = _allergiesCtrl.text.trim();

    try {
      final file = _getBackupFile();
      if (file != null) {
        final payload = {
          'fc_name': name,
          'fc_contact_name': contactName,
          'fc_phone': cleanPhone,
          'fc_blood': blood,
          'fc_allergies': allergies,
          'fc_history': _history,
        };
        file.writeAsStringSync(jsonEncode(payload), flush: true);
      }
    } catch (_) {}

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fc_name', name);
      await prefs.setString('fc_contact_name', contactName);
      await prefs.setString('fc_phone', cleanPhone);
      await prefs.setString('fc_blood', blood);
      await prefs.setString('fc_allergies', allergies);
      await prefs.setString('fc_history', jsonEncode(_history));
    } catch (_) {}

    if (showBanner && mounted) {
      FocusScope.of(context).unfocus();
      setState(() {
        _phoneCtrl.text = cleanPhone;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Contacto y ficha médica guardados en el iPhone.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _startGpsTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        setState(() => _gpsText = 'GPS: Activa la ubicación en Ajustes.');
      }
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        setState(() => _gpsText = 'GPS: Permiso denegado.');
      }
      return;
    }

    try {
      final initialPos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      _updateGpsState(initialPos);
    } catch (_) {}

    _gpsSub?.cancel();
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(_updateGpsState);
  }

  void _updateGpsState(Position pos) {
    final lat = pos.latitude.toStringAsFixed(6);
    final lon = pos.longitude.toStringAsFixed(6);
    if (!mounted) return;
    setState(() {
      _mapsUrl = 'https://maps.google.com/?q=$lat,$lon';
      _gpsText = 'Ubicación actual: $lat, $lon';
    });
  }

  bool _isTargetSensor(ScanResult r) {
    final advName = r.advertisementData.advName.toLowerCase();
    final platName = r.device.platformName.toLowerCase();
    final hasService = r.advertisementData.serviceUuids.any(
        (u) => u.toString().toLowerCase() == serviceUuid.toString().toLowerCase());

    return hasService ||
        advName.contains('am1v') ||
        platName.contains('am1v') ||
        advName.contains('sensortile') ||
        platName.contains('sensortile') ||
        advName.contains('allmems') ||
        platName.contains('allmems') ||
        advName.contains('bluenrg') ||
        platName.contains('bluenrg');
  }

  Future<void> _scanAndConnect() async {
    if (_isScanning) return;
    await _persistAllNow(showBanner: false);

    setState(() {
      _isScanning = true;
      _foundDevices = [];
      _statusText = 'Iniciando Bluetooth del iPhone...';
    });

    try {
      final adapterState = await FlutterBluePlus.adapterState
          .where((s) =>
              s == BluetoothAdapterState.on ||
              s == BluetoothAdapterState.off ||
              s == BluetoothAdapterState.unauthorized)
          .first
          .timeout(const Duration(seconds: 5),
              onTimeout: () => BluetoothAdapterState.on);

      if (adapterState == BluetoothAdapterState.unauthorized) {
        if (mounted) {
          setState(() {
            _isScanning = false;
            _statusText =
                'Permiso Bluetooth denegado. Actívalo en Ajustes > FallCare.';
          });
        }
        return;
      }

      if (adapterState == BluetoothAdapterState.off) {
        if (mounted) {
          setState(() {
            _isScanning = false;
            _statusText = 'Enciende el Bluetooth en tu iPhone.';
          });
        }
        return;
      }

      if (mounted) {
        setState(() => _statusText = 'Buscando SensorTile (AM1V420)...');
      }

      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) async {
        if (mounted) {
          setState(() {
            _foundDevices = results
                .where((r) =>
                    r.advertisementData.advName.isNotEmpty ||
                    r.device.platformName.isNotEmpty)
                .toList();
          });
        }

        for (final r in results) {
          if (_isTargetSensor(r)) {
            await FlutterBluePlus.stopScan();
            await _scanSub?.cancel();
            await _connectToDevice(r.device);
            return;
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));

      await Future.delayed(const Duration(seconds: 12));
      if (!_isConnected && mounted) {
        setState(() {
          _isScanning = false;
          _statusText = _foundDevices.isEmpty
              ? 'No se detectó la SensorTile. Verifica batería/encendido.'
              : 'Selecciona tu dispositivo en la lista de abajo:';
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
      await FlutterBluePlus.stopScan();
      final label = device.platformName.isNotEmpty
          ? device.platformName
          : device.remoteId.str;
      if (mounted) {
        setState(() {
          _isScanning = false;
          _statusText = 'Conectando a $label...';
        });
      }

      await device.connect(autoConnect: false);
      _connectedDevice = device;

      _connSub?.cancel();
      _connSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          _stopAlarm();
          _countdownTimer?.cancel();
          _autoResetTimer?.cancel();
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
      bool subscribed = false;
      for (final s in services) {
        if (s.uuid == serviceUuid) {
          for (final c in s.characteristics) {
            if (c.uuid == charUuid) {
              _fallChar = c;
              await c.setNotifyValue(true);
              subscribed = true;
              _charSub?.cancel();
              _charSub = c.onValueReceived.listen((value) {
                if (value.isEmpty) return;
                final byteVal = value[0];
                if (mounted) {
                  setState(() => _lastByteText =
                      'Sensor: 0x0${byteVal.toRadixString(16)}');
                }
                if (byteVal == 1) {
                  _triggerFallAlert();
                }
              });
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _isConnected = true;
          _isScanning = false;
          _foundDevices = [];
          _lastByteText = subscribed
              ? 'Sensor: 0x00 (Listo)'
              : 'Sensor: Conectado (sin servicio caídas)';
          _statusText = 'Monitoreando en primer y segundo plano ($label)';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isScanning = false;
          _isConnected = false;
          _statusText = 'Error al conectar: $e';
        });
      }
    }
  }

  void _triggerFallAlert() {
    if (_isFallActive) return;
    _autoResetTimer?.cancel();
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final dateStr = '${now.day}/${now.month}/${now.year}';

    setState(() {
      _isFallActive = true;
      _fallTime = now;
      _countdown = 15;
      _autoAlertStatus =
          'La alerta automática con ubicación se enviará al llegar a 0s.';
    });

    _addHistory(dateStr, timeStr, 'Alerta activa (sin confirmar)');
    _showBackgroundFallNotification(timeStr);
    _startAlarmSound();

    bool alreadyDispatched = false;
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) return;
      final elapsed = DateTime.now().difference(now).inSeconds;
      final remaining = 15 - elapsed;

      if (remaining <= 0) {
        timer.cancel();
        setState(() => _countdown = 0);
        if (!alreadyDispatched) {
          alreadyDispatched = true;
          _updateLatestHistory('Alerta confirmada (enviada automáticamente)');
          _sendAutomaticAlert(timeStr);
        }
      } else {
        setState(() => _countdown = remaining);
      }
    });
  }

  Future<void> _sendAutomaticAlert(String timeStr) async {
    if (!mounted) return;
    setState(() {
      _autoAlertStatus = '📡 Enviando alerta automática con ubicación GPS...';
    });

    final digits = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    final last10 =
        digits.length >= 10 ? digits.substring(digits.length - 10) : digits;

    if (last10.length < 7) {
      if (mounted) {
        setState(() {
          _autoAlertStatus =
              '⚠️ Escribe un número de teléfono válido (10 dígitos) en el formulario.';
        });
      }
      _scheduleAutoReset();
      return;
    }

    if (_mapsUrl.isEmpty) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 4),
          ),
        );
        _updateGpsState(pos);
      } catch (_) {}
    }

    final patient = _nameCtrl.text.trim().isEmpty
        ? 'Usuario FallCare'
        : _nameCtrl.text.trim();
    final blood =
        _bloodCtrl.text.trim().isEmpty ? 'No registrado' : _bloodCtrl.text.trim();
    final allergies = _allergiesCtrl.text.trim().isEmpty
        ? 'Ninguna registrada'
        : _allergiesCtrl.text.trim();
    final locationLine =
        _mapsUrl.isEmpty ? 'Ubicación GPS no disponible aún' : _mapsUrl;

    final body = '''
🚨 EMERGENCIA: Se ha detectado una caída de $patient ($timeStr).

🩺 FICHA MÉDICA:
• RH / EPS: $blood
• Alergias: $allergies

📍 UBICACIÓN ACTUAL:
$locationLine
''';

    final topicName = 'fallcare-$last10';
    final jsonPayload = <String, dynamic>{
      'topic': topicName,
      'title': 'ALERTA DE CAIDA - $patient',
      'message': body,
      'priority': 5,
      'tags': ['rotating_light', 'warning'],
      if (_mapsUrl.isNotEmpty)
        'actions': [
          {
            'action': 'view',
            'label': 'Ver ubicacion en mapa',
            'url': _mapsUrl,
          }
        ],
    };

    try {
      final response = await http
          .post(
            Uri.parse('https://ntfy.sh'),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: utf8.encode(jsonEncode(jsonPayload)),
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final contactLabel = _contactNameCtrl.text.trim().isEmpty
            ? last10
            : '${_contactNameCtrl.text.trim()} ($last10)';
        setState(() {
          _autoAlertStatus =
              '✅ Alerta enviada a $contactLabel. Volviendo a estado normal...';
        });
      } else {
        setState(() {
          _autoAlertStatus =
              '⚠️ Error del servidor (${response.statusCode}): ${response.body}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _autoAlertStatus = '⚠️ No se pudo enviar la alerta: $e';
        });
      }
    }

    _scheduleAutoReset();
  }

  void _scheduleAutoReset() {
    _autoResetTimer?.cancel();
    _autoResetTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || !_isFallActive) return;
      _resetToNormalAfterAlert();
    });
  }

  Future<void> _resetToNormalAfterAlert() async {
    _stopAlarm();
    _countdownTimer?.cancel();
    _autoResetTimer?.cancel();

    if (_fallChar != null) {
      try {
        await _fallChar!.write(
          [0x00],
          withoutResponse: _fallChar!.properties.writeWithoutResponse,
        );
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _isFallActive = false;
      _autoAlertStatus = '';
      if (_isConnected) {
        _lastByteText = 'Sensor: 0x00 (Listo)';
        _statusText = 'Alerta enviada. Monitoreando en primer y segundo plano';
      } else {
        _statusText =
            'Alerta enviada. Presiona "Conectar SensorTile" para iniciar.';
      }
    });
  }

  Future<void> _startAlarmSound() async {
    _stopAlarm();
    HapticFeedback.heavyImpact();
    _hapticTimer = Timer.periodic(const Duration(milliseconds: 1100), (_) {
      HapticFeedback.heavyImpact();
    });

    try {
      await _audioPlayer.play(AssetSource('alarma_caida.wav'), volume: 1.0);
    } catch (_) {
      SystemSound.play(SystemSoundType.alert);
      _hapticTimer?.cancel();
      _hapticTimer = Timer.periodic(const Duration(milliseconds: 1100), (_) {
        SystemSound.play(SystemSoundType.alert);
        HapticFeedback.heavyImpact();
      });
    }
  }

  void _stopAlarm() {
    _hapticTimer?.cancel();
    _hapticTimer = null;
    _audioPlayer.stop();
  }

  Future<void> _acknowledgeFall() async {
    _stopAlarm();
    _countdownTimer?.cancel();
    _autoResetTimer?.cancel();
    final elapsed =
        _fallTime != null ? DateTime.now().difference(_fallTime!).inSeconds : 0;
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
      _autoAlertStatus = '';
      _statusText = _isConnected
          ? 'Monitoreando en primer y segundo plano'
          : 'Presiona "Conectar SensorTile" para iniciar.';
    });
  }

  Future<void> _callEmergency() async {
    final phone = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (phone.isEmpty) return;
    final formatted = phone.length == 10 ? '+57$phone' : '+$phone';
    await launchUrl(Uri.parse('tel:$formatted'));
  }

  Future<void> _addHistory(String date, String time, String status) async {
    setState(() {
      _history.insert(0, {'date': date, 'time': time, 'status': status});
      if (_history.length > 20) _history.removeLast();
    });
    await _persistAllNow(showBanner: false);
  }

  Future<void> _updateLatestHistory(String status) async {
    if (_history.isEmpty) return;
    setState(() => _history[0]['status'] = status);
    await _persistAllNow(showBanner: false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveDebounce?.cancel();
    _persistAllNow(showBanner: false);
    _stopAlarm();
    _audioPlayer.dispose();
    _countdownTimer?.cancel();
    _autoResetTimer?.cancel();
    _scanSub?.cancel();
    _charSub?.cancel();
    _connSub?.cancel();
    _gpsSub?.cancel();
    _nameCtrl.dispose();
    _contactNameCtrl.dispose();
    _phoneCtrl.dispose();
    _bloodCtrl.dispose();
    _allergiesCtrl.dispose();
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
                style:
                    const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
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
                      const Text('Tiempo para cancelar envío automático:'),
                      Text(
                        _countdown > 0 ? '${_countdown}s' : '🚨 ALERTA ENVIADA',
                        style: const TextStyle(
                            fontSize: 34, fontWeight: FontWeight.w900),
                      ),
                      if (_autoAlertStatus.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          _autoAlertStatus,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ],
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
                if (!_isConnected && _foundDevices.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Dispositivos cercanos (toca para conectar):',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        ..._foundDevices.map((r) {
                          final name = r.advertisementData.advName.isNotEmpty
                              ? r.advertisementData.advName
                              : r.device.platformName;
                          return TextButton(
                            onPressed: () => _connectToDevice(r.device),
                            child: Text('📡 $name (${r.rssi} dBm)'),
                          );
                        }),
                      ],
                    ),
                  ),
                ],
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
                    const Text('CONTACTO DE EMERGENCIA Y FICHA MÉDICA',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _contactNameCtrl,
                      onChanged: (_) => _scheduleSave(),
                      decoration: const InputDecoration(
                          labelText: 'Nombre del contacto de emergencia'),
                    ),
                    TextField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      onChanged: (_) => _scheduleSave(),
                      decoration: const InputDecoration(
                          labelText:
                              'Teléfono de emergencia (ej. 313 580 7499)'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _nameCtrl,
                      onChanged: (_) => _scheduleSave(),
                      decoration: const InputDecoration(
                          labelText: 'Nombre completo del paciente'),
                    ),
                    TextField(
                      controller: _bloodCtrl,
                      onChanged: (_) => _scheduleSave(),
                      decoration:
                          const InputDecoration(labelText: 'RH y EPS'),
                    ),
                    TextField(
                      controller: _allergiesCtrl,
                      onChanged: (_) => _scheduleSave(),
                      decoration: const InputDecoration(labelText: 'Alergias'),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: () => _persistAllNow(showBanner: true),
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
