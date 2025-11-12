import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/api_client.dart';

class ChatbotBody extends StatefulWidget {
  const ChatbotBody({super.key});

  @override
  State<ChatbotBody> createState() => _ChatbotBodyState();
}

class _ChatState {
  final String stage;
  final String? model;
  final String? storage;
  final String? condition;

  const _ChatState({
    required this.stage,
    this.model,
    this.storage,
    this.condition,
  });

  factory _ChatState.initial() =>
      const _ChatState(stage: 'awaiting_model', model: null, storage: null, condition: null);

  factory _ChatState.fromJson(Map<String, dynamic> json) => _ChatState(
        stage: (json['stage'] ?? 'awaiting_model').toString(),
        model: json['model']?.toString(),
        storage: json['storage']?.toString(),
        condition: json['condition']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'stage': stage,
        'model': model,
        'storage': storage,
        'condition': condition,
      };
}

class _ChatMessage {
  final bool fromUser;
  final String text;
  final List<_InfoEntry> infoEntries;
  final List<_ProductCardData> products;

  const _ChatMessage({
    required this.fromUser,
    required this.text,
    this.infoEntries = const [],
    this.products = const [],
  });
}

class _InfoEntry {
  final String label;
  final String value;

  const _InfoEntry(this.label, this.value);

  factory _InfoEntry.fromJson(Map<String, dynamic> json) =>
      _InfoEntry(json['label']?.toString() ?? '-', json['value']?.toString() ?? '-');
}

class _ProductCardData {
  final String title;
  final String subtitle;
  final String price;
  final String url;
  final String? imageUrl;

  const _ProductCardData({
    required this.title,
    required this.subtitle,
    required this.price,
    required this.url,
    this.imageUrl,
  });

  factory _ProductCardData.fromJson(Map<String, dynamic> json) => _ProductCardData(
        title: (json['title'] ?? '제목 없음').toString(),
        subtitle: (json['subtitle'] ?? '').toString(),
        price: (json['price'] ?? '').toString(),
        url: (json['url'] ?? '').toString(),
        imageUrl: json['image_url']?.toString(),
      );
}

class _ChatbotBodyState extends State<ChatbotBody> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<_ChatMessage> _messages = [];

  late final ApiClient _api;
  _ChatState _state = _ChatState.initial();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _api = ApiClient();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _appendBotMessage(
        '안녕하세요! 중고폰 시세가 궁금하신가요? 모델명을 말씀해 주시면 빠르게 현재 시세를 알려드릴게요.',
      );
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _appendBotMessage(
    String text, {
    List<_InfoEntry> info = const [],
    List<_ProductCardData> products = const [],
  }) {
    setState(() {
      _messages.add(
        _ChatMessage(
          fromUser: false,
          text: text,
          infoEntries: info,
          products: products,
        ),
      );
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _sendMessage() async {
    if (_sending) return;
    final input = _ctrl.text.trim();
    if (input.isEmpty) return;
    _ctrl.clear();

    setState(() {
      _messages.add(_ChatMessage(fromUser: true, text: input));
      _sending = true;
    });
    _scrollToBottom();

    try {
      final response = await _api.post<Map<String, dynamic>>(
        '/chatbot/message',
        data: {
          'message': input,
          'state': _state.toJson(),
        },
      );
      final raw = response.data ?? const {};
      final replyJson = (raw['reply'] ?? const {}) as Map<String, dynamic>;
      final stateJson = (raw['state'] ?? const {}) as Map<String, dynamic>;

      final infoEntries = (replyJson['infoEntries'] as List?)
              ?.map((e) => _InfoEntry.fromJson((e as Map).cast()))
              .toList() ??
          const <_InfoEntry>[];
      final products = (replyJson['products'] as List?)
              ?.map((e) => _ProductCardData.fromJson((e as Map).cast()))
              .toList() ??
          const <_ProductCardData>[];
      final replyText = (replyJson['text'] ?? '요청을 처리했습니다.').toString();

      setState(() {
        _state = _ChatState.fromJson(stateJson);
        _messages.add(
          _ChatMessage(
            fromUser: false,
            text: replyText,
            infoEntries: infoEntries,
            products: products,
          ),
        );
      });
    } catch (err) {
      setState(() {
        _messages.add(
          const _ChatMessage(
            fromUser: false,
            text: '서버와 통신하는 중 문제가 발생했습니다. 잠시 후 다시 시도해 주세요.',
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToBottom();
      }
    }
  }

  Future<void> _openUrl(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _stateChips(ColorScheme cs) {
    final chips = <String>[];
    if (_state.model != null) chips.add('모델 ${_humanize(_state.model!)}');
    if (_state.storage != null) chips.add('용량 ${_state.storage}');
    if (_state.condition != null) chips.add('상태 ${_state.condition!.toUpperCase()}급');
    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: chips
            .map(
              (text) => Chip(
                label: Text(text),
                backgroundColor: cs.surfaceContainerHighest.withOpacity(.6),
              ),
            )
            .toList(),
      ),
    );
  }

  String _humanize(String canonical) => canonical
      .split('_')
      .map((part) => part.isEmpty ? part : part[0].toUpperCase() + part.substring(1))
      .join(' ');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 12),
            _stateChips(cs),
            if (_sending) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withOpacity(.35),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ListView.separated(
                  controller: _scroll,
                  itemCount: _messages.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, index) => _MessageBubble(
                    message: _messages[index],
                    onTapLink: _openUrl,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      onSubmitted: (_) => _sendMessage(),
                      enabled: !_sending,
                      decoration: InputDecoration(
                        hintText: '메시지를 입력하세요',
                        filled: true,
                        fillColor: cs.surfaceContainerHighest.withOpacity(.6),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send),
                    label: const Text('보내기'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final _ChatMessage message;
  final Future<void> Function(String url) onTapLink;

  const _MessageBubble({
    required this.message,
    required this.onTapLink,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final alignment =
        message.fromUser ? Alignment.centerRight : Alignment.centerLeft;

    final bubbleColor = message.fromUser
        ? cs.primary
        : cs.surfaceContainerHighest.withOpacity(.65);
    final textColor = message.fromUser ? cs.onPrimary : cs.onSurfaceVariant;

    return Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 60, maxWidth: 360),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message.text,
                style: TextStyle(color: textColor, height: 1.4),
              ),
              if (message.infoEntries.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _InfoCard(entries: message.infoEntries),
                ),
              if (message.products.isNotEmpty)
                ...message.products.map(
                  (product) => Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _ProductCard(
                      data: product,
                      onTap: () => onTapLink(product.url),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final List<_InfoEntry> entries;

  const _InfoCard({required this.entries});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: entries
            .map(
              (entry) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        entry.label,
                        style: TextStyle(
                          color: cs.onSecondaryContainer.withOpacity(.75),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      entry.value,
                      style: TextStyle(
                        color: cs.onSecondaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  final _ProductCardData data;
  final VoidCallback onTap;

  const _ProductCard({
    required this.data,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return Material(
      color: cs.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: data.imageUrl == null || data.imageUrl!.isEmpty
                    ? Container(
                        width: 84,
                        height: 84,
                        color: cs.surfaceContainerHighest.withOpacity(.6),
                        child: Icon(
                          Icons.image_not_supported_outlined,
                          color: cs.onSurfaceVariant.withOpacity(.6),
                        ),
                      )
                    : Image.network(
                        data.imageUrl!,
                        width: 84,
                        height: 84,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 84,
                          height: 84,
                          color: cs.surfaceContainerHighest.withOpacity(.6),
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: cs.onSurfaceVariant.withOpacity(.6),
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (data.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        data.subtitle,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      data.price,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.open_in_new, size: 20, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
