/// Conditional facade for SSH remote motifd bootstrapping.
library;

export 'ssh_bootstrapper_io.dart'
    if (dart.library.js_interop) 'ssh_bootstrapper_web.dart';
