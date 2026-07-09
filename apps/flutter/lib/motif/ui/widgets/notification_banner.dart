import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/motif_proto.dart';
import '../../state/app_state.dart';
import '../../state/motif_client.dart';
import '../theme/motif_theme.dart';

/// Top-anchored in-app banner for server `notification` events (mirrors the iOS
/// LiveNotificationBanner). Auto-dismisses after a few seconds; tap opens the
/// named session when present, otherwise dismisses.
class NotificationBannerHost extends StatefulWidget {
  final AppState app;
  final Widget child;
  const NotificationBannerHost({
    super.key,
    required this.app,
    required this.child,
  });

  @override
  State<NotificationBannerHost> createState() => _NotificationBannerHostState();
}

class _NotificationBannerHostState extends State<NotificationBannerHost> {
  Timer? _dismiss;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_onChange);
  }

  @override
  void didUpdateWidget(covariant NotificationBannerHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_onChange);
      widget.app.addListener(_onChange);
    }
  }

  void _onChange() {
    if (_currentNotification != null) {
      _dismiss?.cancel();
      _dismiss = Timer(const Duration(seconds: 4), () {
        _currentNotification?.client.consumeNotification();
      });
    }
    if (mounted) setState(() {});
  }

  ({MotifClient client, MotifNotification notification, String serverId})?
  get _currentNotification {
    for (final group in widget.app.knownServerClients) {
      final notification = group.client.latestNotification;
      if (notification != null) {
        return (
          client: group.client,
          notification: notification,
          serverId: group.server.id,
        );
      }
    }
    return null;
  }

  void _onTap(
    MotifClient client,
    MotifNotification notification,
    String serverId,
  ) {
    _dismiss?.cancel();
    final sessionId = notification.sessionId?.trim();
    client.consumeNotification();
    if (sessionId != null && sessionId.isNotEmpty) {
      widget.app.requestOpenSession(serverId: serverId, session: sessionId);
    }
  }

  @override
  void dispose() {
    _dismiss?.cancel();
    widget.app.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentNotification;
    final n = current?.notification;
    final c = context.motif;
    return Stack(
      children: [
        widget.child,
        if (n != null && current != null)
          Positioned(
            top: MediaQuery.of(context).padding.top + MotifSpacing.sm,
            left: MotifSpacing.md,
            right: MotifSpacing.md,
            child: SafeArea(
              bottom: false,
              child: Material(
                color: Colors.transparent,
                child: GestureDetector(
                  onTap: () =>
                      _onTap(current.client, current.notification, current.serverId),
                  child: Container(
                    padding: const EdgeInsets.all(MotifSpacing.md),
                    decoration: BoxDecoration(
                      color: c.surfaceElevated,
                      borderRadius: BorderRadius.circular(MotifRadius.md),
                      border: Border.all(color: c.border),
                      boxShadow: MotifElevation.overlay(c.shadow),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.notifications, color: c.accent, size: 20),
                        const SizedBox(width: MotifSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                n.title,
                                style: MotifType.headline.copyWith(
                                  color: c.textPrimary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (n.body.isNotEmpty)
                                Text(
                                  n.body,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: MotifType.subhead.copyWith(
                                    color: c.textSecondary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
