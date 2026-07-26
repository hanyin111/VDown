import 'package:flutter/material.dart';

import 'pages/download_page.dart';
import 'pages/settings_page.dart';
import 'pages/tasks_page.dart';

/// 自适应导航壳：宽屏用 NavigationRail，窄屏（移动端）用底部 NavigationBar。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _destinations = [
    (icon: Icons.download_rounded, label: '下载'),
    (icon: Icons.list_alt_rounded, label: '任务'),
    (icon: Icons.settings_rounded, label: '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final pages = [
      DownloadPage(onGoToTasks: () => setState(() => _index = 1)),
      const TasksPage(),
      const SettingsPage(),
    ];

    return LayoutBuilder(builder: (context, constraints) {
      final useRail = constraints.maxWidth >= 640;
      final body = IndexedStack(index: _index, children: pages);

      if (useRail) {
        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                labelType: NavigationRailLabelType.all,
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    size: 36,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                destinations: [
                  for (final d in _destinations)
                    NavigationRailDestination(
                      icon: Icon(d.icon),
                      label: Text(d.label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ],
          ),
        );
      }

      return Scaffold(
        body: SafeArea(child: body),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            for (final d in _destinations)
              NavigationDestination(icon: Icon(d.icon), label: d.label),
          ],
        ),
      );
    });
  }
}
