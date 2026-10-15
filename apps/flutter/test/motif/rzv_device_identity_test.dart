import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/net/rzv/rzv_device_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'concurrent creation and later reload use the persisted installation ID',
    () async {
      SharedPreferences.setMockInitialValues({});
      final ids = await Future.wait(
        List.generate(8, (_) => RzvDeviceIdentity.load()),
      );
      expect(ids.toSet(), hasLength(1));
      expect(ids.first, matches(RegExp(r'^app_[0-9a-f]{32}$')));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(RzvDeviceIdentity.preferenceKey), ids.first);
      SharedPreferences.setMockInitialValues({
        RzvDeviceIdentity.preferenceKey: ids.first,
      });
      expect(await RzvDeviceIdentity.load(), ids.first);
    },
  );

  test(
    'invalid stored metadata is replaced, clearing data creates a new ID',
    () async {
      SharedPreferences.setMockInitialValues({
        RzvDeviceIdentity.preferenceKey: 'bad\nvalue',
      });
      final first = await RzvDeviceIdentity.load();
      expect(first, matches(RegExp(r'^app_[0-9a-f]{32}$')));
      SharedPreferences.setMockInitialValues({});
      expect(await RzvDeviceIdentity.load(), isNot(first));
    },
  );
}
