import 'package:flutter/material.dart';
import 'app_router.dart';
import 'theme/app_theme.dart';
import 'providers/app_providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AppProviders(
      deps: buildDeps(),
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        title: '02-15',
        theme: buildAppTheme(),
        routerConfig: router,
      ),
    );
  }
}
