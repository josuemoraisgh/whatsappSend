import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/send_result.dart';
import '../providers/config_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/send_provider.dart';
import '../widgets/app_button.dart';

/// Tela de envio com WebView embutido e log em tempo real.
/// No Android oferece dois modos: automático (WebView) e manual (app nativo).
class SendScreen extends StatelessWidget {
  const SendScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SendProvider>(
      builder: (context, send, _) {
        if (send.switchingMode) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: AppColors.waGreen),
                SizedBox(height: 16),
                Text('Alternando modo de envio…'),
              ],
            ),
          );
        }

        final hasWebView = send.requiresWebView;

        return LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 720;

            if (isWide && hasWebView) {
              // Desktop: WebView e Log lado a lado
              return Column(
                children: [
                  _ActionPanel(send),
                  const Divider(height: 1),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(child: _WebViewPanel(send, expanded: true)),
                        const VerticalDivider(width: 1),
                        Expanded(child: _LogPanel(send)),
                      ],
                    ),
                  ),
                ],
              );
            }

            if (hasWebView) {
              // Mobile com WebView: coluna
              return Column(
                children: [
                  _ActionPanel(send),
                  const Divider(height: 1),
                  Expanded(
                    child: Column(
                      children: [
                        _WebViewPanel(send),
                        Expanded(child: _LogPanel(send)),
                      ],
                    ),
                  ),
                ],
              );
            }

            // Modo nativo: só log
            return Column(
              children: [
                _ActionPanel(send),
                const Divider(height: 1),
                Expanded(child: _LogPanel(send)),
              ],
            );
          },
        );
      },
    );
  }
}

// ── Painel de ação ────────────────────────────────────────────────

class _ActionPanel extends StatelessWidget {
  const _ActionPanel(this.send);
  final SendProvider send;

  @override
  Widget build(BuildContext context) {
    final contacts = context.read<ContactsProvider>();

    return Container(
      color: AppColors.cardBg,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Botões de envio
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AppButton(
                label: 'Enviar Todos (${contacts.total})',
                icon: Icons.send,
                onPressed:
                    send.isSending ? null : () => _start(context, 'todos'),
                height: 40,
                minWidth: 160,
                radius: 20,
                disabled: send.isSending,
              ),
              AppButton(
                label: 'Selecionados (${contacts.selectedCount})',
                icon: Icons.checklist,
                onPressed: (send.isSending || contacts.selectedCount == 0)
                    ? null
                    : () => _start(context, 'selecionados'),
                color: AppColors.blue,
                hoverColor: AppColors.blueHover,
                pressedColor: AppColors.blue,
                height: 40,
                minWidth: 160,
                radius: 20,
                disabled: send.isSending || contacts.selectedCount == 0,
              ),
              AppButton(
                label: 'Reenviar Falhas (${contacts.errorCount})',
                icon: Icons.refresh,
                onPressed: (send.isSending || contacts.errorCount == 0)
                    ? null
                    : () => _start(context, 'falhas'),
                color: AppColors.red,
                hoverColor: AppColors.redHover,
                pressedColor: AppColors.redPressed,
                height: 40,
                minWidth: 170,
                radius: 20,
                disabled: send.isSending || contacts.errorCount == 0,
              ),
              AppButton(
                label: 'Parar',
                icon: Icons.stop,
                onPressed: send.isSending ? send.cancel : null,
                color: const Color(0xFF9E9E9E),
                hoverColor: const Color(0xFF757575),
                pressedColor: const Color(0xFF616161),
                height: 40,
                minWidth: 100,
                radius: 20,
                disabled: !send.isSending,
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Barra de progresso
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: send.progressPct,
                    minHeight: 8,
                    backgroundColor: const Color(0xFFDDDDDD),
                    valueColor: const AlwaysStoppedAnimation(AppColors.waGreen),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${send.progress} / ${send.total}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: Color(0xFF555555),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // ── Seletor de modo (só Android/iOS) ──
          if (send.canSwitchMode)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  _ModeChip(
                    label: 'WhatsApp Web',
                    icon: Icons.smart_toy_outlined,
                    selected: send.sendMode == SendMode.webView,
                    onTap: send.isSending
                        ? null
                        : () => context
                            .read<SendProvider>()
                            .switchMode(SendMode.webView),
                  ),
                  const SizedBox(width: 8),
                  _ModeChip(
                    label: 'App nativo',
                    icon: Icons.touch_app_outlined,
                    selected: send.sendMode == SendMode.native,
                    onTap: send.isSending
                        ? null
                        : () => context
                            .read<SendProvider>()
                            .switchMode(SendMode.native),
                  ),
                ],
              ),
            ),

          // ── Dica contextual ──
          if (send.requiresWebView)
            Row(
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 14,
                  color: Color(0xFF888888),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    send.canSwitchMode
                        ? 'Vincule o WhatsApp Web uma vez '
                            '(use "Vincular com número de telefone" em vez de QR). '
                            'Depois, o envio é totalmente automático.'
                        : 'Use Ctrl+Clique nos contatos para seleção múltipla.',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF888888),
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => context.read<SendProvider>().showWebView =
                      !send.showWebView,
                  icon: Icon(
                    send.showWebView ? Icons.visibility_off : Icons.visibility,
                    size: 16,
                  ),
                  label: Text(
                    send.showWebView
                        ? 'Ocultar WhatsApp Web'
                        : 'Mostrar WhatsApp Web',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            )
          else
            const Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 14,
                  color: Color(0xFF888888),
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Cada contato será aberto no WhatsApp instalado. '
                    'Toque "Enviar" para confirmar cada mensagem.',
                    style: TextStyle(fontSize: 11, color: Color(0xFF888888)),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  void _start(BuildContext context, String mode) {
    final contacts = context.read<ContactsProvider>();
    final cfg = context.read<ConfigProvider>();
    final send = context.read<SendProvider>();

    final List toSend = switch (mode) {
      'todos' => contacts.contacts,
      'selecionados' => contacts.selectedContacts,
      'falhas' => contacts.errorContacts,
      _ => [],
    };

    if (toSend.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            mode == 'selecionados'
                ? 'Nenhum contato selecionado.'
                : 'Nenhum contato com falha.',
          ),
        ),
      );
      return;
    }

    send.startSend(
      contacts: List.from(toSend),
      config: cfg.config,
      attachments: cfg.attachments,
      onContactStatus: (id, phone, status, detail) {
        contacts.updateStatus(id, phone, status, detail);
      },
      onFinished: () {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Concluído — ${contacts.sentCount} enviados, '
                '${contacts.errorCount} erro(s).',
              ),
            ),
          );
        }
      },
    );
  }
}

// ── Chip de seleção de modo ───────────────────────────────────────

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.waGreen : const Color(0xFFEEEEEE),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppColors.waDarkGreen : const Color(0xFFCCCCCC),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? AppColors.white : const Color(0xFF666666),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: selected ? AppColors.white : const Color(0xFF666666),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── WebView ───────────────────────────────────────────────────────

class _WebViewPanel extends StatelessWidget {
  const _WebViewPanel(this.send, {this.expanded = false});
  final SendProvider send;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final ctrl = send.webViewController;
    if (ctrl == null) return const SizedBox.shrink();

    final content = Visibility(
      visible: send.showWebView,
      maintainState: true,
      child: Stack(
        children: [
          ctrl.buildWidget(),
          if (send.loginRequired && !send.loggedIn)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.waDarkGreen.withValues(alpha: 0.88),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.qr_code_scanner,
                      color: AppColors.white,
                      size: 20,
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Escaneie o QR code com o WhatsApp do seu celular para conectar.',
                        style: TextStyle(
                          color: AppColors.white,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    if (expanded) {
      return content;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      height: send.showWebView ? 320 : 0,
      child: content,
    );
  }
}

// ── Log ───────────────────────────────────────────────────────────

class _LogPanel extends StatefulWidget {
  const _LogPanel(this.send);
  final SendProvider send;

  @override
  State<_LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<_LogPanel> {
  final _scrollCtrl = ScrollController();

  @override
  void didUpdateWidget(_LogPanel old) {
    super.didUpdateWidget(old);
    if (widget.send.log.length != old.send.log.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: AppColors.background,
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
          child: Row(
            children: [
              const Text(
                'Log de execução:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const Spacer(),
              AppButton(
                label: 'Limpar',
                icon: Icons.clear_all,
                onPressed: widget.send.clearLog,
                color: AppColors.neutralBtn,
                hoverColor: AppColors.neutralBtnHover,
                pressedColor: AppColors.neutralBtnPressed,
                height: 28,
                minWidth: 80,
                radius: 14,
                fontSize: 11,
              ),
            ],
          ),
        ),

        // Área de texto do log
        Expanded(
          child: Container(
            color: AppColors.logBg,
            child: widget.send.log.isEmpty
                ? const Center(
                    child: Text(
                      'O log aparecerá aqui durante o envio.',
                      style: TextStyle(color: Color(0xFF5A7A5A), fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(10),
                    itemCount: widget.send.log.length,
                    itemBuilder: (_, i) {
                      final entry = widget.send.log[i];
                      return _LogLine(entry);
                    },
                  ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine(this.entry);
  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = switch (entry.type) {
      LogType.ok => AppColors.logOk,
      LogType.error => AppColors.logError,
      LogType.info => AppColors.logInfo,
      LogType.warning => AppColors.logWarning,
    };

    final h = entry.time.hour.toString().padLeft(2, '0');
    final m = entry.time.minute.toString().padLeft(2, '0');
    final s = entry.time.second.toString().padLeft(2, '0');

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          children: [
            TextSpan(
              text: '[$h:$m:$s] ',
              style: const TextStyle(color: Color(0xFF5A7A6A)),
            ),
            TextSpan(
              text: entry.message,
              style: TextStyle(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
