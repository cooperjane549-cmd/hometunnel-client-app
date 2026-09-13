import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:wireguard_flutter_plus/wireguard_flutter_plus.dart';

void main() {
  runApp(const HomeTunnelClientApp());
}

class HomeTunnelClientApp extends StatelessWidget {
  const HomeTunnelClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HomeTunnel Client',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: Colors.blueAccent,
      ),
      home: const ClientHomePage(),
    );
  }
}

class ClientHomePage extends StatefulWidget {
  const ClientHomePage({super.key});

  @override
  State<ClientHomePage> createState() => _ClientHomePageState();
}

class _ClientHomePageState extends State<ClientHomePage> {
  final TextEditingController _codeController = TextEditingController();
  final String _backendUrl = "https://hometunnel-backend-render.onrender.com";
  final wireguard = WireGuardFlutter.instance;

  StreamSubscription<VpnStage>? _vpnStageSubscription;

  bool _isConnecting = false;
  bool _isConnected = false;
  String _statusMessage = "Disconnected";

  String _clientPrivateKey = "";
  String _clientPublicKey = "";
  bool _keysReady = false;
  bool _wgInitialized = false;

  @override
  void initState() {
    super.initState();
    _generateWireGuardKeyPair();
  }

  @override
  void dispose() {
    _vpnStageSubscription?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  /// Generates a valid 32-byte raw Curve25519 key pair compatible with WireGuard
  Future<void> _generateWireGuardKeyPair() async {
    try {
      final secureRandom = Random.secure();
      final privateKeyBytes = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        privateKeyBytes[i] = secureRandom.nextInt(256);
      }

      // Clamp private key as per Curve25519 specification
      privateKeyBytes[0] &= 248;
      privateKeyBytes[31] &= 127;
      privateKeyBytes[31] |= 64;

      // Compute public key using basepoint mult
      final publicKeyBytes = _curve25519BasePointMult(privateKeyBytes);

      if (!mounted) return;
      setState(() {
        _clientPrivateKey = base64Encode(privateKeyBytes);
        _clientPublicKey = base64Encode(publicKeyBytes);
        _keysReady = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = "Key generation failed: $e";
      });
    }
  }

  // Curve25519 Scalar Multiplication (Basepoint G)
  Uint8List _curve25519BasePointMult(Uint8List sk) {
    final BigInt p = BigInt.parse("57896044618658097711785492504343953926634992332820282019728792003956564819949");
    final BigInt d = _decodeLittleEndian(sk);

    // Compute (x, z) coordinates over Montgomery curve y^2 = x^3 + 486662*x^2 + x
    BigInt x1 = BigInt.from(9);
    BigInt x2 = BigInt.one;
    BigInt z2 = BigInt.zero;
    BigInt x3 = x1;
    BigInt z3 = BigInt.one;
    bool swap = false;

    for (int t = 254; t >= 0; t--) {
      bool kT = ((d >> t) & BigInt.one) == BigInt.one;
      swap ^= kT;
      if (swap) {
        var dummy = x2; x2 = x3; x3 = dummy;
        dummy = z2; z2 = z3; z3 = dummy;
      }
      swap = kT;

      BigInt a = (x2 + z2) % p;
      BigInt aa = (a * a) % p;
      BigInt b = (x2 - z2) % p;
      BigInt bb = (b * b) % p;
      BigInt e = (aa - bb) % p;
      BigInt c = (x3 + z3) % p;
      BigInt dVal = (x3 - z3) % p;
      BigInt da = (dVal * a) % p;
      BigInt cb = (c * b) % p;

      x3 = ((da + cb) % p * (da + cb) % p) % p;
      z3 = (x1 * ((da - cb) % p * (da - cb) % p) % p) % p;
      x2 = (aa * bb) % p;
      BigInt a24 = BigInt.from(121665);
      z2 = (e * ((bb + (a24 * e) % p) % p)) % p;
    }

    if (swap) {
      var dummy = x2; x2 = x3; x3 = dummy;
      dummy = z2; z2 = z3; z3 = dummy;
    }

    BigInt pkVal = (x2 * z2.modPow(p - BigInt.two, p)) % p;
    return _encodeLittleEndian(pkVal, 32);
  }

  BigInt _decodeLittleEndian(Uint8List bytes) {
    BigInt result = BigInt.zero;
    for (int i = bytes.length - 1; i >= 0; i--) {
      result = (result << 8) | BigInt.from(bytes[i]);
    }
    return result;
  }

  Uint8List _encodeLittleEndian(BigInt val, int length) {
    final bytes = Uint8List(length);
    BigInt temp = val;
    for (int i = 0; i < length; i++) {
      bytes[i] = (temp & BigInt.from(0xFF)).toInt();
      temp >>= 8;
    }
    return bytes;
  }

  Future<void> _connectToHost() async {
    if (!_keysReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Still generating keys, try again in a second")),
      );
      return;
    }

    final code = _codeController.text.trim();
    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter a valid 6-digit code")),
      );
      return;
    }

    setState(() {
      _isConnecting = true;
      _statusMessage = "Looking up host...";
    });

    try {
      final pairResponse = await http.post(
        Uri.parse("$_backendUrl/pair"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"code": code, "clientPublicKey": _clientPublicKey}),
      ).timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (pairResponse.statusCode != 200) {
        setState(() {
          _isConnecting = false;
          _statusMessage = "Invalid or expired code.";
        });
        return;
      }

      final data = jsonDecode(pairResponse.body);
      final String hostPublicKey = data['hostPublicKey'];
      final String hostEndpoint = data['hostEndpoint'];

      await _startWireGuardTunnel(hostPublicKey, hostEndpoint);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _statusMessage = "Connection failed. Check your internet and try again.";
      });
    }
  }

  Future<void> _startWireGuardTunnel(String hostPublicKey, String hostEndpoint) async {
    setState(() => _statusMessage = "Connecting to Home Node...");

    final wgConfig = '''
[Interface]
PrivateKey = $_clientPrivateKey
Address = 10.200.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $hostPublicKey
Endpoint = $hostEndpoint
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''';

    try {
      if (!_wgInitialized) {
        await wireguard.initialize(interfaceName: 'wg0', vpnName: 'HomeTunnel');
        _wgInitialized = true;

        _vpnStageSubscription = wireguard.vpnStageSnapshot.listen((stage) {
          if (!mounted) return;
          setState(() {
            _statusMessage = "VPN stage: ${stage.name}";
            if (stage == VpnStage.connected) {
              _isConnecting = false;
              _isConnected = true;
              _statusMessage = "Tunnel Active via Home Node!";
            } else if (stage == VpnStage.disconnected) {
              _isConnecting = false;
              _isConnected = false;
              _statusMessage = "Disconnected";
            }
          });
        });
      }

      await wireguard.startVpn(
        serverAddress: hostEndpoint,
        wgQuickConfig: wgConfig,
        providerBundleIdentifier: 'co.ke.hometunnel.wgextension',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _statusMessage = "VPN initialization failed: $e";
      });
    }
  }

  Future<void> _disconnect() async {
    try {
      await wireguard.stopVpn();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _isConnected = false;
      _isConnecting = false;
      _statusMessage = "Disconnected";
      _codeController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HomeTunnel Client'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              _isConnected ? Icons.vpn_lock : Icons.phonelink_ring,
              size: 80,
              color: _isConnected ? Colors.greenAccent : Colors.blueAccent,
            ),
            const SizedBox(height: 24),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: _isConnected ? Colors.greenAccent : Colors.orangeAccent,
              ),
            ),
            const SizedBox(height: 32),
            if (!_isConnected) ...[
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 28, letterSpacing: 8, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  hintText: '000000',
                  counterText: "",
                  filled: true,
                  fillColor: const Color(0xFF1E1E1E),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isConnecting ? null : _connectToHost,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.blueAccent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _isConnecting
                    ? const SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Text('Connect Tunnel', style: TextStyle(fontSize: 18, color: Colors.white)),
              ),
            ] else ...[
              ElevatedButton(
                onPressed: _disconnect,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.redAccent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Disconnect Tunnel', style: TextStyle(fontSize: 18, color: Colors.white)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
