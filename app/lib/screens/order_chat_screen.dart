import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../services/backend_api.dart';
import '../theme.dart';

/// A friendly AI assistant that answers the customer A-to-Z about THEIR order —
/// status, what they ordered, amount, when it's ready/shipped — grounded only
/// in that order's own Firestore data. The model call goes through our own
/// backend (`BackendApi.chat`), never straight from the device. Only the
/// signed-in owner of the order (orders/{id}.uid == currentUser.uid) can chat
/// about it; anything else shows a friendly "Order not found" state.
class OrderChatScreen extends StatefulWidget {
  const OrderChatScreen({super.key, this.orderId});

  /// Firestore document id of the order. Null / empty / unknown ids render the
  /// "Order not found" state instead of crashing.
  final String? orderId;

  @override
  State<OrderChatScreen> createState() => _OrderChatScreenState();
}

class _Msg {
  _Msg(this.text, {required this.mine, this.local = false});

  final String text;

  /// True when the customer typed it.
  final bool mine;

  /// True for UI-only messages (greeting, error placeholders, and a question
  /// the assistant never answered) that must NOT be replayed to the model as
  /// conversation history. Mutable so a sent question can be demoted to local
  /// when its reply fails — otherwise the model would receive two consecutive
  /// user turns on the next question.
  bool local;
}

enum _LoadState { loading, ready, notFound, error }

class _OrderChatScreenState extends State<OrderChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _msgs = [];

  _LoadState _state = _LoadState.loading;
  String _facts = '';
  bool _sending = false;

  /// How many past messages (user + assistant) are replayed to the model.
  static const _historyLimit = 10;

  static const _suggestions = [
    'Where is my order?',
    'When will it ship?',
    'What did I order?',
  ];

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ─── Load the order (ownership-checked) ───────────────────────────────
  Future<void> _init() async {
    final id = widget.orderId?.trim() ?? '';
    if (id.isEmpty) {
      if (!mounted) return;
      setState(() => _state = _LoadState.notFound);
      return;
    }

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final snap =
          await FirebaseFirestore.instance.collection('orders').doc(id).get();
      if (!mounted) return;

      final data = snap.data();
      // Ownership: only the signed-in user who placed the order may read it.
      // A missing doc, a missing uid, or a mismatch all look the same to the
      // customer — "not found" — so we never leak that an id exists.
      if (!snap.exists ||
          data == null ||
          uid == null ||
          (data['uid'] ?? '').toString() != uid) {
        setState(() => _state = _LoadState.notFound);
        return;
      }

      _facts = _buildFacts(data);
      setState(() {
        _state = _LoadState.ready;
        _msgs.add(_Msg(
          'Hi! 👋 I can help with your order. Ask me anything about it.',
          mine: false,
          local: true,
        ));
      });
      _scrollDown();
    } on FirebaseException catch (e) {
      if (!mounted) return;
      // Rules deny reads of other people's orders → treat as not found.
      setState(() => _state = e.code == 'permission-denied'
          ? _LoadState.notFound
          : _LoadState.error);
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _LoadState.error);
    }
  }

  // ─── Facts string handed to the model ─────────────────────────────────
  String _buildFacts(Map<String, dynamic> d) {
    String s(dynamic v) => (v ?? '').toString().trim();
    Map<String, dynamic> m(dynamic v) =>
        v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    int? n(dynamic v) => v is num ? v.toInt() : int.tryParse(s(v));

    DateTime? date(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v);
      return null;
    }

    final payment = m(d['payment']);
    final upi = m(d['upiProof']);
    final delivery = m(d['delivery']);
    final addr = m(d['address']);

    final placed = date(d['placedAt']);
    final placedLabel =
        placed == null ? null : DateFormat('d MMM yyyy').format(placed.toLocal());

    final paise = n(d['totalPaise']) ?? n(payment['amountPaise']);
    final rupees = paise == null ? null : (paise / 100).toStringAsFixed(0);

    final status = s(d['status']).isEmpty ? 'received' : s(d['status']);
    final deliveryStatus =
        s(delivery['status']).isEmpty ? 'pending' : s(delivery['status']);

    // Backend (VM) filing state — the only field that says whether the shop
    // actually accepted the payment AND received the photos. Written under
    // `delivery` (the map the owner may update); older docs had it top-level.
    final backend = s(delivery['backendStatus']).isNotEmpty
        ? s(delivery['backendStatus'])
        : s(d['backendStatus']);
    final backendError = s(delivery['backendError']).isNotEmpty
        ? s(delivery['backendError'])
        : s(d['backendError']);

    // Payment: `upiProof` is written by the app BEFORE the shop's server has
    // accepted the order, so it is only a claim. The server's verdict is
    // `backendStatus`; never say "paid" unless it is 'filed' (or the shop
    // marked payment.status paid).
    final paymentStatus = s(payment['status']);
    final utr = s(upi['utr']);
    final String paymentLine;
    final String? photosLine;
    if (backend == 'rejected') {
      paymentLine =
          "Payment status: the shop's server could NOT confirm this payment"
          '${backendError.isEmpty ? '' : ' (reason: $backendError)'}; the order '
          'is ON HOLD and the photos were not received. The customer should '
          'contact the shop and must NOT pay again.';
      photosLine = null;
    } else if (backend == 'pending_upload' || backend == 'upload_failed') {
      paymentLine = upi.isNotEmpty
          ? 'Payment status: a UPI payment screenshot was attached, but the '
              'order is not complete yet (see photos)'
          : 'Payment status: not confirmed yet';
      photosLine =
          'Photos: NOT yet received by the shop — the customer should open the '
          'app, go to checkout and tap "Retry upload" to finish this order.';
    } else if (paymentStatus == 'paid' || paymentStatus == 'captured') {
      paymentLine = 'Payment status: paid';
      photosLine = null;
    } else if (backend == 'filed' && upi.isNotEmpty) {
      paymentLine =
          'Payment status: UPI payment received and the photos reached the '
          'shop; the shop reconciles it with the bank';
      photosLine = null;
    } else if (upi.isNotEmpty) {
      paymentLine = 'Payment status: UPI payment screenshot attached';
      photosLine = null;
    } else if (paymentStatus.isNotEmpty) {
      paymentLine = 'Payment status: $paymentStatus';
      photosLine = null;
    } else {
      paymentLine = 'Payment status: unknown';
      photosLine = null;
    }
    final placedAndPaid = backend == 'filed' ||
        paymentStatus == 'paid' ||
        paymentStatus == 'captured';

    final category = s(d['categoryTitle']).isNotEmpty
        ? s(d['categoryTitle'])
        : s(d['category']);
    final size = [s(d['sizeLabel']), s(d['sizeDimensions'])]
        .where((x) => x.isNotEmpty)
        .join(', ');
    final pack = s(d['productTitle']);
    final snapCount = n(d['snapCount']);
    final photoCount = n(d['photoCount']);
    final sheetsNeeded = n(d['sheetsNeeded']);
    final sheetsUploaded = n(delivery['sheetsUploaded']);

    final addressParts = [
      s(addr['line1']),
      s(addr['line2']),
      s(addr['city']),
      s(addr['state']),
      s(addr['pincode']),
    ].where((x) => x.isNotEmpty).toList();

    final lines = <String>[
      'Order number: ${s(d['orderNumber']).isEmpty ? 'not available' : s(d['orderNumber'])}',
      if (placedLabel != null) 'Order date: $placedLabel',
      if (category.isNotEmpty) 'Category: $category',
      if (size.isNotEmpty) 'Size: $size',
      if (pack.isNotEmpty)
        'Pack: $pack${snapCount != null ? ' ($snapCount prints)' : ''}',
      if (photoCount != null)
        'Photos uploaded by customer: $photoCount'
      else if (snapCount != null)
        'Photos/prints: $snapCount',
      if (rupees != null) 'Amount: ₹$rupees (INR)',
      paymentLine,
      if (photosLine != null) photosLine,
      if (utr.isNotEmpty) 'Payment reference (UTR): $utr',
      'Fulfilment status: $status',
      'Delivery status: $deliveryStatus',
      if (sheetsNeeded != null)
        'Print sheets prepared: ${sheetsUploaded ?? 0} of $sheetsNeeded',
      if (s(d['customerName']).isNotEmpty) 'Customer name: ${s(d['customerName'])}',
      if (s(d['customerPhone']).isNotEmpty)
        'Contact phone: ${s(d['customerPhone'])}',
      if (addressParts.isNotEmpty) 'Shipping address: ${addressParts.join(', ')}',
      'Typical delivery: 3–5 days across India after dispatch.',
      'Meaning of fulfilment statuses: received = '
          '${placedAndPaid ? 'order placed and paid' : 'order placed (see payment/photos status above — not yet complete)'}; '
          'printing = your photos are being printed; shipped = on the way to you; '
          'delivered = arrived. These are the ONLY statuses — never mention any other.',
    ];
    return lines.join('\n');
  }

  // ─── Chat ─────────────────────────────────────────────────────────────
  List<Map<String, String>> _history() {
    final turns = _msgs
        .where((x) => !x.local)
        .map((x) => {
              'role': x.mine ? 'user' : 'assistant',
              'text': x.text,
            })
        .toList();
    if (turns.length <= _historyLimit) return turns;
    return turns.sublist(turns.length - _historyLimit);
  }

  Future<void> _send(String text) async {
    final t = text.trim();
    if (t.isEmpty || _sending || _state != _LoadState.ready) return;

    // History is the conversation BEFORE this message.
    final history = _history();

    final question = _Msg(t, mine: true);
    setState(() {
      _msgs.add(question);
      _sending = true;
      _input.clear();
    });
    _scrollDown();

    // BackendApi.chat never throws: `ok` false carries the server's own text
    // (503 ai_unconfigured "being set up", 502, 400) or a network fallback.
    final r = await BackendApi.chat(
      facts: _facts,
      message: t,
      history: history,
    );
    if (!mounted) return;
    setState(() {
      if (!r.ok) {
        // An unanswered question must not be replayed either, or the model
        // would see two consecutive user turns on the next message.
        question.local = true;
      }
      _msgs.add(_Msg(r.reply, mine: false, local: !r.ok));
      _sending = false;
    });
    _scrollDown();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  // ─── UI ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Order help'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
      ),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    switch (_state) {
      case _LoadState.loading:
        return const Center(child: CircularProgressIndicator());
      case _LoadState.notFound:
        return _EmptyState(
          icon: Icons.receipt_long_outlined,
          title: 'Order not found',
          message:
              'We couldn\'t find this order in your account. If you placed it on another device, please use that device, or contact the shop team.',
          actionLabel: 'Go to home',
          onAction: () => context.go('/home'),
        );
      case _LoadState.error:
        return _EmptyState(
          icon: Icons.wifi_off_rounded,
          title: 'Could not load your order',
          message: 'Please check your internet connection and try again.',
          actionLabel: 'Retry',
          onAction: () {
            setState(() => _state = _LoadState.loading);
            _init();
          },
        );
      case _LoadState.ready:
        return Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(16),
                itemCount: _msgs.length + (_sending ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i >= _msgs.length) return const _Typing();
                  return _Bubble(_msgs[i]);
                },
              ),
            ),
            if (_msgs.length <= 1)
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final sug in _suggestions)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          label: Text(sug),
                          onPressed: _sending ? null : () => _send(sug),
                        ),
                      ),
                  ],
                ),
              ),
            _Composer(
              controller: _input,
              enabled: !_sending,
              onSend: () => _send(_input.text),
            ),
          ],
        );
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.msg);
  final _Msg msg;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: msg.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: msg.mine ? AppColors.primary : const Color(0xFFF1F1F3),
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(
          msg.text,
          style: TextStyle(
              fontSize: 14,
              color: msg.mine ? Colors.white : AppColors.textPrimary),
        ),
      ),
    );
  }
}

/// Three-dot "assistant is typing" indicator, shown as the last list item
/// while a reply is awaited.
class _Typing extends StatefulWidget {
  const _Typing();

  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F1F3),
          borderRadius: BorderRadius.circular(16),
        ),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                // Each dot peaks a third of a cycle after the previous one.
                final phase = (_ctrl.value - i / 3) % 1.0;
                final opacity = 0.3 + 0.7 * (1 - (phase * 2 - 1).abs());
                return Padding(
                  padding: EdgeInsets.only(right: i == 2 ? 0 : 5),
                  child: Opacity(
                    opacity: opacity.clamp(0.3, 1.0),
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: AppColors.textSecondary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer(
      {required this.controller, required this.enabled, required this.onSend});
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFECECEC))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              textInputAction: TextInputAction.send,
              onSubmitted: enabled ? (_) => onSend() : null,
              decoration: InputDecoration(
                hintText: enabled ? 'Ask about your order…' : 'Waiting for reply…',
                border: const OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: enabled ? onSend : null,
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }
}
