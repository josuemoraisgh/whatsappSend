import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../providers/config_provider.dart';
import '../widgets/app_button.dart';
import '../widgets/section_card.dart';

/// Tela de mensagem padrão e arquivos para envio.
class MessageScreen extends StatefulWidget {
  const MessageScreen({super.key});

  @override
  State<MessageScreen> createState() => _MessageScreenState();
}

class _MessageScreenState extends State<MessageScreen>
    with AutomaticKeepAliveClientMixin {
  late final TextEditingController _msgCtr;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final config = context.read<ConfigProvider>().config;
    _msgCtr = TextEditingController(text: config.defaultMessage);
  }

  @override
  void dispose() {
    _msgCtr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        children: [
          _MessageCard(_msgCtr),
          const SizedBox(height: 8),
          const _AttachmentsCard(),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}

// ── Card Mensagem ─────────────────────────────────────────────────

class _MessageCard extends StatelessWidget {
  const _MessageCard(this.controller);
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Mensagem Padrão',
      subtitle:
          'Usada quando o contato não tem mensagem individual.  Variáveis: {nome}  {telefone}',
      accentColor: AppColors.waGreen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: controller,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'Ex: Olá {nome}, tudo bem?',
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: AppButton(
              label: 'Salvar Mensagem',
              icon: Icons.save_outlined,
              onPressed: () => _save(context),
              height: 36,
              minWidth: 160,
              radius: 18,
            ),
          ),
        ],
      ),
    );
  }

  void _save(BuildContext context) {
    context.read<ConfigProvider>().updateDefaultMessage(controller.text.trim());
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Mensagem padrão salva.')));
  }
}

// ── Card Arquivos ─────────────────────────────────────────────────

class _AttachmentsCard extends StatelessWidget {
  const _AttachmentsCard();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Arquivos para enviar (até 3)',
      subtitle:
          'Enviados após a mensagem de texto. Suporta qualquer tipo de arquivo.',
      accentColor: AppColors.orange,
      child: Column(children: List.generate(3, (i) => _FileRow(index: i))),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.index});
  final int index;

  static const _colors = [AppColors.waGreen, AppColors.blue, AppColors.orange];

  @override
  Widget build(BuildContext context) {
    final path = context.select<ConfigProvider, String>(
      (p) => p.getAttachment(index),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          // Número do arquivo
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _colors[index],
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                color: AppColors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Campo de texto
          Expanded(
            child: Tooltip(
              message: path.isNotEmpty ? path : '',
              waitDuration: const Duration(milliseconds: 400),
              child: TextFormField(
                key: ValueKey('attach_${index}_$path'),
                initialValue:
                    path.isNotEmpty ? path.split(RegExp(r'[/\\]')).last : '',
                readOnly: true,
                decoration: InputDecoration(
                  hintText: 'Nenhum arquivo selecionado',
                  hintStyle: const TextStyle(
                    color: Color(0xFFAAAAAA),
                    fontSize: 12,
                  ),
                  suffixIcon: path.isNotEmpty
                      ? IconButton(
                          icon: const Icon(
                            Icons.clear,
                            size: 16,
                            color: Color(0xFF999999),
                          ),
                          onPressed: () => context
                              .read<ConfigProvider>()
                              .setAttachment(index, ''),
                        )
                      : null,
                ),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Botão procurar
          AppButton(
            label: 'Procurar',
            onPressed: () => _browse(context),
            color: AppColors.neutralBtn,
            hoverColor: AppColors.neutralBtnHover,
            pressedColor: AppColors.neutralBtnPressed,
            height: 34,
            minWidth: 80,
            radius: 17,
            fontSize: 12,
          ),
        ],
      ),
    );
  }

  Future<void> _browse(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Selecionar arquivo ${index + 1}',
    );
    if (result?.files.single.path != null && context.mounted) {
      context.read<ConfigProvider>().setAttachment(
            index,
            result!.files.single.path!,
          );
    }
  }
}
