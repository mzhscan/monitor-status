// Lightweight Android-style toast built on OverlayEntry.
//
// Why not SnackBar:
//   - SnackBar slides up from the bottom of a Scaffold and pushes the FAB
//     up. For a pure hint that should NOT take any layout space, SnackBar
//     is the wrong primitive.
//   - We want something that floats over any screen (detail page, dialogs
//     in the future) without anchoring to a Scaffold.
//
// Usage:
//   AppToast.show(context, '已保存');

import 'package:flutter/material.dart';

class AppToast {
  /// Show a transient toast at the bottom-center of the screen.
  /// Auto-dismisses after [duration] (default 1.5s) with a 250ms fade
  /// in/out. Stacks over any widget; no layout impact.
  static void show(
    BuildContext context,
    String message, {
    Duration? duration,
  }) {
    // Use the root overlay so the toast floats over every route.
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return; // no overlay → silently drop (e.g. during teardown)
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _ToastWidget(
        message: message,
        duration: duration ?? const Duration(milliseconds: 1500),
        onDismiss: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }
}

class _ToastWidget extends StatefulWidget {
  final String message;
  final Duration duration;
  final VoidCallback onDismiss;
  const _ToastWidget({
    required this.message,
    required this.duration,
    required this.onDismiss,
  });

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _run();
  }

  Future<void> _run() async {
    await _ctrl.forward();
    if (!mounted) return;
    await Future.delayed(widget.duration);
    if (!mounted) return;
    await _ctrl.reverse();
    if (mounted) widget.onDismiss();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Positioned(
      left: 0,
      right: 0,
      // 60px above the bottom safe area — looks like Android's native Toast
      // (which is at the bottom with some margin).
      bottom: mq.padding.bottom + 60,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _opacity,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xCC000000),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
