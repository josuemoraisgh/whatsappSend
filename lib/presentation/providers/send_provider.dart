import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../../core/webview/app_webview_controller.dart';
import '../../core/webview/webview_factory.dart';
import '../../data/services/native_whatsapp_service.dart';
import '../../data/services/webview_whatsapp_service.dart';
import '../../domain/entities/app_config.dart';
import '../../domain/entities/contact.dart';
import '../../domain/entities/send_result.dart';
import '../../domain/services/whatsapp_sender_service.dart';

/// Modo de envio disponível no Android.
enum SendMode {
  /// Automático via WhatsApp Web (WebView). Exige vincular uma vez.
  webView,

  /// Abre cada contato no WhatsApp instalado (manual, um a um).
  native,
}

class LogEntry {
  const LogEntry(this.message, this.type, this.time);
  final String message;
  final LogType type;
  final DateTime time;
}

/// Gerencia o estado do processo de envio e o WebViewController compartilhado.
final class SendProvider extends ChangeNotifier {
  SendProvider._(this._service, this._webViewController, this._sendMode);

  WhatsAppSenderService _service;
  AppWebViewController? _webViewController;
  SendMode _sendMode;

  /// Retorna o controller do WebView (nulo no modo nativo).
  AppWebViewController? get webViewController => _webViewController;

  /// Indica se o serviço ativo usa WebView.
  bool get requiresWebView => _service.requiresWebView;

  /// Modo de envio atual.
  SendMode get sendMode => _sendMode;

  /// Verdadeiro se a plataforma suporta escolha de modo (Android/iOS).
  bool get canSwitchMode => Platform.isAndroid || Platform.isIOS;

  bool _isSending = false;
  bool _cancelRequested = false;
  bool _showWebView = true;
  bool _loginRequired = false;
  bool _loggedIn = false;
  bool _switchingMode = false;
  bool _connectingWa = false; // verifica sessão em background

  int _progress = 0;
  int _total = 0;

  final List<LogEntry> _log = [];

  bool get isSending => _isSending;
  bool get showWebView => _showWebView;
  bool get loginRequired => _loginRequired;
  bool get loggedIn => _loggedIn;
  bool get switchingMode => _switchingMode;
  bool get connectingWa => _connectingWa;
  int get progress => _progress;
  int get total => _total;
  List<LogEntry> get log => List.unmodifiable(_log);

  double get progressPct => _total == 0 ? 0 : _progress / _total;

  set showWebView(bool v) {
    _showWebView = v;
    notifyListeners();
  }

  // ── Troca de modo (só Android) ────────────────────────────────────

  Future<void> switchMode(SendMode mode) async {
    if (mode == _sendMode || _isSending) return;
    _switchingMode = true;
    notifyListeners();

    // Descarta WebView antigo se havia
    _webViewController?.dispose();
    _webViewController = null;

    if (mode == SendMode.webView) {
      final ctrl = createWebViewController();
      await ctrl.initialize();
      _webViewController = ctrl;
      _service = WebViewWhatsAppService(ctrl);
    } else {
      _service = NativeWhatsAppService();
    }

    _sendMode = mode;
    _loginRequired = false;
    _loggedIn = false;
    _switchingMode = false;
    notifyListeners();
  }

  // ── Envio ─────────────────────────────────────────────────────────

  Future<void> startSend({
    required List<Contact> contacts,
    required AppConfig config,
    required List<String> attachments,
    required void Function(
      String id,
      String phone,
      String status,
      String detail,
    ) onContactStatus,
    required VoidCallback onFinished,
  }) async {
    _isSending = true;
    _cancelRequested = false;
    _loginRequired = false;
    _loggedIn = false;
    _progress = 0;
    _total = contacts.length;
    _showWebView = true;
    notifyListeners();

    final stream = _service.sendMessages(
      contacts: contacts,
      config: config,
      attachments: attachments,
      isCancelled: () => _cancelRequested,
    );

    await for (final event in stream) {
      switch (event) {
        case SendEventLog(:final message, :final type):
          _log.add(LogEntry(message, type, DateTime.now()));
          notifyListeners();

        case SendEventProgress(:final current, :final total):
          _progress = current;
          _total = total;
          notifyListeners();

        case SendEventContactStatus(
            :final contactId,
            :final phone,
            :final status,
            :final detail,
          ):
          onContactStatus(contactId, phone, status, detail);

        case SendEventLoginRequired():
          _loginRequired = true;
          _showWebView = true;
          notifyListeners();

        case SendEventLoggedIn():
          _loggedIn = true;
          notifyListeners();

        case SendEventFinished():
          _isSending = false;
          notifyListeners();
          onFinished();
      }
    }

    _isSending = false;
    notifyListeners();
  }

  void cancel() {
    _cancelRequested = true;
  }

  // ── Conectar / Desconectar WhatsApp Web ──────────────────────────

  /// Abre o WhatsApp Web no WebView e verifica em background se a sessão
  /// anterior ainda é válida (sem QR). Só disponível quando usa WebView.
  Future<void> connectWhatsApp() async {
    final ctrl = _webViewController;
    if (ctrl == null || _isSending || _connectingWa) return;

    _loginRequired = true;
    _loggedIn = false;
    _showWebView = true;
    _connectingWa = true;
    notifyListeners();

    try {
      await ctrl.loadUrl('https://web.whatsapp.com');
    } catch (_) {}

    // Polling em background (15s) para detectar se já estava logado
    unawaited(
      Future.microtask(() async {
        const sel = '#pane-side, [data-testid="chat-list"],'
            'div[aria-label="Lista de conversas"],'
            'div[aria-label="Conversation list"]';
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline)) {
          try {
            final r = await ctrl.executeJavaScript(
              'Boolean(document.querySelector(${'"$sel"'}))',
            );
            if (r == 'true') {
              _loggedIn = true;
              break;
            }
          } catch (_) {}
          await Future.delayed(const Duration(milliseconds: 800));
        }
        _connectingWa = false;
        notifyListeners();
      }),
    );
  }

  /// Remove toda a sessão salva do WhatsApp Web e reinicializa o WebView.
  /// O próximo acesso exigirá novo QR Code.
  Future<void> disconnectWhatsApp() async {
    if (_isSending) return;

    _loggedIn = false;
    _loginRequired = false;
    _connectingWa = false;
    notifyListeners();

    final oldCtrl = _webViewController;
    if (oldCtrl == null) return;

    // 1. Limpa cookies / pasta de sessão
    await oldCtrl.clearSession();

    // 2. Descarta o controller antigo
    oldCtrl.dispose();
    _webViewController = null;

    // 3. Cria um controller novo (pasta limpa será recriada pelo initialize)
    final newCtrl = createWebViewController();
    await newCtrl.initialize();
    _webViewController = newCtrl;
    _service = WebViewWhatsAppService(newCtrl);

    notifyListeners();
  }

  void clearLog() {
    _log.clear();
    notifyListeners();
  }

  // ── Factory ───────────────────────────────────────────────────────

  static Future<SendProvider> build() async {
    if (Platform.isAndroid || Platform.isIOS) {
      // Android inicia no modo nativo por padrão;
      // o usuário pode trocar para WebView (automático) na tela de envio.
      return SendProvider._(NativeWhatsAppService(), null, SendMode.native);
    }
    final ctrl = createWebViewController();
    await ctrl.initialize();
    final provider =
        SendProvider._(WebViewWhatsAppService(ctrl), ctrl, SendMode.webView);
    // Tenta restaurar sessão em background ao abrir o app
    unawaited(provider.connectWhatsApp());
    return provider;
  }
}
