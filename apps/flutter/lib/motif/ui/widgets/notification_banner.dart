import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../models/motif_proto.dart';
import '../../state/app/app_state.dart';
import '../../state/workspace/workspace_view_model.dart';
import '../theme/motif_theme.dart';

part 'notification_banner.g.dart';

final class NotificationBannerCoordinator {
  Timer? _dismiss;
  MotifNotification? _scheduledNotification;

  void sync(
    AppState app,
    ({WorkspaceKey key, MotifNotification notification})? current,
  ) {
    final notification = current?.notification;
    if (identical(_scheduledNotification, notification)) return;
    _scheduledNotification = notification;
    _dismiss?.cancel();
    if (current != null) {
      _dismiss = Timer(
        const Duration(seconds: 4),
        () => app.consumeNotification(current.key),
      );
    }
  }

  void cancel() => _dismiss?.cancel();

  void dispose() => cancel();
}

/// Top-anchored in-app banner for server `notification` events (mirrors the iOS
/// LiveNotificationBanner). Auto-dismisses after a few seconds; tap opens the
/// named session when present, otherwise dismisses.
@ObservationWidget()
class NotificationBannerHost extends _$NotificationBannerHost {
  final AppState app;
  final Widget child;
  const NotificationBannerHost({
    super.key,
    required this.app,
    required this.child,
  });

  @PlainState()
  NotificationBannerCoordinator createCoordinator() =>
      NotificationBannerCoordinator();

  @override
  bool shouldRecreateStates(covariant NotificationBannerHost oldWidget) =>
      !identical(oldWidget.app, app);

  void _onTap(
    NotificationBannerCoordinator coordinator,
    WorkspaceKey key,
    MotifNotification notification,
  ) {
    coordinator.cancel();
    final sessionId = notification.sessionId?.trim();
    app.consumeNotification(key);
    if (sessionId != null && sessionId.isNotEmpty) {
      app.requestOpenSession(
        serverId: key.serverId,
        session: sessionId,
        viewId: notification.viewId,
      );
    }
  }

  @override
  Widget build(
    BuildContext context, {
    required NotificationBannerCoordinator coordinator,
  }) {
    final current = app.currentNotification;
    coordinator.sync(app, current);
    final n = current?.notification;
    final c = context.motif;
    return Stack(
      children: [
        child,
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
                      _onTap(coordinator, current.key, current.notification),
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
