import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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
  State<ClientHomePage> meCreateState() => _ClientHomePageState();
}

class _ClientHomePageState extends State<ClientHomePage> {
  final TextEditingController _codeController = TextEditingController();
  final String _backendUrl = "https://hometunnel-backend-render.onrender.com";
  
  bool _isConnecting = false;
  bool _isConnected = false;
  String _statusMessage = "Disconnected";

  Future<void> _connectToHost() async {
    final code = _codeController.text.trim();
    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter a valid 6-digit code")),
      );
      return;
    }

    setState(() {
      _isConnecting = true;
      _statusMessage = "Pairing with Host ($code)...";
    });

    try {
      final response = await http.post(
        Uri.parse("$_backendUrl/pair"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"code": code, "role": "client"}),
      );

      if (response.statusCode == 200) {
        setState(() {
          _isConnecting = false;
          _isConnected = true;
          _statusMessage = "Tunnel Active via Home Node!";
        });
      } else {
        setState(() {
          _isConnecting = false;
          _statusMessage = "Pairing failed. Check code.";
        });
      }
    } catch (e) {
      setState(() {
        _isConnecting = false;
        _statusMessage = "Error connecting to signaling server.";
      });
    }
  }

  void _disconnect() {
    setState(() {
      _isConnected = false;
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
                    ? const CircularProgressIndicator(color: Colors.white)
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
