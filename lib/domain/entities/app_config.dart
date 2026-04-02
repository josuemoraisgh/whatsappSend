/// Configurações da aplicação — compatível com config.json do projeto Python.
class AppConfig {
  const AppConfig({
    this.defaultMessage = 'Olá {nome}!',
    this.intervalMin = 3,
    this.intervalMax = 6,
    this.pageTimeout = 40,
  });

  final String defaultMessage;
  final int intervalMin;
  final int intervalMax;
  final int pageTimeout;

  AppConfig copyWith({
    String? defaultMessage,
    int? intervalMin,
    int? intervalMax,
    int? pageTimeout,
  }) =>
      AppConfig(
        defaultMessage: defaultMessage ?? this.defaultMessage,
        intervalMin: intervalMin ?? this.intervalMin,
        intervalMax: intervalMax ?? this.intervalMax,
        pageTimeout: pageTimeout ?? this.pageTimeout,
      );

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        defaultMessage: (json['mensagem_padrao'] as String?) ?? 'Olá {nome}!',
        intervalMin: (json['intervalo_min'] as num?)?.toInt() ?? 3,
        intervalMax: (json['intervalo_max'] as num?)?.toInt() ?? 6,
        pageTimeout: (json['timeout_pagina'] as num?)?.toInt() ?? 40,
      );

  Map<String, dynamic> toJson() => {
        'mensagem_padrao': defaultMessage,
        'intervalo_min': intervalMin,
        'intervalo_max': intervalMax,
        'timeout_pagina': pageTimeout,
      };
}
