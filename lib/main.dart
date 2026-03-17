import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'receiving_state.dart';

const _uuid = Uuid();

const _defaultBaseUrl = 'http://10.0.2.2:8000';
const _eventEndpoint = '/v1/events/vehicle-received/batch';
const _cloudEventType = 'com.arista.inventory.goods_received.verified';

// Pre-defined assignment context (sesuai permintaan)
const _predefinedWarehouseId = 'arista-kalimalang';
const _predefinedWarehouseName = 'Gudang Arista Kalimalang';

class AuthBootstrap {
  const AuthBootstrap({
    required this.supabaseEnabled,
    required this.supabaseInitError,
  });

  final bool supabaseEnabled;
  final String? supabaseInitError;
}

class AppSession {
  const AppSession({
    required this.baseUrl,
    required this.token,
    required this.operatorId,
    required this.operatorLabel,
    required this.email,
  });

  final String baseUrl;
  final String token;
  final String operatorId;
  final String operatorLabel;
  final String email;
}

class ApiResult {
  const ApiResult({
    required this.ok,
    required this.statusCode,
    required this.body,
  });

  final bool ok;
  final int statusCode;
  final String body;
}

class PendingScanItem {
  PendingScanItem({
    required this.id,
    required this.rawScan,
    required this.payload,
    required this.idempotencyKey,
    required this.correlationId,
    required this.createdAt,
  });

  final String id;
  final String rawScan;
  final Map<String, dynamic> payload;
  final String idempotencyKey;
  final String correlationId;
  final String createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'rawScan': rawScan,
    'payload': payload,
    'idempotencyKey': idempotencyKey,
    'correlationId': correlationId,
    'createdAt': createdAt,
  };

  factory PendingScanItem.fromJson(Map<String, dynamic> json) =>
      PendingScanItem(
        id: json['id'] as String,
        rawScan: json['rawScan'] as String,
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        idempotencyKey: json['idempotencyKey'] as String,
        correlationId: json['correlationId'] as String,
        createdAt: json['createdAt'] as String,
      );
}

class OfflineQueueStore {
  const OfflineQueueStore();

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _queueKey = 'offline_scan_queue';

  Future<List<PendingScanItem>> load() async {
    final raw = await _secure.read(key: _queueKey);
    if (raw == null || raw.isEmpty) {
      return [];
    }
    try {
      return (jsonDecode(raw) as List)
          .map(
            (item) => PendingScanItem.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
    } catch (_) {
      await _secure.delete(key: _queueKey);
      return [];
    }
  }

  Future<void> save(List<PendingScanItem> queue) async {
    final raw = jsonEncode(queue.map((item) => item.toJson()).toList());
    await _secure.write(key: _queueKey, value: raw);
  }
}

class GatewayClient {
  GatewayClient(this._client);

  final http.Client _client;

  Future<ApiResult> sendVehicleReceived({
    required AppSession session,
    required Map<String, dynamic> payload,
    required String idempotencyKey,
    required String correlationId,
  }) async {
    final uri = Uri.parse('${session.baseUrl}$_eventEndpoint');
    final response = await _client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${session.token}',
            'X-Idempotency-Key': idempotencyKey,
            'X-Correlation-Id': correlationId,
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 90));

    return ApiResult(
      ok: response.statusCode >= 200 && response.statusCode < 300,
      statusCode: response.statusCode,
      body: response.body,
    );
  }

  Future<ApiResult> getPoReference({
    required AppSession session,
    required String poNumber,
  }) async {
    final encodedPo = Uri.encodeComponent(poNumber.trim());
    final uri = Uri.parse('${session.baseUrl}/v1/events/po/$encodedPo');
    final response = await _client
        .get(uri, headers: {'Authorization': 'Bearer ${session.token}'})
        .timeout(const Duration(seconds: 20));

    return ApiResult(
      ok: response.statusCode >= 200 && response.statusCode < 300,
      statusCode: response.statusCode,
      body: response.body,
    );
  }
}

class SessionStore {
  const SessionStore();

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _tokenKey = 'session_token';
  static const _emailKey = 'cfg_email';
  static const _baseUrlKey = 'cfg_base_url';

  Future<String?> loadToken() => _secure.read(key: _tokenKey);

  Future<void> saveToken(String token) async {
    await _secure.write(key: _tokenKey, value: token);
  }

  Future<void> clearToken() async {
    await _secure.delete(key: _tokenKey);
  }

  Future<String> loadBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_baseUrlKey) ?? _defaultBaseUrl;
  }

  Future<void> saveBaseUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, value.trim());
  }

  Future<String> loadEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_emailKey) ?? '';
  }

  Future<void> saveEmail(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailKey, value.trim());
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  var supabaseEnabled = false;
  String? supabaseInitError;

  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) {
    try {
      await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
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
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF4F46E5));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Event Capture',
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF7F8FC),
        cardTheme: CardThemeData(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
      home: LoginPage(authBootstrap: authBootstrap),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.authBootstrap});

  final AuthBootstrap authBootstrap;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _store = const SessionStore();

  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController(text: _defaultBaseUrl);

  bool _busy = false;
  String _status = 'Silakan login untuk mulai.';

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _baseUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    _emailCtrl.text = await _store.loadEmail();
    _baseUrlCtrl.text = await _store.loadBaseUrl();

    if (!widget.authBootstrap.supabaseEnabled) {
      if (!mounted) return;
      setState(() {
        _status =
            widget.authBootstrap.supabaseInitError ??
            'Supabase nonaktif. Tambahkan --dart-define SUPABASE_URL & SUPABASE_ANON_KEY.';
      });
      return;
    }

    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      return;
    }

    final token = session.accessToken;
    final operatorId = session.user.id;
    final email = session.user.email ?? _emailCtrl.text.trim();

    await _store.saveToken(token);
    await _store.saveEmail(email);
    await _store.saveBaseUrl(_baseUrlCtrl.text.trim());

    if (!mounted) return;
    _goHome(
      AppSession(
        baseUrl: _baseUrlCtrl.text.trim(),
        token: token,
        operatorId: operatorId,
        operatorLabel: email.isEmpty ? operatorId : email,
        email: email,
      ),
    );
  }

  Future<void> _login() async {
    if (!widget.authBootstrap.supabaseEnabled) {
      setState(() {
        _status = 'Supabase belum aktif. Login tidak bisa dijalankan.';
      });
      return;
    }

    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    final baseUrl = _baseUrlCtrl.text.trim();

    if (email.isEmpty || password.isEmpty) {
      setState(() => _status = 'Email dan password wajib diisi.');
      return;
    }
    if (baseUrl.isEmpty) {
      setState(() => _status = 'Base URL gateway wajib diisi.');
      return;
    }

    setState(() => _busy = true);
    try {
      final response = await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      final session = response.session;
      if (session == null) {
        throw Exception('Session kosong dari Supabase.');
      }

      final token = session.accessToken;
      final operatorId = session.user.id;
      final userEmail = session.user.email ?? email;

      await _store.saveToken(token);
      await _store.saveEmail(userEmail);
      await _store.saveBaseUrl(baseUrl);

      if (!mounted) return;
      _goHome(
        AppSession(
          baseUrl: baseUrl,
          token: token,
          operatorId: operatorId,
          operatorLabel: userEmail,
          email: userEmail,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Login gagal: $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _goHome(AppSession session) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => HomeMenuPage(session: session)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFEDE9FE), Color(0xFFF8FAFC)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Event Capture',
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Login operator gudang untuk mulai proses penerimaan unit.',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: _baseUrlCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Gateway Base URL',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _passwordCtrl,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Password',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _login,
                            icon: const Icon(Icons.login),
                            label: Text(_busy ? 'Signing in...' : 'Login'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF2FF),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            'Assignment tetap setelah login:\n'
                            '- Lokasi: $_predefinedWarehouseName\n'
                            '- Tugas: Penerimaan Unit',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(_status, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomeMenuPage extends StatelessWidget {
  const HomeMenuPage({super.key, required this.session});

  final AppSession session;

  Future<void> _logout(BuildContext context) async {
    const store = SessionStore();
    await store.clearToken();
    await Supabase.instance.client.auth.signOut();
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => LoginPage(
          authBootstrap: const AuthBootstrap(
            supabaseEnabled: true,
            supabaseInitError: null,
          ),
        ),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Menu Utama'),
        actions: [
          IconButton(
            tooltip: 'Logout',
            onPressed: () => _logout(context),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Operator: ${session.operatorLabel}',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text('WHO (user_id): ${session.operatorId}'),
                    const SizedBox(height: 4),
                    Text(
                      'Warehouse: $_predefinedWarehouseName ($_predefinedWarehouseId)',
                    ),
                    const SizedBox(height: 4),
                    const Text('Role tugas: Penerimaan Unit'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ReceiveUnitPocPage(session: session),
                  ),
                );
              },
              child: Ink(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
                  ),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(18),
                  child: Row(
                    children: [
                      Icon(Icons.inventory_2, color: Colors.white),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Penerimaan Unit',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Icon(Icons.arrow_forward_ios, color: Colors.white),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ReceiveUnitPocPage extends StatelessWidget {
  const ReceiveUnitPocPage({super.key, required this.session});

  final AppSession session;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ReceivingState(),
      child: _ReceiveUnitPocView(session: session),
    );
  }
}

class _ReceiveUnitPocView extends StatefulWidget {
  const _ReceiveUnitPocView({required this.session});

  final AppSession session;

  @override
  State<_ReceiveUnitPocView> createState() => _ReceiveUnitPocViewState();
}

class _ReceiveUnitPocViewState extends State<_ReceiveUnitPocView> {
  final _client = GatewayClient(http.Client());
  bool _busy = false;
  String _status = 'Scan QR Surat Jalan (PO) untuk memulai.';
  int _batchDone = 0;
  int _batchTotal = 0;
  final Map<String, String> _itemStatuses = {};

  String _buildDeterministicIdempotencyKey(Map<String, dynamic> payload) {
    final data = (payload['data'] as Map<String, dynamic>? ?? const {});
    final items =
        (data['received_items'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
          ..sort(
            (a, b) => ((a['vin'] ?? '').toString()).compareTo(
              ((b['vin'] ?? '').toString()),
            ),
          );

    final canonicalItems = items
        .map(
          (e) =>
              '${e['vin'] ?? ''}|${e['model'] ?? ''}|${e['odometer'] ?? ''}|${e['condition'] ?? ''}|${e['received_at'] ?? ''}',
        )
        .join(';');

    final subject = (payload['subject'] ?? '').toString();
    final inspectorId =
        ((data['receiving_context'] as Map<String, dynamic>? ??
                    const {})['inspector_id'] ??
                '')
            .toString();
    final seed = '$subject|$inspectorId|$canonicalItems';
    return seed;
  }

  Future<void> _showSubmitResultDialog({
    required bool success,
    required String title,
    required String message,
  }) {
    final color = success ? Colors.green : Colors.red;
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return AlertDialog(
          icon: Icon(
            success ? Icons.check_circle_rounded : Icons.error_rounded,
            color: color,
            size: 30,
          ),
          title: Text(title),
          content: Text(message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  void _resetForNewScan() {
    final state = context.read<ReceivingState>();
    state.resetSession();
    setState(() {
      _batchDone = 0;
      _batchTotal = 0;
      _itemStatuses.clear();
      _status = 'Scan QR Surat Jalan (PO) untuk memulai.';
    });
  }

  @override
  void dispose() {
    _client._client.close();
    super.dispose();
  }

  Future<void> _scanPo() async {
    final code = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanCodePage()));
    if (code == null || code.trim().isEmpty || !mounted) return;

    final state = context.read<ReceivingState>();
    final scannedPo = code.trim();

    if (!useRemotePoLookup) {
      final ok = state.activatePo(scannedPo);
      setState(() {
        _status = ok
            ? 'PO aktif: ${state.activePo?.poNumber}. Lanjut scan VIN unit.'
            : (state.lastError ?? 'PO tidak terdaftar');
      });
      return;
    }

    setState(() => _status = 'Mengecek PO ke server...');
    try {
      final result = await _client.getPoReference(
        session: widget.session,
        poNumber: scannedPo,
      );
      if (!mounted) return;

      if (!result.ok) {
        setState(() {
          _status = result.statusCode == 404
              ? 'PO tidak ditemukan di master Supabase.'
              : 'Lookup PO gagal (HTTP ${result.statusCode}).';
        });
        return;
      }

      final payload = _safeDecodeMap(result.body);
      final ok = state.activatePoFromRemote(payload);
      setState(() {
        _status = ok
            ? 'PO aktif (Supabase): ${state.activePo?.poNumber}. Lanjut scan VIN unit.'
            : (state.lastError ?? 'Data PO dari server tidak valid');
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _status = 'Timeout saat lookup PO ke server.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Gagal lookup PO: $e');
    }
  }

  Future<void> _scanVinAndVerify() async {
    final state = context.read<ReceivingState>();
    if (state.activePo == null) {
      setState(() => _status = 'Scan PO dulu sebelum scan VIN.');
      return;
    }

    final code = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanCodePage()));
    if (code == null || code.trim().isEmpty || !mounted) return;

    final vin = code.trim().toUpperCase();
    if (state.isVinVerified(vin)) {
      setState(() => _status = 'VIN sudah diverifikasi sebelumnya.');
      return;
    }

    final formResult = await _showVerifyModal(vin);
    if (formResult == null || !mounted) return;

    final ok = state.verifyVin(
      scannedVin: vin,
      odometer: formResult.$1,
      condition: formResult.$2,
    );
    setState(() {
      _status = ok
          ? 'VIN $vin berhasil diverifikasi.'
          : (state.lastError ?? 'Gagal verifikasi VIN');
    });
  }

  Future<(int, String)?> _showVerifyModal(String vin) async {
    final odometerCtrl = TextEditingController();
    String condition = 'Grade A';

    return showDialog<(int, String)>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModal) {
            return AlertDialog(
              title: Text('Verifikasi VIN $vin'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: odometerCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Odometer'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: condition,
                    items: const [
                      DropdownMenuItem(
                        value: 'Grade A',
                        child: Text('Grade A'),
                      ),
                      DropdownMenuItem(
                        value: 'Grade B',
                        child: Text('Grade B'),
                      ),
                      DropdownMenuItem(
                        value: 'Grade C',
                        child: Text('Grade C'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setModal(() => condition = value);
                    },
                    decoration: const InputDecoration(
                      labelText: 'Condition Score',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Batal'),
                ),
                FilledButton(
                  onPressed: () {
                    final odometer = int.tryParse(odometerCtrl.text.trim());
                    if (odometer == null || odometer < 0) return;
                    Navigator.of(context).pop((odometer, condition));
                  },
                  child: const Text('Simpan'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _submitBatch() async {
    final state = context.read<ReceivingState>();
    final payload = state.generateCloudEvent(
      inspectorId: widget.session.operatorId,
    );
    if (payload == null) {
      setState(() => _status = 'Minimal 1 unit harus diverifikasi.');
      return;
    }

    final items =
        (payload['data'] as Map<String, dynamic>)['received_items'] as List;
    final vins = items
        .map(
          (item) => ((item as Map<String, dynamic>)['vin'] ?? '-').toString(),
        )
        .toList();

    setState(() {
      _batchTotal = vins.length;
      _batchDone = 0;
      _itemStatuses
        ..clear()
        ..addEntries(vins.map((vin) => MapEntry(vin, 'pending')));
      _busy = true;
      _status = 'Menyiapkan batch $_batchTotal unit...';
    });

    for (final vin in vins) {
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 220));
      setState(() {
        _itemStatuses[vin] = 'processing';
        _status = 'Memproses VIN $vin ($_batchDone/$_batchTotal)';
      });
    }

    try {
      final result = await _client.sendVehicleReceived(
        session: widget.session,
        payload: payload,
        idempotencyKey: _buildDeterministicIdempotencyKey(payload),
        correlationId: _uuid.v4(),
      );
      if (!mounted) return;
      var shouldResetSession = false;
      var popupSuccess = false;
      var popupTitle = '';
      var popupMessage = '';
      setState(() {
        if (result.ok) {
          final body = _safeDecodeMap(result.body);
          final rawStatuses = body['item_statuses'];
          final itemStatuses = (rawStatuses is List ? rawStatuses : const [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();

          _batchDone = 0;
          _itemStatuses.clear();
          for (final item in itemStatuses) {
            final vin = _stringOf(item['vin']) ?? '-';
            final status = _stringOf(item['status']) ?? 'pending';
            _itemStatuses[vin] = switch (status) {
              'published' => 'success',
              'failed' => 'failed',
              'processing' => 'processing',
              _ => 'pending',
            };
            if (status == 'published') {
              _batchDone++;
            }
          }
          if (_itemStatuses.isEmpty) {
            _batchDone = _batchTotal;
            for (final vin in vins) {
              _itemStatuses[vin] = 'success';
            }
          }
          _status =
              'Data batch berhasil disimpan & event dipublish ($_batchDone/$_batchTotal).';
          shouldResetSession = true;
          popupSuccess = true;
          popupTitle = 'Submit Berhasil';
          popupMessage =
              'Event berhasil dikirim ($_batchDone/$_batchTotal published). Form akan direset untuk scan baru.';
        } else {
          final hasSuccess = _batchDone > 0;
          for (final vin in _itemStatuses.keys) {
            if (_itemStatuses[vin] != 'success') {
              _itemStatuses[vin] = 'failed';
            }
          }
          _status = hasSuccess
              ? 'Batch parsial gagal (HTTP ${result.statusCode}): ${result.body}'
              : 'Gagal batch (HTTP ${result.statusCode}): ${result.body}';
          popupSuccess = false;
          popupTitle = 'Submit Gagal';
          popupMessage = _status;
        }
      });
      await _showSubmitResultDialog(
        success: popupSuccess,
        title: popupTitle,
        message: popupMessage,
      );
      if (shouldResetSession && mounted) {
        _resetForNewScan();
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _status =
            'Timeout >90 detik. Data kemungkinan sudah masuk. Silakan cek status batch atau ulang sync jika perlu.';
      });
      await _showSubmitResultDialog(
        success: false,
        title: 'Submit Timeout',
        message: _status,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        for (final vin in _itemStatuses.keys) {
          if (_itemStatuses[vin] != 'success') {
            _itemStatuses[vin] = 'failed';
          }
        }
        _status = 'Gagal kirim batch: $e';
      });
      await _showSubmitResultDialog(
        success: false,
        title: 'Exception',
        message: _status,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _statusChip(String status) {
    IconData icon;
    Color color;
    String label;
    switch (status) {
      case 'success':
        icon = Icons.check_circle_rounded;
        color = Colors.green.shade700;
        label = 'Published';
        break;
      case 'failed':
        icon = Icons.error_rounded;
        color = Colors.red.shade700;
        label = 'Failed';
        break;
      case 'processing':
        icon = Icons.sync_rounded;
        color = Colors.blue.shade700;
        label = 'Processing';
        break;
      case 'verified':
        icon = Icons.verified_rounded;
        color = Colors.teal.shade700;
        label = 'Verified';
        break;
      default:
        icon = Icons.schedule_rounded;
        color = Colors.orange.shade700;
        label = 'Pending';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ReceivingState>();
    final po = state.activePo;
    final theme = Theme.of(context);
    final progress = state.totalUnits == 0
        ? 0.0
        : (state.verifiedCount / state.totalUnits);
    final statusLower = _status.toLowerCase();
    final statusColor = statusLower.contains('gagal')
        ? Colors.red
        : statusLower.contains('berhasil')
        ? Colors.green
        : theme.colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('POC Penerimaan Unit'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _busy
                      ? Colors.orange.withValues(alpha: 0.15)
                      : Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _busy ? 'SYNCING' : 'READY',
                  style: TextStyle(
                    color: _busy
                        ? Colors.orange.shade800
                        : Colors.green.shade800,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Vehicle Receiving Gateway',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  po == null
                      ? 'Mulai dengan scan QR Surat Jalan, lanjut verifikasi VIN unit.'
                      : 'PO aktif ${po.poNumber} • ${state.verifiedCount}/${state.totalUnits} unit verified',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.qr_code_2_rounded,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Tahap 1 · Identifikasi PO',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Scan QR Surat Jalan untuk memuat daftar unit yang diharapkan.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _busy ? null : _scanPo,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR Surat Jalan'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (po != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.description_outlined),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            po.poNumber,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('Vendor: ${po.vendorInfo}'),
                    Text('Warehouse: ${po.warehouseId}'),
                    Text('Tujuan: ${po.destinationBranch}'),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 6),
                    Text(
                      'Progress verifikasi: ${state.verifiedCount}/${state.totalUnits} unit',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.fact_check_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Tahap 2 · Verifikasi Unit',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Scan VIN fisik, isi odometer & condition untuk menandai unit verified.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _busy ? null : _scanVinAndVerify,
                    icon: const Icon(Icons.document_scanner),
                    label: const Text('Scan VIN Fisik Unit'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (po != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: po.units
                      .map(
                        (u) => ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          leading: Icon(
                            state.isVinVerified(u.vin)
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            color: state.isVinVerified(u.vin)
                                ? Colors.green
                                : Colors.grey,
                          ),
                          title: Text(u.vin),
                          subtitle: Text('${u.model} • ${u.color}'),
                          trailing: _statusChip(
                            state.isVinVerified(u.vin) ? 'verified' : 'pending',
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _submitBatch,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload),
              label: Text(
                _busy ? 'Mengirim...' : 'Unit Diterima (Batch Publish)',
              ),
            ),
          ),
          if (_batchTotal > 0) ...[
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.auto_graph_rounded,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Progress Batch: $_batchDone/$_batchTotal',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _batchTotal == 0 ? 0 : (_batchDone / _batchTotal),
                    ),
                    const SizedBox(height: 10),
                    ..._itemStatuses.entries.map(
                      (entry) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(entry.key),
                        trailing: _statusChip(entry.value),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Card(
            color: statusColor.withValues(alpha: 0.10),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded, color: statusColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_status, style: TextStyle(color: statusColor)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ReceiveUnitPage extends StatefulWidget {
  const ReceiveUnitPage({super.key, required this.session});

  final AppSession session;

  @override
  State<ReceiveUnitPage> createState() => _ReceiveUnitPageState();
}

class _ReceiveUnitPageState extends State<ReceiveUnitPage> {
  final _client = GatewayClient(http.Client());
  final _queueStore = const OfflineQueueStore();
  final _connectivity = Connectivity();

  bool _busy = false;
  bool _syncing = false;
  bool _online = false;
  String _status = 'Klik scan untuk membaca QRCode/Barcode event.';
  String _rawScan = '';
  Map<String, dynamic>? _payload;
  List<MapEntry<String, String>> _scannedAttributes = [];
  int _selectedTab = 0;
  List<PendingScanItem> _queue = [];
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    _queue = await _queueStore.load();
    final initial = await _connectivity.checkConnectivity();
    _applyConnectivity(initial, autoSync: true);
    _connectivitySub = _connectivity.onConnectivityChanged.listen((result) {
      _applyConnectivity(result, autoSync: true);
    });
    if (mounted) {
      setState(() {});
    }
  }

  void _applyConnectivity(
    List<ConnectivityResult> result, {
    required bool autoSync,
  }) {
    final connected = result.any((item) => item != ConnectivityResult.none);
    final changed = connected != _online;
    _online = connected;

    if (mounted && changed) {
      setState(() {
        _status = connected
            ? 'Internet tersedia. Sinkronisasi antrean berjalan di background.'
            : 'Offline: hasil scan akan masuk ke antrean lokal.';
      });
    }

    if (connected && autoSync) {
      unawaited(_flushQueue(background: true));
    }
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _client._client.close();
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanCodePage()));
    if (code == null || code.trim().isEmpty) {
      return;
    }

    final payload = _buildPayloadFromScan(
      scanned: code.trim(),
      operatorId: widget.session.operatorId,
    );
    final scannedAttributes = _extractScannedAttributes(code.trim());

    setState(() {
      _rawScan = code.trim();
      _payload = payload;
      _scannedAttributes = scannedAttributes;
      _status = 'Scan berhasil. Periksa detail atribut lalu Submit.';
    });
  }

  List<MapEntry<String, String>> _extractScannedAttributes(String raw) {
    final loosePairs = _extractLoosePairs(raw);
    final root = _safeDecodeMap(raw);
    final dataRoot = _asMap(root['data']);

    final purchaseOrder = _firstNonEmptyString([
      _looseGet(loosePairs, const [
        'purchase_order',
        'purchaseOrder',
        'subject',
        'po_number',
        'purchase order',
      ]),
      _lookupAnyString(root, const [
        'purchase_order',
        'purchaseOrder',
        'subject',
        'po_number',
      ]),
      _lookupAnyString(dataRoot, const ['purchase_order', 'purchaseOrder']),
      _extractFieldFromRaw(raw, const [
        'purchase_order',
        'purchaseOrder',
        'subject',
        'po_number',
      ]),
    ]);
    final vendorId = _firstNonEmptyString([
      _looseGet(loosePairs, const [
        'vendor_id',
        'vendorId',
        'vendor',
        'vendor id',
      ]),
      _lookupAnyString(root, const ['vendor_id', 'vendorId', 'vendor']),
      _lookupAnyString(dataRoot, const ['vendor_id', 'vendorId', 'vendor']),
      _extractFieldFromRaw(raw, const ['vendor_id', 'vendorId', 'vendor']),
    ]);
    final operatorId = _firstNonEmptyString([
      _looseGet(loosePairs, const ['operator_id', 'operatorId', 'operator id']),
      _lookupAnyString(root, const ['operator_id', 'operatorId']),
      _lookupAnyString(dataRoot, const ['operator_id', 'operatorId']),
      _extractFieldFromRaw(raw, const ['operator_id', 'operatorId']),
    ]);
    final productId = _firstNonEmptyString([
      _looseGet(loosePairs, const [
        'product_id',
        'productId',
        'model_code',
        'sku',
        'product id',
      ]),
      _lookupAnyString(root, const [
        'product_id',
        'productId',
        'model_code',
        'sku',
      ]),
      _lookupAnyString(dataRoot, const [
        'product_id',
        'productId',
        'model_code',
        'sku',
      ]),
      _extractFieldFromRaw(raw, const [
        'product_id',
        'productId',
        'model_code',
        'sku',
      ]),
    ]);
    final vinNumber = _firstNonEmptyString([
      _looseGet(loosePairs, const [
        'vin_number',
        'vinNumber',
        'vin',
        'vin number',
      ]),
      _lookupAnyString(root, const ['vin_number', 'vinNumber', 'vin']),
      _lookupAnyString(dataRoot, const ['vin_number', 'vinNumber', 'vin']),
      _extractFieldFromRaw(raw, const ['vin_number', 'vinNumber', 'vin']),
      _extractVinFallback(raw),
    ]);
    final conditionNotes = _firstNonEmptyString([
      _stringOf(loosePairs['condition_notes']),
      _stringOf(loosePairs['conditionNotes']),
      _stringOf(loosePairs['condition']),
      _lookupAnyString(root, const [
        'condition_notes',
        'conditionNotes',
        'condition',
      ]),
      _lookupAnyString(dataRoot, const [
        'condition_notes',
        'conditionNotes',
        'condition',
      ]),
      _extractFieldFromRaw(raw, const [
        'condition_notes',
        'conditionNotes',
        'condition',
      ]),
    ]);
    final landedCost = _firstNonEmptyString([
      _stringOf(
        _numOf(
              _looseGet(loosePairs, const [
                'landed_cost_actual',
                'landedCostActual',
                'landed_cost',
                'landed cost actual',
              ]),
            ) ??
            _numOf(loosePairs['landed_cost_actual']) ??
            _numOf(loosePairs['landedCostActual']) ??
            _numOf(loosePairs['landed_cost']),
      ),
      _stringOf(
        _lookupAnyNum(root, const [
          'landed_cost_actual',
          'landedCostActual',
          'landed_cost',
        ]),
      ),
      _stringOf(
        _lookupAnyNum(dataRoot, const [
          'landed_cost_actual',
          'landedCostActual',
          'landed_cost',
        ]),
      ),
      _stringOf(
        _extractFieldFromRawNumber(raw, const [
          'landed_cost_actual',
          'landedCostActual',
          'landed_cost',
        ]),
      ),
      _extractFieldFromRaw(raw, const [
        'landed_cost_actual',
        'landedCostActual',
        'landed_cost',
      ]),
    ]);

    final entries = <MapEntry<String, String>>[];
    void addIf(String label, String? value) {
      if (value != null && value.trim().isNotEmpty) {
        entries.add(MapEntry(label, value.trim()));
      }
    }

    addIf('Purchase Order', purchaseOrder);
    addIf('Vendor ID', vendorId);
    addIf('Operator ID', operatorId);
    addIf('Product ID', productId);
    addIf('VIN Number', vinNumber);
    addIf('Condition Notes', conditionNotes);
    addIf('Landed Cost Actual', landedCost);
    return entries;
  }

  Map<String, dynamic> _buildPayloadFromScan({
    required String scanned,
    required String operatorId,
  }) {
    final nowUtc = DateTime.now().toUtc().toIso8601String();
    final root = _safeDecodeMap(scanned);
    final dataRoot = _asMap(root['data']);

    final vinNumber =
        _firstNonEmptyString([
          _lookupAnyString(dataRoot, const ['vin_number', 'vinNumber', 'vin']),
          _lookupAnyString(root, const ['vin_number', 'vinNumber', 'vin']),
          _findAnyStringDeep(root, const ['vin_number', 'vinNumber', 'vin']),
          _extractFieldFromRaw(scanned, const [
            'vin_number',
            'vinNumber',
            'vin',
          ]),
          _extractVinFallback(scanned),
        ]) ??
        '';

    final productId =
        _firstNonEmptyString([
          _lookupAnyString(dataRoot, const [
            'product_id',
            'productId',
            'model_code',
            'sku',
          ]),
          _lookupAnyString(root, const [
            'product_id',
            'productId',
            'model_code',
            'sku',
          ]),
          _findAnyStringDeep(root, const [
            'product_id',
            'productId',
            'model_code',
            'sku',
          ]),
          _extractFieldFromRaw(scanned, const [
            'product_id',
            'productId',
            'model_code',
            'sku',
          ]),
        ]) ??
        '-';

    final landedCostRaw =
        _lookupAnyNum(dataRoot, const [
          'landed_cost_actual',
          'landedCostActual',
          'landed_cost',
        ]) ??
        _lookupAnyNum(root, const [
          'landed_cost_actual',
          'landedCostActual',
          'landed_cost',
        ]) ??
        _extractFieldFromRawNumber(scanned, const [
          'landed_cost_actual',
          'landedCostActual',
          'landed_cost',
        ]);
    final landedCostActual = _numOf(landedCostRaw) ?? 0;

    return {
      'specversion': '1.0',
      'type': _stringOf(root['type']) ?? _cloudEventType,
      'source': _stringOf(root['source']) ?? 'arista:branch:jkt-pusat',
      'subject':
          _stringOf(root['subject']) ??
          _stringOf(root['po_number']) ??
          _stringOf(root['po_id']) ??
          _extractFieldFromRaw(scanned, const [
            'subject',
            'po_number',
            'po_id',
          ]) ??
          'PO-UNKNOWN',
      'id': _stringOf(root['id']) ?? _uuid.v4(),
      'time': _stringOf(root['time']) ?? nowUtc,
      'data': {
        'vendor_id':
            _firstNonEmptyString([
              _lookupAnyString(dataRoot, const [
                'vendor_id',
                'vendorId',
                'vendor',
              ]),
              _lookupAnyString(root, const ['vendor_id', 'vendorId', 'vendor']),
              _findAnyStringDeep(root, const [
                'vendor_id',
                'vendorId',
                'vendor',
              ]),
              _extractFieldFromRaw(scanned, const [
                'vendor_id',
                'vendorId',
                'vendor',
              ]),
            ]) ??
            '-',
        'operator_id': operatorId,
        'product_id': productId,
        'vin_number': vinNumber,
        'condition_notes':
            _firstNonEmptyString([
              _lookupAnyString(dataRoot, const [
                'condition_notes',
                'conditionNotes',
              ]),
              _lookupAnyString(root, const [
                'condition_notes',
                'conditionNotes',
              ]),
              _extractFieldFromRaw(scanned, const [
                'condition_notes',
                'conditionNotes',
                'condition',
              ]),
            ]) ??
            'Good - No Scratch',
        'landed_cost_actual': landedCostActual,
      },
    };
  }

  Future<void> _submit() async {
    final payload = _payload;
    if (payload == null) {
      setState(() => _status = 'Belum ada hasil scan.');
      return;
    }

    final data = _asMap(payload['data']);
    final vin = _stringOf(data['vin_number']) ?? '';
    final subject = _stringOf(payload['subject']) ?? '';

    if (vin.length != 17) {
      setState(
        () => _status = 'Payload invalid: data.vin_number harus 17 karakter.',
      );
      return;
    }
    if (subject.isEmpty) {
      setState(
        () => _status =
            'Payload invalid: subject wajib ada (contoh PO-2024-001).',
      );
      return;
    }

    final idempotencyKey = _uuid.v4();
    final correlationId = _uuid.v4();

    if (!_online) {
      final queue = await _queueStore.load();
      queue.add(
        PendingScanItem(
          id: _uuid.v4(),
          rawScan: _rawScan,
          payload: payload,
          idempotencyKey: idempotencyKey,
          correlationId: correlationId,
          createdAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      await _queueStore.save(queue);
      if (!mounted) return;
      setState(() {
        _queue = queue;
        _selectedTab = 1;
        _status = 'Offline: scan disimpan ke antrean (${queue.length} item).';
      });
      return;
    }

    setState(() => _busy = true);
    try {
      final result = await _client.sendVehicleReceived(
        session: widget.session,
        payload: payload,
        idempotencyKey: idempotencyKey,
        correlationId: correlationId,
      );

      if (!mounted) return;
      setState(() {
        _status = result.ok
            ? 'Data scan berhasil disimpan. Event dipublish di background.'
            : 'Gagal menyimpan data scan (HTTP ${result.statusCode}): ${result.body}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Gagal menyimpan data scan: $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _flushQueue({required bool background}) async {
    if (_syncing || !_online) {
      return;
    }
    _syncing = true;
    final queue = await _queueStore.load();
    if (queue.isEmpty) {
      _syncing = false;
      if (mounted && !background) {
        setState(() => _status = 'Antrean offline kosong.');
      }
      return;
    }

    final remaining = <PendingScanItem>[];
    var success = 0;

    for (final item in queue) {
      try {
        final result = await _client.sendVehicleReceived(
          session: widget.session,
          payload: item.payload,
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

    await _queueStore.save(remaining);
    _syncing = false;
    if (!mounted) return;
    setState(() {
      _queue = remaining;
      _status =
          'Sinkronisasi antrean: sukses $success, tersisa ${remaining.length}.';
    });
  }

  List<MapEntry<String, String>> _payloadPairs(Map<String, dynamic> payload) {
    final data = _asMap(payload['data']);
    final eventType = _stringOf(payload['type']) ?? '-';
    final source = _stringOf(payload['source']) ?? '-';
    final subject = _stringOf(payload['subject']) ?? '-';
    final eventTime = _stringOf(payload['time']) ?? '-';
    final operatorId = _stringOf(data['operator_id']) ?? '-';
    final vendorId = _stringOf(data['vendor_id']) ?? '-';
    final productId = _stringOf(data['product_id']) ?? '-';
    final vinNumber = _stringOf(data['vin_number']) ?? '-';
    final conditionNotes = _stringOf(data['condition_notes']) ?? '-';
    final landedCost = _stringOf(data['landed_cost_actual']) ?? '-';

    return [
      MapEntry('Operator ID', operatorId),
      MapEntry('Vendor ID', vendorId),
      MapEntry('Product ID', productId),
      MapEntry('VIN Number', vinNumber),
      MapEntry('Source', source),
      MapEntry('Event Time', eventTime),
      MapEntry('Subject/PO', subject),
      MapEntry('Event Type', eventType),
      MapEntry('Condition Notes', conditionNotes),
      MapEntry('Landed Cost Actual', landedCost),
    ];
  }

  Widget _scanTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Context aktif', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text('WHO: ${widget.session.operatorId}'),
                  const Text('Task: Penerimaan Unit'),
                  const Text('Location: Gudang Arista Kalimalang'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QRCode / Barcode'),
            ),
          ),
          const SizedBox(height: 12),
          if (_payload != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Detail Hasil Scan',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    ...((_rawScan.isNotEmpty
                                    ? _scannedAttributes
                                    : _payloadPairs(_payload!))
                                .isNotEmpty
                            ? (_rawScan.isNotEmpty
                                  ? _scannedAttributes
                                  : _payloadPairs(_payload!))
                            : [
                                const MapEntry(
                                  'Info',
                                  'Atribut QR belum terbaca',
                                ),
                              ])
                        .map(
                          (pair) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: Text(
                                    pair.key,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(flex: 7, child: Text(pair.value)),
                              ],
                            ),
                          ),
                        ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: const Icon(Icons.check_circle),
                        label: Text(_busy ? 'Menyimpan...' : 'Simpan Data'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Card(
            color: _online ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_status),
            ),
          ),
        ],
      ),
    );
  }

  Widget _queueTab(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Antrean Offline', style: theme.textTheme.titleMedium),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: (_online && !_syncing)
                    ? () => _flushQueue(background: false)
                    : null,
                icon: _syncing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: const Text('Sync'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _queue.isEmpty
                ? const Center(child: Text('Belum ada antrean offline.'))
                : ListView.separated(
                    itemCount: _queue.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final item = _queue[index];
                      final data = _asMap(item.payload['data']);
                      return Card(
                        child: ListTile(
                          title: Text(
                            'VIN: ${_stringOf(data['vin_number']) ?? '-'}',
                          ),
                          subtitle: Text(
                            'Product: ${_stringOf(data['product_id']) ?? '-'}\nCreated: ${item.createdAt}',
                          ),
                          isThreeLine: true,
                          trailing: const Icon(Icons.schedule),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Penerimaan Unit'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: Chip(
                avatar: Icon(
                  _online ? Icons.cloud_done : Icons.cloud_off,
                  size: 16,
                  color: _online ? Colors.green : Colors.orange,
                ),
                label: Text('Queue: ${_queue.length}'),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  icon: Icon(Icons.qr_code_scanner),
                  label: Text('Scan'),
                ),
                ButtonSegment(
                  value: 1,
                  icon: Icon(Icons.storage),
                  label: Text('Offline Queue'),
                ),
              ],
              selected: {_selectedTab},
              onSelectionChanged: (value) {
                setState(() => _selectedTab = value.first);
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _selectedTab == 0 ? _scanTab(theme) : _queueTab(theme),
          ),
        ],
      ),
    );
  }
}

class ScanCodePage extends StatefulWidget {
  const ScanCodePage({super.key});

  @override
  State<ScanCodePage> createState() => _ScanCodePageState();
}

class _ScanCodePageState extends State<ScanCodePage>
    with SingleTickerProviderStateMixin {
  bool _handled = false;
  late final AnimationController _lineController;

  @override
  void initState() {
    super.initState();
    _lineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _lineController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QRCode / Barcode')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_handled) return;
              final code = capture.barcodes.isNotEmpty
                  ? capture.barcodes.first.rawValue
                  : null;
              if (code == null || code.trim().isEmpty) return;
              _handled = true;
              Navigator.of(context).pop(code.trim());
            },
          ),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          Center(
            child: SizedBox(
              width: 260,
              height: 260,
              child: AnimatedBuilder(
                animation: _lineController,
                builder: (context, _) {
                  final top = 12 + ((_lineController.value) * 236);
                  return Stack(
                    children: [
                      Positioned(
                        top: top,
                        left: 12,
                        right: 12,
                        child: Container(
                          height: 2.8,
                          decoration: BoxDecoration(
                            color: const Color(0xFF34D399),
                            borderRadius: BorderRadius.circular(99),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0xAA34D399),
                                blurRadius: 10,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 26,
            child: Text(
              'Arahkan kamera ke QRCode/Barcode',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                shadows: [Shadow(blurRadius: 5, color: Colors.black54)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Map<String, dynamic> _safeDecodeMap(String raw) {
  final normalized = raw.trim();
  final candidates = <String>{
    normalized,
    normalized.replaceAll(r'\"', '"'),
    normalized.replaceAll(r'\n', '\n'),
  };

  for (final candidate in candidates) {
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // no-op
    }

    try {
      final decodedUri = Uri.decodeComponent(candidate);
      final decoded = jsonDecode(decodedUri);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // no-op
    }

    final firstBrace = candidate.indexOf('{');
    final lastBrace = candidate.lastIndexOf('}');
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      final slice = candidate.substring(firstBrace, lastBrace + 1);
      try {
        final decoded = jsonDecode(slice);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        // no-op
      }
    }
  }

  return <String, dynamic>{};
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  if (value is String) {
    final maybeMap = _safeDecodeMap(value);
    if (maybeMap.isNotEmpty) {
      return maybeMap;
    }
  }
  return <String, dynamic>{};
}

String? _stringOf(dynamic value) {
  if (value == null) return null;
  final s = value.toString().trim();
  return s.isEmpty ? null : s;
}

String? _extractVinFallback(String raw) {
  final v = raw.trim().toUpperCase();
  if (v.length == 17) {
    return v;
  }
  return null;
}

String? _extractFieldFromRaw(String raw, List<String> aliases) {
  final candidates = <String>{
    raw,
    raw.replaceAll(r'\"', '"'),
    raw.replaceAll(r'\n', '\n'),
  };

  for (final alias in aliases) {
    final escaped = RegExp.escape(alias);

    for (final source in candidates) {
      final jsonQuoted = RegExp(
        '"?$escaped"?\\s*:\\s*"([^"\\n\\r]+)"',
        caseSensitive: false,
      );
      final mQuoted = jsonQuoted.firstMatch(source);
      if (mQuoted != null) {
        final value = mQuoted.group(1)?.trim();
        if (value != null && value.isNotEmpty) return value;
      }

      final jsonRaw = RegExp(
        '"?$escaped"?\\s*:\\s*([^,}\\n\\r]+)',
        caseSensitive: false,
      );
      final mRaw = jsonRaw.firstMatch(source);
      if (mRaw != null) {
        final cleaned = mRaw.group(1)?.replaceAll('"', '').trim();
        if (cleaned != null && cleaned.isNotEmpty) return cleaned;
      }

      final queryPattern = RegExp(
        '(^|[?&;,])$escaped=([^&;,\\s]+)',
        caseSensitive: false,
      );
      final mQuery = queryPattern.firstMatch(source);
      if (mQuery != null) {
        final value = Uri.decodeComponent((mQuery.group(2) ?? '').trim());
        if (value.isNotEmpty) return value;
      }
    }
  }
  return null;
}

Map<String, String> _extractLoosePairs(String raw) {
  final result = <String, String>{};
  final normalized = raw
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\"', '"')
      .replaceAll('\\"', '"');

  final segments = normalized.split(RegExp(r'[\n;]+'));
  for (final segment in segments) {
    final text = segment.trim();
    if (text.isEmpty) continue;
    final separatorIndex = text.contains(':')
        ? text.indexOf(':')
        : text.indexOf('=');
    if (separatorIndex <= 0) continue;
    var key = text.substring(0, separatorIndex).trim();
    var value = text.substring(separatorIndex + 1).trim();

    key = key.replaceAll('"', '').trim();
    if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
      value = value.substring(1, value.length - 1).trim();
    }
    if (value.startsWith("'") && value.endsWith("'") && value.length >= 2) {
      value = value.substring(1, value.length - 1).trim();
    }
    if (value.endsWith(',')) {
      value = value.substring(0, value.length - 1).trim();
    }
    if (key.isNotEmpty && value.isNotEmpty) {
      result[key] = value;
    }
  }

  final pattern = RegExp(
    r'"?([a-zA-Z0-9_\-]+)"?\s*[:=]\s*"?([^"\n\r,}]+)"?',
    multiLine: true,
  );

  for (final m in pattern.allMatches(normalized)) {
    final key = (m.group(1) ?? '').trim();
    final value = (m.group(2) ?? '').trim();
    if (key.isEmpty || value.isEmpty) continue;
    result[key] = value;
  }
  return result;
}

String? _looseGet(Map<String, String> pairs, List<String> aliases) {
  for (final alias in aliases) {
    final direct = pairs[alias];
    if (direct != null && direct.trim().isNotEmpty) {
      return direct.trim();
    }

    final target = _canonicalKey(alias);
    for (final entry in pairs.entries) {
      if (_canonicalKey(entry.key) == target && entry.value.trim().isNotEmpty) {
        return entry.value.trim();
      }
    }
  }
  return null;
}

String _canonicalKey(String key) {
  return key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

num? _extractFieldFromRawNumber(String raw, List<String> aliases) {
  final value = _extractFieldFromRaw(raw, aliases);
  if (value == null) return null;
  return _numOf(value);
}

num? _numOf(dynamic value) {
  if (value is num) return value;
  if (value is String) {
    final raw = value.trim();
    final direct = num.tryParse(raw);
    if (direct != null) return direct;

    final cleaned = raw.replaceAll(RegExp(r'[^0-9,.-]'), '');
    final normalized = cleaned.contains(',') && !cleaned.contains('.')
        ? cleaned.replaceAll(',', '.')
        : cleaned.replaceAll(',', '');
    return num.tryParse(normalized);
  }
  return null;
}

String? _lookupAnyString(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = _stringOf(map[key]);
    if (value != null) return value;
  }
  return null;
}

num? _lookupAnyNum(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = _numOf(map[key]);
    if (value != null) return value;
  }
  return null;
}

String? _firstNonEmptyString(List<String?> candidates) {
  for (final value in candidates) {
    if (value != null && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return null;
}

String? _findAnyStringDeep(dynamic node, List<String> aliases) {
  if (node is Map) {
    final map = Map<String, dynamic>.from(node);
    for (final alias in aliases) {
      final direct = _stringOf(map[alias]);
      if (direct != null) return direct;
      final lowerKey = map.keys
          .where((k) => k.toLowerCase() == alias.toLowerCase())
          .toList();
      if (lowerKey.isNotEmpty) {
        final value = _stringOf(map[lowerKey.first]);
        if (value != null) return value;
      }
    }
    for (final value in map.values) {
      final nested = _findAnyStringDeep(value, aliases);
      if (nested != null) return nested;
    }
  } else if (node is List) {
    for (final item in node) {
      final nested = _findAnyStringDeep(item, aliases);
      if (nested != null) return nested;
    }
  }
  return null;
}
