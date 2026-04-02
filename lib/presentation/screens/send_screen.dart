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
class SendScreen extends StatefulWidget {
  const SendScreen({super.key});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  late bool _logCollapsed;
  bool _initialized = false;

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      _logCollapsed = context.read<ConfigProvider>().logCollapsed;
      _initialized = true;
    }
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
                    child: _logCollapsed
                        ? Row(
                            children: [
                              Expanded(
                                  child: _WebViewPanel(send, expanded: true)),
                              _CollapsedLogBar(
                                send: send,
                                onExpand: () {
                                  setState(() => _logCollapsed = false);
                                  context
                                      .read<ConfigProvider>()
                                      .updateLogCollapsed(false);
                                },
                              ),
                            ],
                          )
                        : _ResizableRow(
                            left: _WebViewPanel(send, expanded: true),
                            right: _LogPanel(
                              send,
                              onCollapse: () {
                                setState(() => _logCollapsed = true);
                                context
                                    .read<ConfigProvider>()
                                    .updateLogCollapsed(true);
                              },
                            ),
                            initialFraction:
                                context.read<ConfigProvider>().splitFraction,
                            onFractionChanged: (f) => context
                                .read<ConfigProvider>()
                                .updateSplitFraction(f),
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

          // ── Status de conexão + botões Conectar / Desconectar ──
          if (send.requiresWebView)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: send.loggedIn
                      ? const Color(0xFFE8F5E9)
                      : const Color(0xFFFFF8E1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: send.loggedIn
                        ? AppColors.waGreen
                        : const Color(0xFFFFCA28),
                  ),
                ),
                child: Row(
                  children: [
                    // Indicador de estado
                    if (send.connectingWa)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(AppColors.waGreen),
                        ),
                      )
                    else
                      Icon(
                        send.loggedIn
                            ? Icons.check_circle
                            : Icons.warning_amber_rounded,
                        size: 16,
                        color: send.loggedIn
                            ? AppColors.waGreen
                            : const Color(0xFFF9A825),
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        send.connectingWa
                            ? 'Verificando sessão do WhatsApp Web…'
                            : send.loggedIn
                                ? 'WhatsApp Web conectado'
                                : 'WhatsApp Web desconectado — escaneie o QR Code',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: send.loggedIn
                              ? AppColors.waDarkGreen
                              : const Color(0xFF795548),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Botão Conectar
                    AppButton(
                      label: 'Conectar',
                      icon: Icons.qr_code_scanner,
                      onPressed: (send.isSending || send.connectingWa)
                          ? null
                          : () =>
                              context.read<SendProvider>().connectWhatsApp(),
                      color: AppColors.waGreen,
                      hoverColor: AppColors.waDarkGreen,
                      pressedColor: AppColors.waDarkGreen,
                      height: 30,
                      minWidth: 100,
                      radius: 15,
                      fontSize: 11,
                      disabled: send.isSending || send.connectingWa,
                    ),
                    const SizedBox(width: 6),
                    // Botão Desconectar
                    AppButton(
                      label: 'Desconectar',
                      icon: Icons.logout,
                      onPressed: send.isSending
                          ? null
                          : () => _confirmDisconnect(context, send),
                      color: AppColors.red,
                      hoverColor: AppColors.redHover,
                      pressedColor: AppColors.redPressed,
                      height: 30,
                      minWidth: 120,
                      radius: 15,
                      fontSize: 11,
                      disabled: send.isSending,
                    ),
                  ],
                ),
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

  void _confirmDisconnect(BuildContext ctx, SendProvider send) {
    showDialog<void>(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Desconectar WhatsApp Web?'),
        content: const Text(
          'A sessão salva será removida.\n'
          'Na próxima conexão será necessário escanear o QR Code novamente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              ctx.read<SendProvider>().disconnectWhatsApp();
            },
            child: const Text('Desconectar'),
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

// ── Barra colapsada do Log (vertical estreita) ───────────────────

class _CollapsedLogBar extends StatelessWidget {
  const _CollapsedLogBar({required this.send, required this.onExpand});
  final SendProvider send;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(left: BorderSide(color: Color(0xFFDDDDDD))),
      ),
      child: Column(
        children: [
          const SizedBox(height: 6),
          Tooltip(
            message: 'Mostrar Log',
            child: InkWell(
              onTap: onExpand,
              borderRadius: BorderRadius.circular(4),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child:
                    Icon(Icons.visibility, size: 16, color: Color(0xFF666666)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Tooltip(
            message: 'Limpar Log',
            child: InkWell(
              onTap: send.clearLog,
              borderRadius: BorderRadius.circular(4),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child:
                    Icon(Icons.clear_all, size: 16, color: Color(0xFF666666)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Log ───────────────────────────────────────────────────────────

class _LogPanel extends StatefulWidget {
  const _LogPanel(this.send, {this.onCollapse});
  final SendProvider send;
  final VoidCallback? onCollapse;

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
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;

        // Muito estreito → colapsar automaticamente
        if (w < 120 && widget.onCollapse != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            widget.onCollapse!();
          });
          return const SizedBox.shrink();
        }

        // Estreito (< 280px): só ícones, sem texto
        final compact = w < 280;

        return Column(
          children: [
            Container(
              color: AppColors.background,
              padding:
                  EdgeInsets.fromLTRB(compact ? 4 : 14, 6, compact ? 4 : 14, 4),
              child: compact
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.onCollapse != null)
                          Tooltip(
                            message: 'Esconder',
                            child: InkWell(
                              onTap: widget.onCollapse,
                              borderRadius: BorderRadius.circular(4),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.visibility_off,
                                    size: 16, color: Color(0xFF666666)),
                              ),
                            ),
                          ),
                        const SizedBox(width: 4),
                        Tooltip(
                          message: 'Limpar',
                          child: InkWell(
                            onTap: widget.send.clearLog,
                            borderRadius: BorderRadius.circular(4),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(Icons.clear_all,
                                  size: 16, color: Color(0xFF666666)),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Log de execução:',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        if (widget.onCollapse != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: AppButton(
                              label: 'Esconder',
                              icon: Icons.visibility_off,
                              onPressed: widget.onCollapse,
                              color: AppColors.neutralBtn,
                              hoverColor: AppColors.neutralBtnHover,
                              pressedColor: AppColors.neutralBtnPressed,
                              height: 28,
                              minWidth: 80,
                              radius: 14,
                              fontSize: 11,
                            ),
                          ),
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

            // Área de texto do log (selecionável / copiável)
            Expanded(
              child: Container(
                color: AppColors.logBg,
                child: widget.send.log.isEmpty
                    ? const Center(
                        child: Text(
                          'O log aparecerá aqui durante o envio.',
                          style:
                              TextStyle(color: Color(0xFF5A7A5A), fontSize: 12),
                        ),
                      )
                    : SelectionArea(
                        child: ListView.builder(
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
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }
}

// ── Painel redimensionável (divisor arrastável) ──────────────────

class _ResizableRow extends StatefulWidget {
  const _ResizableRow({
    required this.left,
    required this.right,
    this.initialFraction = 0.55,
    this.onFractionChanged,
  });
  final Widget left;
  final Widget right;
  final double initialFraction;
  final ValueChanged<double>? onFractionChanged;

  @override
  State<_ResizableRow> createState() => _ResizableRowState();
}

class _ResizableRowState extends State<_ResizableRow> {
  late double _leftFraction = widget.initialFraction;
  static const double _dividerWidth = 6.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth - _dividerWidth;
        final leftW = (total * _leftFraction).clamp(100.0, total - 40.0);
        final rightW = total - leftW;
        return Row(
          children: [
            SizedBox(width: leftW, child: widget.left),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) {
                setState(() {
                  _leftFraction =
                      ((leftW + d.delta.dx) / total).clamp(0.15, 0.85);
                });
              },
              onHorizontalDragEnd: (_) {
                widget.onFractionChanged?.call(_leftFraction);
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: Container(
                  width: _dividerWidth,
                  color: const Color(0xFFDDDDDD),
                  child: const Center(
                    child: SizedBox(
                      width: 2,
                      child: ColoredBox(color: Color(0xFFBBBBBB)),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(width: rightW, child: widget.right),
          ],
        );
      },
    );
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
      child: Text.rich(
        TextSpan(
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
