import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/firebase/merchant_sync_service.dart';
import '../services/merchant_gate.dart';
import '../services/onedrive/onedrive_auth.dart';
import '../theme.dart';
import '../widgets/primary_button.dart';

/// Merchant → Cloud sync: connect the merchant's OneDrive (device-code
/// sign-in) and file waiting orders into it as
/// "PrintingPartner/Orders of D-M-YYYY/{Category}/{no} (i of n).jpg".
class MerchantCloudScreen extends StatefulWidget {
  const MerchantCloudScreen({super.key});

  @override
  State<MerchantCloudScreen> createState() => _MerchantCloudScreenState();
}

class _MerchantCloudScreenState extends State<MerchantCloudScreen> {
  bool _connected = false;
  String? _account;
  bool _busy = false;
  String _status = '';

  // Device-code flow state
  final _clientIdController = TextEditingController();
  String? _userCode;
  String? _verificationUri;

  @override
  void initState() {
    super.initState();
    _refreshConnection();
  }

  @override
  void dispose() {
    _clientIdController.dispose();
    super.dispose();
  }

  Future<void> _refreshConnection() async {
    final connected = await OneDriveAuth.instance.isConnected;
    final account = await OneDriveAuth.instance.connectedAccount;
    if (!mounted) return;
    setState(() {
      _connected = connected;
      _account = account;
    });
  }

  Future<void> _connect() async {
    final clientId = _clientIdController.text.trim();
    if (clientId.length < 30) {
      setState(() => _status =
          'Paste the Application (client) ID from the Azure app registration.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Requesting sign-in code…';
    });
    try {
      final dc = await OneDriveAuth.instance.startDeviceCode(clientId);
      if (!mounted) return;
      setState(() {
        _userCode = dc.userCode;
        _verificationUri = dc.verificationUri;
        _status = 'Waiting for you to finish signing in…';
      });
      final err = await OneDriveAuth.instance.waitForSignIn(
        deviceCode: dc.deviceCode,
        interval: dc.interval,
        expiresIn: dc.expiresIn,
      );
      if (!mounted) return;
      setState(() {
        _userCode = null;
        _verificationUri = null;
        _status = err ?? 'OneDrive connected ✓';
      });
      await _refreshConnection();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Connection failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _status = 'Checking for orders…';
    });
    final summary = await MerchantSyncService.instance.syncNow(
      onProgress: (stage) {
        if (mounted) setState(() => _status = stage);
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = summary;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CLOUD SYNC')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // ── Connection card ──────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _connected
                              ? Icons.cloud_done_rounded
                              : Icons.cloud_off_rounded,
                          color: _connected
                              ? AppColors.success
                              : AppColors.textSecondary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _connected
                                ? 'OneDrive connected${_account != null ? '\n$_account' : ''}'
                                : 'OneDrive not connected',
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, height: 1.3),
                          ),
                        ),
                        if (_connected)
                          TextButton(
                            onPressed: () async {
                              // Unlinking the shop's storage is destructive —
                              // require the PIN before it can happen.
                              if (!await MerchantGate.verify(context,
                                  title: 'PIN to disconnect OneDrive')) {
                                return;
                              }
                              await OneDriveAuth.instance.disconnect();
                              await _refreshConnection();
                            },
                            child: const Text('Disconnect'),
                          ),
                      ],
                    ),
                    if (!_connected) ...[
                      const SizedBox(height: 12),
                      const Text(
                        'One-time setup: paste the Azure app "Application (client) ID" '
                        '(see backend/ONEDRIVE_SETUP.md, step 1), then sign in with '
                        'the Microsoft account whose OneDrive should receive orders.',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _clientIdController,
                        decoration: const InputDecoration(
                          labelText: 'Application (client) ID',
                          hintText: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
                        ),
                      ),
                      const SizedBox(height: 12),
                      PrimaryButton(
                        label: 'Connect OneDrive',
                        icon: Icons.cloud_rounded,
                        loading: _busy && _userCode == null,
                        onPressed: _busy ? null : _connect,
                      ),
                    ],
                    if (_userCode != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.lavender,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          children: [
                            const Text('On any device, open:',
                                style: TextStyle(fontSize: 12)),
                            Text(
                              _verificationUri ?? '',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 14),
                            ),
                            const SizedBox(height: 8),
                            const Text('and enter this code:',
                                style: TextStyle(fontSize: 12)),
                            const SizedBox(height: 4),
                            SelectableText(
                              _userCode!,
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 4,
                                color: AppColors.primary,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextButton.icon(
                              onPressed: () {
                                Clipboard.setData(
                                    ClipboardData(text: _userCode!));
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('Code copied')));
                              },
                              icon: const Icon(Icons.copy_rounded, size: 16),
                              label: const Text('Copy code'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Pending orders + sync ────────────────────────────────
            StreamBuilder(
              stream: MerchantSyncService.instance.pendingOrders(),
              builder: (context, snapshot) {
                final waiting = snapshot.data?.docs.length;
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          waiting == null
                              ? 'Orders waiting to be filed: …'
                              : 'Orders waiting to be filed: $waiting',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Each order lands in your OneDrive as '
                          '"PrintingPartner → Orders of D-M-YYYY → Category → '
                          'orderNo (i of n).jpg", ready to print.',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 14),
                        PrimaryButton(
                          label: 'Sync to OneDrive now',
                          icon: Icons.sync_rounded,
                          loading: _busy && _userCode == null && _connected,
                          onPressed:
                              (_busy || !_connected) ? null : _syncNow,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 14),
              Center(
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
