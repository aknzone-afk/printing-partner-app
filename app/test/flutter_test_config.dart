// Global test configuration (flutter_test runs this around every test file).
//
// WHY THIS EXISTS: the shop's dev PC has an Intel Raptor Lake CPU (Family 6
// Model 183, 8 performance + 16 efficiency cores) whose PERFORMANCE cores
// compute wrongly under load (Windows logs blue screens and access violations
// in unrelated programs on the same machine). The pure-Dart image loops these
// tests run are exactly the kind of work that trips it: on the default cores
// `flutter test` failed 3 runs out of 3 with impossible errors such as
//   "NoSuchMethodError: Class 'double' has no instance getter 'rNormalized'"
// or the test process dying with 0xC0000005, in a different test each time;
// pinned to the efficiency cores the same suite passed 12 runs out of 12.
//
// So on that CPU model only, the TEST PROCESS pins itself to the efficiency
// cores (logical CPUs 16-31). It changes nothing in the app and no system
// setting, and it does nothing on any other machine. Once the CPU is
// replaced this file can simply be deleted.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  _avoidFaultyPerformanceCores();
  await testMain();
}

typedef _GetCurrentProcessC = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();
typedef _SetAffinityC = Int32 Function(IntPtr process, IntPtr mask);
typedef _SetAffinityDart = int Function(int process, int mask);

void _avoidFaultyPerformanceCores() {
  try {
    if (!Platform.isWindows) return;
    final env = Platform.environment;
    final cpu = env['PROCESSOR_IDENTIFIER'] ?? '';
    // 13900K / 14900K(S): 8 P-cores with hyper-threading (logical 0-15)
    // followed by 16 E-cores (logical 16-31).
    if (!cpu.contains('GenuineIntel') ||
        !cpu.contains('Family 6 Model 183') ||
        env['NUMBER_OF_PROCESSORS'] != '32') {
      return;
    }
    if (env['PP_TEST_ALL_CORES'] == '1') return; // opt out
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getCurrentProcess = kernel32.lookupFunction<_GetCurrentProcessC,
        _GetCurrentProcessDart>('GetCurrentProcess');
    final setAffinity = kernel32.lookupFunction<_SetAffinityC,
        _SetAffinityDart>('SetProcessAffinityMask');
    setAffinity(getCurrentProcess(), 0xFFFF0000);
  } catch (_) {
    // Best effort only: never let this stop the tests from running.
  }
}
