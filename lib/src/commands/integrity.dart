/* Copyright (C) S. Brett Sutton - All Rights Reserved
 * Unauthorized copying of this file, via any medium is strictly prohibited
 * Proprietary and confidential
 * Written by Brett Sutton <bsutton@onepub.dev>, Jan 2022
 */

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dcli/dcli.dart';
import 'package:zone_di2/zone_di2.dart';

import '../batman_settings.dart';
import '../dependency_injection/tokens.dart';
import '../hive/hive_store.dart';
import '../hive/model/file_checksum.dart';
import '../local_settings.dart';
import '../log.dart';
import '../parsed_args.dart';
import '../scanner.dart';
import '../when.dart';

class IntegrityCommand extends Command<void> {
  IntegrityCommand();

  @override
  String get description =>
      'Scans the set of monitored directories and files reporting any changes'
      ' since the last baseline.';

  @override
  String get name => 'integrity';

  @override
  Future<int> run() async => provide(<Token<LocalSettings>, LocalSettings>{
        localSettingsToken: LocalSettings.load()
      }, _run);

  Future<int> _run() async {
    if (ParsedArgs().secureMode && !Shell.current.isPrivilegedProcess) {
      logerr('Error: You must be root to run an integrity scan');
      return 1;
    }

    if (!exists(inject(localSettingsToken).rulePath)) {
      logerr('''Error: You must run 'batman install' first.''');
      return 1;
    }

    if (!ParsedArgs().secureMode) {
      logwarn(
          '$when Warning: you are running in insecure mode. Not all files can'
          ' be checked');
    }

    BatmanSettings.load();
    await integrityScan(
        secureMode: ParsedArgs().secureMode, quiet: ParsedArgs().quiet);
    return 0;
  }

  Future<void> integrityScan(
      {required bool secureMode, required bool quiet}) async {
    Shell.current.withPrivileges(() async {
      await withTempFile((alteredFiles) async {
        log('Marking baseline.');
        await HiveStore().mark();

        await scanner(
            (rules, entity, pathToInvalidFiles) async => _scanEntity(
                rules: rules,
                entity: entity,
                pathToInvalidFiles: pathToInvalidFiles),
            name: 'File Integrity Scan',
            pathToInvalidFiles: alteredFiles);

        log('Integrity scan complete.');
        log('Sweeping for deleted files.');
        final deleted = await _sweep(alteredFiles);
        if (deleted == 0) {
          log('No deleted files found.');
        } else {
          logerr('Found $deleted deleted deleted files');
        }

        /// Given we have just written every record twice (mark and sweep)
        /// Its time to compact the box.
        await HiveStore().compact();
        await HiveStore().close();
      }, keep: true);
    }, allowUnprivileged: true);
  }

  /// Creates a baseline of the given file by creating
  /// a hash and saving the results in an identicial directory
  /// structure under .batman/baseline
  static Future<int> _scanEntity(
      {required BatmanSettings rules,
      required String entity,
      required String pathToInvalidFiles}) async {
    var failed = 0;
    if (!rules.excluded(entity)) {
      try {
        final hash = await FileChecksum.contentChecksum(entity);

        final result =
            await HiveStore().compareCheckSum(entity, hash, clear: true);
        switch (result) {
          case CheckSumCompareResult.mismatch:
            failed = 1;
            final message = 'Integrity: Detected altered file: $entity';
            logerr(red('$when $message'));
            pathToInvalidFiles.append(message);
            break;
          case CheckSumCompareResult.missing:
            failed = 1;
            final message =
                'Integrity: New file created since baseline: $entity';
            logwarn('$when $message');
            pathToInvalidFiles.append(message);
            break;
          case CheckSumCompareResult.matching:
            // no action required.
            break;
        }
      } on FileSystemException catch (e) {
        if (e.osError!.errorCode == 13 && !ParsedArgs().secureMode) {
          final message =
              'Error: permission denied for $entity, no hash calculated.';
          log('$when $message');
          pathToInvalidFiles.append(message);
        } else {
          final message = '${e.message} $entity';
          logerr(red('$when $message'));
          printerr(orange('is priviliged:  ${Shell.current.isPrivilegedUser}'));
          pathToInvalidFiles.append(message);
        }
      }
    }
    return failed;
  }

  /// We marked all files in hive db at the start
  /// We no check for any that didn't get cleared.
  /// If a file didn't get cleared than it was deleted
  /// since the baseline.
  Future<int> _sweep(String pathToInvalidFiles) async =>
      _sweepAsync(pathToInvalidFiles);

  Future<int> _sweepAsync(String pathToInvalidFiles) async {
    var count = 0;
    await for (final path in HiveStore().sweep()) {
      final message = 'Error: file deleted  $path';
      logerr(red('$when $message'));
      count++;
      pathToInvalidFiles.append(message);
    }
    return count;
  }
}
