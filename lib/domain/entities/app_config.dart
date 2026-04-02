/// Configurações da aplicação — compatível com config.json do projeto Python.
class AppConfig {
  const AppConfig({
    this.defaultMessage = 'Olá {nome}!',
    this.intervalMin = 3,
    this.intervalMax = 6,
    this.pageTimeout = 40,
    this.splitFraction = 0.55,
    this.logCollapsed = false,
    this.savedAttachments = const ['', '', ''],
  });

  final String defaultMessage;
  final int intervalMin;
  final int intervalMax;
  final int pageTimeout;
  final double splitFraction;
  final bool logCollapsed;
  final List<String> savedAttachments;

  AppConfig copyWith({
    String? defaultMessage,
    int? intervalMin,
    int? intervalMax,
    int? pageTimeout,
    double? splitFraction,
    bool? logCollapsed,
    List<String>? savedAttachments,
  }) =>
      AppConfig(
        defaultMessage: defaultMessage ?? this.defaultMessage,
        intervalMin: intervalMin ?? this.intervalMin,
        intervalMax: intervalMax ?? this.intervalMax,
        pageTimeout: pageTimeout ?? this.pageTimeout,
        splitFraction: splitFraction ?? this.splitFraction,
        logCollapsed: logCollapsed ?? this.logCollapsed,
        savedAttachments: savedAttachments ?? this.savedAttachments,
      );

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        defaultMessage: (json['mensagem_padrao'] as String?) ?? 'Olá {nome}!',
        intervalMin: (json['intervalo_min'] as num?)?.toInt() ?? 3,
        intervalMax: (json['intervalo_max'] as num?)?.toInt() ?? 6,
        pageTimeout: (json['timeout_pagina'] as num?)?.toInt() ?? 40,
        splitFraction: (json['split_fraction'] as num?)?.toDouble() ?? 0.55,
        logCollapsed: (json['log_collapsed'] as bool?) ?? false,
        savedAttachments: (json['saved_attachments'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const ['', '', ''],
      );

  Map<String, dynamic> toJson() => {
        'mensagem_padrao': defaultMessage,
        'intervalo_min': intervalMin,
        'intervalo_max': intervalMax,
        'timeout_pagina': pageTimeout,
        'split_fraction': splitFraction,
        'log_collapsed': logCollapsed,
        'saved_attachments': savedAttachments,
      };
}
