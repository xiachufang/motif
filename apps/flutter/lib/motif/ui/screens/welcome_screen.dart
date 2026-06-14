import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../platform/tailscale_support.dart';
import '../../state/app_state.dart';
import '../../state/connection_state.dart';
import '../theme/motif_theme.dart';
import '../widgets/motif_form.dart';
import '../widgets/tailscale_section.dart';
import 'rzv_pairing_sheet.dart';
import 'server_edit_sheet.dart';

/// First-run screen, shown when no server is configured.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  Future<void> _connectServer(BuildContext context) async {
    final app = context.read<AppState>();
    final result = await showServerEditSheet(context, connectOnSave: true);
    if (result == null || !result.connectAfterSave) return;
    await app.connectServerAndRefresh(result.server.id, force: true);
    if (tailscaleSupported &&
        context.mounted &&
        app.serverViewState(result.server.id).primaryAction ==
            ServerConnectionAction.openTailscale) {
      showTailscaleConnectionSheet(context);
    }
  }

  Future<void> _pairServer(BuildContext context) async {
    final app = context.read<AppState>();
    final id = await showRzvPairingSheet(context);
    if (id == null || !context.mounted) return;
    await app.connectServerAndRefresh(id, force: true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    // Rebuild when a server gets added so we transition into the app.
    context.watch<AppState>();
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
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: MotifSpacing.sm),
                      Text(
                        'Add a motifd server to start. The app will connect '
                        'and load its sessions for you.',
                        style: TextStyle(color: c.textSecondary, fontSize: 15),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (tailscaleSupported) ...[
              const SizedBox(height: MotifSpacing.xl),
              const MotifSection(
                title: 'Tailscale',
                footer:
                    'motifd is reached over the tailnet. Connect first to discover servers automatically.',
                children: [TailscaleSection()],
              ),
            ],
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
                  leading: Icon(Icons.add_circle, color: c.accent, size: 22),
                  title: 'Connect a Server',
                  titleColor: c.accent,
                  titleWeight: FontWeight.w700,
                  onTap: () => unawaited(_connectServer(context)),
                ),
                MotifSectionRow(
                  leading: Icon(Icons.qr_code_2, color: c.accent, size: 22),
                  title: 'Scan or paste a pairing link',
                  titleColor: c.accent,
                  titleWeight: FontWeight.w700,
                  onTap: () => unawaited(_pairServer(context)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
