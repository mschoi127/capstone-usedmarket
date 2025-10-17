import 'package:flutter/material.dart';
import '../data/product_repository.dart';
import '../data/api_client.dart';

class AppDeps {
  final ProductRepository products;
  AppDeps({required this.products});
}

class AppProviders extends InheritedWidget {
  final AppDeps deps;
  const AppProviders({super.key, required this.deps, required super.child});

  static AppDeps of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<AppProviders>();
    assert(w != null, 'AppProviders not found in context');
    return w!.deps;
  }

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) => false;
}

AppDeps buildDeps() {
  final client = ApiClient();
  final repo = ProductRepository(client);
  return AppDeps(products: repo);
}
