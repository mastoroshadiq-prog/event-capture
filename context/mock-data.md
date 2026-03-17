Data ini disinkronkan dengan QRCode Testing Kit v3.0. Gunakan variabel ini di dalam Flutter.
const Map<String, dynamic> SSOT_PO_DATA = {
  // SKENARIO 1: TOYOTA MIXED BATCH (4 UNIT)
  "PO-ARISTA-2026-006": {
    "vendor_info": "PT Toyota Astra Motor",
    "carrier_name": "Sinar Logistic",
    "description": "Stock Replenishment - Mixed Models",
    "warehouse_id": "WH-SDR-01",
    "destination_branch": "ARISTA Sudirman",
    "units": [
      {"vin": "MHRM1F1G1PK200001", "model": "Innova Zenix V Hybrid", "color": "Platinum White"},
      {"vin": "MHRM1F1G1PK200002", "model": "Veloz 1.5 Q CVT", "color": "Black Metallic"},
      {"vin": "MHRM1F1G1PK200003", "model": "Avanza 1.5 G CVT", "color": "Silver Metallic"},
      {"vin": "MHRM1F1G1PK200004", "model": "Fortuner 2.8 GR Sport", "color": "Super White"}
    ]
  },

  // SKENARIO 2: SPECIAL ORDER (1 UNIT)
  "PO-ARISTA-2026-007": {
    "vendor_info": "PT Astra Daihatsu Motor",
    "carrier_name": "Internal Drive",
    "description": "Customer Order - Pesanan Khusus",
    "warehouse_id": "WH-SDR-02",
    "destination_branch": "ARISTA Sudirman",
    "units": [
      {"vin": "MHRK2F1G1RK300999", "model": "Daihatsu Terios R AT", "color": "Greenish Gun Metal"}
    ]
  },

  // SKENARIO 3: FLEET EXPANSION (3 UNIT)
  "PO-ARISTA-2026-008": {
    "vendor_info": "PT Astra Daihatsu Motor",
    "carrier_name": "Fleet Transport Service",
    "description": "Fleet Expansion - Gran Max Series",
    "warehouse_id": "WH-SDR-01",
    "destination_branch": "ARISTA Sudirman",
    "units": [
      {"vin": "MHRB3F1G1SK400111", "model": "Gran Max PU 1.5 AC PS", "color": "White"},
      {"vin": "MHRB3F1G1SK400112", "model": "Gran Max PU 1.5 AC PS", "color": "White"},
      {"vin": "MHRB3F1G1SK400113", "model": "Gran Max PU 1.5 AC PS", "color": "White"}
    ]
  }
};
