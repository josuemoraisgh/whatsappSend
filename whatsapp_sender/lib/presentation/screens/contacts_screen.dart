import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/contact.dart';
import '../providers/contacts_provider.dart';
import '../providers/send_provider.dart';
import '../widgets/app_button.dart';
import '../widgets/contact_dialog.dart';
import '../widgets/status_badge.dart';

/// Tela de gerenciamento de contatos — equivalente à aba "Contatos" do app Python.
class ContactsScreen extends StatelessWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ContactsProvider>(
      builder: (context, prov, _) {
        return Column(
          children: [
            Expanded(child: _ContactsTable(prov)),
            _ActionBar(prov),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Text(
                '${prov.total} contato(s)',
                style: const TextStyle(fontSize: 11, color: Color(0xFF777777)),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── Tabela ────────────────────────────────────────────────────────

class _ContactsTable extends StatelessWidget {
  const _ContactsTable(this.prov);
  final ContactsProvider prov;

  @override
  Widget build(BuildContext context) {
    final contacts = prov.contacts;

    if (contacts.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline, size: 56, color: Color(0xFFCCCCCC)),
            SizedBox(height: 12),
            Text(
              'Nenhum contato cadastrado',
              style: TextStyle(color: Color(0xFF999999)),
            ),
            SizedBox(height: 6),
            Text(
              'Clique em "+ Novo" para adicionar',
              style: TextStyle(color: Color(0xFFBBBBBB), fontSize: 12),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: constraints.maxWidth,
                ),
                child: SingleChildScrollView(
                  child: DataTable(
                    headingRowColor:
                        WidgetStateProperty.all(AppColors.waDarkGreen),
                    headingTextStyle: const TextStyle(
                      color: AppColors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                    dataRowMinHeight: 36,
                    dataRowMaxHeight: 44,
                    showCheckboxColumn: true,
                    border: const TableBorder(
                      horizontalInside: BorderSide(
                        color: Color(0xFFEEEEEE),
                        width: 1,
                      ),
                    ),
                    columns: const [
                      DataColumn(label: Text('Nome')),
                      DataColumn(label: Text('Telefone')),
                      DataColumn(label: Text('Mensagem Individual')),
                      DataColumn(label: Text('Status')),
                      DataColumn(label: Text('Ações')),
                    ],
                    rows: contacts.asMap().entries.map((entry) {
                      final c = entry.value;
                      final isSelected = prov.selectedIds.contains(c.id);
                      final bg = _rowColor(c.status);

                      return DataRow(
                        selected: isSelected,
                        color: WidgetStateProperty.resolveWith((_) => bg),
                        onSelectChanged: (_) => context
                            .read<ContactsProvider>()
                            .toggleSelection(c.id),
                        cells: [
                          DataCell(Text(c.name,
                              style: const TextStyle(fontSize: 12))),
                          DataCell(Text(c.phone,
                              style: const TextStyle(fontSize: 12))),
                          DataCell(
                            Text(
                              c.individualMessage.isEmpty
                                  ? '—'
                                  : c.individualMessage,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: c.individualMessage.isEmpty
                                    ? const Color(0xFFAAAAAA)
                                    : null,
                              ),
                            ),
                          ),
                          DataCell(StatusBadge(c.status)),
                          DataCell(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _IconBtn(
                                  icon: Icons.edit_outlined,
                                  color: AppColors.blue,
                                  tooltip: 'Editar',
                                  onTap: () => _editContact(context, c),
                                ),
                                const SizedBox(width: 4),
                                _IconBtn(
                                  icon: Icons.delete_outline,
                                  color: AppColors.red,
                                  tooltip: 'Remover',
                                  onTap: () => _removeContact(context, c),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Color? _rowColor(SendStatus s) => switch (s) {
        SendStatus.sent => AppColors.waBubble.withValues(alpha: 0.5),
        SendStatus.error => AppColors.redBubble.withValues(alpha: 0.5),
        SendStatus.ignored => AppColors.orangeBubble.withValues(alpha: 0.5),
        _ => null,
      };

  Future<void> _editContact(BuildContext context, Contact c) async {
    final result = await ContactDialog.show(context, contact: c);
    if (result != null && context.mounted) {
      await context.read<ContactsProvider>().update(result);
    }
  }

  Future<void> _removeContact(BuildContext context, Contact c) async {
    final ok = await _confirm(
      context,
      'Remover contato?',
      'Remover "${c.name}" da lista?',
    );
    if (ok && context.mounted) {
      await context.read<ContactsProvider>().removeById(c.id);
    }
  }
}

// ── Barra de ações ────────────────────────────────────────────────

class _ActionBar extends StatelessWidget {
  const _ActionBar(this.prov);
  final ContactsProvider prov;

  @override
  Widget build(BuildContext context) {
    final sending = context.select<SendProvider, bool>((s) => s.isSending);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      color: AppColors.background,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          AppButton(
            label: '+ Novo',
            onPressed: sending ? null : () => _addContact(context),
            height: 34,
            minWidth: 90,
            radius: 17,
          ),
          AppButton(
            label: 'Remover selecionados (${prov.selectedCount})',
            onPressed: (sending || prov.selectedCount == 0)
                ? null
                : () => _removeSelected(context),
            color: AppColors.red,
            hoverColor: AppColors.redHover,
            pressedColor: AppColors.redPressed,
            height: 34,
            minWidth: 90,
            radius: 17,
            disabled: prov.selectedCount == 0,
          ),
          AppButton(
            label: 'Select All',
            onPressed: () => context.read<ContactsProvider>().selectAll(),
            color: AppColors.neutralBtn,
            hoverColor: AppColors.neutralBtnHover,
            pressedColor: AppColors.neutralBtnPressed,
            height: 34,
            minWidth: 90,
            radius: 17,
          ),
          AppButton(
            label: 'Deselect All',
            onPressed: () => context.read<ContactsProvider>().clearSelection(),
            color: AppColors.neutralBtn,
            hoverColor: AppColors.neutralBtnHover,
            pressedColor: AppColors.neutralBtnPressed,
            height: 34,
            minWidth: 90,
            radius: 17,
          ),
          AppButton(
            label: 'Import JSON',
            onPressed: sending ? null : () => _importJson(context),
            color: AppColors.neutralBtn,
            hoverColor: AppColors.neutralBtnHover,
            pressedColor: AppColors.neutralBtnPressed,
            icon: Icons.upload_file,
            height: 34,
            minWidth: 120,
            radius: 17,
          ),
          AppButton(
            label: 'Export JSON',
            onPressed: () => _exportJson(context),
            color: AppColors.neutralBtn,
            hoverColor: AppColors.neutralBtnHover,
            pressedColor: AppColors.neutralBtnPressed,
            icon: Icons.download,
            height: 34,
            minWidth: 120,
            radius: 17,
          ),
          AppButton(
            label: 'Clear All',
            onPressed:
                (sending || prov.total == 0) ? null : () => _clearAll(context),
            color: const Color(0xFF9E9E9E),
            hoverColor: const Color(0xFF757575),
            pressedColor: const Color(0xFF616161),
            height: 34,
            minWidth: 90,
            radius: 17,
            disabled: prov.total == 0,
          ),
        ],
      ),
    );
  }

  Future<void> _addContact(BuildContext context) async {
    final result = await ContactDialog.show(context);
    if (result != null && context.mounted) {
      await context.read<ContactsProvider>().add(result);
    }
  }

  Future<void> _removeSelected(BuildContext context) async {
    final count = prov.selectedCount;
    final ok = await _confirm(
      context,
      'Remover contatos?',
      'Remover $count contato(s) selecionado(s)?',
    );
    if (ok && context.mounted) {
      await context.read<ContactsProvider>().removeSelected();
    }
  }

  Future<void> _clearAll(BuildContext context) async {
    final ok = await _confirm(
      context,
      'Limpar tudo?',
      'Remover TODOS os ${prov.total} contatos da lista?',
    );
    if (ok && context.mounted) {
      await context.read<ContactsProvider>().clearAll();
    }
  }

  Future<void> _importJson(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'Importar contatos JSON',
    );
    if (result == null || result.files.single.path == null) return;

    if (!context.mounted) return;

    final replace = await _askReplaceOrAppend(context);
    if (replace == null) return;
    if (!context.mounted) return;

    final repo = context.read<ContactsProvider>();
    try {
      final count = await repo.importFromFile(
        result.files.single.path!,
        replace: replace,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count contato(s) importado(s).')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erro ao importar: $e')));
      }
    }
  }

  Future<void> _exportJson(BuildContext context) async {
    final repo = context.read<ContactsProvider>();
    final path = await FilePicker.platform.saveFile(
      fileName: 'contatos_export.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'Exportar contatos JSON',
    );
    if (path == null) return;
    try {
      await repo.exportToFile(path);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Exportado em $path')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erro ao exportar: $e')));
      }
    }
  }
}

// ── Botão de ícone inline ─────────────────────────────────────────

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, color: color, size: 18),
          ),
        ),
      );
}

// ── Helpers ───────────────────────────────────────────────────────

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text(
            'Confirmar',
            style: TextStyle(color: AppColors.red),
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<bool?> _askReplaceOrAppend(BuildContext context) async {
  return showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Importar contatos'),
      content: const Text('Como deseja importar os contatos encontrados?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Adicionar ao final'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text(
            'Substituir lista',
            style: TextStyle(color: AppColors.red),
          ),
        ),
      ],
    ),
  );
}
