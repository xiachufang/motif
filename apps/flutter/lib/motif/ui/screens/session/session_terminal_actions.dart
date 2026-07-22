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
      _scaffoldKey.currentState?.openDrawer();
      unawaited(app.refreshConnectedSessions().catchError((_) => null));
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
      _openMobileEndDrawer(_MobileEndDrawerPanel.files);
      return;
    }
    final sidebar = readObservationScope<AppState>(context).sessionSidebar;
    setState(() => sidebar.showFileTree = !sidebar.showFileTree);
  }

  void _toggleGitDiff() {
    if (!_usesSidebarLayout) {
      _openMobileEndDrawer(_MobileEndDrawerPanel.gitDiff);
      return;
    }
    final sidebar = readObservationScope<AppState>(context).sessionSidebar;
    setState(() => sidebar.showGitDiff = !sidebar.showGitDiff);
  }

  void _openMobileEndDrawer(_MobileEndDrawerPanel panel) {
    setState(() => _mobileEndDrawerPanel = panel);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scaffoldKey.currentState?.openEndDrawer();
    });
  }

  Future<void> _closeMobileDrawers() async {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold == null) return;
    if (scaffold.isDrawerOpen) scaffold.closeDrawer();
    if (scaffold.isEndDrawerOpen) scaffold.closeEndDrawer();
    for (var frame = 0; frame < 30; frame++) {
      if (!mounted || (!scaffold.isDrawerOpen && !scaffold.isEndDrawerOpen)) {
        return;
      }
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Future<void> _openPreviewFromMobileDrawer(String path) async {
    await _closeMobileDrawers();
    if (mounted) await _openPreview(path);
  }

  Future<void> _openDiffFromMobileDrawer({
    String? path,
    required bool staged,
  }) async {
    await _closeMobileDrawers();
    if (mounted) await _pushDiffView(path: path, staged: staged);
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
    if (bytes.isEmpty) return;
    final ptyId = await _prepareTerminalInput();
    if (ptyId == null) return;
    await _terminalController.writePty(ptyId, bytes);
  }

  Future<bool> _dispatchTerminalInput(TerminalInputEvent event) async {
    final ptyId = await _prepareTerminalInput(requireTerminalState: true);
    if (ptyId == null) return false;
    return _terminalController.dispatchTerminalInput(ptyId, event);
  }

  Future<bool> _sendPasteBytes(List<int> bytes) async {
    if (bytes.isEmpty) return false;
    final ptyId = await _prepareTerminalInput(requireTerminalState: true);
    if (ptyId == null) return false;
    return _terminalController.dispatchTerminalInput(
      ptyId,
      TerminalPasteInput(bytes),
    );
  }

  Future<bool> _sendCommandBytes(List<int> bytes) async {
    if (bytes.isEmpty) return false;
    final ptyId = await _prepareTerminalInput(requireTerminalState: true);
    if (ptyId == null) return false;

    final content = _splitTrailingCommandEnter(bytes);
    if (content == null) {
      await _terminalController.writePty(ptyId, bytes);
      return true;
    }

    // Encode command content as a real paste using the active Ghostty terminal
    // modes, then encode Enter as a semantic key. The local surface owns both
    // operations because it is the only component with the current VT state.
    final pasted = _terminalController.dispatchTerminalInput(
      ptyId,
      TerminalPasteInput(content),
    );
    if (!pasted) return false;
    final enter = TerminalKeyInput(
      keyId: TerminalKeyIds.enter,
      action: TerminalKeyAction.press,
    );
    final pressed = _terminalController.dispatchTerminalInput(ptyId, enter);
    final released = _terminalController.dispatchTerminalInput(
      ptyId,
      enter.copyWith(action: TerminalKeyAction.release),
    );
    return pressed && released;
  }

  Future<String?> _prepareTerminalInput({
    bool requireTerminalState = false,
  }) async {
    if (!_terminalController.canInput) return null;
    final ptyId = _activePtyId();
    if (ptyId == null) return null;
    _focusTerminal();
    await _terminalController.activatePtyStream(ptyId);
    if (!requireTerminalState) {
      return _terminalController.canInput ? ptyId : null;
    }
    // A reconnect can replay mode-setting output (DECCKM, DECBKM, mode 2004,
    // and keyboard protocol state). Wait for the transport replay; the
    // surface-side input barrier then flushes every delivered byte to Ghostty.
    await _terminalController.waitForPtyReplay(ptyId);
    await _terminalController.waitForPtySurfaceReplay(ptyId);
    return _terminalController.canInput ? ptyId : null;
  }

  List<int>? _splitTrailingCommandEnter(List<int> bytes) {
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
    return List<int>.from(bytes.take(end));
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

  Future<void> _openTerminalFile(TerminalFileTarget target) async {
    final path = target.resolveAgainst(_workspaceApi.activeCwd());
    if (path == null) {
      if (mounted) {
        showMotifToast(context, 'Cannot resolve ${target.path}.');
      }
      return;
    }
    try {
      final stat = await _workspaceApi.stat(path);
      if (stat.type == FileType.dir) {
        _openDirectoryInFiles(path);
        return;
      }
    } catch (_) {
      // Preserve the previous behavior for paths that disappear between
      // matching and activation, or servers that do not expose fs.stat.
    }
    await _openPreview(path);
  }

  void _openDirectoryInFiles(String path) {
    if (!mounted) return;
    if (_usesSidebarLayout) {
      final sidebar = readObservationScope<AppState>(context).sessionSidebar;
      setState(() {
        _fileTreeRoot = path;
        sidebar.showFileTree = true;
      });
      return;
    }

    setState(() {
      _fileTreeRoot = path;
      _mobileEndDrawerPanel = _MobileEndDrawerPanel.files;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scaffoldKey.currentState?.openEndDrawer();
    });
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
