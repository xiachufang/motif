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
    final recordingInput = _inputControllerForView(_asrInputViewId) ?? _input;
    if (_recording && recordingInput.text != _lastAsrText) {
      _ignoreFinal = true;
      _toggleMic(); // stop
    }
  }

  Future<void> _toggleMic() async {
    if (_micStarting) return;
    final speech = readObservationScope<AppState>(context).platform.speech;
    if (_recording) {
      final finalText = await speech.stop();
      final input = _inputControllerForView(_asrInputViewId) ?? _input;
      if (!_ignoreFinal && finalText.isNotEmpty) {
        _lastAsrText = _mergeAsr(_asrBase, finalText);
        input.text = _lastAsrText;
      }
      _ignoreFinal = false;
      _asrInputViewId = null;
      if (mounted) setState(() => _recording = false);
      return;
    }
    _asrInputViewId = _workspaceState.views.active?.id;
    final input = _inputControllerForView(_asrInputViewId) ?? _input;
    _asrBase = input.text;
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
          final input = _inputControllerForView(_asrInputViewId) ?? _input;
          _lastAsrText = _mergeAsr(_asrBase, partial);
          input.text = _lastAsrText;
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
            _asrInputViewId = null;
            showMotifToast(context, 'Voice input: $e');
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
        _asrInputViewId = null;
        showMotifToast(context, 'Voice input unavailable: $e');
      }
    }
  }

  Future<void> _attachPhoto() async {
    final ptyId = _activePtyId();
    if (ptyId == null) return;
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final dot = picked.name.lastIndexOf('.');
      final ext = dot >= 0 ? picked.name.substring(dot + 1) : 'jpg';
      final remotePath =
          '/tmp/motif-${DateTime.now().microsecondsSinceEpoch}.$ext';
      await _workspaceApi.writeBytes(remotePath, bytes);
      // Insert the uploaded path without executing it. This uses the same
      // paste envelope as the composer, but intentionally omits Enter.
      await _sendBytes(bracketedPasteBytes(remotePath));
    } catch (e) {
      if (mounted) {
        showMotifToast(context, 'Attach failed: $e');
      }
    }
  }

  String _mergeAsr(String base, String text) {
    if (base.isEmpty) return text;
    if (text.isEmpty) return base;
    return base.codeUnits.last <= 0x20 ? '$base$text' : '$base $text';
  }

  void _syncWindowTitle() {
    unawaited(MotifWindowTitle.set(widget.session).catchError((_) {}));
  }
}
