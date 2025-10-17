import 'package:flutter/material.dart';

class DashboardBody extends StatelessWidget {
  const DashboardBody({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: List.generate(6, (i) {
          return SizedBox(
            width: 320,
            height: 140,
            child: Card(
              color: cs.surfaceContainerLow,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Widget ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    const Text('내용을 채워 넣으세요'),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
