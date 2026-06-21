// ignore_for_file: invalid_use_of_protected_member

part of '../session_screen.dart';

extension _SessionScreenTerminalActions on _SessionScreenState {
  bool _handleShortcut(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    if (ModalRoute.of(context)?.isCurrent != true || _switchingSession) {
      return false;
    }

    final hw = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final primaryPressed = _usesCommandShortcuts
        ? hw.isMetaPressed
        : hw.isControlPressed;

    if (primaryPressed && hw.isShiftPressed && !hw.isAltPressed) {
      if (key == LogicalKeyboardKey.keyW) {
        unawaited(_closeSession(_motif));
        return true;
      }
      if (key == LogicalKeyboardKey.keyL) {
        _toggleSessionsPanel(context.read<AppState>());
        return true;
      }
      if (key == LogicalKeyboardKey.keyE) {
        _toggleFileTree(_motif);
        return true;
      }
      if (key == LogicalKeyboardKey.keyG) {
        _toggleGitDiff(_motif);
        return true;
      }
    }

    if (primaryPressed && !hw.isShiftPressed && !hw.isAltPressed) {
      final tabIndex = _chromeTabIndexForKey(key);
      if (tabIndex != null) {
        _activateTabAtChromeIndex(tabIndex);
        return true;
      }
      if (key == LogicalKeyboardKey.keyT) {
        unawaited(_newPty());
        return true;
      }
      if (key == LogicalKeyboardKey.keyW) {
        // Close the active tab; on the last tab, hide the window instead so the
        // close-window shortcut works in the session view too.
        if (_motif.views.length <= 1) {
          unawaited(DesktopWindow.hide());
        } else {
          unawaited(_closeActiveTab());
        }
        return true;
      }
      if (key == LogicalKeyboardKey.pageUp) {
        _activateRelativeTab(-1);
        return true;
      }
      if (key == LogicalKeyboardKey.pageDown) {
        _activateRelativeTab(1);
        return true;
      }
    }

    if (hw.isControlPressed &&
        !hw.isMetaPressed &&
        !hw.isAltPressed &&
        key == LogicalKeyboardKey.tab) {
      _activateRelativeTab(hw.isShiftPressed ? -1 : 1);
      return true;
    }

    if (_usesCommandShortcuts &&
        hw.isMetaPressed &&
        hw.isAltPressed &&
        !hw.isControlPressed &&
        !hw.isShiftPressed) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _activateRelativeTab(-1);
        return true;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _activateRelativeTab(1);
        return true;
      }
    }

    return false;
  }

  int? _chromeTabIndexForKey(LogicalKeyboardKey key) {
    return switch (key) {
      LogicalKeyboardKey.digit1 || LogicalKeyboardKey.numpad1 => 1,
      LogicalKeyboardKey.digit2 || LogicalKeyboardKey.numpad2 => 2,
      LogicalKeyboardKey.digit3 || LogicalKeyboardKey.numpad3 => 3,
      LogicalKeyboardKey.digit4 || LogicalKeyboardKey.numpad4 => 4,
      LogicalKeyboardKey.digit5 || LogicalKeyboardKey.numpad5 => 5,
      LogicalKeyboardKey.digit6 || LogicalKeyboardKey.numpad6 => 6,
      LogicalKeyboardKey.digit7 || LogicalKeyboardKey.numpad7 => 7,
      LogicalKeyboardKey.digit8 || LogicalKeyboardKey.numpad8 => 8,
      LogicalKeyboardKey.digit9 || LogicalKeyboardKey.numpad9 => 9,
      _ => null,
    };
  }

  void _activateTabAtChromeIndex(int chromeIndex) {
    final views = _motif.views;
    if (views.isEmpty) return;
    final index = chromeIndex == 9
        ? views.length - 1
        : (chromeIndex - 1).clamp(0, views.length - 1).toInt();
    _activateView(views[index].id);
  }

  void _activateRelativeTab(int delta) {
    final motif = _motif;
    final views = motif.views;
    if (views.isEmpty) return;
    final current = views.indexWhere((v) => v.id == motif.activeViewId);
    final base = current < 0 ? 0 : current;
    final next = (base + delta) % views.length;
    _activateView(views[next < 0 ? next + views.length : next].id);
  }

  void _activateView(String viewId) {
    final motif = _motif;
    if (motif.isLive) {
      unawaited(motif.activateView(viewId));
    } else {
      motif.selectViewLocally(viewId);
    }
    _focusTerminalAfterTabSwitch();
  }

  Future<void> _closeActiveTab() async {
    final motif = _motif;
    final activeViewId = motif.activeViewId;
    final view = activeViewId == null
        ? motif.views.firstOrNull
        : motif.views.where((v) => v.id == activeViewId).firstOrNull;
    if (view == null) return;
    await _closeViewWithConfirmation(context, motif, view);
    _focusTerminalAfterTabSwitch();
  }

  void _toggleSessionsPanel(AppState app) {
    if (!_usesSidebarLayout) {
      unawaited(_showSessionMenuAtOverlay(app, _motif));
      return;
    }
    final sidebar = app.sessionSidebar;
    setState(() => sidebar.showSessions = !sidebar.showSessions);
    if (sidebar.showSessions) {
      unawaited(app.refreshConnectedSessions().catchError((_) => null));
    }
  }

  void _toggleFileTree(MotifClient motif) {
    if (!_usesSidebarLayout) {
      _openFileTree(motif);
      return;
    }
    final sidebar = context.read<AppState>().sessionSidebar;
    setState(() => sidebar.showFileTree = !sidebar.showFileTree);
  }

  void _toggleGitDiff(MotifClient motif) {
    if (!_usesSidebarLayout) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GitDiffPanel(cwd: motif.activeCwd, motif: motif),
        ),
      );
      return;
    }
    final sidebar = context.read<AppState>().sessionSidebar;
    setState(() => sidebar.showGitDiff = !sidebar.showGitDiff);
  }

  void _focusTerminal() {
    if (!mounted) return;
    setState(() => _terminalFocusSerial++);
  }

  void _focusTerminalAfterTabSwitch() {
    if (!terminalAutofocusesOnTabSwitchByDefault()) return;
    _focusTerminal();
  }

  Future<void> _sendBytes(List<int> bytes) async {
    if (!_motif.canInput) return;
    final ptyId = _activePtyId(_motif);
    if (ptyId == null || bytes.isEmpty) return;
    _focusTerminal();
    await _motif.activatePtyStream(ptyId);
    await _motif.writePty(ptyId, bytes);
  }

  void _insertText(String text) {
    final sel = _input.selection;
    final base = _input.text;
    if (sel.isValid) {
      _input.text = base.replaceRange(sel.start, sel.end, text);
    } else {
      _input.text = base + text;
    }
  }

  String? _activePtyId(MotifClient motif) {
    final vid = motif.activeViewId;
    for (final v in motif.views) {
      if (v.id == vid && v.spec is PtyViewSpec) {
        return (v.spec as PtyViewSpec).ptyId;
      }
    }
    // If a non-PTY view is active, route explicit terminal actions to the first PTY.
    for (final v in motif.views) {
      if (v.spec is PtyViewSpec) return (v.spec as PtyViewSpec).ptyId;
    }
    return motif.ptys.isEmpty ? null : motif.ptys.first.id;
  }

  Future<void> _send() async {
    // Keep the typed text in the input box while disconnected.
    if (!_motif.canInput) return;
    final ptyId = _activePtyId(_motif);
    if (ptyId == null) return;
    final text = _input.text.replaceAll('\n', '');
    _focusTerminal();
    await _motif.activatePtyStream(ptyId);
    await _motif.writePty(ptyId, _terminalBytes(text, enter: true));
    _input.clear();
  }

  void _openChangeDirectory(MotifClient motif) {
    showChangeDirectorySheet(
      context,
      motif: motif,
      baseDir: motif.activeCwd ?? '~',
      onChoose: (path) {
        final cmd = "cd '$path'";
        _sendBytes(_terminalBytes(cmd, enter: true));
      },
    );
  }

  void _openFileTree(MotifClient motif) {
    final root = motif.activeCwd ?? '~';
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            FileTreePanel(root: root, onOpen: _openPreview, motif: motif),
      ),
    );
  }

  Future<void> _openPreview(String path) async {
    final motif = _motif;
    final existing = motif.views.where((v) {
      final spec = v.spec;
      return spec is PreviewViewSpec && spec.path == path;
    }).firstOrNull;
    if (existing != null) {
      await motif.activateView(existing.id);
      return;
    }
    try {
      await motif.openView(spec: PreviewViewSpec(path), activate: true);
    } catch (e) {
      if (mounted) {
        showMotifToast(context, 'Open preview failed: $e');
      }
    }
  }
}
