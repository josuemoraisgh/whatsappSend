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
          // Filtra apenas arquivos que existem
          final validFiles = <String>[];
          for (int j = 0; j < attachments.length; j++) {
            final arq = attachments[j];
            if (File(arq).existsSync()) {
              validFiles.add(arq);
            } else {
              yield SendEventLog(
                '   Arquivo ${j + 1} não encontrado: ${p.basename(arq)}',
                LogType.warning,
              );
            }
          }
          if (validFiles.isNotEmpty) {
            yield SendEventLog(
              '   Anexando ${validFiles.length} arquivo(s) de uma vez…',
              LogType.info,
            );
            final fileDbg = <String>[];
            final fileOk = await _sendFiles(
              controller,
              validFiles,
              config.pageTimeout,
              debug: fileDbg,
            );
            for (final d in fileDbg) {
              yield SendEventLog('   [dbg] $d', LogType.info);
            }
            if (fileOk) {
              yield SendEventLog(
                '   ${validFiles.length} arquivo(s) enviado(s).',
                LogType.ok,
              );
              detail += ' | ${validFiles.length} arq(s) ok';
            } else {
              yield SendEventLog(
                '   FALHA ao enviar arquivo(s).',
                LogType.warning,
              );
              detail += ' | arqs falhou';
            }
          }
        } else if (textResult && attachments.isEmpty) {
          yield SendEventLog(
            '   Nenhum arquivo anexado.',
            LogType.info,
          );
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
        } else {
          // SPA: aguarda transição de chat antes de prosseguir
          log('Aguardando transição SPA…');
          await Future.delayed(const Duration(milliseconds: 500));
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

      // Aguarda Lexical editor inicializar completamente
      await Future.delayed(const Duration(milliseconds: 300));

      // 3. Injeta texto via múltiplos métodos (com verificação assíncrona).
      log('Mensagem (${message.length} chars): "${message.length > 50 ? '${message.substring(0, 50)}…' : message}"');
      final textOk = await _injectText(ctrl, message, debug: debug);
      if (!textOk) {
        log('FALHA: nenhum método de injeção funcionou');
        return false;
      }

      await Future.delayed(const Duration(milliseconds: 150));

      // 4. Envia a mensagem (botão enviar → fallback Enter)
      final sent = await _clickSendButton(ctrl, debug: debug);
      if (!sent) {
        log('FALHA: nenhum método de envio funcionou');
        return false;
      }

      log('Mensagem enviada ✓');
      await Future.delayed(const Duration(milliseconds: 400));
      return true;
    } catch (e) {
      log('Exceção: $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────
  //  INJEÇÃO DE TEXTO — múltiplos métodos
  // ─────────────────────────────────────────────────────────────────

  /// Tenta inserir texto na caixa de mensagem usando 4 métodos distintos.
  /// Cada método aguarda o React/Lexical processar antes de verificar.
  Future<bool> _injectText(
    AppWebViewController ctrl,
    String message, {
    List<String>? debug,
  }) async {
    void log(String s) => debug?.add(s);
    final msgJson = jsonEncode(message);

    /// Verifica se a caixa de mensagem contém texto.
    Future<String> checkText() async {
      return await ctrl.executeJavaScript('''
        (function() {
          var sels = [
            'div[contenteditable="true"][data-tab="10"]',
            'div[contenteditable="true"][aria-label*="mensagem"]',
            'div[contenteditable="true"][aria-label*="message"]',
            'footer div[contenteditable="true"]'
          ];
          for (var s of sels) {
            var el = document.querySelector(s);
            if (el) {
              var t = el.textContent.trim();
              if (t.length > 0) return 'has_text:' + t.length;
              return 'empty:html=' + el.innerHTML.substring(0, 100);
            }
          }
          return 'no_box';
        })()
      ''');
    }

    // ─── M1: insertText SEM limpar (preserva estrutura Lexical) ───
    log('M1: insertText sem limpeza');
    await ctrl.executeJavaScript('''
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
            document.execCommand('insertText', false, msg);
            el.dispatchEvent(new Event('input', {bubbles: true}));
            return 'done:' + s;
          }
        }
        return 'no_box';
      })($msgJson)
    ''');
    await Future.delayed(const Duration(milliseconds: 200));
    var check = await checkText();
    log('M1 verify: $check');
    if (check.startsWith('has_text')) return true;

    // ─── M2: selectAllChildren + delete + insertText ───
    log('M2: selectAllChildren + delete + insertText');
    await ctrl.executeJavaScript('''
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
            var sel = window.getSelection();
            sel.selectAllChildren(el);
            document.execCommand('delete', false, null);
            document.execCommand('insertText', false, msg);
            el.dispatchEvent(new Event('input', {bubbles: true}));
            return 'done:' + s;
          }
        }
        return 'no_box';
      })($msgJson)
    ''');
    await Future.delayed(const Duration(milliseconds: 200));
    check = await checkText();
    log('M2 verify: $check');
    if (check.startsWith('has_text')) return true;

    // ─── M3: InputEvent beforeinput (Lexical nativo) ───
    log('M3: InputEvent beforeinput');
    await ctrl.executeJavaScript('''
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
            el.textContent = '';
            el.dispatchEvent(new InputEvent('beforeinput', {
              inputType: 'insertText', data: msg,
              bubbles: true, cancelable: true, composed: true
            }));
            el.dispatchEvent(new InputEvent('input', {
              inputType: 'insertText', data: msg,
              bubbles: true, composed: true
            }));
            return 'done:' + s;
          }
        }
        return 'no_box';
      })($msgJson)
    ''');
    await Future.delayed(const Duration(milliseconds: 200));
    check = await checkText();
    log('M3 verify: $check');
    if (check.startsWith('has_text')) return true;

    // ─── M4: ClipboardEvent paste ───
    log('M4: ClipboardEvent paste');
    await ctrl.executeJavaScript('''
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
            try {
              var dt = new DataTransfer();
              dt.setData('text/plain', msg);
              el.dispatchEvent(new ClipboardEvent('paste', {
                clipboardData: dt, bubbles: true, cancelable: true
              }));
            } catch(e) { return 'paste_err:' + e.message; }
            return 'done:' + s;
          }
        }
        return 'no_box';
      })($msgJson)
    ''');
    await Future.delayed(const Duration(milliseconds: 200));
    check = await checkText();
    log('M4 verify: $check');
    if (check.startsWith('has_text')) return true;

    return false;
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
      await Future.delayed(const Duration(milliseconds: 600));

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
      await Future.delayed(const Duration(milliseconds: 400));
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
      await Future.delayed(const Duration(milliseconds: 400));
      return true;
    }

    return false;
  }

  /// Envia múltiplos arquivos de uma vez no mesmo DataTransfer.
  /// Abre o menu de anexo → Documento → injeta todos os arquivos → Send.
  Future<bool> _sendFiles(
    AppWebViewController ctrl,
    List<String> filePaths,
    int timeout, {
    List<String>? debug,
  }) async {
    void log(String s) => debug?.add(s);

    try {
      return await Future(() async {
        // ── Prepara os arquivos em base64 ──
        final filesData = <Map<String, String>>[];
        for (final fp in filePaths) {
          final file = File(fp);
          if (!await file.exists()) {
            log('Arquivo não encontrado: $fp');
            continue;
          }
          final bytes = await file.readAsBytes();
          final b64 = base64Encode(bytes);
          final fileName = p.basename(fp);
          final mimeType = lookupMimeType(fp) ?? 'application/octet-stream';
          filesData.add({'b64': b64, 'name': fileName, 'mime': mimeType});
          log('Preparado: $fileName (${bytes.length} bytes, $mimeType)');
        }
        if (filesData.isEmpty) {
          log('Nenhum arquivo válido para enviar');
          return false;
        }
        log('${filesData.length} arquivo(s) preparados');

        // ── Passo 1: Instala interceptor + MutationObserver ──
        log('Instalando interceptor…');
        await ctrl.executeJavaScript('''
          (function() {
            window.__waFileCtx = {
              inp: null,
              orig: HTMLInputElement.prototype.click,
              observer: null
            };
            HTMLInputElement.prototype.click = function() {
              if (this.type === 'file') {
                window.__waFileCtx.inp = this;
                return;
              }
              window.__waFileCtx.orig.call(this);
            };
            window.__waFileCtx.observer = new MutationObserver(function(mutations) {
              for (var m of mutations) {
                for (var n of m.addedNodes) {
                  if (n.tagName === 'INPUT' && n.type === 'file') {
                    window.__waFileCtx.inp = n;
                  }
                  if (n.querySelectorAll) {
                    var inps = n.querySelectorAll('input[type="file"]');
                    if (inps.length) window.__waFileCtx.inp = inps[inps.length-1];
                  }
                }
              }
            });
            window.__waFileCtx.observer.observe(document.body, {childList:true, subtree:true});
            return 'ok';
          })()
        ''');

        // ── Passo 2: Abre menu de anexo (+) ──
        final attachResult = await ctrl.executeJavaScript('''
          (function() {
            var sels = [
              'span[data-icon="attach-menu-plus"]',
              'span[data-icon="plus"]',
              'span[data-icon="clip"]',
              '[data-testid="attach-menu-plus"]',
              'div[title="Attach"]',
              'div[title="Anexar"]',
              'button[aria-label="Attach"]',
              'button[aria-label="Anexar"]'
            ];
            for (var sel of sels) {
              var el = document.querySelector(sel);
              if (el) {
                var btn = el.closest('button, div[role="button"], [role="listitem"]');
                if (btn) btn.click(); else el.click();
                return 'attach:' + sel;
              }
            }
            var allBtns = document.querySelectorAll('button, div[role="button"]');
            for (var b of allBtns) {
              var l = (b.getAttribute('aria-label') || '').toLowerCase();
              if (l.includes('attach') || l.includes('anexar') || l.includes('adjuntar')) {
                b.click();
                return 'aria_fallback:' + l.substring(0, 30);
              }
            }
            return 'no_attach';
          })()
        ''');
        log('Menu anexo: $attachResult');

        if (attachResult == 'no_attach') {
          log('Botão de anexo não encontrado');
          await _cleanupFileInterceptor(ctrl);
          return false;
        }

        await Future.delayed(const Duration(milliseconds: 500));

        // ── Passo 3: Clica na opção "Documento" ──
        final docResult = await ctrl.executeJavaScript('''
          (function() {
            var sels = [
              'span[data-icon="attach-document"]',
              '[data-testid="mi-attach-document"]',
              'button[aria-label="Documento"]',
              'button[aria-label="Document"]',
              'li[data-testid="mi-attach-document"]'
            ];
            for (var sel of sels) {
              var el = document.querySelector(sel);
              if (el) {
                var btn = el.closest('button, li, div[role="button"]');
                if (btn) btn.click(); else el.click();
                return 'doc:' + sel;
              }
            }
            var menu = document.querySelector('[data-animate-dropdown-item="true"]')
                    || document.querySelector('ul[role="list"]')
                    || document.querySelector('div[tabindex="-1"] ul');
            if (menu) {
              var items = menu.querySelectorAll('li, button, div[role="button"]');
              if (items.length > 0) {
                items[0].click();
                return 'menu_first_item:' + items.length;
              }
            }
            return 'no_doc';
          })()
        ''');
        log('Opção documento: $docResult');

        await Future.delayed(const Duration(milliseconds: 400));

        // ── Passo 4: Injeta TODOS os arquivos no mesmo input via DataTransfer ──
        final filesJson = jsonEncode(
          filesData
              .map((f) =>
                  {'b64': f['b64'], 'name': f['name'], 'mime': f['mime']})
              .toList(),
        );
        final setResult = await ctrl.executeJavaScript('''
          (function(filesArr) {
            // Cleanup interceptor
            if (window.__waFileCtx && window.__waFileCtx.observer) {
              window.__waFileCtx.observer.disconnect();
            }
            if (window.__waFileCtx && window.__waFileCtx.orig) {
              HTMLInputElement.prototype.click = window.__waFileCtx.orig;
            }

            var input = window.__waFileCtx ? window.__waFileCtx.inp : null;
            if (!input) {
              var inputs = document.querySelectorAll('input[type="file"]');
              if (inputs.length > 0) input = inputs[inputs.length - 1];
            }
            delete window.__waFileCtx;

            if (!input) return 'no_input:total=' + document.querySelectorAll('input[type="file"]').length;

            try {
              var dt = new DataTransfer();
              for (var fd of filesArr) {
                var binary = atob(fd.b64);
                var buf = new Uint8Array(binary.length);
                for (var i = 0; i < binary.length; i++) buf[i] = binary.charCodeAt(i);
                var f = new File([buf], fd.name, {type: fd.mime, lastModified: Date.now()});
                dt.items.add(f);
              }

              // Atribui todos os arquivos de uma vez
              input.files = dt.files;

              // React _valueTracker reset
              var tracker = input._valueTracker;
              if (tracker) { tracker.setValue(''); }

              // Eventos React-compatíveis
              input.dispatchEvent(new Event('input', {bubbles: true}));
              input.dispatchEvent(new Event('change', {bubbles: true}));

              var names = [];
              for (var i = 0; i < input.files.length; i++) {
                names.push(input.files[i].name);
              }
              return 'files_set:count=' + input.files.length + ',names=' + names.join(';');
            } catch(e) { return 'set_err:' + e.message; }
          })($filesJson)
        ''');
        log('Set files: $setResult');

        if (!setResult.startsWith('files_set')) {
          // Fallback: busca diretamente o input
          log('Fallback: injeção direta…');
          final fallbackResult = await ctrl.executeJavaScript('''
            (function(filesArr) {
              var inputs = document.querySelectorAll('input[type="file"]');
              if (inputs.length === 0) return 'no_inputs';
              var input = inputs[inputs.length - 1];
              try {
                var dt = new DataTransfer();
                for (var fd of filesArr) {
                  var binary = atob(fd.b64);
                  var buf = new Uint8Array(binary.length);
                  for (var i = 0; i < binary.length; i++) buf[i] = binary.charCodeAt(i);
                  var f = new File([buf], fd.name, {type: fd.mime, lastModified: Date.now()});
                  dt.items.add(f);
                }
                input.files = dt.files;
                var tracker = input._valueTracker;
                if (tracker) tracker.setValue('');
                input.dispatchEvent(new Event('input', {bubbles: true}));
                input.dispatchEvent(new Event('change', {bubbles: true}));
                return 'fallback_ok:' + input.files.length;
              } catch(e) { return 'fallback_err:' + e.message; }
            })($filesJson)
          ''');
          log('Fallback: $fallbackResult');
          if (!fallbackResult.startsWith('fallback_ok')) return false;
        }

        // ── Passo 5: Aguarda preview modal e clica em enviar ──
        log('Aguardando preview modal…');
        await Future.delayed(const Duration(milliseconds: 800));
        final sendOk = await _clickFilePreviewSend(ctrl, debug: debug);
        log('Preview send: ${sendOk ? "ok" : "falhou"}');

        if (!sendOk) {
          final pageDebug = await ctrl.executeJavaScript('''
            (function() {
              var sendBtns = document.querySelectorAll(
                '[data-testid="media-upload-send-btn"], span[data-icon="send"], span[data-icon="send-white"]'
              );
              var modals = document.querySelectorAll('[data-animate-modal-body="true"], [role="dialog"]');
              return 'sendBtns=' + sendBtns.length + ',modals=' + modals.length;
            })()
          ''');
          log('Page debug: $pageDebug');
        }

        return sendOk;
      }).timeout(
        Duration(seconds: timeout > 0 ? timeout : 60),
        onTimeout: () {
          log('TIMEOUT global ao enviar arquivos');
          _cleanupFileInterceptor(ctrl);
          return false;
        },
      );
    } catch (e) {
      log('Exceção: $e');
      await _cleanupFileInterceptor(ctrl);
      return false;
    }
  }

  /// Restaura HTMLInputElement.prototype.click caso o interceptor ainda exista.
  Future<void> _cleanupFileInterceptor(AppWebViewController ctrl) async {
    try {
      await ctrl.executeJavaScript('''
        if (window.__waFileCtx) {
          if (window.__waFileCtx.observer) window.__waFileCtx.observer.disconnect();
          HTMLInputElement.prototype.click = window.__waFileCtx.orig;
          delete window.__waFileCtx;
        }
      ''');
    } catch (_) {}
  }

  /// Clica no botão de envio dentro do modal de preview de arquivo/mídia.
  Future<bool> _clickFilePreviewSend(
    AppWebViewController ctrl, {
    List<String>? debug,
  }) async {
    void log(String s) => debug?.add(s);

    // ── 1: Aguarda o overlay/modal de preview (até 12s, polling 500ms) ──
    // O preview de arquivo aparece como um overlay que NÃO está dentro do footer.
    String modalInfo = 'none';
    final end = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(end)) {
      try {
        modalInfo = await ctrl.executeJavaScript('''
          (function(){
            // O preview de documentos tem um botão com data-testid específico
            var uploadBtn = document.querySelector('[data-testid="media-upload-send-btn"]');
            if (uploadBtn) return 'upload_btn';

            // Preview modal: overlay que contém itens de mídia/documento
            // Típico: div que tem "send" icon mas NÃO está dentro de footer
            var sendIcons = document.querySelectorAll('span[data-icon*="send"]');
            for (var s of sendIcons) {
              if (!s.closest('footer')) return 'send_icon_outside_footer:' + s.getAttribute('data-icon');
            }

            // Modal genérico com role=dialog ou data-animate-modal
            var modal = document.querySelector('[data-animate-modal-body="true"]')
                     || document.querySelector('[role="dialog"]');
            if (modal) return 'modal_found';

            // Procura pelo painel de preview de documento (caption input area)
            var captionBox = document.querySelector('div[contenteditable="true"][data-tab="input-caption"]')
                          || document.querySelector('div[contenteditable="true"]:not([data-tab="10"])');
            if (captionBox && !captionBox.closest('footer')) return 'caption_box';

            return 'waiting';
          })()
        ''');
        if (modalInfo != 'waiting') break;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
    log('Preview detect: $modalInfo');

    if (modalInfo == 'waiting') {
      // Diagnóstico: listar todos os data-icon e overlays
      final diag = await ctrl.executeJavaScript('''
        (function() {
          var icons = [];
          document.querySelectorAll('span[data-icon]').forEach(function(s) {
            var inFooter = s.closest('footer') ? 'F' : 'O';
            icons.push(inFooter + ':' + s.getAttribute('data-icon'));
          });
          return icons.join(',').substring(0, 400);
        })()
      ''');
      log('Diag icons: $diag');
      return false;
    }

    // Espera extra para o modal renderizar completamente
    await Future.delayed(const Duration(milliseconds: 500));

    // ── 2: Dump completo do DOM do modal para diagnóstico ──
    final domDump = await ctrl.executeJavaScript('''
      (function(){
        var info = [];

        // Todos os botões/roles fora do footer
        var allBtns = document.querySelectorAll('button, [role="button"], div[tabindex="0"]');
        for (var b of allBtns) {
          if (b.closest('footer')) continue;
          var icon = b.querySelector('span[data-icon]');
          var iName = icon ? icon.getAttribute('data-icon') : '';
          var testId = b.getAttribute('data-testid') || '';
          var ariaLbl = b.getAttribute('aria-label') || '';
          var cls = (b.className || '').substring(0, 30);
          if (iName || testId || ariaLbl) {
            info.push('tag=' + b.tagName + ',icon=' + iName + ',tid=' + testId + ',aria=' + ariaLbl);
          }
        }
        return info.join(' | ').substring(0, 500);
      })()
    ''');
    log('DOM fora footer: $domDump');

    // ── 3: Tenta clicar no botão correto (FORA do footer) ──
    final clickResult = await ctrl.executeJavaScript('''
      (function() {
        function fireClick(el) {
          el.focus();
          el.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, cancelable:true, view:window}));
          el.dispatchEvent(new MouseEvent('mouseup', {bubbles:true, cancelable:true, view:window}));
          el.dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true, view:window}));
          el.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, cancelable:true}));
          el.dispatchEvent(new PointerEvent('pointerup', {bubbles:true, cancelable:true}));
        }

        // Estratégia A: data-testid específico do upload
        var uploadBtn = document.querySelector('[data-testid="media-upload-send-btn"]');
        if (uploadBtn) {
          var btn = uploadBtn.closest('button, [role="button"]') || uploadBtn;
          fireClick(btn);
          return 'A:upload_btn';
        }

        // Estratégia B: qualquer span send* que NÃO esteja no footer
        var sendIcons = document.querySelectorAll('span[data-icon*="send"]');
        for (var s of sendIcons) {
          if (s.closest('footer')) continue; // pula o botão de texto
          var btn = s.closest('button, [role="button"], div[tabindex="0"]');
          if (btn) { fireClick(btn); return 'B:non_footer_btn:' + s.getAttribute('data-icon'); }
          fireClick(s);
          return 'B:non_footer_icon:' + s.getAttribute('data-icon');
        }

        // Estratégia C: dentro de modal/dialog, busca qualquer botão com ícone send
        var containers = document.querySelectorAll(
          '[data-animate-modal-body="true"], [role="dialog"]'
        );
        for (var c of containers) {
          var btns = c.querySelectorAll('button, [role="button"], div[tabindex="0"]');
          for (var b of btns) {
            var icon = b.querySelector('span[data-icon]');
            var iName = icon ? (icon.getAttribute('data-icon') || '') : '';
            var ariaLbl = (b.getAttribute('aria-label') || '').toLowerCase();
            if (iName.includes('send') || ariaLbl.includes('send') || ariaLbl.includes('enviar')) {
              fireClick(b);
              return 'C:modal_btn:' + iName + '/' + ariaLbl;
            }
          }
        }

        // Estratégia D: procura o botão circular verde (verde grande) fora do footer
        // O botão send do preview é tipicamente um div com role=button e cor verde
        var allClicables = document.querySelectorAll('[role="button"]');
        for (var el of allClicables) {
          if (el.closest('footer')) continue;
          var style = window.getComputedStyle(el);
          var bg = style.backgroundColor;
          // Verde WA: rgb(0, 168, 132) ou similar
          if (bg && (bg.includes('0, 168') || bg.includes('0, 163') || bg.includes('37, 211') || bg.includes('0,168') || bg.includes('00a884'))) {
            fireClick(el);
            return 'D:green_btn:bg=' + bg;
          }
        }

        return 'not_found';
      })()
    ''');
    log('Click result: $clickResult');

    if (clickResult != 'not_found') {
      await Future.delayed(const Duration(seconds: 1));
      return true;
    }

    // ── 4: Fallback Enter no activeElement ou no caption box ──
    log('Tentando Enter…');
    final enterResult = await ctrl.executeJavaScript('''
      (function() {
        // Procura caption box do preview (fora do footer)
        var targets = document.querySelectorAll('div[contenteditable="true"]');
        var target = null;
        for (var t of targets) {
          if (!t.closest('footer')) { target = t; break; }
        }
        if (!target) target = document.activeElement || document.body;
        target.focus();
        var opts = {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true, cancelable:true};
        target.dispatchEvent(new KeyboardEvent('keydown', opts));
        target.dispatchEvent(new KeyboardEvent('keypress', opts));
        target.dispatchEvent(new KeyboardEvent('keyup', opts));
        return 'enter:' + target.tagName + '.' + (target.getAttribute('data-tab') || 'none');
      })()
    ''');
    log('Enter result: $enterResult');
    await Future.delayed(const Duration(seconds: 1));

    // Verifica se o modal fechou (indica que enviou)
    final modalGone = await ctrl.executeJavaScript('''
      (function(){
        var sendIcons = document.querySelectorAll('span[data-icon*="send"]');
        var outsideFooter = 0;
        for (var s of sendIcons) { if (!s.closest('footer')) outsideFooter++; }
        var modal = document.querySelector('[data-animate-modal-body="true"], [role="dialog"]');
        return 'outsideSend=' + outsideFooter + ',modal=' + (modal ? 'yes' : 'no');
      })()
    ''');
    log('Após enter: $modalGone');

    // Se não há mais ícone send fora do footer, provavelmente enviou
    return modalGone.contains('outsideSend=0') ||
        modalGone.contains('modal=no');
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
