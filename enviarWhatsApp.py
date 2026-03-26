# -*- coding: utf-8 -*-
"""
enviarWhatsApp.py

Envia mensagens em lote pelo WhatsApp Web sem API, usando Selenium.

Fluxo:
1) Abre o Chrome com perfil persistente (evita re-escanear QR a cada execução).
2) Na PRIMEIRA execução, você escaneia o QR code manualmente no navegador.
3) Para cada contato em contatos.json, navega para a URL de envio do WhatsApp Web.
4) Aguarda a caixa de mensagem carregar e pressiona Enter para enviar.
5) Registra o resultado de cada envio em out/log_YYYYMMDD_HHMMSS.json.

Requisitos (instale com instal.bat):
    pip install selenium webdriver-manager

Customizações:
    - Edite contatos.json com nome, telefone e (opcionalmente) mensagem individual.
    - Edite config.json para ajustar mensagem padrão, intervalos e caminho do perfil.
"""

import json
import os
import re
import time
import random
import urllib.parse
from datetime import datetime
from pathlib import Path

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException, NoSuchElementException


# ===================== CONSTANTES =====================

CONFIG_FILE   = Path("config.json")
CONTATOS_FILE = Path("contatos.json")
OUT_DIR       = Path("out")
OUT_DIR.mkdir(parents=True, exist_ok=True)

# Seletores CSS do WhatsApp Web (múltiplos para robustez entre versões)
SELETORES_CAIXA_MENSAGEM = (
    'div[contenteditable="true"][data-tab="10"],'
    'div[contenteditable="true"][aria-label*="mensagem"],'
    'div[contenteditable="true"][aria-label*="message"],'
    'div[contenteditable="true"][aria-label*="Mensagem"],'
    'footer div[contenteditable="true"]'
)

SELETORES_LOGIN_OK = (
    '[data-icon="chat"],'
    '[data-testid="chat-list"],'
    'div[aria-label="Lista de conversas"],'
    'div[aria-label="Conversation list"],'
    '#pane-side'
)

SELETOR_POPUP_NUMERO_INVALIDO = (
    'div[data-animate-modal-popup="true"],'
    'div[role="dialog"]'
)

CONFIG_PADRAO = {
    "mensagem_padrao": "Olá {nome}!",
    "perfil_chrome": str(Path.home() / "whatsapp_chrome_profile"),
    "intervalo_min": 6,
    "intervalo_max": 14,
    "chromedriver_caminho": "",
    "timeout_pagina": 40,
}


# ===================== UTILITÁRIOS =====================

def banner(msg: str) -> None:
    print("\n" + "=" * 10 + f" {msg} " + "=" * 10)


def carregar_config() -> dict:
    if CONFIG_FILE.exists():
        dados = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        # Preenche chaves ausentes com padrão
        for k, v in CONFIG_PADRAO.items():
            dados.setdefault(k, v)
        return dados
    CONFIG_FILE.write_text(
        json.dumps(CONFIG_PADRAO, ensure_ascii=False, indent=4), encoding="utf-8"
    )
    print(f"[AVISO] {CONFIG_FILE} criado com valores padrão. Edite antes de continuar.")
    return dict(CONFIG_PADRAO)


def carregar_contatos() -> list:
    if not CONTATOS_FILE.exists():
        raise FileNotFoundError(
            f"Arquivo '{CONTATOS_FILE}' não encontrado. "
            "Crie-o com uma lista de objetos {nome, telefone}."
        )
    contatos = json.loads(CONTATOS_FILE.read_text(encoding="utf-8"))
    if not isinstance(contatos, list):
        raise ValueError(f"'{CONTATOS_FILE}' deve conter uma lista JSON.")
    return contatos


def formatar_telefone(tel: str) -> str:
    """
    Normaliza o telefone para o formato internacional sem '+'.
    Exemplo: '(34) 9 9111-0001' → '5534991110001'
    """
    digits = re.sub(r"\D+", "", str(tel))
    if digits.startswith("0"):
        digits = digits[1:]
    # Adiciona código do Brasil se tiver 10 ou 11 dígitos (sem código de país)
    if len(digits) in (10, 11):
        digits = "55" + digits
    return digits


def montar_mensagem(template: str, contato: dict) -> str:
    """Interpola variáveis {nome}, {telefone} etc. no template da mensagem."""
    try:
        return template.format_map(contato)
    except (KeyError, ValueError):
        return template


# ===================== SELENIUM =====================

def criar_driver(config: dict) -> webdriver.Chrome:
    profile_dir = config["perfil_chrome"]
    Path(profile_dir).mkdir(parents=True, exist_ok=True)

    options = Options()
    options.add_argument(f"--user-data-dir={profile_dir}")
    options.add_argument("--profile-directory=Default")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-gpu")
    # Suprime logs desnecessários do Chrome no console
    options.add_experimental_option("excludeSwitches", ["enable-logging"])
    options.add_experimental_option("useAutomationExtension", False)

    cd_path = config.get("chromedriver_caminho", "").strip()

    if cd_path and Path(cd_path).exists():
        service = Service(cd_path)
    else:
        # Tenta o chromedriver local em Arquivos/
        local_cd = Path("Arquivos") / "chromedriver.exe"
        if local_cd.exists():
            print(f"[INFO] Usando chromedriver local: {local_cd}")
            service = Service(str(local_cd))
        else:
            # Baixa automaticamente via webdriver-manager
            print("[INFO] Baixando chromedriver via webdriver-manager...")
            try:
                from webdriver_manager.chrome import ChromeDriverManager
                service = Service(ChromeDriverManager().install())
            except ImportError:
                raise RuntimeError(
                    "webdriver-manager não instalado. Execute instal.bat primeiro."
                )

    driver = webdriver.Chrome(service=service, options=options)
    driver.set_window_size(1280, 900)
    return driver


def aguardar_login(driver: webdriver.Chrome, timeout: int = 120) -> bool:
    """
    Aguarda o WhatsApp Web ficar pronto (login via QR ou sessão já ativa).
    Retorna True se o login foi detectado dentro do timeout.
    """
    print(f"Aguardando WhatsApp Web (máx. {timeout}s) ", end="", flush=True)
    try:
        WebDriverWait(driver, timeout).until(
            EC.presence_of_element_located(
                (By.CSS_SELECTOR, SELETORES_LOGIN_OK)
            )
        )
        print("— conectado!")
        return True
    except TimeoutException:
        print("\n[AVISO] Timeout. Verifique se o QR code foi escaneado.")
        return False


def fechar_popup_numero_invalido(driver: webdriver.Chrome) -> bool:
    """
    Detecta e fecha o popup 'Número de telefone não existe no WhatsApp'.
    Retorna True se um popup foi encontrado e fechado.
    """
    try:
        popup = driver.find_element(By.CSS_SELECTOR, SELETOR_POPUP_NUMERO_INVALIDO)
        # Tenta clicar em OK / fechar
        for seletor_btn in ('button[aria-label="OK"]', 'div[role="button"]', 'button'):
            try:
                popup.find_element(By.CSS_SELECTOR, seletor_btn).click()
                return True
            except NoSuchElementException:
                continue
    except NoSuchElementException:
        pass
    return False


def enviar_mensagem(
    driver: webdriver.Chrome,
    telefone: str,
    mensagem: str,
    timeout: int,
) -> dict:
    """
    Navega para a URL de envio do WhatsApp Web e pressiona Enter para enviar.
    Retorna um dict com o resultado: {telefone, status, detalhe, ...}.
    """
    tel = formatar_telefone(telefone)
    msg_encoded = urllib.parse.quote(mensagem)
    url = f"https://web.whatsapp.com/send?phone={tel}&text={msg_encoded}"

    driver.get(url)
    resultado = {
        "telefone_original": telefone,
        "telefone_formatado": tel,
        "status": "erro",
        "detalhe": "",
        "horario": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }

    try:
        caixa = WebDriverWait(driver, timeout).until(
            EC.presence_of_element_located(
                (By.CSS_SELECTOR, SELETORES_CAIXA_MENSAGEM)
            )
        )
    except TimeoutException:
        # Verifica se é popup de número inválido
        if fechar_popup_numero_invalido(driver):
            resultado["detalhe"] = "Número não encontrado no WhatsApp"
        else:
            resultado["detalhe"] = f"Timeout ({timeout}s): caixa de mensagem não apareceu"
        _salvar_screenshot(driver, OUT_DIR, tel)
        return resultado

    # Pausa breve para garantir que a página está estável
    time.sleep(1.5)

    try:
        caixa.click()
        time.sleep(0.4)
        caixa.send_keys(Keys.ENTER)
        time.sleep(2.0)  # aguarda a mensagem ser de fato enviada

        resultado["status"] = "enviado"
        resultado["detalhe"] = "Mensagem enviada com sucesso"
    except Exception as exc:
        resultado["detalhe"] = f"Erro ao enviar: {exc}"
        _salvar_screenshot(driver, OUT_DIR, tel)

    return resultado


def _salvar_screenshot(driver: webdriver.Chrome, pasta: Path, identificador: str) -> None:
    caminho = pasta / f"erro_{identificador}_{datetime.now().strftime('%H%M%S')}.png"
    try:
        driver.save_screenshot(str(caminho))
        print(f"    [Screenshot] {caminho.name}")
    except Exception:
        pass


# ===================== MAIN =====================

def main() -> None:
    banner("enviarWhatsApp.py")

    config   = carregar_config()
    contatos = carregar_contatos()

    print(f"[INFO] {len(contatos)} contato(s) carregado(s) de '{CONTATOS_FILE}'.")
    print(f"[INFO] Mensagem padrão: \"{config['mensagem_padrao']}\"")
    print(f"[INFO] Perfil Chrome  : {config['perfil_chrome']}")

    driver = criar_driver(config)
    driver.get("https://web.whatsapp.com")

    if not aguardar_login(driver, timeout=120):
        print("[ERRO] WhatsApp Web não conectou. Encerrando.")
        driver.quit()
        return

    log: list = []
    timeout       = int(config["timeout_pagina"])
    intervalo_min = float(config["intervalo_min"])
    intervalo_max = float(config["intervalo_max"])
    mensagem_pad  = config["mensagem_padrao"]
    total         = len(contatos)

    banner("Iniciando envios")

    for i, contato in enumerate(contatos, 1):
        nome     = contato.get("nome", "").strip()
        telefone = str(contato.get("telefone", "")).strip()

        if not telefone:
            print(f"[{i:03d}/{total}] IGNORADO — sem telefone: {nome or '(sem nome)'}")
            log.append({"nome": nome, "status": "ignorado", "detalhe": "campo telefone vazio"})
            continue

        # Mensagem individual tem prioridade; senão usa a padrão
        template = str(contato.get("mensagem") or mensagem_pad).strip() or mensagem_pad
        mensagem = montar_mensagem(template, {**contato, "nome": nome})

        print(f"[{i:03d}/{total}] {nome or telefone} → ", end="", flush=True)

        resultado = enviar_mensagem(driver, telefone, mensagem, timeout)
        resultado["nome"] = nome
        log.append(resultado)

        if resultado["status"] == "enviado":
            print("OK")
        else:
            print(f"FALHA — {resultado['detalhe'][:80]}")

        # Intervalo aleatório entre envios (evita bloqueio)
        if i < total:
            pausa = random.uniform(intervalo_min, intervalo_max)
            print(f"    Aguardando {pausa:.1f}s...")
            time.sleep(pausa)

    # Salva log consolidado
    log_path = OUT_DIR / f"log_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    log_path.write_text(json.dumps(log, ensure_ascii=False, indent=2), encoding="utf-8")

    enviados  = sum(1 for r in log if r.get("status") == "enviado")
    erros     = sum(1 for r in log if r.get("status") == "erro")
    ignorados = sum(1 for r in log if r.get("status") == "ignorado")

    banner("Resultado")
    print(f"  Enviados : {enviados}")
    print(f"  Erros    : {erros}")
    print(f"  Ignorados: {ignorados}")
    print(f"  Log salvo: {log_path}")

    input("\nPressione ENTER para fechar o navegador...")
    driver.quit()


if __name__ == "__main__":
    main()
