import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_pointer_policy.dart';

void main() {
  test('desktop secondary click opens terminal context menu', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    ]) {
      expect(
        terminalContextMenuShouldOpen(
          buttons: kSecondaryButton,
          platform: platform,
        ),
        isTrue,
        reason: '$platform',
      );
    }
  });

  test('primary click does not open terminal context menu', () {
    expect(
      terminalContextMenuShouldOpen(
        buttons: kPrimaryButton,
        platform: TargetPlatform.macOS,
      ),
      isFalse,
    );
  });

  test('mobile secondary press does not open desktop menu', () {
    expect(
      terminalContextMenuShouldOpen(
        buttons: kSecondaryButton,
        platform: TargetPlatform.iOS,
      ),
      isFalse,
    );
  });

  test('desktop combined press containing secondary opens menu', () {
    expect(
      terminalContextMenuShouldOpen(
        buttons: kPrimaryButton | kSecondaryButton,
        platform: TargetPlatform.macOS,
      ),
      isTrue,
    );
  });
}
