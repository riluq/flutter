// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:args/command_runner.dart';
import 'package:intl/intl.dart' as intl;
import 'package:intl/intl_standalone.dart' as intl_standalone;
import 'package:meta/meta.dart';

import 'src/base/bot_detector.dart';
import 'src/base/common.dart';
import 'src/base/context.dart';
import 'src/base/file_system.dart';
import 'src/base/io.dart';
import 'src/base/logger.dart';
import 'src/base/process.dart';
import 'src/base/terminal.dart';
import 'src/context_runner.dart';
import 'src/doctor.dart';
import 'src/globals.dart' as globals;
import 'src/reporting/github_template.dart';
import 'src/reporting/reporting.dart';
import 'src/runner/flutter_command.dart';
import 'src/runner/flutter_command_runner.dart';
import 'src/version.dart';

/// Runs the Flutter tool with support for the specified list of [commands].
Future<int> run(
  List<String> args,
  List<FlutterCommand> commands, {
  bool muteCommandLogging = false,
  bool verbose = false,
  bool verboseHelp = false,
  bool reportCrashes,
  String flutterVersion,
  Map<Type, Generator> overrides,
}) {
  reportCrashes ??= !isRunningOnBot(globals.platform);

  if (muteCommandLogging) {
    // Remove the verbose option; for help and doctor, users don't need to see
    // verbose logs.
    args = List<String>.from(args);
    args.removeWhere((String option) => option == '-v' || option == '--verbose');
  }

  final FlutterCommandRunner runner = FlutterCommandRunner(verboseHelp: verboseHelp);
  commands.forEach(runner.addCommand);

  return runInContext<int>(() async {
    // Initialize the system locale.
    final String systemLocale = await intl_standalone.findSystemLocale();
    intl.Intl.defaultLocale = intl.Intl.verifiedLocale(
      systemLocale, intl.NumberFormat.localeExists,
      onFailure: (String _) => 'en_US',
    );

    String getVersion() => flutterVersion ?? FlutterVersion.instance.getVersionString(redactUnknownBranches: true);
    Object firstError;
    StackTrace firstStackTrace;
    return await runZoned<Future<int>>(() async {
      try {
        await runner.run(args);
        return await _exit(0);
      } catch (error, stackTrace) {
        firstError = error;
        firstStackTrace = stackTrace;
        return await _handleToolError(
            error, stackTrace, verbose, args, reportCrashes, getVersion);
      }
    }, onError: (Object error, StackTrace stackTrace) async {
      // If sending a crash report throws an error into the zone, we don't want
      // to re-try sending the crash report with *that* error. Rather, we want
      // to send the original error that triggered the crash report.
      final Object e = firstError ?? error;
      final StackTrace s = firstStackTrace ?? stackTrace;
      await _handleToolError(e, s, verbose, args, reportCrashes, getVersion);
    });
  }, overrides: overrides);
}

Future<int> _handleToolError(
  dynamic error,
  StackTrace stackTrace,
  bool verbose,
  List<String> args,
  bool reportCrashes,
  String getFlutterVersion(),
) async {
  if (error is UsageException) {
    globals.printError('${error.message}\n');
    globals.printError("Run 'flutter -h' (or 'flutter <command> -h') for available flutter commands and options.");
    // Argument error exit code.
    return _exit(64);
  } else if (error is ToolExit) {
    if (error.message != null) {
      globals.printError(error.message);
    }
    if (verbose) {
      globals.printError('\n$stackTrace\n');
    }
    return _exit(error.exitCode ?? 1);
  } else if (error is ProcessExit) {
    // We've caught an exit code.
    if (error.immediate) {
      exit(error.exitCode);
      return error.exitCode;
    } else {
      return _exit(error.exitCode);
    }
  } else {
    // We've crashed; emit a log report.
    stderr.writeln();

    if (!reportCrashes) {
      // Print the stack trace on the bots - don't write a crash report.
      stderr.writeln('$error');
      stderr.writeln(stackTrace.toString());
      return _exit(1);
    }

    // Report to both [Usage] and [CrashReportSender].
    flutterUsage.sendException(error);
    await CrashReportSender.instance.sendReport(
      error: error,
      stackTrace: stackTrace,
      getFlutterVersion: getFlutterVersion,
      command: args.join(' '),
    );

    final String errorString = error.toString();
    globals.printError('Oops; flutter has exited unexpectedly: "$errorString".');

    try {
      await _informUserOfCrash(args, error, stackTrace, errorString);

      return _exit(1);
    } catch (error) {
      stderr.writeln(
        'Unable to generate crash report due to secondary error: $error\n'
            'please let us know at https://github.com/flutter/flutter/issues.',
      );
      // Any exception throw here (including one thrown by `_exit()`) will
      // get caught by our zone's `onError` handler. In order to avoid an
      // infinite error loop, we throw an error that is recognized above
      // and will trigger an immediate exit.
      throw ProcessExit(1, immediate: true);
    }
  }
}

Future<void> _informUserOfCrash(List<String> args, dynamic error, StackTrace stackTrace, String errorString) async {
  final String doctorText = await _doctorText();
  final File file = await _createLocalCrashReport(args, error, stackTrace, doctorText);

  globals.printError('A crash report has been written to ${file.path}.');
  globals.printStatus('This crash may already be reported. Check GitHub for similar crashes.', emphasis: true);

  final GitHubTemplateCreator gitHubTemplateCreator = context.get<GitHubTemplateCreator>() ?? GitHubTemplateCreator();
  final String similarIssuesURL = await gitHubTemplateCreator.toolCrashSimilarIssuesGitHubURL(errorString);
  globals.printStatus('$similarIssuesURL\n', wrap: false);
  globals.printStatus('To report your crash to the Flutter team, first read the guide to filing a bug.', emphasis: true);
  globals.printStatus('https://flutter.dev/docs/resources/bug-reports\n', wrap: false);
  globals.printStatus('Create a new GitHub issue by pasting this link into your browser and completing the issue template. Thank you!', emphasis: true);

  final String command = _crashCommand(args);
  final String gitHubTemplateURL = await gitHubTemplateCreator.toolCrashIssueTemplateGitHubURL(
    command,
    errorString,
    _crashException(error),
    stackTrace,
    doctorText
  );
  globals.printStatus('$gitHubTemplateURL\n', wrap: false);
}

String _crashCommand(List<String> args) => 'flutter ${args.join(' ')}';

String _crashException(dynamic error) => '${error.runtimeType}: $error';

/// File system used by the crash reporting logic.
///
/// We do not want to use the file system stored in the context because it may
/// be recording. Additionally, in the case of a crash we do not trust the
/// integrity of the [AppContext].
@visibleForTesting
FileSystem crashFileSystem = const LocalFileSystem();

/// Saves the crash report to a local file.
Future<File> _createLocalCrashReport(List<String> args, dynamic error, StackTrace stackTrace, String doctorText) async {
  File crashFile = fsUtils.getUniqueFile(crashFileSystem.currentDirectory, 'flutter', 'log');

  final StringBuffer buffer = StringBuffer();

  buffer.writeln('Flutter crash report; please file at https://github.com/flutter/flutter/issues.\n');

  buffer.writeln('## command\n');
  buffer.writeln('${_crashCommand(args)}\n');

  buffer.writeln('## exception\n');
  buffer.writeln('${_crashException(error)}\n');
  buffer.writeln('```\n$stackTrace```\n');

  buffer.writeln('## flutter doctor\n');
  buffer.writeln('```\n$doctorText```');

  try {
    crashFile.writeAsStringSync(buffer.toString());
  } on FileSystemException catch (_) {
    // Fallback to the system temporary directory.
    crashFile = fsUtils.getUniqueFile(crashFileSystem.systemTempDirectory, 'flutter', 'log');
    try {
      crashFile.writeAsStringSync(buffer.toString());
    } on FileSystemException catch (e) {
      globals.printError('Could not write crash report to disk: $e');
      globals.printError(buffer.toString());
    }
  }

  return crashFile;
}

Future<String> _doctorText() async {
  try {
    final BufferLogger logger = BufferLogger(
      terminal: globals.terminal,
      outputPreferences: outputPreferences,
    );

    await context.run<bool>(
      body: () => doctor.diagnose(verbose: true, showColor: false),
      overrides: <Type, Generator>{
        Logger: () => logger,
      },
    );

    return logger.statusText;
  } catch (error, trace) {
    return 'encountered exception: $error\n\n${trace.toString().trim()}\n';
  }
}

Future<int> _exit(int code) async {
  // Prints the welcome message if needed.
  flutterUsage.printWelcome();

  // Send any last analytics calls that are in progress without overly delaying
  // the tool's exit (we wait a maximum of 250ms).
  if (flutterUsage.enabled) {
    final Stopwatch stopwatch = Stopwatch()..start();
    await flutterUsage.ensureAnalyticsSent();
    globals.printTrace('ensureAnalyticsSent: ${stopwatch.elapsedMilliseconds}ms');
  }

  // Run shutdown hooks before flushing logs
  await shutdownHooks.runShutdownHooks();

  final Completer<void> completer = Completer<void>();

  // Give the task / timer queue one cycle through before we hard exit.
  Timer.run(() {
    try {
      globals.printTrace('exiting with code $code');
      exit(code);
      completer.complete();
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    }
  });

  await completer.future;
  return code;
}
