import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class AuthBootstrap {
  const AuthBootstrap({
    required this.supabaseEnabled,
    required this.supabaseInitError,
  });

  final bool supabaseEnabled;
  final String? supabaseInitError;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  var supabaseEnabled = false;
  String? supabaseInitError;

  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) {
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        anonKey: supabaseAnonKey,
      );
      supabaseEnabled = true;
    } catch (error) {
      supabaseInitError = error.toString();
    }
  }

  runApp(
    EventCaptureApp(
      authBootstrap: AuthBootstrap(
        supabaseEnabled: supabaseEnabled,
        supabaseInitError: supabaseInitError,
      ),
    ),
  );
}

class EventCaptureApp extends StatelessWidget {
  const EventCaptureApp({super.key, required this.authBootstrap});

  final AuthBootstrap authBootstrap;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Event Capture',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: CapturePage(authBootstrap: authBootstrap),
    );
  }
}

enum WarehouseEventType { vehicleReceived, vehicleInspected }

extension WarehouseEventTypeX on WarehouseEventType {
  String get label {
    switch (this) {
      case WarehouseEventType.vehicleReceived:
        return 'vehicle.received';
      case WarehouseEventType.vehicleInspected:
        return 'vehicle.inspected';
    }
  }

  String get endpoint {
    switch (this) {
      case WarehouseEventType.vehicleReceived:
        return '/v1/events/vehicle-received';
      case WarehouseEventType.vehicleInspected:
        return '/v1/events/vehicle-inspected';
    }
  }
}

class ApiResult {
  const ApiResult({required this.ok, required this.statusCode, required this.body});

  final bool ok;
  final int statusCode;
  final String body;
}

class QueuedEvent {
  QueuedEvent({
    required this.eventType,
    required this.payload,
    required this.token,
    required this.idempotencyKey,
    required this.correlationId,
    required this.createdAt,
  });

  final String eventType;
  final Map<String, dynamic> payload;
  final String token;
  final String idempotencyKey;
  final String correlationId;
  final String createdAt;

  Map<String, dynamic> toJson() => {
        'eventType': eventType,
        'payload': payload,
        'token': token,
        'idempotencyKey': idempotencyKey,
        'correlationId': correlationId,
        'createdAt': createdAt,
      };

  factory QueuedEvent.fromJson(Map<String, dynamic> json) => QueuedEvent(
        eventType: json['eventType'] as String,
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        token: json['token'] as String,
        idempotencyKey: json['idempotencyKey'] as String,
        correlationId: json['correlationId'] as String,
        createdAt: json['createdAt'] as String,
      );
}

class OfflineStoreService {
  const OfflineStoreService();

  static const _storageKey = 'pending_event_queue';
  static const _tokenKey = 'cfg_token';
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<String?> loadToken() => _secureStorage.read(key: _tokenKey);

  Future<void> saveToken(String token) async {
    await _secureStorage.write(key: _tokenKey, value: token);
  }

  Future<List<QueuedEvent>> load() async {
    final raw = await _secureStorage.read(key: _storageKey);
    if (raw == null || raw.isEmpty) {
      return [];
    }
    try {
      return (jsonDecode(raw) as List)
          .map((item) => QueuedEvent.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();
    } catch (_) {
      await _secureStorage.delete(key: _storageKey);
      return [];
    }
  }

  Future<void> save(List<QueuedEvent> queue) async {
    final raw = jsonEncode(queue.map((event) => event.toJson()).toList());
    await _secureStorage.write(key: _storageKey, value: raw);
  }

  Future<void> enqueue(QueuedEvent event) async {
    final queue = await load();
    queue.add(event);
    await save(queue);
  }
}

class GatewayClient {
  GatewayClient(this._client);

  final http.Client _client;

  Future<ApiResult> send({
    required String baseUrl,
    required String endpoint,
    required Map<String, dynamic> payload,
    required String token,
    required String idempotencyKey,
    required String correlationId,
  }) async {
    final uri = Uri.parse('$baseUrl$endpoint');
    final response = await _client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            'X-Idempotency-Key': idempotencyKey,
            'X-Correlation-Id': correlationId,
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 10));

    return ApiResult(
      ok: response.statusCode >= 200 && response.statusCode < 300,
      statusCode: response.statusCode,
      body: response.body,
    );
  }
}

class CapturePage extends StatefulWidget {
  const CapturePage({super.key, required this.authBootstrap});

  final AuthBootstrap authBootstrap;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  final _uuid = const Uuid();
  final _queueService = const OfflineStoreService();
  final _gatewayClient = GatewayClient(http.Client());
  final _connectivity = Connectivity();

  final _baseUrlCtrl = TextEditingController(text: 'http://10.0.2.2:8000');
  final _tokenCtrl = TextEditingController();
  final _supabaseEmailCtrl = TextEditingController();
  final _supabasePasswordCtrl = TextEditingController();
  final _tenantCtrl = TextEditingController(text: 'tenant-a');
  final _sourceCtrl = TextEditingController(text: 'urn:warehouse:event-capture:android');

  final _operatorCtrl = TextEditingController();
  final _inspectorCtrl = TextEditingController();
  final _vendorCtrl = TextEditingController();

  final _vinCtrl = TextEditingController();
  final _shipmentCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _colorCtrl = TextEditingController();
  final _rawScanCtrl = TextEditingController();

  final _warehouseCtrl = TextEditingController();
  final _gateCtrl = TextEditingController();
  final _businessProcessCtrl = TextEditingController(text: 'inbound_receipt');
  final _reasonCtrl = TextEditingController(text: 'apm_delivery');
  final _deviceCtrl = TextEditingController(text: 'android-device-001');
  final _appVersionCtrl = TextEditingController(text: '1.0.0');
  final _conditionsCtrl = TextEditingController();
  final _damagesCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  WarehouseEventType _selectedType = WarehouseEventType.vehicleReceived;
  String _scanMethod = 'qrcode';
  String _inspectionStatus = 'pass';
  String _status = 'Siap';
  int _queueSize = 0;
  bool _networkAvailable = false;
  bool _busy = false;
  bool _authBusy = false;
  bool _syncingQueue = false;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<AuthState>? _authStateSubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _authStateSubscription?.cancel();
    _gatewayClient._client.close();
    final all = [
      _baseUrlCtrl,
      _tokenCtrl,
      _supabaseEmailCtrl,
      _supabasePasswordCtrl,
      _tenantCtrl,
      _sourceCtrl,
      _operatorCtrl,
      _inspectorCtrl,
      _vendorCtrl,
      _vinCtrl,
      _shipmentCtrl,
      _modelCtrl,
      _colorCtrl,
      _rawScanCtrl,
      _warehouseCtrl,
      _gateCtrl,
      _businessProcessCtrl,
      _reasonCtrl,
      _deviceCtrl,
      _appVersionCtrl,
      _conditionsCtrl,
      _damagesCtrl,
      _notesCtrl,
    ];
    for (final controller in all) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _loadPrefsAndQueue();
    await _initSupabaseAuth();
    await _initConnectivityMonitor();
  }

  Future<void> _initSupabaseAuth() async {
    if (!widget.authBootstrap.supabaseEnabled) {
      if (widget.authBootstrap.supabaseInitError != null && mounted) {
        setState(() {
          _status = 'Supabase init gagal: ${widget.authBootstrap.supabaseInitError}';
        });
      }
      return;
    }

    _authStateSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      final session = event.session;
      final accessToken = session?.accessToken ?? '';
      if (accessToken.isNotEmpty) {
        _tokenCtrl.text = accessToken;
        unawaited(_queueService.saveToken(accessToken));
      }

      if (!mounted) {
        return;
      }

      final userEmail = session?.user.email ?? _supabaseEmailCtrl.text.trim();
      setState(() {
        if (userEmail.isNotEmpty) {
          _supabaseEmailCtrl.text = userEmail;
        }
      });
    });

    await _syncSupabaseSession(silent: true);
  }

  Future<void> _syncSupabaseSession({required bool silent}) async {
    if (!widget.authBootstrap.supabaseEnabled) {
      return;
    }

    final session = Supabase.instance.client.auth.currentSession;
    final accessToken = session?.accessToken ?? '';
    if (accessToken.isNotEmpty) {
      _tokenCtrl.text = accessToken;
      await _queueService.saveToken(accessToken);
      if (mounted && !silent) {
        setState(() {
          _status = 'Session Supabase aktif untuk ${session?.user.email ?? '-'}';
        });
      }
    }
  }

  String _resolveAuthToken() {
    if (widget.authBootstrap.supabaseEnabled) {
      final sessionToken = Supabase.instance.client.auth.currentSession?.accessToken;
      if (sessionToken != null && sessionToken.isNotEmpty) {
        _tokenCtrl.text = sessionToken;
        return sessionToken;
      }
    }
    return _tokenCtrl.text.trim();
  }

  Future<void> _signInSupabase() async {
    if (!widget.authBootstrap.supabaseEnabled) {
      setState(() {
        _status =
            'Supabase belum aktif. Jalankan app dengan --dart-define SUPABASE_URL dan SUPABASE_ANON_KEY.';
      });
      return;
    }

    final email = _supabaseEmailCtrl.text.trim();
    final password = _supabasePasswordCtrl.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _status = 'Email/password Supabase wajib diisi.';
      });
      return;
    }

    setState(() => _authBusy = true);
    try {
      final response = await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      final accessToken = response.session?.accessToken ?? '';
      if (accessToken.isEmpty) {
        throw Exception('Access token kosong dari Supabase.');
      }
      _tokenCtrl.text = accessToken;
      await _queueService.saveToken(accessToken);
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Login Supabase sukses untuk $email';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Login Supabase gagal: $error';
      });
    } finally {
      if (mounted) {
        setState(() => _authBusy = false);
      }
    }
  }

  Future<void> _signOutSupabase() async {
    if (!widget.authBootstrap.supabaseEnabled) {
      return;
    }
    setState(() => _authBusy = true);
    try {
      await Supabase.instance.client.auth.signOut();
      _tokenCtrl.clear();
      _supabasePasswordCtrl.clear();
      await _queueService.saveToken('');
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Logout Supabase berhasil.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Logout Supabase gagal: $error';
      });
    } finally {
      if (mounted) {
        setState(() => _authBusy = false);
      }
    }
  }

  bool _hasNetwork(List<ConnectivityResult> result) {
    return result.any((item) => item != ConnectivityResult.none);
  }

  Future<void> _initConnectivityMonitor() async {
    final initial = await _connectivity.checkConnectivity();
    _applyConnectivity(initial, triggerAutoSync: true);

    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((result) {
      _applyConnectivity(result, triggerAutoSync: true);
    });
  }

  void _applyConnectivity(
    List<ConnectivityResult> result, {
    required bool triggerAutoSync,
  }) {
    final connected = _hasNetwork(result);
    final changed = connected != _networkAvailable;

    if (mounted && changed) {
      setState(() {
        _networkAvailable = connected;
        _status = connected
            ? 'Koneksi tersedia. Sinkronisasi antrean berjalan otomatis.'
            : 'Offline: event baru akan disimpan ke antrean lokal.';
      });
    } else {
      _networkAvailable = connected;
    }

    if (connected && triggerAutoSync) {
      unawaited(_flushQueue(silent: true, fromAuto: true));
    }
  }

  Future<void> _loadPrefsAndQueue() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrlCtrl.text = prefs.getString('cfg_base_url') ?? _baseUrlCtrl.text;
    _supabaseEmailCtrl.text = prefs.getString('cfg_supabase_email') ?? '';
    _tokenCtrl.text = await _queueService.loadToken() ?? '';
    final queue = await _queueService.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _queueSize = queue.length;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cfg_base_url', _baseUrlCtrl.text.trim());
    await prefs.setString('cfg_supabase_email', _supabaseEmailCtrl.text.trim());
    await _queueService.saveToken(_tokenCtrl.text.trim());
  }

  List<String> _splitCsv(String raw) {
    return raw
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  Map<String, dynamic> _buildPayload() {
    final nowUtc = DateTime.now().toUtc().toIso8601String();
    final base = <String, dynamic>{
      'tenant_id': _tenantCtrl.text.trim(),
      'source': _sourceCtrl.text.trim(),
      'who': {
        'operator_id': _operatorCtrl.text.trim(),
        if (_inspectorCtrl.text.trim().isNotEmpty)
          'inspector_id': _inspectorCtrl.text.trim(),
        if (_vendorCtrl.text.trim().isNotEmpty) 'vendor_id': _vendorCtrl.text.trim(),
      },
      'what': {
        'vin': _vinCtrl.text.trim(),
        'shipment_id': _shipmentCtrl.text.trim(),
        if (_modelCtrl.text.trim().isNotEmpty) 'model_code': _modelCtrl.text.trim(),
        if (_colorCtrl.text.trim().isNotEmpty) 'color_code': _colorCtrl.text.trim(),
        'raw_scan_value': _rawScanCtrl.text.trim(),
      },
      'where': {
        'warehouse_id': _warehouseCtrl.text.trim(),
        if (_gateCtrl.text.trim().isNotEmpty) 'gate_id': _gateCtrl.text.trim(),
      },
      'why': {
        'business_process': _businessProcessCtrl.text.trim(),
        'reason_code': _reasonCtrl.text.trim(),
      },
      'how': {
        'scan_method': _scanMethod,
        'app_version': _appVersionCtrl.text.trim(),
        'device_id': _deviceCtrl.text.trim(),
      },
    };

    if (_selectedType == WarehouseEventType.vehicleReceived) {
      base['receipt'] = {
        'when_scanned_at': nowUtc,
        'when_received_at': nowUtc,
        'condition_checklist': _splitCsv(_conditionsCtrl.text),
        'notes': _notesCtrl.text.trim(),
      };
    } else {
      base['inspection'] = {
        'when_scanned_at': nowUtc,
        'when_inspected_at': nowUtc,
        'inspection_status': _inspectionStatus,
        'damage_codes': _splitCsv(_damagesCtrl.text),
        'notes': _notesCtrl.text.trim(),
      };
    }

    return base;
  }

  String? _validateInput() {
    if (_tenantCtrl.text.trim().isEmpty) return 'tenant_id wajib diisi';
    if (_operatorCtrl.text.trim().isEmpty) return 'operator_id wajib diisi';
    if (_vinCtrl.text.trim().length != 17) return 'VIN wajib 17 karakter';
    if (_shipmentCtrl.text.trim().isEmpty) return 'shipment_id wajib diisi';
    if (_warehouseCtrl.text.trim().isEmpty) return 'warehouse_id wajib diisi';
    if (_deviceCtrl.text.trim().isEmpty) return 'device_id wajib diisi';
    if (_rawScanCtrl.text.trim().isEmpty) return 'raw_scan_value wajib diisi';
    if (_baseUrlCtrl.text.trim().isEmpty) return 'Base URL gateway wajib diisi';
    if (_resolveAuthToken().isEmpty) return 'Token auth kosong. Login Supabase dulu.';
    return null;
  }

  Future<void> _sendNow() async {
    final validationError = _validateInput();
    if (validationError != null) {
      setState(() => _status = 'Validasi gagal: $validationError');
      return;
    }

    setState(() => _busy = true);
    await _savePrefs();

    final idempotencyKey = _uuid.v4();
    final correlationId = _uuid.v4();
    final payload = _buildPayload();
    final token = _resolveAuthToken();

    if (!_networkAvailable) {
      await _queueService.enqueue(
        QueuedEvent(
          eventType: _selectedType.label,
          payload: payload,
          token: token,
          idempotencyKey: idempotencyKey,
          correlationId: correlationId,
          createdAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      final queue = await _queueService.load();
      if (mounted) {
        setState(() {
          _queueSize = queue.length;
          _status = 'Offline: event disimpan aman di lokal (${queue.length} antrean).';
          _busy = false;
        });
      }
      return;
    }

    try {
      final result = await _gatewayClient.send(
        baseUrl: _baseUrlCtrl.text.trim(),
        endpoint: _selectedType.endpoint,
        payload: payload,
        token: token,
        idempotencyKey: idempotencyKey,
        correlationId: correlationId,
      );

      if (result.ok) {
        setState(() => _status = 'ACK ${result.statusCode}: ${result.body}');
      } else {
        await _queueService.enqueue(
          QueuedEvent(
            eventType: _selectedType.label,
            payload: payload,
            token: token,
            idempotencyKey: idempotencyKey,
            correlationId: correlationId,
            createdAt: DateTime.now().toUtc().toIso8601String(),
          ),
        );
        final queue = await _queueService.load();
        setState(() {
          _queueSize = queue.length;
          _status = 'NACK ${result.statusCode}. Disimpan ke antrean lokal.';
        });
      }
    } catch (error) {
      await _queueService.enqueue(
        QueuedEvent(
          eventType: _selectedType.label,
          payload: payload,
          token: token,
          idempotencyKey: idempotencyKey,
          correlationId: correlationId,
          createdAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      final queue = await _queueService.load();
      setState(() {
        _queueSize = queue.length;
        _status = 'Koneksi gagal: $error. Disimpan ke antrean lokal.';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _flushQueue({bool silent = false, bool fromAuto = false}) async {
    if (_syncingQueue) {
      return;
    }

    if (!_networkAvailable) {
      if (mounted && !silent) {
        setState(() => _status = 'Masih offline, antrean belum bisa dipublish.');
      }
      return;
    }

    _syncingQueue = true;
    if (mounted && !silent) {
      setState(() => _busy = true);
    }

    final queue = await _queueService.load();
    if (queue.isEmpty) {
      if (mounted) {
        setState(() {
          _queueSize = 0;
          if (!silent) {
            _status = 'Antrean kosong.';
          }
          _busy = false;
        });
      }
      _syncingQueue = false;
      return;
    }

    final remaining = <QueuedEvent>[];
    var success = 0;

    for (final item in queue) {
      final endpoint = item.eventType == WarehouseEventType.vehicleInspected.label
          ? WarehouseEventType.vehicleInspected.endpoint
          : WarehouseEventType.vehicleReceived.endpoint;
      try {
        final result = await _gatewayClient.send(
          baseUrl: _baseUrlCtrl.text.trim(),
          endpoint: endpoint,
          payload: item.payload,
          token: item.token,
          idempotencyKey: item.idempotencyKey,
          correlationId: item.correlationId,
        );

        if (result.ok) {
          success++;
        } else {
          remaining.add(item);
        }
      } catch (_) {
        remaining.add(item);
      }
    }

    await _queueService.save(remaining);
    if (!mounted) {
      _syncingQueue = false;
      return;
    }
    setState(() {
      _queueSize = remaining.length;
      _busy = false;
      if (!silent || success > 0 || fromAuto) {
        _status =
            'Sinkronisasi antrean: sukses $success, tersisa ${remaining.length}.';
      }
    });
    _syncingQueue = false;
  }

  Future<void> _scanCode() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanCodePage()),
    );
    if (code == null || code.trim().isEmpty) {
      return;
    }

    _rawScanCtrl.text = code.trim();

    try {
      final decoded = jsonDecode(code);
      if (decoded is Map<String, dynamic>) {
        if ((decoded['vin'] as String?)?.isNotEmpty ?? false) {
          _vinCtrl.text = decoded['vin'] as String;
        }
        if ((decoded['shipment_id'] as String?)?.isNotEmpty ?? false) {
          _shipmentCtrl.text = decoded['shipment_id'] as String;
        }
        if ((decoded['model_code'] as String?)?.isNotEmpty ?? false) {
          _modelCtrl.text = decoded['model_code'] as String;
        }
      }
    } catch (_) {
      if (code.trim().length == 17) {
        _vinCtrl.text = code.trim();
      }
    }

    setState(() {
      _scanMethod = 'qrcode';
      _status = 'Scan berhasil: ${code.trim()}';
    });
  }

  Widget _textField(TextEditingController controller, String label,
      {String? hint, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final supabaseReady = widget.authBootstrap.supabaseEnabled;
    final hasSession =
        supabaseReady && Supabase.instance.client.auth.currentSession != null;
    final currentUserEmail =
        supabaseReady ? (Supabase.instance.client.auth.currentUser?.email ?? '') : '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Event Capture Android'),
        actions: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Center(child: Text('Queue: $_queueSize')),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    _textField(_baseUrlCtrl, 'Gateway Base URL'),
                    _textField(_tokenCtrl, 'JWT Bearer Token', maxLines: 2),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _supabaseEmailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Supabase Email',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _supabasePasswordCtrl,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Supabase Password',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: (!supabaseReady || _authBusy)
                                ? null
                                : _signInSupabase,
                            icon: const Icon(Icons.login),
                            label: Text(_authBusy ? 'Signing in...' : 'Login Supabase'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: (!supabaseReady || _authBusy || !hasSession)
                                ? null
                                : _signOutSupabase,
                            icon: const Icon(Icons.logout),
                            label: const Text('Logout'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        supabaseReady
                            ? (hasSession
                                ? 'Supabase session aktif: $currentUserEmail'
                                : 'Supabase siap, belum login.')
                            : 'Supabase nonaktif. Gunakan --dart-define SUPABASE_URL dan SUPABASE_ANON_KEY.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<WarehouseEventType>(
              initialValue: _selectedType,
              decoration: const InputDecoration(
                labelText: 'Event Type',
                border: OutlineInputBorder(),
              ),
              items: WarehouseEventType.values
                  .map(
                    (item) => DropdownMenuItem(
                      value: item,
                      child: Text(item.label),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() => _selectedType = value);
              },
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _scanCode,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan Barcode/QR'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _flushQueue(silent: false),
                    icon: const Icon(Icons.sync),
                    label: const Text('Kirim Ulang Queue'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _textField(_tenantCtrl, 'tenant_id'),
            _textField(_sourceCtrl, 'source'),
            _textField(_operatorCtrl, 'who.operator_id'),
            _textField(_inspectorCtrl, 'who.inspector_id'),
            _textField(_vendorCtrl, 'who.vendor_id'),
            _textField(_vinCtrl, 'what.vin (17 karakter)'),
            _textField(_shipmentCtrl, 'what.shipment_id'),
            _textField(_modelCtrl, 'what.model_code'),
            _textField(_colorCtrl, 'what.color_code'),
            _textField(_rawScanCtrl, 'what.raw_scan_value'),
            _textField(_warehouseCtrl, 'where.warehouse_id'),
            _textField(_gateCtrl, 'where.gate_id'),
            _textField(_businessProcessCtrl, 'why.business_process'),
            _textField(_reasonCtrl, 'why.reason_code'),
            _textField(_deviceCtrl, 'how.device_id'),
            _textField(_appVersionCtrl, 'how.app_version'),
            DropdownButtonFormField<String>(
              initialValue: _scanMethod,
              decoration: const InputDecoration(
                labelText: 'how.scan_method',
                border: OutlineInputBorder(),
              ),
              items: const ['barcode', 'qrcode', 'manual']
                  .map((item) => DropdownMenuItem(value: item, child: Text(item)))
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() => _scanMethod = value);
              },
            ),
            const SizedBox(height: 10),
            if (_selectedType == WarehouseEventType.vehicleReceived)
              _textField(
                _conditionsCtrl,
                'receipt.condition_checklist (CSV)',
                hint: 'contoh: body_ok,accessories_complete',
              )
            else
              Column(
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _inspectionStatus,
                    decoration: const InputDecoration(
                      labelText: 'inspection.inspection_status',
                      border: OutlineInputBorder(),
                    ),
                    items: const ['pass', 'fail', 'hold']
                        .map((item) => DropdownMenuItem(value: item, child: Text(item)))
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _inspectionStatus = value);
                    },
                  ),
                  const SizedBox(height: 10),
                  _textField(
                    _damagesCtrl,
                    'inspection.damage_codes (CSV)',
                    hint: 'contoh: SCRATCH01,BROKEN02',
                  ),
                ],
              ),
            _textField(_notesCtrl, 'notes', maxLines: 2),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _sendNow,
                icon: const Icon(Icons.send),
                label: Text(_busy ? 'Memproses...' : 'Kirim Event'),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              color: _networkAvailable
                  ? Colors.green.withValues(alpha: 0.12)
                  : Colors.orange.withValues(alpha: 0.12),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    Icon(
                      _networkAvailable ? Icons.cloud_done : Icons.cloud_off,
                      size: 18,
                      color: _networkAvailable ? Colors.green : Colors.orange,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _networkAvailable ? 'Online (auto-sync aktif)' : 'Offline mode aktif',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    if (_syncingQueue)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_status),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ScanCodePage extends StatefulWidget {
  const ScanCodePage({super.key});

  @override
  State<ScanCodePage> createState() => _ScanCodePageState();
}

class _ScanCodePageState extends State<ScanCodePage> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Barcode/QR')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_handled) {
            return;
          }
          final first = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
          if (first == null || first.trim().isEmpty) {
            return;
          }
          _handled = true;
          Navigator.of(context).pop(first.trim());
        },
      ),
    );
  }
}
