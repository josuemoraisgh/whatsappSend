import 'package:flutter/foundation.dart';

import '../../domain/entities/app_config.dart';
import '../../domain/repositories/config_repository.dart';

/// Gerencia configurações da aplicação e lista de arquivos para envio.
final class ConfigProvider extends ChangeNotifier {
  ConfigProvider(this._repo, AppConfig initial) : _config = initial {
    // Restaura anexos salvos
    final saved = initial.savedAttachments;
    _attachments = List.generate(
      3,
      (i) => i < saved.length ? saved[i] : '',
    );
  }

  final ConfigRepository _repo;
  AppConfig _config;

  AppConfig get config => _config;

  // Até 3 arquivos para enviar junto com a mensagem
  late final List<String> _attachments;
  List<String> get attachments =>
      _attachments.where((a) => a.isNotEmpty).toList();

  String getAttachment(int index) => _attachments[index];

  void setAttachment(int index, String path) {
    _attachments[index] = path;
    _saveAttachments();
    notifyListeners();
  }

  void _saveAttachments() {
    update(_config.copyWith(savedAttachments: List.of(_attachments)));
  }

  Future<void> update(AppConfig config) async {
    _config = config;
    await _repo.save(_config);
    notifyListeners();
  }

  Future<void> updateDefaultMessage(String message) =>
      update(_config.copyWith(defaultMessage: message));

  /// Proporção WebView / Log
  double get splitFraction => _config.splitFraction;

  Future<void> updateSplitFraction(double fraction) =>
      update(_config.copyWith(splitFraction: fraction));
}
