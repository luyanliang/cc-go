/// 扫码页（task 5.2）：mobile_scanner 取帧 → parsePairQr 解析；识别到
/// 有效配对码即 pop 返回载荷，宿主屏负责填表。非配对码内容不动作。
library;

import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../transport/pair_qr.dart';

class ScanPairQrScreen extends StatefulWidget {
  const ScanPairQrScreen({super.key});

  @override
  State<ScanPairQrScreen> createState() => _ScanPairQrScreenState();
}

class _ScanPairQrScreenState extends State<ScanPairQrScreen> {
  final _controller = MobileScannerController();
  var _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handle(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final payload = parsePairQr(raw);
      if (payload == null) continue;
      _done = true;
      if (mounted) Navigator.of(context).pop(payload);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描 daemon 二维码')),
      body: MobileScanner(
        controller: _controller,
        onDetect: _handle,
      ),
    );
  }
}
