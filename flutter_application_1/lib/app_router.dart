// lib/app_router.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'pages/main_search_page.dart';
import 'pages/chatbot_page.dart';
import 'pages/market_analysis_page.dart';
import 'pages/dashboard_page.dart';

class MainShell extends StatelessWidget {
  const MainShell({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final uri = GoRouterState.of(context).uri.toString();
    final tabs = <({String path, IconData icon, String label, String title})>[
      (
        path: '/chat',
        icon: Icons.chat_bubble_outline,
        label: 'Chat',
        title: 'Chatbot'
      ),
      (path: '/', icon: Icons.search, label: 'Search', title: 'Search'),
      (
        path: '/analysis',
        icon: Icons.insights,
        label: 'Analysis',
        title: 'Analysis'
      ),
    ];

    int idx =
        tabs.indexWhere((t) => uri == t.path || uri.startsWith('${t.path}/'));
    if (idx < 0) idx = 0;

    return Scaffold(
      appBar: AppBar(title: Text(tabs[idx].title)),
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: idx,
        onDestinationSelected: (i) => GoRouter.of(context).go(tabs[i].path),
        destinations: [
          for (final t in tabs)
            NavigationDestination(icon: Icon(t.icon), label: t.label)
        ],
      ),
    );
  }
}

final router = GoRouter(
  initialLocation: '/chat',
  routes: [
    ShellRoute(
      builder: (context, state, child) => MainShell(child: child),
      routes: [
        GoRoute(path: '/', builder: (context, state) => const MainSearchPage()),
        GoRoute(
            path: '/chat', builder: (context, state) => const ChatbotBody()),
        GoRoute(
            path: '/analysis',
            builder: (context, state) => const AnalysisPage()),
        GoRoute(
            path: '/dash', builder: (context, state) => const DashboardBody()),
      ],
    ),
  ],
);
