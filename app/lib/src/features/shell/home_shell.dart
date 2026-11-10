import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'pillpal_navigation_bar.dart';

/// Scaffold with the bottom navigation between the four main tabs.
class HomeShell extends StatelessWidget {
  /// Creates the shell around [navigationShell].
  const HomeShell({required this.navigationShell, super.key});

  /// The tab navigator provided by go_router.
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: PillPalNavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onSelected: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
      ),
    );
  }
}
