import 'package:flutter/foundation.dart';

const bool useRemotePoLookup = true;

const Map<String, dynamic> ssotPoData = {
  'PO-ARISTA-2026-003': {
    'vendor_info': 'PT Toyota Astra Motor',
    'carrier_name': 'Sinar Logistic',
    'description': 'Stock Replenishment - Regular Batch',
    'warehouse_id': 'WH-SDR-01',
    'destination_branch': 'ARISTA Sudirman',
    'units': [
      {
        'vin': 'MHRM1F1G1PK100001',
        'model': 'Avanza 1.5 G CVT',
        'color': 'Silver Metallic',
      },
      {
        'vin': 'MHRM1F1G1PK100002',
        'model': 'Avanza 1.5 G CVT',
        'color': 'Black Metallic',
      },
      {
        'vin': 'MHRM1F1G1PK100003',
        'model': 'Avanza 1.5 G CVT',
        'color': 'White Pearl',
      },
      {
        'vin': 'MHRM1F1G1PK100004',
        'model': 'Avanza 1.5 G CVT',
        'color': 'Grey Metallic',
      },
      {
        'vin': 'MHRM1F1G1PK100005',
        'model': 'Avanza 1.5 G CVT',
        'color': 'Blue Metallic',
      },
    ],
  },
  'PO-ARISTA-2026-004': {
    'vendor_info': 'PT Toyota Astra Motor',
    'carrier_name': 'Internal Drive',
    'description': 'Customer Order - Priority VIP',
    'warehouse_id': 'WH-SDR-02',
    'destination_branch': 'ARISTA Sudirman',
    'units': [
      {
        'vin': 'MHRK2F1G1RK000999',
        'model': 'Toyota Raize 1.0 Turbo',
        'color': 'Red Black Roof',
      },
    ],
  },
  'PO-ARISTA-2026-005': {
    'vendor_info': 'PT Astra Daihatsu Motor',
    'carrier_name': 'Fleet Transport Service',
    'description': 'Fleet Order - Project ARISTA',
    'warehouse_id': 'WH-SDR-01',
    'destination_branch': 'ARISTA Sudirman',
    'units': [
      {
        'vin': 'MHRB3F1G1SK000111',
        'model': 'Daihatsu Sigra 1.2 R',
        'color': 'White',
      },
      {
        'vin': 'MHRB3F1G1SK000222',
        'model': 'Daihatsu Sigra 1.2 R',
        'color': 'Bronze Metallic',
      },
    ],
  },
};

class PoUnit {
  const PoUnit({required this.vin, required this.model, required this.color});

  final String vin;
  final String model;
  final String color;
}

class PoContext {
  const PoContext({
    required this.poNumber,
    required this.vendorInfo,
    required this.carrierName,
    required this.description,
    required this.warehouseId,
    required this.destinationBranch,
    required this.units,
  });

  final String poNumber;
  final String vendorInfo;
  final String carrierName;
  final String description;
  final String warehouseId;
  final String destinationBranch;
  final List<PoUnit> units;
}

class VerifiedUnit {
  const VerifiedUnit({
    required this.vin,
    required this.model,
    required this.odometer,
    required this.condition,
    required this.receivedAt,
  });

  final String vin;
  final String model;
  final int odometer;
  final String condition;
  final DateTime receivedAt;
}

class ReceivingState extends ChangeNotifier {
  PoContext? _activePo;
  final Map<String, VerifiedUnit> _verifiedByVin = {};
  String? _lastError;

  PoContext? get activePo => _activePo;
  String? get lastError => _lastError;
  List<VerifiedUnit> get verifiedUnits => _verifiedByVin.values.toList();
  int get verifiedCount => _verifiedByVin.length;
  int get totalUnits => _activePo?.units.length ?? 0;
  bool isVinVerified(String vin) =>
      _verifiedByVin.containsKey(vin.trim().toUpperCase());

  bool activatePo(String scannedCode) {
    final key = scannedCode.trim();
    final raw = ssotPoData[key];
    if (raw is! Map<String, dynamic>) {
      _lastError = 'PO tidak terdaftar';
      notifyListeners();
      return false;
    }

    final unitsRaw = (raw['units'] as List?) ?? const [];
    final units = unitsRaw
        .whereType<Map>()
        .map(
          (row) => PoUnit(
            vin: (row['vin'] ?? '').toString(),
            model: (row['model'] ?? '').toString(),
            color: (row['color'] ?? '').toString(),
          ),
        )
        .toList();

    _activePo = PoContext(
      poNumber: key,
      vendorInfo: (raw['vendor_info'] ?? '-').toString(),
      carrierName: (raw['carrier_name'] ?? '-').toString(),
      description: (raw['description'] ?? '-').toString(),
      warehouseId: (raw['warehouse_id'] ?? '-').toString(),
      destinationBranch: (raw['destination_branch'] ?? '-').toString(),
      units: units,
    );
    _verifiedByVin.clear();
    _lastError = null;
    notifyListeners();
    return true;
  }

  bool activatePoFromRemote(Map<String, dynamic> raw) {
    final key = (raw['po_number'] ?? '').toString().trim();
    if (key.isEmpty) {
      _lastError = 'PO tidak valid dari server';
      notifyListeners();
      return false;
    }

    final unitsRaw = (raw['units'] as List?) ?? const [];
    final units = unitsRaw
        .whereType<Map>()
        .map(
          (row) => PoUnit(
            vin: (row['vin'] ?? '').toString(),
            model: (row['model'] ?? '').toString(),
            color: (row['color'] ?? '').toString(),
          ),
        )
        .toList();

    _activePo = PoContext(
      poNumber: key,
      vendorInfo: (raw['vendor_info'] ?? '-').toString(),
      carrierName: (raw['carrier_name'] ?? '-').toString(),
      description: (raw['description'] ?? '-').toString(),
      warehouseId: (raw['warehouse_id'] ?? '-').toString(),
      destinationBranch: (raw['destination_branch'] ?? '-').toString(),
      units: units,
    );
    _verifiedByVin.clear();
    _lastError = null;
    notifyListeners();
    return true;
  }

  bool verifyVin({
    required String scannedVin,
    required int odometer,
    required String condition,
  }) {
    final po = _activePo;
    if (po == null) {
      _lastError = 'Scan PO dulu sebelum verifikasi unit';
      notifyListeners();
      return false;
    }

    final vin = scannedVin.trim().toUpperCase();
    final match = po.units.where((u) => u.vin.toUpperCase() == vin).toList();
    if (match.isEmpty) {
      _lastError = 'VIN tidak terdaftar di PO aktif';
      notifyListeners();
      return false;
    }
    if (_verifiedByVin.containsKey(vin)) {
      _lastError = 'VIN sudah diverifikasi sebelumnya';
      notifyListeners();
      return false;
    }

    _verifiedByVin[vin] = VerifiedUnit(
      vin: match.first.vin,
      model: match.first.model,
      odometer: odometer,
      condition: condition,
      receivedAt: DateTime.now().toUtc(),
    );
    _lastError = null;
    notifyListeners();
    return true;
  }

  Map<String, dynamic>? buildCloudEvent({required String inspectorId}) {
    final po = _activePo;
    if (po == null || _verifiedByVin.isEmpty) {
      return null;
    }

    return {
      'specversion': '1.0',
      'type': 'com.arista.vehicle.inventory.received.v1',
      'source': '/id/branch/jakarta-sudirman',
      'subject': po.poNumber,
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'time': DateTime.now().toUtc().toIso8601String(),
      'datacontenttype': 'application/json',
      'data': {
        'receiving_context': {
          'warehouse_id': po.warehouseId,
          'inspector_id': inspectorId,
          'delivery_purpose': po.description,
        },
        'received_items': _verifiedByVin.values
            .map(
              (u) => {
                'vin': u.vin,
                'model': u.model,
                'odometer': u.odometer,
                'condition': u.condition,
                'received_at': u.receivedAt.toIso8601String(),
              },
            )
            .toList(),
      },
    };
  }

  Map<String, dynamic>? generateCloudEvent({required String inspectorId}) {
    return buildCloudEvent(inspectorId: inspectorId);
  }

  void resetSession() {
    _activePo = null;
    _verifiedByVin.clear();
    _lastError = null;
    notifyListeners();
  }
}
