import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

const _defaultBaseUrl = 'http://10.0.2.2:8000';
const _eventEndpoint = '/v1/events/vehicle-received';
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
        .timeout(const Duration(seconds: 12));

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
                    builder: (_) => ReceiveUnitPage(session: session),
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

class ReceiveUnitPage extends StatefulWidget {
  const ReceiveUnitPage({super.key, required this.session});

  final AppSession session;

  @override
  State<ReceiveUnitPage> createState() => _ReceiveUnitPageState();
}

class _ReceiveUnitPageState extends State<ReceiveUnitPage> {
  final _client = GatewayClient(http.Client());

  bool _busy = false;
  String _status = 'Klik scan untuk membaca QRCode/Barcode event.';
  String _rawScan = '';
  Map<String, dynamic>? _payload;

  @override
  void dispose() {
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

    setState(() {
      _rawScan = code.trim();
      _payload = payload;
      _status = 'Scan berhasil. Periksa preview lalu kirim event.';
    });
  }

  Map<String, dynamic> _buildPayloadFromScan({
    required String scanned,
    required String operatorId,
  }) {
    final nowUtc = DateTime.now().toUtc().toIso8601String();
    final root = _safeDecodeMap(scanned);
    final dataRoot = _asMap(root['data']);
    final itemValue = dataRoot['item_list'];
    final itemRoot = itemValue is List && itemValue.isNotEmpty
        ? _asMap(itemValue.first)
        : _asMap(itemValue);

    final vinNumber =
        _firstNonEmptyString([
          _lookupAnyString(itemRoot, const ['vin_number', 'vinNumber', 'vin']),
          _lookupAnyString(dataRoot, const ['vin_number', 'vinNumber', 'vin']),
          _lookupAnyString(root, const ['vin_number', 'vinNumber', 'vin']),
          _extractVinFallback(scanned),
        ]) ??
        '';

    final productId =
        _firstNonEmptyString([
          _lookupAnyString(itemRoot, const [
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
          _lookupAnyString(root, const [
            'product_id',
            'productId',
            'model_code',
            'sku',
          ]),
        ]) ??
        'UNKNOWN';

    final landedCostRaw =
        _lookupAnyNum(itemRoot, const [
          'landed_cost_actual',
          'landedCostActual',
          'landed_cost',
        ]) ??
        _lookupAnyNum(dataRoot, const [
          'landed_cost_actual',
          'landedCostActual',
          'landed_cost',
        ]) ??
        _lookupAnyNum(root, const [
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
            ]) ??
            'UNKNOWN',
        'operator_id': operatorId,
        'item_list': {
          'product_id': productId,
          'vin_number': vinNumber,
          'condition_notes':
              _stringOf(itemRoot['condition_notes']) ??
              _stringOf(root['condition_notes']) ??
              'Good - No Scratch',
          'landed_cost_actual': landedCostActual,
        },
      },
    };
  }

  Future<void> _send() async {
    final payload = _payload;
    if (payload == null) {
      setState(() => _status = 'Belum ada hasil scan.');
      return;
    }

    final data = _asMap(payload['data']);
    final item = _asMap(data['item_list']);
    final vin = _stringOf(item['vin_number']) ?? '';
    final subject = _stringOf(payload['subject']) ?? '';

    if (vin.length != 17) {
      setState(
        () => _status =
            'Payload invalid: data.item_list.vin_number harus 17 karakter.',
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

    setState(() => _busy = true);
    try {
      final result = await _client.sendVehicleReceived(
        session: widget.session,
        payload: payload,
        idempotencyKey: _uuid.v4(),
        correlationId: _uuid.v4(),
      );

      if (!mounted) return;
      setState(() {
        _status = result.ok
            ? 'ACK ${result.statusCode}: ${result.body}'
            : 'NACK ${result.statusCode}: ${result.body}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Gagal kirim event: $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Penerimaan Unit - Scan')),
      body: SingleChildScrollView(
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
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QRCode / Barcode'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_rawScan.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Raw Scan', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 6),
                      SelectableText(_rawScan),
                    ],
                  ),
                ),
              ),
            if (_payload != null) ...[
              const SizedBox(height: 10),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Preview Payload (vehicle.received)',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: SelectableText(
                          const JsonEncoder.withIndent('  ').convert(_payload),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _send,
                          icon: const Icon(Icons.send),
                          label: Text(_busy ? 'Mengirim...' : 'Kirim Event'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Card(
              color: const Color(0xFFEEF2FF),
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
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {
    // no-op
  }
  return <String, dynamic>{};
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
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

num? _numOf(dynamic value) {
  if (value is num) return value;
  if (value is String) {
    return num.tryParse(value.trim());
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
