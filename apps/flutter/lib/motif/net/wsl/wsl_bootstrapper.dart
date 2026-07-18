/// Conditional facade for WSL motifd bootstrapping.
library;

export 'wsl_bootstrapper_io.dart'
    if (dart.library.js_interop) 'wsl_bootstrapper_web.dart';
