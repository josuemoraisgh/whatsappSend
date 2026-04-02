import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_webview_controller.dart';

const _kDesktopAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// Implementação para Android/iOS usando `webview_flutter`.
/// A sessão é persistida automaticamente pelo WebView do sistema.
class MobileWebViewController implements AppWebViewController {
  late final WebViewController _controller;
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_kDesktopAgent);
    _initialized = true;
  }

  @override
  bool get isInitialized => _initialized;

  @override
  Future<void> loadUrl(String url) => _controller.loadRequest(Uri.parse(url));

  @override
  Future<String> executeJavaScript(String script) async {
    final result = await _controller.runJavaScriptReturningResult(script);
    return result.toString();
  }

  @override
  Future<void> clearSession() async {
    try {
      await _controller.clearLocalStorage();
      await _controller.clearCache();
      // Limpa cookies do WebView inteiro
      await WebViewCookieManager().clearCookies();
    } catch (_) {}
  }

  @override
  Widget buildWidget() => WebViewWidget(controller: _controller);

  @override
  void dispose() {
    // webview_flutter não requer dispose explícito.
  }
}
