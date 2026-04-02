import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:webview_windows/webview_windows.dart' as win;

import 'app_webview_controller.dart';

/// Implementação para Windows Desktop usando `webview_windows` (WebView2/Edge).
///
/// A sessão é persistida automaticamente pelo WebView2, que armazena cookies
/// e localStorage na pasta `WebView2/` ao lado do executável.
/// Não é necessário configurar userDataPath — o comportamento padrão já
/// mantém a sessão do WhatsApp Web entre reinicializações do app.
class DesktopWebViewController implements AppWebViewController {
  final _controller = win.WebviewController();
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    await _controller.initialize();
    _initialized = true;
  }

  @override
  bool get isInitialized => _initialized;

  @override
  Future<void> loadUrl(String url) => _controller.loadUrl(url);

  @override
  Future<String> executeJavaScript(String script) async {
    final result = await _controller.executeScript(script);
    var s = result?.toString() ?? '';
    // WebView2 retorna resultados JSON-serializados. Strings JS vêm
    // envolvidas em aspas duplas (ex: '"ok"' em vez de 'ok').
    // Precisamos remover essas aspas para comparações funcionarem.
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      s = s.substring(1, s.length - 1);
      // Desfaz escapes JSON básicos (\" → ", \\ → \, \n → newline)
      s = s
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', r'\')
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\t', '\t');
    }
    return s;
  }

  @override
  Future<void> clearSession() async {
    // 1. Navega para página em branco antes de apagar os dados
    try {
      await _controller.loadUrl('about:blank');
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (_) {}

    // 2. Remove a pasta WebView2 que fica ao lado do executável.
    //    Ela contém todos os cookies (inclusive HttpOnly) e armazenamento local.
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final webView2Dir = Directory(p.join(exeDir, 'WebView2'));
      if (await webView2Dir.exists()) {
        await webView2Dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  @override
  Widget buildWidget() => win.Webview(_controller);

  @override
  void dispose() => _controller.dispose();
}
