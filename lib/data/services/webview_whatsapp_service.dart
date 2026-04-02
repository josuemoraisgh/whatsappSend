import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/webview/app_webview_controller.dart';
import '../../core/utils/message_formatter.dart';
import '../../core/utils/phone_formatter.dart';
import '../../domain/entities/app_config.dart';
import '../../domain/entities/contact.dart';
import '../../domain/entities/send_result.dart';
import '../../domain/services/whatsapp_sender_service.dart';

/// CSS selectors — mesmos do app Python original.
const _kSelLoginOk =
    '#pane-side, [data-testid="chat-list"], div[aria-label="Lista de conversas"],'
    'div[aria-label="Conversation list"]';

const _kSelMsgBox = 'div[contenteditable="true"][data-tab="10"],'
    'div[contenteditable="true"][aria-label*="mensagem"],'
    'div[contenteditable="true"][aria-label*="message"],'
    'footer div[contenteditable="true"]';

/// Implementação do serviço de envio via WebView (Windows Desktop).
/// Ações são realizadas por navegação de URL e injeção de JavaScript.
final class WebViewWhatsAppService implements WhatsAppSenderService {
  WebViewWhatsAppService(this._controller);
  final AppWebViewController _controller;

  @override
  bool get requiresWebView => true;

  AppWebViewController get controller => _controller;

  // ─────────────────────────────────────────────────────────────────
  //  STREAM PRINCIPAL
  // ─────────────────────────────────────────────────────────────────
  @override
  Stream<SendEvent> sendMessages({
    required List<Contact> contacts,
    required AppConfig config,
    required List<String> attachments,
    required bool Function() isCancelled,
  }) async* {
    final controller = _controller;
    final rng = math.Random();
    bool firstContact = true;

    // 1 ── abre WhatsApp Web e aguarda login ──────────────────────
    yield SendEventLoginRequired();
    await controller.loadUrl('https://web.whatsapp.com');

    yield SendEventLog(
      'Aguardando WhatsApp Web — escaneie o QR code se necessário…',
      LogType.warning,
    );

    final loggedIn = await _waitForSelector(
      controller,
      _kSelLoginOk,
      const Duration(seconds: 120),
    );

    if (!loggedIn) {
      yield SendEventLog(
        'Timeout no login. Feche e tente novamente.',
        LogType.error,
      );
      yield SendEventFinished(0, 0, 0, '');
      return;
    }

    yield SendEventLoggedIn();
    yield SendEventLog('WhatsApp Web conectado!', LogType.ok);

    // 2 ── loop de envios ──────────────────────────────────────────
    final total = contacts.length;
    final results = <SendResult>[];
    int i = 0;

    for (final contact in contacts) {
      if (isCancelled()) {
        yield SendEventLog('Envio interrompido pelo usuário.', LogType.warning);
        break;
      }

      i++;
      final name = contact.name.trim();
      final phone = contact.phone.trim();

      // Bloco isolado por try-catch — uma falha num contato nunca mata o loop.
      try {
        if (phone.isEmpty) {
          yield SendEventLog(
            '[$i/$total] IGNORADO (sem telefone): ${name.isEmpty ? "-" : name}',
            LogType.warning,
          );
          yield SendEventContactStatus(
            contact.id,
            phone,
            'ignorado',
            'telefone vazio',
          );
          yield SendEventProgress(i, total);
          results.add(
            SendResult(
              name: name,
              originalPhone: phone,
              formattedPhone: '',
              status: 'ignorado',
              detail: 'telefone vazio',
              timestamp: DateTime.now(),
            ),
          );
          continue;
        }

        final template = contact.individualMessage.isNotEmpty
            ? contact.individualMessage
            : config.defaultMessage;
        final message = MessageFormatter.format(template, {
          'nome': name,
          'telefone': phone,
          'name': name,
        });
        final tel = PhoneFormatter.format(phone);

        yield SendEventLog('[$i/$total] $name → $tel', LogType.info);

        // Envia texto ──────────────────────────────────────────────
        final textDbg = <String>[];
        final textResult = await _sendText(
          controller,
          tel,
          message,
          config.pageTimeout,
          firstContact: firstContact,
          debug: textDbg,
        );
        firstContact = false;

        // Exibe debug detalhado no log
        for (final d in textDbg) {
          yield SendEventLog('   [dbg] $d', LogType.info);
        }

        String status = textResult ? 'enviado' : 'erro';
        String detail = textResult ? 'texto enviado' : 'falha ao enviar texto';

        if (textResult) {
          yield SendEventLog('   Texto enviado.', LogType.ok);
        } else {
          yield SendEventLog('   FALHA ao enviar texto.', LogType.error);
        }

        // Envia arquivos ───────────────────────────────────────────
        if (textResult && attachments.isNotEmpty) {
          for (int j = 0; j < attachments.length; j++) {
            if (isCancelled()) break;
            final arq = attachments[j];
            if (!File(arq).existsSync()) {
              yield SendEventLog(
                '   Arquivo ${j + 1} não encontrado: ${p.basename(arq)}',
                LogType.warning,
              );
              continue;
            }
            final fileDbg = <String>[];
            final fileOk = await _sendFile(controller, arq, config.pageTimeout,
                debug: fileDbg);
            for (final d in fileDbg) {
              yield SendEventLog('   [dbg] $d', LogType.info);
            }
            if (fileOk) {
              yield SendEventLog(
                '   Arquivo ${j + 1} (${p.basename(arq)}) enviado.',
                LogType.ok,
              );
              detail += ' | arq${j + 1} ok';
            } else {
              yield SendEventLog(
                '   Arquivo ${j + 1} (${p.basename(arq)}) FALHOU.',
                LogType.warning,
              );
              detail += ' | arq${j + 1} falhou';
            }
          }
        }

        results.add(
          SendResult(
            name: name,
            originalPhone: phone,
            formattedPhone: tel,
            status: status,
            detail: detail,
            timestamp: DateTime.now(),
          ),
        );
        yield SendEventContactStatus(contact.id, phone, status, detail);
        yield SendEventProgress(i, total);

        // Intervalo anti-bloqueio ──────────────────────────────────
        if (i < total && !isCancelled()) {
          final delay = config.intervalMin +
              rng.nextInt(
                (config.intervalMax - config.intervalMin).clamp(1, 999) + 1,
              );
          yield SendEventLog('   Aguardando ${delay}s…', LogType.info);
          await Future.delayed(Duration(seconds: delay));
        }
      } catch (e) {
        // Exceção inesperada neste contato — loga e continua para o próximo.
        yield SendEventLog(
          '[$i/$total] ERRO INESPERADO ($name): $e',
          LogType.error,
        );
        results.add(
          SendResult(
            name: name,
            originalPhone: phone,
            formattedPhone: '',
            status: 'erro',
            detail: 'exceção: $e',
            timestamp: DateTime.now(),
          ),
        );
        yield SendEventContactStatus(
          contact.id,
          phone,
          'erro',
          'exceção: $e',
        );
        yield SendEventProgress(i, total);
      }
    }

    // 3 ── salva log ───────────────────────────────────────────────
    final logPath = await _saveLog(results);

    final sent = results.where((r) => r.status == 'enviado').length;
    final errors = results.where((r) => r.status == 'erro').length;
    final ignored = results.where((r) => r.status == 'ignorado').length;

    yield SendEventLog('═' * 46, LogType.info);
    yield SendEventLog('Enviados:  $sent', LogType.ok);
    if (errors > 0) yield SendEventLog('Erros:     $errors', LogType.error);
    if (ignored > 0) yield SendEventLog('Ignorados: $ignored', LogType.warning);
    yield SendEventLog('Log salvo: $logPath', LogType.info);

    yield SendEventFinished(sent, errors, ignored, logPath);
  }

  // ─────────────────────────────────────────────────────────────────
  //  ENVIAR TEXTO
  // ─────────────────────────────────────────────────────────────────
  Future<bool> _sendText(
    AppWebViewController ctrl,
    String tel,
    String message,
    int timeout, {
    bool firstContact = true,
    List<String>? debug,
  }) async {
    void log(String s) => debug?.add(s);

    try {
      // 1. Navega até o chat.
      //    — Primeiro contato: URL (precisa de carregamento completo).
      //    — Demais: barra de pesquisa interna do WA Web (SPA, instantâneo).
      if (firstContact) {
        log('Navegação inicial via loadUrl');
        await ctrl.loadUrl('https://web.whatsapp.com/send?phone=$tel');
      } else {
        log('Navegação via search bar (SPA)');
        final navOk = await _navigateViaSearch(ctrl, tel, debug: debug);
        if (!navOk) {
          log('Search falhou, fallback via URL');
          await ctrl.executeJavaScript(
            'window.location.href = ${jsonEncode('https://web.whatsapp.com/send?phone=$tel')};',
          );
        }
      }

      // 2. Polling para caixa de mensagem + popup de erro.
      log('Aguardando caixa de msgs (timeout: ${timeout}s)…');
      final msgBoxReady = await _waitForMsgBoxOrError(
        ctrl,
        Duration(seconds: timeout),
        debug: debug,
      );

      if (msgBoxReady == _NavResult.errorPopup) {
        log('Número inválido — popup detectado');
        return false;
      }
      if (msgBoxReady == _NavResult.timeout) {
        log('Timeout — caixa de msgs não apareceu');
        return false;
      }
      log('Caixa de msgs encontrada');

      // 3. Injeta o texto via execCommand (compatível com React/Lexical).
      final injected = await ctrl.executeJavaScript('''
        (function(msg) {
          var sels = [
            'div[contenteditable="true"][data-tab="10"]',
            'div[contenteditable="true"][aria-label*="mensagem"]',
            'div[contenteditable="true"][aria-label*="message"]',
            'footer div[contenteditable="true"]'
          ];
          for (var s of sels) {
            var el = document.querySelector(s);
            if (el) {
              el.focus();
              document.execCommand('selectAll', false, null);
              document.execCommand('delete', false, null);
              document.execCommand('insertText', false, msg);
              el.dispatchEvent(new Event('input', {bubbles: true}));
              return el.textContent.trim().length > 0 ? 'ok' : 'empty';
            }
          }
          return 'no_box';
        })(${jsonEncode(message)})
      ''');
      log('Injeção de texto: $injected');
      if (injected != 'ok') return false;

      await Future.delayed(const Duration(milliseconds: 500));

      // 4. Envia a mensagem (botão enviar → fallback Enter)
      final sent = await _clickSendButton(ctrl, debug: debug);
      if (!sent) {
        log('FALHA: nenhum método de envio funcionou');
        return false;
      }

      log('Mensagem enviada ✓');
      await Future.delayed(const Duration(seconds: 1));
      return true;
    } catch (e) {
      log('Exceção: $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────
  //  NAVEGAÇÃO RÁPIDA VIA SEARCH BAR (SPA — sem reload)
  // ─────────────────────────────────────────────────────────────────

  /// Usa a barra de pesquisa do WhatsApp Web para navegar até o contato
  /// sem recarregar a página inteira. Retorna `true` se conseguiu abrir o chat.
  Future<bool> _navigateViaSearch(
    AppWebViewController ctrl,
    String tel, {
    List<String>? debug,
  }) async {
    void log(String s) => debug?.add(s);

    try {
      // 1. Fecha qualquer modal/search aberta e volta para a lista de conversas
      await ctrl.executeJavaScript('''
        (function() {
          var esc = new KeyboardEvent('keydown', {key:'Escape', code:'Escape', keyCode:27, bubbles:true});
          document.dispatchEvent(esc);
        })()
      ''');
      await Future.delayed(const Duration(milliseconds: 200));

      // 2. Abre "Novo Chat" ou clica no ícone de pesquisa
      final searchOpened = await ctrl.executeJavaScript('''
        (function() {
          var sels = [
            'span[data-icon="new-chat-outline"]',
            'span[data-icon="search"]',
            '[data-testid="chat-list-search"]',
            'div[contenteditable="true"][data-tab="3"]'
          ];
          for (var sel of sels) {
            var el = document.querySelector(sel);
            if (el) {
              if (el.contentEditable === 'true') {
                el.focus();
                return 'search_box_direct';
              }
              var btn = el.closest('button, div[role="button"]');
              if (btn) btn.click(); else el.click();
              return 'opened:' + sel;
            }
          }
          return 'not_found';
        })()
      ''');
      log('Search open: $searchOpened');
      if (searchOpened == 'not_found') return false;

      await Future.delayed(const Duration(milliseconds: 400));

      // 3. Encontra a caixa de pesquisa e digita o telefone
      final typed = await ctrl.executeJavaScript('''
        (function(phone) {
          var sels = [
            'div[contenteditable="true"][data-tab="3"]',
            'div[contenteditable="true"][aria-label*="Pesquisar"]',
            'div[contenteditable="true"][aria-label*="Search"]',
            '[data-testid="chat-list-search"] div[contenteditable="true"]'
          ];
          for (var s of sels) {
            var el = document.querySelector(s);
            if (el) {
              el.focus();
              document.execCommand('selectAll', false, null);
              document.execCommand('delete', false, null);
              document.execCommand('insertText', false, phone);
              el.dispatchEvent(new Event('input', {bubbles: true}));
              return 'typed';
            }
          }
          return 'no_search_box';
        })(${jsonEncode(tel)})
      ''');
      log('Digitou tel: $typed');
      if (typed != 'typed') return false;

      // 4. Aguarda resultados aparecerem (até 3s)
      await Future.delayed(const Duration(milliseconds: 1200));

      // 5. Clica no primeiro resultado da pesquisa
      final clicked = await ctrl.executeJavaScript('''
        (function() {
          // Resultados da busca no painel de novo chat / lista lateral
          var resultSels = [
            '[data-testid="cell-frame-container"]',
            '[data-testid="chat-list-item"]',
            '[data-testid="search-result"]',
            '#pane-side [role="listitem"]',
            '#pane-side [role="row"]'
          ];
          for (var sel of resultSels) {
            var items = document.querySelectorAll(sel);
            if (items.length > 0) {
              items[0].click();
              return 'clicked:' + sel + ':' + items.length;
            }
          }

          // Fallback: link "Enviar mensagem para +XX" que aparece para
          // números que não estão nos contatos.
          var allSpans = document.querySelectorAll('span[title]');
          for (var sp of allSpans) {
            var t = sp.title || sp.textContent || '';
            if (t.includes('+') || t.includes('mensagem') || t.includes('message')) {
              sp.closest('[role="listitem"], [role="row"], [role="button"]')?.click();
              return 'span_fallback:' + t.substring(0, 40);
            }
          }
          return 'no_result';
        })()
      ''');
      log('Clique resultado: $clicked');

      // Considera sucesso se clicou em algo; o polling do message box
      // no _sendText vai confirmar se o chat realmente abriu.
      return clicked != 'no_result';
    } catch (e) {
      log('Search error: $e');
      return false;
    }
  }

  /// Resultado da navegação até o chat.
  static const _NavResult = (ok: 0, errorPopup: 1, timeout: 2);

  /// Faz polling simultâneo da caixa de mensagem e do popup de erro.
  Future<int> _waitForMsgBoxOrError(
    AppWebViewController ctrl,
    Duration timeout, {
    List<String>? debug,
  }) async {
    final end = DateTime.now().add(timeout);
    int attempts = 0;
    while (DateTime.now().isBefore(end)) {
      attempts++;
      try {
        // Verifica popup de erro (número inválido)
        final result = await ctrl.executeJavaScript('''
          (function() {
            var popup = document.querySelector('[data-animate-modal-popup="true"]')
                     || document.querySelector('div[role="alert"]');
            if (popup) {
              var t = popup.textContent.toLowerCase();
              if (t.includes('invalid') || t.includes('inválid') ||
                  t.includes('phone number') || t.includes('número')) return 'error';
            }
            var sels = [
              'div[contenteditable="true"][data-tab="10"]',
              'div[contenteditable="true"][aria-label*="mensagem"]',
              'div[contenteditable="true"][aria-label*="message"]',
              'footer div[contenteditable="true"]'
            ];
            for (var s of sels) {
              if (document.querySelector(s)) return 'ready';
            }
            return 'waiting';
          })()
        ''');
        if (result == 'error') return _NavResult.errorPopup;
        if (result == 'ready') return _NavResult.ok;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 400));
    }
    debug?.add('waitForMsgBox: $attempts tentativas, timeout');
    return _NavResult.timeout;
  }

  /// Tenta clicar no botão de enviar de múltiplas formas.
  Future<bool> _clickSendButton(
    AppWebViewController ctrl, {
    List<String>? debug,
  }) async {
    void log(String s) => debug?.add(s);

    // Abordagem 1: encontra o ícone de envio e clica no botão pai
    final btnResult = await ctrl.executeJavaScript('''
      (function() {
        var icons = [
          'span[data-icon="send"]',
          '[data-testid="send"]',
          'span[data-icon="compose-btn-send"]'
        ];
        for (var sel of icons) {
          var icon = document.querySelector(sel);
          if (icon) {
            // Sobe na árvore DOM para achar o <button> ou [role=button]
            var btn = icon.closest('button, [role="button"]');
            if (btn) { btn.click(); return 'btn_click:' + sel; }
            // Fallback: clica no próprio ícone
            icon.click();
            return 'icon_click:' + sel;
          }
        }

        // Tenta labels (PT/EN)
        var labels = ['Enviar', 'Send'];
        for (var lbl of labels) {
          var el = document.querySelector('div[aria-label="' + lbl + '"]')
                || document.querySelector('button[aria-label="' + lbl + '"]');
          if (el) { el.click(); return 'label_click:' + lbl; }
        }
        return 'not_found';
      })()
    ''');
    log('Botão enviar: $btnResult');

    if (btnResult != 'not_found') {
      await Future.delayed(const Duration(milliseconds: 800));
      return true;
    }

    // Abordagem 2: tecla Enter no campo de texto
    log('Tentando Enter no campo de texto');
    final enterOk = await ctrl.executeJavaScript('''
      (function() {
        var sels = [
          'div[contenteditable="true"][data-tab="10"]',
          'footer div[contenteditable="true"]'
        ];
        for (var s of sels) {
          var el = document.querySelector(s);
          if (el) {
            el.focus();
            var opts = {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true};
            el.dispatchEvent(new KeyboardEvent('keydown', opts));
            return 'enter_ok';
          }
        }
        return 'no_box';
      })()
    ''');
    log('Resultado Enter: $enterOk');

    if (enterOk == 'enter_ok') {
      await Future.delayed(const Duration(milliseconds: 800));
      return true;
    }

    return false;
  }

  Future<bool> _sendFile(
    AppWebViewController ctrl,
    String filePath,
    int timeout, {
    List<String>? debug,
  }) async {
    void log(String s) => debug?.add(s);

    try {
      return await Future(() async {
        final file = File(filePath);
        if (!await file.exists()) {
          log('Arquivo não encontrado: $filePath');
          return false;
        }

        final bytes = await file.readAsBytes();
        final b64 = base64Encode(bytes);
        final fileName = p.basename(filePath);
        final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';
        log('Arquivo: $fileName (${bytes.length} bytes, $mimeType)');

        // ── Método 1: ClipboardEvent paste ────────────────────────
        log('Tentando método 1 (paste)…');
        final pasteResult = await ctrl.executeJavaScript('''
          (function(b64, name, mime) {
            try {
              var binary = atob(b64);
              var buf    = new Uint8Array(binary.length);
              for (var i = 0; i < binary.length; i++) buf[i] = binary.charCodeAt(i);
              var f  = new File([buf], name, {type: mime, lastModified: Date.now()});
              var dt = new DataTransfer();
              dt.items.add(f);
              var sels = [
                'div[contenteditable="true"][data-tab="10"]',
                'footer div[contenteditable="true"]'
              ];
              for (var s of sels) {
                var el = document.querySelector(s);
                if (el) {
                  el.focus();
                  el.dispatchEvent(new ClipboardEvent('paste', {
                    bubbles: true, cancelable: true, clipboardData: dt
                  }));
                  return 'paste_ok';
                }
              }
              return 'no_box';
            } catch(e) { return 'paste_err:' + e.message; }
          })(${jsonEncode(b64)}, ${jsonEncode(fileName)}, ${jsonEncode(mimeType)})
        ''');
        log('Paste result: $pasteResult');

        if (pasteResult == 'paste_ok') {
          await Future.delayed(const Duration(seconds: 2));
          final sendOk = await _clickFilePreviewSend(ctrl, debug: debug);
          if (sendOk) return true;
          log('Modal de preview não encontrado após paste');
        }

        // ── Método 2: DragEvent drop ──────────────────────────────
        log('Tentando método 2 (drop)…');
        final dropResult = await ctrl.executeJavaScript('''
          (function(b64, name, mime) {
            try {
              var binary = atob(b64);
              var buf    = new Uint8Array(binary.length);
              for (var i = 0; i < binary.length; i++) buf[i] = binary.charCodeAt(i);
              var f  = new File([buf], name, {type: mime, lastModified: Date.now()});
              var dt = new DataTransfer();
              dt.items.add(f);
              var targets = [
                '#main footer',
                '#main',
                '[data-testid="conversation-panel-body"]'
              ];
              for (var t of targets) {
                var el = document.querySelector(t);
                if (el) {
                  el.dispatchEvent(new DragEvent('dragenter', {bubbles: true, dataTransfer: dt}));
                  el.dispatchEvent(new DragEvent('dragover',  {bubbles: true, dataTransfer: dt}));
                  el.dispatchEvent(new DragEvent('drop',      {bubbles: true, cancelable: true, dataTransfer: dt}));
                  return 'drop_ok';
                }
              }
              return 'no_target';
            } catch(e) { return 'drop_err:' + e.message; }
          })(${jsonEncode(b64)}, ${jsonEncode(fileName)}, ${jsonEncode(mimeType)})
        ''');
        log('Drop result: $dropResult');

        if (dropResult == 'drop_ok') {
          await Future.delayed(const Duration(seconds: 2));
          final sendOk = await _clickFilePreviewSend(ctrl, debug: debug);
          if (sendOk) return true;
          log('Modal de preview não encontrado após drop');
        }

        log('Ambos os métodos falharam');
        return false;
      }).timeout(
        Duration(seconds: timeout > 0 ? timeout : 20),
        onTimeout: () {
          log('TIMEOUT global ao enviar arquivo');
          return false;
        },
      );
    } catch (e) {
      log('Exceção: $e');
      return false;
    }
  }

  /// Clica no botão de envio dentro do modal de preview de arquivo/mídia.
  Future<bool> _clickFilePreviewSend(
    AppWebViewController ctrl, {
    List<String>? debug,
  }) async {
    void log(String s) => debug?.add(s);

    const previewSendSels = [
      'div[data-testid="media-upload-send-btn"]',
      'span[data-icon="send-white"]',
      'span[data-icon="send"]',
    ];
    // Aguarda o modal de preview aparecer (até 5s)
    final previewFound = await _waitForSelector(
      ctrl,
      previewSendSels.join(', '),
      const Duration(seconds: 5),
    );
    log('Preview modal: ${previewFound ? "encontrado" : "não encontrado"}');
    if (!previewFound) return false;

    // Tenta clicar no botão (busca o parent button)
    final clickResult = await ctrl.executeJavaScript('''
      (function() {
        var sels = [
          'div[data-testid="media-upload-send-btn"]',
          'span[data-icon="send-white"]',
          'span[data-icon="send"]'
        ];
        for (var sel of sels) {
          var el = document.querySelector(sel);
          if (el) {
            var btn = el.closest('button, [role="button"]');
            if (btn) { btn.click(); return 'btn_click:' + sel; }
            el.click();
            return 'icon_click:' + sel;
          }
        }
        return 'not_found';
      })()
    ''');
    log('Clique preview enviar: $clickResult');

    if (clickResult != 'not_found') {
      await Future.delayed(const Duration(seconds: 3));
      return true;
    }
    return false;
  }

  // ─────────────────────────────────────────────────────────────────
  //  HELPERS
  // ─────────────────────────────────────────────────────────────────

  /// Faz polling de um seletor CSS até aparecer ou timeout.
  Future<bool> _waitForSelector(
    AppWebViewController ctrl,
    String selector,
    Duration timeout,
  ) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      try {
        final r = await ctrl.executeJavaScript(
          'Boolean(document.querySelector(${jsonEncode(selector)}))',
        );
        if (r == 'true') return true;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  /// Salva o log de envios em JSON no diretório de suporte da app.
  Future<String> _saveLog(List<SendResult> results) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .replaceAll('T', '_')
          .substring(0, 15);
      final file = File('${dir.path}/log_$ts.json');
      await file.writeAsString(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(results.map((r) => r.toJson()).toList()),
      );
      return file.path;
    } catch (_) {
      return '';
    }
  }
}
