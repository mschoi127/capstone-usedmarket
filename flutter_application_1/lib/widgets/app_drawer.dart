import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppDrawer extends StatelessWidget {
  final String currentPath;
  const AppDrawer({super.key, required this.currentPath});

  @override
  Widget build(BuildContext context) {
    final items = [
      ('/', Icons.search, 'Main Search'),
      ('/chatbot', Icons.chat_bubble_outline, 'Chatbot'),
      ('/market_analysis', Icons.insights_outlined, 'Market Analysis'),
      ('/dashboard', Icons.dashboard_outlined, 'Dashboard'),
    ];

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ListTile(
              leading: Icon(Icons.storefront),
              title: Text(
                'JonggoJoa',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final it = items[i];
                  final selected = currentPath == it.$1;
                  return ListTile(
                    selected: selected,
                    leading: Icon(it.$2),
                    title: Text(it.$3),
                    onTap: () {
                      context.go(it.$1);
                      Navigator.of(context).maybePop();
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
