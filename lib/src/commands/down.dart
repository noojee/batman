import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dcli/dcli.dart';

import '../batman_settings.dart';

class DownCommand extends Command<void> {
  DownCommand() {
    argParser.addOption('file', abbr: 'f', help: '''
Path to the docker-compose.yaml file
batman baseline --docker=batman --file=~/.batman/docker-compose.yaml
    ''');
  }

  @override
  String get description => 'Stops the docker container';

  @override
  String get name => 'down';

  @override
  void run() {
    var file = argResults!['file'] as String?;
    var fileArg = '';
    file ??= join(BatmanSettings.pathToSettingsDir, 'docker-compose.yaml');
    if (!exists(file)) {
      printerr(red('The docker-compose file $file does not exist'));
      exit(1);
    }
    fileArg = '-f $file';

    'docker-compose $fileArg down'.run;
  }
}
