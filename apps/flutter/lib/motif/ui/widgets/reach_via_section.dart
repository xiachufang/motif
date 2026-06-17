import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../platform/tailscale_support.dart';
import '../theme/motif_theme.dart';
import 'motif_form.dart';
import 'tailscale_section.dart';

class ReachViaSection extends StatelessWidget {
  final VoidCallback onAddDirect;
  final VoidCallback onPairRendezvous;
  final VoidCallback onAddSsh;

  const ReachViaSection({
    super.key,
    required this.onAddDirect,
    required this.onPairRendezvous,
    required this.onAddSsh,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return MotifSection(
      title: 'Reach Via',
      footer: 'Choose the network path Motif uses before it talks to motifd.',
      children: [
        MotifSectionRow(
          leading: Icon(Icons.public, color: c.textSecondary, size: 22),
          title: 'Direct',
          subtitle: 'Connect to a host and port you can already reach',
          onTap: onAddDirect,
          showChevron: true,
        ),
        if (tailscaleSupported) const TailscaleSection(),
        MotifSectionRow(
          leading: Icon(
            Icons.cell_tower_outlined,
            color: c.textSecondary,
            size: 22,
          ),
          title: 'Rendezvous',
          subtitle: 'Pair with a relay link or QR code',
          onTap: onPairRendezvous,
          showChevron: true,
        ),
        if (!kIsWeb)
          MotifSectionRow(
            leading: Icon(Icons.key_outlined, color: c.textSecondary, size: 22),
            title: 'SSH',
            subtitle: 'Open a tunnel with password or private key auth',
            onTap: onAddSsh,
            showChevron: true,
          ),
      ],
    );
  }
}
