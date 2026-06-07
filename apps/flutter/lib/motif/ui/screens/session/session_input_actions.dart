// ignore_for_file: invalid_use_of_protected_member

part of '../session_screen.dart';

extension _SessionScreenInputActions on _SessionScreenState {
  void _scheduleKeyboardInsetSync() {
    if (_keyboardInsetSyncScheduled || !mounted) return;
    _keyboardInsetSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardInsetSyncScheduled = false;
      if (mounted) _syncKeyboardInsetFromContext();
    });
  }

  void _syncKeyboardInsetFromContext() {
    final media = MediaQuery.maybeOf(context);
    _setKeyboardInset(media?.viewInsets.bottom ?? 0);
  }

  void _setKeyboardInset(double inset) {
    final previous = _keyboardInset.value;
    if ((inset - previous).abs() < 0.5) return;
    _keyboardInset.value = inset;
    final now = DateTime.now();
    final previousLogAt = _lastKeyboardInsetLogAt;
    _lastKeyboardInsetLogAt = now;
    final dtMs = previousLogAt == null
        ? null
        : now.difference(previousLogAt).inMilliseconds;
    Log.d(
      'inset=${inset.toStringAsFixed(1)} '
      'prev=${previous.toStringAsFixed(1)} '
      'delta=${(inset - previous).toStringAsFixed(1)} '
      'dt=${dtMs ?? '-'}ms',
      name: 'motif.keyboard',
    );
  }

  void _setBottomBarContentSize(Size size) {
    if (!mounted || size.height <= 0) return;
    final previous = _bottomBarContentHeight.value;
    if ((size.height - previous).abs() < 0.5) return;
    _bottomBarContentHeight.value = size.height;
  }

  /// Mirrors the iOS ASRBailGestureMonitor: if the user edits the input bar while
  /// recording (a change ASR didn't make), discard the in-flight transcript and
  /// stop listening.
  void _onInputChanged() {
    if (_recording && _input.text != _lastAsrText) {
      _ignoreFinal = true;
      _toggleMic(); // stop
    }
  }

  Future<void> _toggleMic() async {
    if (_micStarting) return;
    final speech = context.read<AppState>().platform.speech;
    if (_recording) {
      final finalText = await speech.stop();
      if (!_ignoreFinal && finalText.isNotEmpty) {
        _lastAsrText = _mergeAsr(_asrBase, finalText);
        _input.text = _lastAsrText;
      }
      _ignoreFinal = false;
      if (mounted) setState(() => _recording = false);
      return;
    }
    _asrBase = _input.text;
    _ignoreFinal = false;
    if (mounted) {
      setState(() {
        _micStarting = true;
        _recording = false;
      });
    }
    var failed = false;
    try {
      await speech.start(
        onPartial: (partial) {
          if (_ignoreFinal) return;
          _lastAsrText = _mergeAsr(_asrBase, partial);
          _input.text = _lastAsrText;
        },
        onError: (e) {
          failed = true;
          // Mid-session failures (e.g. Doubao backend dying) don't stop the
          // recorder by themselves — shut it down so the mic turns off
          // instead of streaming into a dead session.
          if (_recording) unawaited(speech.stop());
          if (mounted) {
            setState(() {
              _micStarting = false;
              _recording = false;
            });
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Voice input: $e')));
          }
        },
      );
      if (mounted && !failed && speech.isAvailable) {
        setState(() {
          _micStarting = false;
          _recording = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _micStarting = false;
          _recording = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Voice input unavailable: $e')));
      }
    }
  }

  Future<void> _attachPhoto() async {
    final ptyId = _activePtyId(_motif);
    if (ptyId == null) return;
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final dot = picked.name.lastIndexOf('.');
      final ext = dot >= 0 ? picked.name.substring(dot + 1) : 'jpg';
      final remotePath =
          '/tmp/motif-${DateTime.now().microsecondsSinceEpoch}.$ext';
      await _motif.writeFileBytes(remotePath, bytes);
      // Bracketed-paste the uploaded path into the shell.
      final paste = <int>[
        0x1b,
        0x5b,
        0x32,
        0x30,
        0x30,
        0x7e,
        ..._terminalBytes(remotePath),
        0x1b,
        0x5b,
        0x32,
        0x30,
        0x31,
        0x7e,
      ];
      await _sendBytes(paste);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Attach failed: $e')));
      }
    }
  }

  String _mergeAsr(String base, String text) {
    if (base.isEmpty) return text;
    if (text.isEmpty) return base;
    return base.codeUnits.last <= 0x20 ? '$base$text' : '$base $text';
  }

  MotifClient get _motif =>
      context.read<AppState>().clientForServer(widget.serverId);

  void _syncWindowTitle() {
    unawaited(MotifWindowTitle.set(widget.session).catchError((_) {}));
  }
}
