import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme.dart';

/// A friendly AI assistant that answers the customer A-to-Z about THEIR order —
/// status, what they ordered, amount, when it's ready/shipped — grounded only
/// in that order's own Firestore data. Powered by Gemini (Firebase AI Logic,
/// free on Spark). For questions it can't answer it points them to the shop.
class OrderChatScreen extends StatefulWidget {
  const OrderChatScreen({super.key, required this.orderId});
  final String orderId;

  @override
  State<OrderChatScreen> createState() => _OrderChatScreenState();
}

class _Msg {
  final String text;
  final bool mine;
  _Msg(this.text, this.mine);
}

class _OrderChatScreenState extends State<OrderChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _msgs = [];
  ChatSession? _chat;
  bool _loading = true;
  bool _sending = false;
  String? _loadError;

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

  Future<void> _init() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('orders')
          .doc(widget.orderId)
          .get();
      final facts = _facts(snap.data() ?? {});
      final model = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-2.5-flash',
        systemInstruction: Content.system('''
You are "Printing Partner" — a warm, concise order-support assistant for a photo-printing shop.
Answer ONLY from the order facts below. Keep replies to 1–3 short sentences, friendly, in simple English.
If something is not in the facts (refunds, changing the order, a complaint, anything you're unsure of),
say you'll pass it to the shop team and suggest they'll reply soon. Never invent dates, prices or tracking numbers.

ORDER FACTS:
$facts
'''),
      );
      _chat = model.startChat();
      setState(() {
        _loading = false;
        _msgs.add(_Msg(
            'Hi! 👋 I can help with your order. Ask me anything about it.',
            false));
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _loadError =
            'Could not load your order right now. Please check your internet.';
      });
    }
  }

  String _facts(Map<String, dynamic> d) {
    String s(dynamic v) => (v ?? '').toString();
    final status = s(d['status']).isEmpty ? 'received' : s(d['status']);
    final delivery = (d['delivery'] as Map?) ?? {};
    final upi = (d['upiProof'] as Map?) ?? {};
    final addr = (d['address'] as Map?) ?? {};
    final paise = (d['totalPaise'] as num?)?.toInt();
    final rupees = paise == null ? null : (paise / 100).toStringAsFixed(0);
    final placed = (d['placedAt'] is Timestamp)
        ? (d['placedAt'] as Timestamp).toDate()
        : null;

    final lines = <String>[
      'Order number: ${s(d['orderNumber'])}',
      'Product: ${s(d['productTitle'])} (${s(d['sizeLabel'])}, ${s(d['sizeDimensions'])})',
      'Photos/prints: ${s(d['snapCount'])}',
      if (rupees != null) 'Amount: ₹$rupees (paid by UPI)',
      if (upi['utr'] != null && s(upi['utr']).isNotEmpty)
        'Payment reference (UTR): ${s(upi['utr'])}',
      'Current status: $status',
      'Print sheets prepared: ${s(delivery['sheetsUploaded'])} of ${s(d['sheetsNeeded'])}',
      'Delivery status: ${s(delivery['status']).isEmpty ? 'pending' : s(delivery['status'])}',
      if (placed != null)
        'Placed on: ${placed.day}-${placed.month}-${placed.year}',
      if (addr.isNotEmpty)
        'Shipping to: ${s(addr['city'])}, ${s(addr['state'])} ${s(addr['pincode'])}',
      'Typical delivery: 3–5 days across India after dispatch.',
      'Meaning of statuses: received = order placed; getting_ready/processing = being printed; dispatched/shipped = on the way; delivered = arrived.',
    ];
    return lines.join('\n');
  }

  Future<void> _send(String text) async {
    final t = text.trim();
    if (t.isEmpty || _sending || _chat == null) return;
    setState(() {
      _msgs.add(_Msg(t, true));
      _sending = true;
      _input.clear();
    });
    _scrollDown();
    try {
      final resp = await _chat!.sendMessage(Content.text(t));
      final reply = (resp.text ?? '').trim();
      setState(() {
        _msgs.add(_Msg(
            reply.isEmpty
                ? 'Sorry, I didn\'t catch that. Could you rephrase?'
                : reply,
            false));
        _sending = false;
      });
    } catch (e) {
      setState(() {
        _msgs.add(_Msg(
            'I\'m having trouble answering right now. Please try again, or the shop team will help you.',
            false));
        _sending = false;
      });
    }
    _scrollDown();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Order help'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_loadError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: AppColors.textSecondary)),
                    ),
                  )
                : Column(
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
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            children: [
                              for (final sug in _suggestions)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ActionChip(
                                    label: Text(sug),
                                    onPressed:
                                        _sending ? null : () => _send(sug),
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
        child: Text(
          msg.text,
          style: TextStyle(
              fontSize: 14,
              color: msg.mine ? Colors.white : AppColors.textPrimary),
        ),
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing();
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F1F3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const SizedBox(
        width: 34,
        child: Text('…', style: TextStyle(fontSize: 18)),
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
              onSubmitted: (_) => onSend(),
              decoration: const InputDecoration(
                hintText: 'Ask about your order…',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
