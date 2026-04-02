import 'package:flutter/widgets.dart';

/// Abstração multiplataforma para WebView (Android + Windows).
abstract class AppWebViewController {
  /// Inicializa o controller. Deve ser chamado antes de qualquer uso.
  Future<void> initialize();

  /// Se o controller já está pronto para uso.
  bool get isInitialized;

  /// Carrega uma URL.
  Future<void> loadUrl(String url);

  /// Executa JavaScript e retorna o resultado como String.
  Future<String> executeJavaScript(String script);

  /// Limpa toda a sessão (cookies, localStorage, cache).
  /// Usado para desconectar do WhatsApp Web.
  Future<void> clearSession();

  /// Constrói o widget de WebView para a plataforma corrente.
  Widget buildWidget();

  /// Libera os recursos.
  void dispose();
}
