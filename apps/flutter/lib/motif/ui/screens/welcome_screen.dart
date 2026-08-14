import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../models/settings.dart';
import '../../state/app/app_state.dart';
import '../../state/connection/connection_state.dart';
import '../../state/app/motif_scope.dart';
import '../theme/motif_theme.dart';
import '../widgets/motif_form.dart';
import '../widgets/tailscale_section.dart';
import 'add_server_flow.dart';
import 'server_edit_sheet.dart';

part 'welcome_screen.g.dart';

/// First-run screen, shown when no server is configured.
@ObservationWidget()
class WelcomeScreen extends _$WelcomeScreen {
  const WelcomeScreen({super.key});

  Future<void> _connectServer(BuildContext context) async {
    final app = readObservationScope<AppState>(context);
    final result = await showAddServerFlow(context, connectOnSave: true);
    if (result == null || !result.connectAfterSave) return;
    await app.connectServerAndRefresh(result.server.id, force: true);
    if (context.mounted &&
        app.serverViewState(result.server.id).primaryAction ==
            ServerConnectionAction.setupTransport) {
      _setupTransport(context, result.server);
    }
  }

  void _setupTransport(BuildContext context, MotifServer server) {
    switch (server.kind) {
      case ServerKind.tailscale:
        showTailscaleConnectionSheet(context);
        return;
      case ServerKind.ssh:
      case ServerKind.wsl:
        unawaited(showServerEditSheet(context, existing: server));
        return;
      case ServerKind.rendezvous:
        unawaited(showServerEditSheet(context, existing: server));
        return;
      case ServerKind.direct:
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Scaffold(
      appBar: AppBar(title: const Text('motif'), centerTitle: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            MotifSpacing.lg,
            MotifSpacing.md,
            MotifSpacing.lg,
            MotifSpacing.xl,
          ),
          children: [
            MotifSection(
              dividerIndent: MotifSpacing.lg,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MotifSpacing.md,
                    vertical: MotifSpacing.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Welcome to motif',
                        style: MotifType.display.copyWith(color: c.textPrimary),
                      ),
                      const SizedBox(height: MotifSpacing.sm),
                      Text(
                        'Add a motifd server to start. The app will connect '
                        'and load its sessions for you.',
                        style: MotifType.body.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: MotifSpacing.xl),
            MotifSection(
              title: 'Servers',
              children: [
                MotifSectionRow(
                  title: 'No servers yet.',
                  titleColor: c.textSecondary,
                  titleWeight: FontWeight.w400,
                ),
                MotifSectionRow(
                  leading: Icon(
                    Icons.add_circle,
                    color: c.accent,
                    size: MotifIconSize.md,
                  ),
                  title: 'Add Server',
                  titleColor: c.accent,
                  titleWeight: FontWeight.w700,
                  onTap: () => unawaited(_connectServer(context)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
