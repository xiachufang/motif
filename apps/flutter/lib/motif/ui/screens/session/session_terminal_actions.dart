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
        unawaited(_closeSession());
        return true;
      }
      if (key == LogicalKeyboardKey.keyL) {
        _toggleSessionsPanel(readObservationScope<AppState>(context));
        return true;
      }
      if (key == LogicalKeyboardKey.keyE) {
        _toggleFileTree();
        return true;
      }
      if (key == LogicalKeyboardKey.keyG) {
        _toggleGitDiff();
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
        // Close the active tab whenever one exists; only hide the window when
        // the session has no tabs left. Claim this ⌘W so the app-level "hide
        // window" binding (which Flutter fires right after this handler) doesn't
        // also hide the window on top of a tab close.
        readObservationScope<AppState>(context).markCloseShortcutConsumed();
        if (_workspaceState.views.items.isEmpty) {
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
    final views = _workspaceState.views.items;
    if (views.isEmpty) return;
    final index = chromeIndex == 9
        ? views.length - 1
        : (chromeIndex - 1).clamp(0, views.length - 1).toInt();
    _activateView(views[index].id);
  }

  void _activateRelativeTab(int delta) {
    final views = _workspaceState.views.items;
    if (views.isEmpty) return;
    final current = views.indexWhere(
      (v) => v.id == _workspaceState.views.activeViewId,
    );
    final base = current < 0 ? 0 : current;
    final next = (base + delta) % views.length;
    _activateView(views[next < 0 ? next + views.length : next].id);
  }

  void _activateView(String viewId) {
    if (_attachment.isLive) {
      unawaited(_viewController.activate(viewId));
    } else {
      _viewController.selectLocally(viewId);
    }
    _focusTerminalAfterTabSwitch();
  }

  Future<void> _closeActiveTab() async {
    final items = _workspaceState.views.items;
    final activeViewId = _workspaceState.views.activeViewId;
    final view = activeViewId == null
        ? items.firstOrNull
        : items.where((v) => v.id == activeViewId).firstOrNull;
    if (view == null) return;
    await _closeViewWithConfirmation(
      context,
      terminal: _terminalController,
      views: _viewController,
      view: view,
    );
    _focusTerminalAfterTabSwitch();
  }

  void _toggleSessionsPanel(AppState app) {
    if (!_usesSidebarLayout) {
      unawaited(_showSessionMenuAtOverlay(app));
      return;
    }
    final sidebar = app.sessionSidebar;
    setState(() => sidebar.showSessions = !sidebar.showSessions);
    if (sidebar.showSessions) {
      unawaited(app.refreshConnectedSessions().catchError((_) => null));
    }
  }

  void _toggleFileTree() {
    if (!_usesSidebarLayout) {
      _openFileTree();
      return;
    }
    final sidebar = readObservationScope<AppState>(context).sessionSidebar;
    setState(() => sidebar.showFileTree = !sidebar.showFileTree);
  }

  void _toggleGitDiff() {
    if (!_usesSidebarLayout) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GitDiffPanel(
            cwd: _workspaceApi.activeCwd(),
            workspace: _workspaceApi,
            onOpenDiff: ({path, required staged}) =>
                _pushDiffView(path: path, staged: staged),
          ),
        ),
      );
      return;
    }
    final sidebar = readObservationScope<AppState>(context).sessionSidebar;
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
    if (!_terminalController.canInput) return;
    final ptyId = _activePtyId();
    if (ptyId == null || bytes.isEmpty) return;
    _focusTerminal();
    await _terminalController.activatePtyStream(ptyId);
    await _terminalController.writePty(ptyId, bytes);
  }

  Future<bool> _sendCommandBytes(List<int> bytes) async {
    if (!_terminalController.canInput) return false;
    final ptyId = _activePtyId();
    if (ptyId == null || bytes.isEmpty) return false;
    _focusTerminal();
    await _terminalController.activatePtyStream(ptyId);

    final split = _splitTrailingCommandEnter(bytes);
    if (split == null) {
      await _terminalController.writePty(ptyId, bytes);
      return true;
    }

    // Mark command content as a completed paste before sending Enter. This
    // prevents burst-paste detection in TUIs such as Codex and Claude Code
    // from turning the trailing Enter into another pasted newline. Raw key
    // quick commands (which have no trailing Enter) stay on the branch above.
    await _terminalController.writePty(
      ptyId,
      bracketedPastePayloadBytes(split.content),
    );
    await _terminalController.writePty(ptyId, split.enter);
    return true;
  }

  ({List<int> content, List<int> enter})? _splitTrailingCommandEnter(
    List<int> bytes,
  ) {
    var end = bytes.length;
    if (end == 0) return null;

    final last = bytes[end - 1];
    if (last == 0x0a) {
      end--;
      if (end > 0 && bytes[end - 1] == 0x0d) end--;
    } else if (last == 0x0d) {
      end--;
    } else {
      return null;
    }

    if (end == 0) return null;
    return (
      content: List<int>.from(bytes.take(end)),
      enter: _terminalBytes('', enter: true),
    );
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

  String? _activePtyId() {
    final vid = _workspaceState.views.activeViewId;
    for (final v in _workspaceState.views.items) {
      if (v.id == vid && v.spec is PtyViewSpec) {
        return (v.spec as PtyViewSpec).ptyId;
      }
    }
    // If a non-PTY view is active, route explicit terminal actions to the first PTY.
    for (final v in _workspaceState.views.items) {
      if (v.spec is PtyViewSpec) return (v.spec as PtyViewSpec).ptyId;
    }
    final ptys = _terminalController.viewModel.ptys;
    return ptys.isEmpty ? null : ptys.first.id;
  }

  Future<void> _send() async {
    // Keep the typed text in the input box while disconnected.
    if (!_terminalController.canInput) return;
    final ptyId = _activePtyId();
    if (ptyId == null) return;
    final text = _input.text.replaceAll('\n', '');
    if (await _sendCommandBytes(_terminalBytes(text, enter: true))) {
      _input.clear();
    }
  }

  void _openChangeDirectory() {
    showChangeDirectorySheet(
      context,
      workspace: _workspaceApi,
      baseDir: _workspaceApi.activeCwd() ?? '~',
      onChoose: (path) {
        final cmd = "cd '$path'";
        _sendCommandBytes(_terminalBytes(cmd, enter: true));
      },
    );
  }

  void _openFileTree() {
    final root = _workspaceApi.activeCwd() ?? '~';
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileTreePanel(
          root: root,
          onOpen: _openPreview,
          workspace: _workspaceApi,
        ),
      ),
    );
  }

  Future<void> _openPreview(String path) async {
    final existing = _workspaceState.views.items.where((v) {
      final spec = v.spec;
      return spec is PreviewViewSpec && spec.path == path;
    }).firstOrNull;
    if (existing != null) {
      await _viewController.activate(existing.id);
      return;
    }
    try {
      await _viewController.open(spec: PreviewViewSpec(path), activate: true);
    } catch (e) {
      if (mounted) {
        showMotifToast(context, 'Open preview failed: $e');
      }
    }
  }

  Future<void> _pushDiffView({String? path, required bool staged}) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GitDiffView(
          cwd: _workspaceApi.activeCwd(),
          initialStaged: staged,
          path: path,
          workspace: _workspaceApi,
        ),
      ),
    );
  }

  Future<void> _openDiff({String? path, required bool staged}) async {
    final existing = _workspaceState.views.items.where((v) {
      final spec = v.spec;
      return spec is DiffViewSpec && spec.path == path && spec.staged == staged;
    }).firstOrNull;
    if (existing != null) {
      await _viewController.activate(existing.id);
      return;
    }
    try {
      await _viewController.open(
        spec: DiffViewSpec(staged: staged, path: path),
        activate: true,
      );
    } catch (e) {
      if (mounted) {
        showMotifToast(context, 'Open diff failed: $e');
      }
    }
  }
}
