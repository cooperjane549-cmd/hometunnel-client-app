import 'dart:async';
import 'dart:convert';
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
    _generateRealKeyPair();
  }

  @override
  void dispose() {
    _vpnStageSubscription?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _generateRealKeyPair() async {
    try {
      // Use native WireGuard key generator to guarantee raw 32-byte keys
      final keyPair = await wireguard.generateKeyPair();
      
      if (!mounted) return;
      setState(() {
        _clientPrivateKey = keyPair.privateKey;
        _clientPublicKey = keyPair.publicKey;
        _keysReady = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = "Key generation failed: $e";
      });
    }
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
