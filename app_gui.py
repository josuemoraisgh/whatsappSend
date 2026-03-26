# -*- coding: utf-8 -*-
"""
app_gui.py — WhatsApp Sender  (interface gráfica)

Envia mensagens e arquivos via WhatsApp Web sem API oficial.
Requer Google Chrome instalado. Execute instal.bat para dependências.
"""

import json
import queue
import re
import threading
import time
import random
import urllib.parse
from datetime import datetime
from pathlib import Path

import tkinter as tk
from tkinter import ttk, filedialog, messagebox, scrolledtext


# ══════════════════════════════════════════════════════════════════
#  PALETA DE CORES
# ══════════════════════════════════════════════════════════════════
VERDE_WA    = "#25d366"   # verde WhatsApp
VERDE_ESC   = "#075e54"   # cabeçalho escuro
VERDE_MED   = "#128c7e"   # médio
VERDE_HOV   = "#1da851"   # hover
VERDE_PRSS  = "#179c47"   # pressionado
VERDE_CLR   = "#dcf8c6"   # linha enviada
CINZA_BG    = "#f0f2f5"   # bg geral
CINZA_CARD  = "#ffffff"   # cards / entries
CINZA_BTN   = "#607d8b"   # botão neutro
CINZA_BTN_H = "#546e7a"
CINZA_BTN_P = "#455a64"
VERMELHO    = "#e53935"
VERMELHO_H  = "#c62828"
VERMELHO_P  = "#b71c1c"
VERMELHO_CLR= "#ffcdd2"   # linha com erro
LARANJA     = "#f57c00"
LARANJA_CLR = "#fff9c4"   # linha ignorada
AZUL        = "#1565c0"
BRANCO      = "#ffffff"

# ══════════════════════════════════════════════════════════════════
#  ARQUIVOS / CONFIG
# ══════════════════════════════════════════════════════════════════
CONFIG_FILE   = Path("config.json")
CONTATOS_FILE = Path("contatos.json")
OUT_DIR       = Path("out")

CONFIG_PADRAO = {
    "mensagem_padrao":      "Olá {nome}!",
    "perfil_chrome":        str(Path.home() / "whatsapp_chrome_profile"),
    "chromedriver_caminho": "",
    "intervalo_min":        6,
    "intervalo_max":        14,
    "timeout_pagina":       40,
}

# ══════════════════════════════════════════════════════════════════
#  SELETORES CSS — WhatsApp Web
# ══════════════════════════════════════════════════════════════════
SEL_LOGIN_OK = (
    '[data-icon="chat"],'
    '[data-testid="chat-list"],'
    'div[aria-label="Lista de conversas"],'
    'div[aria-label="Conversation list"],'
    '#pane-side'
)
SEL_MSG_BOX = (
    'div[contenteditable="true"][data-tab="10"],'
    'div[contenteditable="true"][aria-label*="mensagem"],'
    'div[contenteditable="true"][aria-label*="message"],'
    'div[contenteditable="true"][aria-label*="Mensagem"],'
    'footer div[contenteditable="true"]'
)
SEL_ATTACH_BTN = [
    'span[data-icon="attach-menu-plus"]',
    'span[data-icon="plus"]',
    'div[title="Attach"]',
    'button[aria-label="Attach"]',
    'span[data-icon="clip"]',
]
SEL_SEND_BTN = [
    'span[data-icon="send"]',
    'div[aria-label="Enviar"]',
    'div[aria-label="Send"]',
    'button[aria-label="Send"]',
    'span[data-testid="send"]',
]


# ══════════════════════════════════════════════════════════════════
#  UTILITÁRIOS
# ══════════════════════════════════════════════════════════════════
def formatar_telefone(tel: str) -> str:
    digits = re.sub(r"\D+", "", str(tel))
    if digits.startswith("0"):
        digits = digits[1:]
    if len(digits) in (10, 11):
        digits = "55" + digits
    return digits


def montar_mensagem(template: str, contato: dict) -> str:
    try:
        return template.format_map(contato)
    except (KeyError, ValueError):
        return template


# ══════════════════════════════════════════════════════════════════
#  BOTÃO ARREDONDADO (Canvas)
# ══════════════════════════════════════════════════════════════════
class RoundedButton(tk.Canvas):
    """Botão com cantos arredondados, hover e estado disabled."""

    def __init__(self, parent, text="", command=None,
                 width=130, height=32, radius=16,
                 bg=VERDE_WA, fg=BRANCO,
                 hover_bg=VERDE_HOV, pressed_bg=VERDE_PRSS,
                 disabled_bg="#b0bec5", disabled_fg="#eceff1",
                 font_spec=("Segoe UI", 9, "bold"),
                 canvas_bg=CINZA_BG, **kw):
        super().__init__(parent, width=width, height=height,
                         highlightthickness=0, borderwidth=0,
                         bg=canvas_bg, cursor="hand2", **kw)
        self._text        = text
        self._command     = command
        self._bg          = bg
        self._hover_bg    = hover_bg
        self._pressed_bg  = pressed_bg
        self._disabled_bg = disabled_bg
        self._disabled_fg = disabled_fg
        self._fg          = fg
        self._font        = font_spec
        self._bw          = width   # btn width  (NÃO sobrescrever self._w do tkinter)
        self._bh          = height  # btn height
        self._br          = radius  # btn radius
        self._state       = "normal"
        self._pressed     = False

        self._draw(self._bg)

        self.bind("<Enter>",           self._on_enter)
        self.bind("<Leave>",           self._on_leave)
        self.bind("<Button-1>",        self._on_press)
        self.bind("<ButtonRelease-1>", self._on_release)

    def _draw(self, fill_color: str):
        self.delete("all")
        text_fill = self._disabled_fg if self._state == "disabled" else self._fg
        self._rrect(2, 2, self._bw - 2, self._bh - 2, self._br,
                    fill=fill_color, outline="")
        self.create_text(self._bw // 2, self._bh // 2,
                         text=self._text, fill=text_fill, font=self._font)

    def _rrect(self, x1, y1, x2, y2, r, **kw):
        """Retângulo arredondado via polígono smooth."""
        pts = [
            x1 + r, y1,   x2 - r, y1,
            x2,     y1,   x2,     y1 + r,
            x2,     y2 - r, x2,   y2,
            x2 - r, y2,   x1 + r, y2,
            x1,     y2,   x1,     y2 - r,
            x1,     y1 + r, x1,   y1,
        ]
        self.create_polygon(pts, smooth=True, **kw)

    def _on_enter(self, _):
        if self._state == "normal":
            self._draw(self._hover_bg)

    def _on_leave(self, _):
        if self._state == "normal":
            self._pressed = False
            self._draw(self._bg)

    def _on_press(self, _):
        if self._state == "normal":
            self._pressed = True
            self._draw(self._pressed_bg)

    def _on_release(self, e):
        if self._state == "normal" and self._pressed:
            self._pressed = False
            inside = 0 <= e.x <= self._bw and 0 <= e.y <= self._bh
            self._draw(self._hover_bg if inside else self._bg)
            if inside and self._command:
                self._command()

    def config(self, **kw):
        redraw = False
        if "state" in kw:
            self._state = kw.pop("state")
            redraw = True
        if "text" in kw:
            self._text = kw.pop("text")
            redraw = True
        if "command" in kw:
            self._command = kw.pop("command")
        if redraw:
            self._draw(self._disabled_bg if self._state == "disabled" else self._bg)
        if kw:
            super().config(**kw)

    configure = config


# ══════════════════════════════════════════════════════════════════
#  DIÁLOGO DE CONTATO
# ══════════════════════════════════════════════════════════════════
class ContatoDialog(tk.Toplevel):
    """Modal para adicionar / editar um contato."""

    def __init__(self, parent, contato: dict | None = None, title: str = "Contato"):
        super().__init__(parent)
        self.title(title)
        self.configure(bg=CINZA_BG)
        self.resizable(False, False)
        self.grab_set()
        self.result: dict | None = None
        self._build(contato or {})
        self.update_idletasks()
        px = parent.winfo_rootx() + (parent.winfo_width()  - self.winfo_width())  // 2
        py = parent.winfo_rooty() + (parent.winfo_height() - self.winfo_height()) // 2
        self.geometry(f"+{px}+{py}")
        self.wait_window()

    def _build(self, c: dict):
        # Cabeçalho
        hdr = tk.Frame(self, bg=VERDE_ESC)
        hdr.pack(fill="x")
        tk.Label(hdr, text="   Dados do Contato",
                 bg=VERDE_ESC, fg=BRANCO,
                 font=("Segoe UI", 11, "bold")).pack(side="left", pady=10, padx=8)

        # Corpo
        body = tk.Frame(self, bg=CINZA_BG, padx=22, pady=16)
        body.pack(fill="both", expand=True)
        body.columnconfigure(0, weight=1)

        def lbl(text, row):
            tk.Label(body, text=text, bg=CINZA_BG, fg="#333",
                     font=("Segoe UI", 9, "bold")).grid(
                row=row, column=0, sticky="w", pady=(10, 2))

        self.v_nome = tk.StringVar(value=c.get("nome", ""))
        self.v_tel  = tk.StringVar(value=c.get("telefone", ""))

        lbl("Nome:", 0)
        ttk.Entry(body, textvariable=self.v_nome, width=42).grid(
            row=1, column=0, sticky="ew")

        lbl("Telefone:", 2)
        ttk.Entry(body, textvariable=self.v_tel, width=42).grid(
            row=3, column=0, sticky="ew")
        tk.Label(body, text="Ex: 5534991110001  ou  (34) 9 9111-0001",
                 bg=CINZA_BG, fg="#999", font=("Segoe UI", 8)).grid(
            row=4, column=0, sticky="w")

        lbl("Mensagem individual (opcional):", 5)
        self.txt_msg = tk.Text(body, width=42, height=4, wrap="word",
                               font=("Segoe UI", 9), relief="solid",
                               borderwidth=1, bg=CINZA_CARD)
        self.txt_msg.insert("1.0", c.get("mensagem", ""))
        self.txt_msg.grid(row=6, column=0, sticky="ew")
        tk.Label(body, text="Vazio = usa mensagem padrão  ·  Use {nome}, {telefone}…",
                 bg=CINZA_BG, fg="#999", font=("Segoe UI", 8)).grid(
            row=7, column=0, sticky="w", pady=(2, 14))

        # Botões
        btns = tk.Frame(body, bg=CINZA_BG)
        btns.grid(row=8, column=0, sticky="e")
        RoundedButton(btns, text="  Salvar  ", command=self._salvar,
                      width=100, height=30, radius=15,
                      canvas_bg=CINZA_BG).pack(side="left", padx=(0, 8))
        RoundedButton(btns, text=" Cancelar ", command=self.destroy,
                      width=100, height=30, radius=15,
                      bg=CINZA_BTN, hover_bg=CINZA_BTN_H, pressed_bg=CINZA_BTN_P,
                      canvas_bg=CINZA_BG).pack(side="left")

    def _salvar(self):
        tel = self.v_tel.get().strip()
        if not tel:
            messagebox.showwarning("Campo obrigatório",
                                   "O campo Telefone é obrigatório.", parent=self)
            return
        self.result = {
            "nome":      self.v_nome.get().strip(),
            "telefone":  tel,
            "mensagem":  self.txt_msg.get("1.0", "end-1c").strip(),
        }
        self.destroy()


# ══════════════════════════════════════════════════════════════════
#  APLICAÇÃO PRINCIPAL
# ══════════════════════════════════════════════════════════════════
class AppWhatsApp(tk.Tk):

    def __init__(self):
        super().__init__()
        self.title("WhatsApp Sender")
        self.geometry("1060x740")
        self.minsize(900, 620)
        self.configure(bg=CINZA_BG)

        self.config_data     = self._carregar_config()
        self.contatos        = self._carregar_contatos()
        self._send_queue     = queue.Queue()
        self._sending        = False
        # {tel_formatado: "enviado" | "erro" | "ignorado"}
        self._status_contato: dict[str, str] = {}

        self._build_theme()
        self._build_ui()
        self._atualizar_lista()
        self._atualizar_btns_count()
        self.after(150, self._processar_fila)

    # ──────────────────────────── TEMA ────────────────────────────

    def _build_theme(self):
        s = ttk.Style(self)
        s.theme_use("clam")

        s.configure(".", font=("Segoe UI", 9), background=CINZA_BG, foreground="#111")
        s.configure("TFrame",  background=CINZA_BG)
        s.configure("TLabel",  background=CINZA_BG, foreground="#222")

        # Notebook / abas
        s.configure("TNotebook", background=VERDE_ESC, borderwidth=0, tabmargins=[0, 0, 0, 0])
        s.configure("TNotebook.Tab",
                    background=VERDE_MED, foreground=BRANCO,
                    padding=[16, 7], font=("Segoe UI", 9, "bold"))
        s.map("TNotebook.Tab",
              background=[("selected", VERDE_WA)],
              foreground=[("selected", BRANCO)])

        # Entry
        s.configure("TEntry",
                    fieldbackground=CINZA_CARD,
                    bordercolor="#ccc", lightcolor="#eee",
                    darkcolor="#aaa", borderwidth=1)
        s.map("TEntry", bordercolor=[("focus", VERDE_MED)])

        # Treeview
        s.configure("Treeview",
                    background=CINZA_CARD, fieldbackground=CINZA_CARD,
                    rowheight=26, font=("Segoe UI", 9))
        s.configure("Treeview.Heading",
                    background=VERDE_ESC, foreground=BRANCO,
                    font=("Segoe UI", 9, "bold"),
                    relief="flat", borderwidth=0)
        s.map("Treeview.Heading", background=[("active", VERDE_MED)])
        s.map("Treeview",
              background=[("selected", VERDE_MED)],
              foreground=[("selected", BRANCO)])

        # Progressbar
        s.configure("green.Horizontal.TProgressbar",
                    troughcolor="#ddd", background=VERDE_WA,
                    borderwidth=0, lightcolor=VERDE_WA, darkcolor=VERDE_WA)

        # Scrollbar
        s.configure("TScrollbar",
                    background=CINZA_BG, troughcolor="#e0e0e0",
                    relief="flat", borderwidth=0, arrowsize=12)

    # ──────────────────────────── PERSISTÊNCIA ────────────────────────────

    def _carregar_config(self) -> dict:
        if CONFIG_FILE.exists():
            try:
                d = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
                for k, v in CONFIG_PADRAO.items():
                    d.setdefault(k, v)
                return d
            except Exception:
                pass
        return dict(CONFIG_PADRAO)

    def _salvar_config(self):
        CONFIG_FILE.write_text(
            json.dumps(self.config_data, ensure_ascii=False, indent=4),
            encoding="utf-8")

    def _carregar_contatos(self) -> list:
        if CONTATOS_FILE.exists():
            try:
                return json.loads(CONTATOS_FILE.read_text(encoding="utf-8"))
            except Exception:
                pass
        return []

    def _salvar_contatos(self):
        CONTATOS_FILE.write_text(
            json.dumps(self.contatos, ensure_ascii=False, indent=2),
            encoding="utf-8")

    # ──────────────────────────── CONSTRUÇÃO DA UI ────────────────────────────

    def _build_ui(self):
        # ── Header ──────────────────────────────────────────────
        hdr = tk.Frame(self, bg=VERDE_ESC, height=52)
        hdr.pack(fill="x", side="top")
        hdr.pack_propagate(False)

        tk.Label(hdr, text="  \U0001f4ac  WhatsApp Sender",
                 bg=VERDE_ESC, fg=BRANCO,
                 font=("Segoe UI", 14, "bold")).pack(side="left", padx=14)

        self.lbl_header_info = tk.Label(
            hdr, text="", bg=VERDE_ESC, fg="#a8e6cf",
            font=("Segoe UI", 9))
        self.lbl_header_info.pack(side="right", padx=16)

        # ── Notebook ────────────────────────────────────────────
        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill="both", expand=True)

        self._build_tab_contatos()
        self._build_tab_mensagem()
        self._build_tab_config()
        self._build_tab_envio()

        # ── Barra de status ─────────────────────────────────────
        status_bar = tk.Frame(self, bg=VERDE_ESC, height=26)
        status_bar.pack(fill="x", side="bottom")
        status_bar.pack_propagate(False)
        self.status_var = tk.StringVar(value="Pronto.")
        tk.Label(status_bar, textvariable=self.status_var,
                 bg=VERDE_ESC, fg="#c8f0dc",
                 font=("Segoe UI", 8), anchor="w").pack(
            fill="x", side="left", padx=10)

    # ╔══════════════════════════════════════════════════════════╗
    # ║  TAB — CONTATOS                                          ║
    # ╚══════════════════════════════════════════════════════════╝

    def _build_tab_contatos(self):
        outer = tk.Frame(self.notebook, bg=CINZA_BG)
        self.notebook.add(outer, text="  Contatos  ")

        # Treeview
        tree_wrap = tk.Frame(outer, bg=CINZA_BG)
        tree_wrap.pack(fill="both", expand=True, padx=10, pady=(10, 6))

        cols = ("nome", "telefone", "mensagem", "status")
        self.tree = ttk.Treeview(tree_wrap, columns=cols,
                                 show="headings", selectmode="extended")
        self.tree.heading("nome",     text="Nome")
        self.tree.heading("telefone", text="Telefone")
        self.tree.heading("mensagem", text="Mensagem Individual")
        self.tree.heading("status",   text="Status")
        self.tree.column("nome",     width=220, minwidth=120)
        self.tree.column("telefone", width=150, minwidth=100)
        self.tree.column("mensagem", width=380, stretch=True, minwidth=160)
        self.tree.column("status",   width=120, minwidth=90, anchor="center")

        # Tags de cor por status
        self.tree.tag_configure("row_ok",   background=VERDE_CLR,    foreground="#1b5e20")
        self.tree.tag_configure("row_erro", background=VERMELHO_CLR, foreground="#b71c1c")
        self.tree.tag_configure("row_ign",  background=LARANJA_CLR,  foreground="#e65100")

        vsb = ttk.Scrollbar(tree_wrap, orient="vertical",   command=self.tree.yview)
        hsb = ttk.Scrollbar(tree_wrap, orient="horizontal", command=self.tree.xview)
        self.tree.configure(yscrollcommand=vsb.set, xscrollcommand=hsb.set)
        self.tree.grid(row=0, column=0, sticky="nsew")
        vsb.grid(row=0, column=1, sticky="ns")
        hsb.grid(row=1, column=0, sticky="ew")
        tree_wrap.rowconfigure(0, weight=1)
        tree_wrap.columnconfigure(0, weight=1)

        self.tree.bind("<Double-1>",         lambda _: self._editar_contato())
        self.tree.bind("<<TreeviewSelect>>", lambda _: self._atualizar_btns_count())
        self.tree.bind("<Button-3>",         self._menu_contexto)

        # Barra de botões
        btn_area = tk.Frame(outer, bg=CINZA_BG, pady=6)
        btn_area.pack(fill="x", padx=10)

        grp1 = tk.Frame(btn_area, bg=CINZA_BG)
        grp1.pack(side="left")
        RoundedButton(grp1, text="+  Novo",    command=self._novo_contato,
                      width=105, height=30, radius=15,
                      canvas_bg=CINZA_BG).pack(side="left", padx=(0, 4))
        RoundedButton(grp1, text="Editar",     command=self._editar_contato,
                      width=90, height=30, radius=15,
                      bg=AZUL, hover_bg="#1976d2", pressed_bg=AZUL,
                      canvas_bg=CINZA_BG).pack(side="left", padx=(0, 4))
        RoundedButton(grp1, text="Remover",    command=self._remover_contato,
                      width=90, height=30, radius=15,
                      bg=VERMELHO, hover_bg=VERMELHO_H, pressed_bg=VERMELHO_P,
                      canvas_bg=CINZA_BG).pack(side="left", padx=(0, 16))

        grp2 = tk.Frame(btn_area, bg=CINZA_BG)
        grp2.pack(side="left")
        RoundedButton(grp2, text="Importar JSON", command=self._importar_json,
                      width=130, height=30, radius=15,
                      bg=CINZA_BTN, hover_bg=CINZA_BTN_H, pressed_bg=CINZA_BTN_P,
                      canvas_bg=CINZA_BG).pack(side="left", padx=(0, 4))
        RoundedButton(grp2, text="Exportar JSON", command=self._exportar_json,
                      width=130, height=30, radius=15,
                      bg=CINZA_BTN, hover_bg=CINZA_BTN_H, pressed_bg=CINZA_BTN_P,
                      canvas_bg=CINZA_BG).pack(side="left")

        RoundedButton(btn_area, text="Limpar Tudo", command=self._limpar_contatos,
                      width=120, height=30, radius=15,
                      bg="#9e9e9e", hover_bg="#757575", pressed_bg="#616161",
                      canvas_bg=CINZA_BG).pack(side="right")

        self.lbl_total = tk.Label(outer, text="0 contato(s)",
                                  bg=CINZA_BG, fg="#777",
                                  font=("Segoe UI", 8))
        self.lbl_total.pack(anchor="w", padx=12, pady=(0, 6))

    # ╔══════════════════════════════════════════════════════════╗
    # ║  TAB — MENSAGEM & ARQUIVOS                               ║
    # ╚══════════════════════════════════════════════════════════╝

    def _build_tab_mensagem(self):
        outer = tk.Frame(self.notebook, bg=CINZA_BG)
        self.notebook.add(outer, text="  Mensagem & Arquivos  ")

        # Card mensagem
        card1 = tk.Frame(outer, bg=CINZA_CARD,
                         highlightthickness=1, highlightbackground="#ddd")
        card1.pack(fill="x", padx=14, pady=(14, 8))
        tk.Frame(card1, bg=VERDE_WA, height=4).pack(fill="x")

        body1 = tk.Frame(card1, bg=CINZA_CARD, padx=14, pady=12)
        body1.pack(fill="x")

        tk.Label(body1, text="Mensagem padrao",
                 bg=CINZA_CARD, fg=VERDE_ESC,
                 font=("Segoe UI", 10, "bold")).pack(anchor="w")
        tk.Label(body1,
                 text="Usada quando o contato nao tem mensagem individual."
                      "  Variaveis: {nome}  {telefone}",
                 bg=CINZA_CARD, fg="#888",
                 font=("Segoe UI", 8)).pack(anchor="w", pady=(2, 8))

        self.txt_msg_padrao = tk.Text(body1, height=6, wrap="word",
                                      font=("Segoe UI", 10),
                                      bg="#fafafa", relief="solid",
                                      borderwidth=1)
        self.txt_msg_padrao.insert("1.0", self.config_data.get("mensagem_padrao", ""))
        self.txt_msg_padrao.pack(fill="x")

        btn_row1 = tk.Frame(body1, bg=CINZA_CARD)
        btn_row1.pack(anchor="e", pady=(10, 2))
        RoundedButton(btn_row1, text="Salvar Mensagem",
                      command=self._salvar_mensagem,
                      width=155, height=30, radius=15,
                      canvas_bg=CINZA_CARD).pack()

        # Card arquivos
        card2 = tk.Frame(outer, bg=CINZA_CARD,
                         highlightthickness=1, highlightbackground="#ddd")
        card2.pack(fill="x", padx=14, pady=(0, 14))
        tk.Frame(card2, bg=LARANJA, height=4).pack(fill="x")

        body2 = tk.Frame(card2, bg=CINZA_CARD, padx=14, pady=12)
        body2.pack(fill="x")

        tk.Label(body2, text="Arquivos para enviar  (ate 3)",
                 bg=CINZA_CARD, fg="#e65100",
                 font=("Segoe UI", 10, "bold")).pack(anchor="w")
        tk.Label(body2,
                 text="Enviados apos a mensagem de texto, um a um."
                      " Suporta qualquer tipo de arquivo.",
                 bg=CINZA_CARD, fg="#888",
                 font=("Segoe UI", 8)).pack(anchor="w", pady=(2, 10))

        self.v_arquivos  = [tk.StringVar(), tk.StringVar(), tk.StringVar()]
        CORES_ARQ = [VERDE_WA, "#2196f3", LARANJA]

        for i, (var, cor) in enumerate(zip(self.v_arquivos, CORES_ARQ), 1):
            row = tk.Frame(body2, bg=CINZA_CARD)
            row.pack(fill="x", pady=4)
            tk.Label(row, text=f" {i} ", bg=cor, fg=BRANCO,
                     font=("Segoe UI", 9, "bold"),
                     width=3).pack(side="left", padx=(0, 8))
            ttk.Entry(row, textvariable=var).pack(
                side="left", fill="x", expand=True, padx=(0, 6))
            RoundedButton(row, text="Procurar", width=82, height=26, radius=13,
                          command=lambda v=var: self._browse_file(v),
                          bg=CINZA_BTN, hover_bg=CINZA_BTN_H, pressed_bg=CINZA_BTN_P,
                          font_spec=("Segoe UI", 8, "bold"),
                          canvas_bg=CINZA_CARD).pack(side="left", padx=(0, 4))
            RoundedButton(row, text="X", width=28, height=26, radius=13,
                          command=lambda v=var: v.set(""),
                          bg="#9e9e9e", hover_bg="#757575", pressed_bg="#616161",
                          font_spec=("Segoe UI", 9, "bold"),
                          canvas_bg=CINZA_CARD).pack(side="left")

    # ╔══════════════════════════════════════════════════════════╗
    # ║  TAB — CONFIGURAÇÕES                                     ║
    # ╚══════════════════════════════════════════════════════════╝

    def _build_tab_config(self):
        outer = tk.Frame(self.notebook, bg=CINZA_BG)
        self.notebook.add(outer, text="  Configuracoes  ")

        card = tk.Frame(outer, bg=CINZA_CARD,
                        highlightthickness=1, highlightbackground="#ddd")
        card.pack(fill="x", padx=14, pady=14)
        tk.Frame(card, bg=AZUL, height=4).pack(fill="x")

        body = tk.Frame(card, bg=CINZA_CARD, padx=20, pady=16)
        body.pack(fill="x")
        body.columnconfigure(1, weight=1)

        self.v_perfil  = tk.StringVar(value=self.config_data.get("perfil_chrome", ""))
        self.v_cd_path = tk.StringVar(value=self.config_data.get("chromedriver_caminho", ""))
        self.v_timeout = tk.StringVar(value=str(self.config_data.get("timeout_pagina", 40)))
        self.v_int_min = tk.StringVar(value=str(self.config_data.get("intervalo_min", 6)))
        self.v_int_max = tk.StringVar(value=str(self.config_data.get("intervalo_max", 14)))

        def campo(r, label, var, browse_fn=None, hint=""):
            tk.Label(body, text=label, bg=CINZA_CARD, fg="#333",
                     font=("Segoe UI", 9, "bold"), anchor="e",
                     width=22).grid(row=r, column=0, sticky="e",
                                    pady=(8, 0), padx=(0, 8))
            ttk.Entry(body, textvariable=var).grid(
                row=r, column=1, sticky="ew", pady=(8, 0))
            if browse_fn:
                RoundedButton(body, text="...", width=34, height=28, radius=14,
                              command=browse_fn,
                              bg=CINZA_BTN, hover_bg=CINZA_BTN_H,
                              pressed_bg=CINZA_BTN_P,
                              font_spec=("Segoe UI", 9),
                              canvas_bg=CINZA_CARD).grid(
                    row=r, column=2, padx=(6, 0), pady=(8, 0))
            if hint:
                tk.Label(body, text=hint, bg=CINZA_CARD, fg="#999",
                         font=("Segoe UI", 8), anchor="w").grid(
                    row=r + 1, column=1, sticky="w", pady=(1, 0))

        campo(0, "Perfil Chrome:",       self.v_perfil,
              lambda: self._browse_dir(self.v_perfil),
              "Pasta de sessao do Chrome. Escaneie o QR code apenas na 1a execucao.")
        campo(2, "ChromeDriver:",        self.v_cd_path,
              lambda: self._browse_exe(self.v_cd_path),
              "Deixe vazio para baixar automaticamente via webdriver-manager.")
        campo(4, "Timeout (s):",         self.v_timeout,
              hint="Segundos aguardando elementos do WhatsApp Web.")
        campo(6, "Intervalo min. (s):",  self.v_int_min,
              hint="Pausa minima entre envios (anti-bloqueio).")
        campo(8, "Intervalo max. (s):",  self.v_int_max)

        btn_f = tk.Frame(body, bg=CINZA_CARD)
        btn_f.grid(row=10, column=0, columnspan=3, pady=(20, 4))
        RoundedButton(btn_f, text="Salvar Configuracoes",
                      command=self._salvar_config_gui,
                      width=190, height=32, radius=16,
                      canvas_bg=CINZA_CARD).pack()

    # ╔══════════════════════════════════════════════════════════╗
    # ║  TAB — ENVIAR                                            ║
    # ╚══════════════════════════════════════════════════════════╝

    def _build_tab_envio(self):
        outer = tk.Frame(self.notebook, bg=CINZA_BG)
        self.notebook.add(outer, text="  Enviar  ")

        # Painel de ação
        action = tk.Frame(outer, bg=CINZA_CARD,
                          highlightthickness=1, highlightbackground="#ddd")
        action.pack(fill="x", padx=10, pady=(10, 6))
        tk.Frame(action, bg=VERDE_WA, height=4).pack(fill="x")

        top = tk.Frame(action, bg=CINZA_CARD, padx=12, pady=12)
        top.pack(fill="x")

        # Linha 1 — botões de envio
        send_row = tk.Frame(top, bg=CINZA_CARD)
        send_row.pack(fill="x", pady=(0, 10))

        self.btn_todos = RoundedButton(
            send_row, text="Enviar Todos (0)",
            command=lambda: self._iniciar_envio("todos"),
            width=160, height=36, radius=18,
            canvas_bg=CINZA_CARD)
        self.btn_todos.pack(side="left", padx=(0, 8))

        self.btn_sel = RoundedButton(
            send_row, text="Selecionados (0)",
            command=lambda: self._iniciar_envio("selecionados"),
            width=170, height=36, radius=18,
            bg=AZUL, hover_bg="#1976d2", pressed_bg=AZUL,
            canvas_bg=CINZA_CARD)
        self.btn_sel.pack(side="left", padx=(0, 8))

        self.btn_falhas = RoundedButton(
            send_row, text="Reenviar Falhas (0)",
            command=lambda: self._iniciar_envio("falhas"),
            width=185, height=36, radius=18,
            bg=VERMELHO, hover_bg=VERMELHO_H, pressed_bg=VERMELHO_P,
            canvas_bg=CINZA_CARD)
        self.btn_falhas.pack(side="left", padx=(0, 20))

        self.btn_parar = RoundedButton(
            send_row, text="Parar",
            command=self._parar_envio,
            width=100, height=36, radius=18,
            bg="#9e9e9e", hover_bg="#757575", pressed_bg="#616161",
            canvas_bg=CINZA_CARD)
        self.btn_parar.config(state="disabled")
        self.btn_parar.pack(side="left")

        # Linha 2 — dica
        tk.Label(top,
                 text="Dica: use Ctrl+Clique na aba Contatos para selecionar individualmente."
                      "  Clique direito para opções rápidas.",
                 bg=CINZA_CARD, fg="#888",
                 font=("Segoe UI", 8)).pack(anchor="w", pady=(0, 6))

        # Linha 3 — progress
        prog_row = tk.Frame(top, bg=CINZA_CARD)
        prog_row.pack(fill="x")
        self.progress_var = tk.DoubleVar()
        ttk.Progressbar(prog_row, variable=self.progress_var,
                        maximum=100, length=420,
                        style="green.Horizontal.TProgressbar").pack(side="left")
        self.lbl_prog = tk.Label(prog_row, text="0 / 0",
                                 bg=CINZA_CARD, fg="#555",
                                 font=("Segoe UI", 9, "bold"), width=10)
        self.lbl_prog.pack(side="left", padx=10)

        # Log
        log_hdr = tk.Frame(outer, bg=CINZA_BG)
        log_hdr.pack(fill="x", padx=10, pady=(4, 2))
        tk.Label(log_hdr, text="Log de execucao:",
                 bg=CINZA_BG, fg="#333",
                 font=("Segoe UI", 9, "bold")).pack(side="left")
        RoundedButton(log_hdr, text="Limpar log",
                      command=self._limpar_log,
                      width=95, height=26, radius=13,
                      bg=CINZA_BTN, hover_bg=CINZA_BTN_H, pressed_bg=CINZA_BTN_P,
                      font_spec=("Segoe UI", 8, "bold"),
                      canvas_bg=CINZA_BG).pack(side="right")

        self.log_text = scrolledtext.ScrolledText(
            outer, wrap="word", state="disabled",
            font=("Consolas", 9), height=20,
            bg="#1e2a1e", fg="#c8f0dc",
            insertbackground=BRANCO,
            borderwidth=0, relief="flat")
        self.log_text.pack(fill="both", expand=True, padx=10, pady=(0, 8))

        self.log_text.tag_config("ok",    foreground="#69f0ae")
        self.log_text.tag_config("erro",  foreground="#ff5252")
        self.log_text.tag_config("info",  foreground="#82b1ff")
        self.log_text.tag_config("aviso", foreground="#ffd740")

    # ──────────────────────────── CONTATOS — HELPERS ──────────────────────────

    def _tag_para_status(self, status: str) -> str:
        return {"enviado": "row_ok", "erro": "row_erro", "ignorado": "row_ign"}.get(status, "")

    def _icone_status(self, status: str) -> str:
        return {"enviado": "v enviado", "erro": "x erro", "ignorado": "-- ignorado"}.get(status, "")

    def _atualizar_lista(self):
        for item in self.tree.get_children():
            self.tree.delete(item)
        for c in self.contatos:
            tel_fmt  = formatar_telefone(str(c.get("telefone", "")))
            status   = self._status_contato.get(tel_fmt, "")
            tag      = self._tag_para_status(status)
            icone    = self._icone_status(status)
            tags_row = (tag,) if tag else ()
            self.tree.insert("", "end", tags=tags_row, values=(
                c.get("nome", ""),
                c.get("telefone", ""),
                (c.get("mensagem") or "")[:70],
                icone,
            ))
        self.lbl_total.config(text=f"{len(self.contatos)} contato(s)")
        self._atualizar_btns_count()

    def _atualizar_btns_count(self):
        total     = len(self.contatos)
        sel_count = len(self.tree.selection())
        err_count = sum(1 for s in self._status_contato.values() if s == "erro")

        self.btn_todos.config( text=f"Enviar Todos ({total})")
        self.btn_sel.config(   text=f"Selecionados ({sel_count})")
        self.btn_falhas.config(text=f"Reenviar Falhas ({err_count})")

        if self._status_contato:
            ok  = sum(1 for s in self._status_contato.values() if s == "enviado")
            err = err_count
            self.lbl_header_info.config(
                text=f"v {ok} enviados   x {err} erros   de {total} contatos")
        else:
            self.lbl_header_info.config(text=f"{total} contato(s) carregado(s)")

    def _aplicar_status_treeview(self, telefone: str, status: str):
        """Atualiza cor e ícone de uma linha no treeview em tempo real."""
        tel_fmt = formatar_telefone(telefone)
        self._status_contato[tel_fmt] = status
        tag   = self._tag_para_status(status)
        icone = self._icone_status(status)
        for item in self.tree.get_children():
            vals = self.tree.item(item, "values")
            if formatar_telefone(str(vals[1])) == tel_fmt:
                self.tree.item(item,
                               tags=(tag,) if tag else (),
                               values=(vals[0], vals[1], vals[2], icone))
                break
        self._atualizar_btns_count()

    # ──────────────────────────── AÇÕES DE CONTATOS ────────────────────────────

    def _novo_contato(self):
        dlg = ContatoDialog(self, title="Novo Contato")
        if dlg.result:
            self.contatos.append(dlg.result)
            self._salvar_contatos()
            self._atualizar_lista()

    def _editar_contato(self):
        sel = self.tree.selection()
        if not sel:
            messagebox.showinfo("Nenhum selecionado",
                                "Selecione um contato para editar.")
            return
        idx = self.tree.index(sel[0])
        dlg = ContatoDialog(self, contato=self.contatos[idx], title="Editar Contato")
        if dlg.result:
            self.contatos[idx] = dlg.result
            self._salvar_contatos()
            self._atualizar_lista()

    def _remover_contato(self):
        sel = self.tree.selection()
        if not sel:
            return
        indices = sorted([self.tree.index(s) for s in sel], reverse=True)
        nomes = [
            self.contatos[i].get("nome") or self.contatos[i].get("telefone", "?")
            for i in indices
        ]
        lista = "\n".join(f"  - {n}" for n in nomes[:8])
        if len(nomes) > 8:
            lista += f"\n  ...e mais {len(nomes)-8}"
        if messagebox.askyesno("Confirmar remoção",
                               f"Remover {len(nomes)} contato(s)?\n\n{lista}"):
            for i in indices:
                self.contatos.pop(i)
            self._salvar_contatos()
            self._atualizar_lista()

    def _limpar_contatos(self):
        if not self.contatos:
            return
        if messagebox.askyesno("Confirmar",
                               f"Remover TODOS os {len(self.contatos)} contatos?"):
            self.contatos.clear()
            self._status_contato.clear()
            self._salvar_contatos()
            self._atualizar_lista()

    def _importar_json(self):
        path = filedialog.askopenfilename(
            filetypes=[("JSON", "*.json"), ("Todos", "*.*")],
            title="Importar contatos")
        if not path:
            return
        try:
            dados = json.loads(Path(path).read_text(encoding="utf-8"))
            if not isinstance(dados, list):
                raise ValueError("O arquivo deve conter uma lista JSON.")
            resp = messagebox.askquestion(
                "Importar",
                f"Encontrados {len(dados)} contato(s).\n\n"
                "Sim = substituir lista atual\nNao = adicionar ao final",
                icon="question")
            if resp == "yes":
                self.contatos = dados
                self._status_contato.clear()
            else:
                self.contatos.extend(dados)
            self._salvar_contatos()
            self._atualizar_lista()
            messagebox.showinfo("Importado", f"{len(dados)} contato(s) importado(s).")
        except Exception as exc:
            messagebox.showerror("Erro ao importar", str(exc))

    def _exportar_json(self):
        path = filedialog.asksaveasfilename(
            defaultextension=".json",
            filetypes=[("JSON", "*.json")],
            initialfile="contatos_export.json",
            title="Exportar contatos")
        if path:
            Path(path).write_text(
                json.dumps(self.contatos, ensure_ascii=False, indent=2),
                encoding="utf-8")
            messagebox.showinfo("Exportado", f"Salvo em:\n{path}")

    def _menu_contexto(self, event):
        """Menu de clique direito no treeview."""
        item = self.tree.identify_row(event.y)
        if item:
            if item not in self.tree.selection():
                self.tree.selection_set(item)

        menu = tk.Menu(self, tearoff=0,
                       bg=CINZA_CARD, fg="#222",
                       activebackground=VERDE_MED, activeforeground=BRANCO,
                       relief="flat", bd=1)
        menu.add_command(label="  Editar",               command=self._editar_contato)
        menu.add_command(label="  Enviar apenas este(s)", command=lambda: self._iniciar_envio("selecionados"))
        menu.add_separator()
        menu.add_command(label="  Remover selecionados", command=self._remover_contato)
        menu.add_separator()
        menu.add_command(label="  Selecionar todos",
                         command=lambda: self.tree.selection_set(self.tree.get_children()))
        menu.add_command(label="  Deselecionar todos",
                         command=lambda: self.tree.selection_remove(self.tree.get_children()))
        menu.tk_popup(event.x_root, event.y_root)

    # ──────────────────────────── BROWSE ────────────────────────────

    def _browse_file(self, var: tk.StringVar):
        p = filedialog.askopenfilename(title="Selecionar arquivo")
        if p:
            var.set(p)

    def _browse_dir(self, var: tk.StringVar):
        p = filedialog.askdirectory(title="Selecionar pasta do perfil Chrome")
        if p:
            var.set(p)

    def _browse_exe(self, var: tk.StringVar):
        p = filedialog.askopenfilename(
            filetypes=[("Executavel", "*.exe"), ("Todos", "*.*")],
            title="Selecionar ChromeDriver")
        if p:
            var.set(p)

    # ──────────────────────────── SALVAR ────────────────────────────

    def _salvar_mensagem(self):
        self.config_data["mensagem_padrao"] = \
            self.txt_msg_padrao.get("1.0", "end-1c").strip()
        self._salvar_config()
        self.status_var.set("Mensagem padrao salva.")

    def _salvar_config_gui(self):
        try:
            timeout = int(self.v_timeout.get())
            int_min = float(self.v_int_min.get())
            int_max = float(self.v_int_max.get())
        except ValueError:
            messagebox.showerror("Erro", "Timeout e intervalos devem ser numeros.")
            return
        if int_min > int_max:
            messagebox.showerror("Erro", "Intervalo minimo nao pode ser maior que o maximo.")
            return
        self.config_data.update({
            "perfil_chrome":        self.v_perfil.get().strip(),
            "chromedriver_caminho": self.v_cd_path.get().strip(),
            "timeout_pagina":       timeout,
            "intervalo_min":        int_min,
            "intervalo_max":        int_max,
        })
        self._salvar_config()
        messagebox.showinfo("Salvo", "Configuracoes salvas com sucesso.")

    # ──────────────────────────── LOG ────────────────────────────

    def _log(self, msg: str, tag: str = ""):
        self.log_text.config(state="normal")
        hora = datetime.now().strftime("%H:%M:%S")
        self.log_text.insert("end", f"[{hora}] {msg}\n", tag or None)
        self.log_text.see("end")
        self.log_text.config(state="disabled")

    def _limpar_log(self):
        self.log_text.config(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.config(state="disabled")

    # ──────────────────────────── ENVIO ────────────────────────────

    def _iniciar_envio(self, modo: str = "todos"):
        """
        modo:
          'todos'        — envia para todos os contatos
          'selecionados' — envia somente para os selecionados no treeview
          'falhas'       — reenvia apenas os que tiveram status 'erro'
        """
        if modo == "todos":
            contatos = list(self.contatos)
            if not contatos:
                messagebox.showwarning("Sem contatos", "Adicione contatos antes de enviar.")
                return

        elif modo == "selecionados":
            sel = self.tree.selection()
            if not sel:
                messagebox.showwarning(
                    "Nada selecionado",
                    "Selecione pelo menos um contato na aba Contatos.\n"
                    "Use Ctrl+Clique para multiplos ou clique direito > Selecionar todos.")
                return
            indices  = [self.tree.index(s) for s in sel]
            contatos = [self.contatos[i] for i in indices]

        elif modo == "falhas":
            contatos = [
                c for c in self.contatos
                if self._status_contato.get(
                    formatar_telefone(str(c.get("telefone", "")))) == "erro"
            ]
            if not contatos:
                messagebox.showinfo(
                    "Sem falhas",
                    "Nenhum contato com status de erro.\n"
                    "Execute um envio primeiro para identificar falhas.")
                return
        else:
            return

        # Sincroniza mensagem padrão
        self.config_data["mensagem_padrao"] = \
            self.txt_msg_padrao.get("1.0", "end-1c").strip()
        self._salvar_config()

        arquivos = [v.get().strip() for v in self.v_arquivos if v.get().strip()]
        for arq in arquivos:
            if not Path(arq).exists():
                messagebox.showwarning("Arquivo nao encontrado",
                                       f"O arquivo nao existe:\n{arq}")
                return

        self._sending = True
        self.btn_todos.config( state="disabled")
        self.btn_sel.config(   state="disabled")
        self.btn_falhas.config(state="disabled")
        self.btn_parar.config( state="normal")
        self.progress_var.set(0)
        self.lbl_prog.config(text=f"0 / {len(contatos)}")

        self.notebook.select(3)  # Vai para aba Enviar

        modo_label = {
            "todos":        "todos os contatos",
            "selecionados": f"{len(contatos)} selecionado(s)",
            "falhas":       f"{len(contatos)} com falha anterior",
        }[modo]
        self._log("=" * 55, "info")
        self._log(f"Modo: {modo_label}", "info")
        if arquivos:
            self._log(f"Arquivos: {', '.join(Path(a).name for a in arquivos)}", "aviso")

        threading.Thread(
            target=self._thread_envio,
            args=(contatos, dict(self.config_data), arquivos),
            daemon=True,
        ).start()

    def _parar_envio(self):
        self._sending = False
        self._send_queue.put(("log", "Parando apos o envio atual...", "aviso"))

    def _processar_fila(self):
        try:
            while True:
                item = self._send_queue.get_nowait()
                tipo = item[0]

                if tipo == "log":
                    self._log(item[1], item[2])

                elif tipo == "progresso":
                    _, atual, total = item
                    pct = (atual / total * 100) if total else 0
                    self.progress_var.set(pct)
                    self.lbl_prog.config(text=f"{atual} / {total}")

                elif tipo == "resultado_contato":
                    _, telefone, status = item
                    self._aplicar_status_treeview(telefone, status)

                elif tipo == "fim":
                    self._sending = False
                    self.btn_todos.config( state="normal")
                    self.btn_sel.config(   state="normal")
                    self.btn_falhas.config(state="normal")
                    self.btn_parar.config( state="disabled")
                    msg = item[1] if len(item) > 1 else "Concluido."
                    self.status_var.set(msg)
                    self._atualizar_btns_count()

        except queue.Empty:
            pass
        self.after(150, self._processar_fila)

    # ──────────────────────────── THREAD SELENIUM ────────────────────────────

    def _thread_envio(self, contatos: list, config: dict, arquivos: list):
        Q = self._send_queue

        def qlog(msg: str, tag: str = ""):
            Q.put(("log", msg, tag))

        # Importar Selenium
        try:
            from selenium import webdriver as wd
            from selenium.webdriver.chrome.options import Options
            from selenium.webdriver.chrome.service import Service
            from selenium.webdriver.common.by import By
            from selenium.webdriver.common.keys import Keys
            from selenium.webdriver.support.ui import WebDriverWait
            from selenium.webdriver.support import expected_conditions as EC
            from selenium.common.exceptions import TimeoutException, NoSuchElementException
        except ImportError:
            qlog("Selenium nao instalado. Execute instal.bat.", "erro")
            Q.put(("fim", "Erro: Selenium nao instalado."))
            return

        # Iniciar Chrome
        options = Options()
        profile_dir = config.get("perfil_chrome",
                                 str(Path.home() / "whatsapp_chrome_profile"))
        Path(profile_dir).mkdir(parents=True, exist_ok=True)
        options.add_argument(f"--user-data-dir={profile_dir}")
        options.add_argument("--profile-directory=Default")
        options.add_argument("--no-sandbox")
        options.add_argument("--disable-dev-shm-usage")
        options.add_argument("--disable-gpu")
        options.add_experimental_option("excludeSwitches", ["enable-logging"])
        options.add_experimental_option("useAutomationExtension", False)

        cd_path = config.get("chromedriver_caminho", "").strip()
        try:
            if cd_path and Path(cd_path).exists():
                service = Service(cd_path)
            else:
                local_cd = Path("Arquivos") / "chromedriver.exe"
                if local_cd.exists():
                    qlog(f"ChromeDriver local: {local_cd}", "info")
                    service = Service(str(local_cd))
                else:
                    qlog("Baixando ChromeDriver...", "info")
                    from webdriver_manager.chrome import ChromeDriverManager
                    service = Service(ChromeDriverManager().install())

            driver = wd.Chrome(service=service, options=options)
            driver.set_window_size(1280, 900)
        except Exception as exc:
            qlog(f"Erro ao iniciar Chrome: {exc}", "erro")
            Q.put(("fim", "Erro ao iniciar Chrome."))
            return

        # Aguardar login
        qlog("Abrindo WhatsApp Web — escaneie o QR code se solicitado...", "aviso")
        driver.get("https://web.whatsapp.com")
        try:
            WebDriverWait(driver, 120).until(
                EC.presence_of_element_located((By.CSS_SELECTOR, SEL_LOGIN_OK))
            )
            qlog("WhatsApp Web conectado!", "ok")
        except TimeoutException:
            qlog("Timeout no login. Feche e tente novamente.", "erro")
            driver.quit()
            Q.put(("fim", "Erro: timeout no login."))
            return

        # Loop de envios
        timeout   = int(config.get("timeout_pagina", 40))
        int_min   = float(config.get("intervalo_min", 6))
        int_max   = float(config.get("intervalo_max", 14))
        msg_pad   = config.get("mensagem_padrao", "Ola {nome}!")
        total     = len(contatos)
        log_lista = []

        OUT_DIR.mkdir(parents=True, exist_ok=True)

        for i, contato in enumerate(contatos, 1):
            if not self._sending:
                qlog("Envio interrompido pelo usuario.", "aviso")
                break

            nome     = contato.get("nome", "").strip()
            telefone = str(contato.get("telefone", "")).strip()

            if not telefone:
                qlog(f"[{i}/{total}] IGNORADO (sem telefone): {nome or '-'}", "aviso")
                Q.put(("resultado_contato", telefone, "ignorado"))
                log_lista.append({"nome": nome, "status": "ignorado",
                                  "detalhe": "telefone vazio"})
                Q.put(("progresso", i, total))
                continue

            template = str(contato.get("mensagem") or msg_pad).strip() or msg_pad
            mensagem = montar_mensagem(template, {**contato, "nome": nome})
            tel      = formatar_telefone(telefone)

            qlog(f"[{i}/{total}]  {nome or tel}", "info")

            resultado = {
                "nome":     nome,
                "telefone": telefone,
                "status":   "erro",
                "detalhe":  "",
                "horario":  datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            }

            # Envia mensagem de texto
            texto_ok = False
            try:
                url = (f"https://web.whatsapp.com/send"
                       f"?phone={tel}&text={urllib.parse.quote(mensagem)}")
                driver.get(url)

                caixa = WebDriverWait(driver, timeout).until(
                    EC.presence_of_element_located((By.CSS_SELECTOR, SEL_MSG_BOX))
                )
                time.sleep(1.5)
                caixa.click()
                time.sleep(0.4)
                caixa.send_keys(Keys.ENTER)
                time.sleep(2.0)

                texto_ok            = True
                resultado["status"] = "enviado"
                resultado["detalhe"]= "texto enviado"
                qlog("   Texto enviado.", "ok")

            except TimeoutException:
                detalhe = f"timeout ({timeout}s)"
                try:
                    popup   = driver.find_element(By.CSS_SELECTOR, 'div[role="dialog"]')
                    detalhe = f"numero invalido: {popup.text[:60]}"
                    for sel_btn in ('button[aria-label="OK"]', 'div[role="button"]'):
                        try:
                            popup.find_element(By.CSS_SELECTOR, sel_btn).click()
                            break
                        except NoSuchElementException:
                            pass
                except NoSuchElementException:
                    pass
                resultado["detalhe"] = detalhe
                qlog(f"   FALHA: {detalhe}", "erro")

            except Exception as exc:
                resultado["detalhe"] = str(exc)[:120]
                qlog(f"   FALHA: {resultado['detalhe'][:80]}", "erro")

            # Envia arquivos
            if texto_ok and arquivos:
                for j, arq in enumerate(arquivos, 1):
                    if not self._sending:
                        break
                    arq_path = Path(arq)
                    if not arq_path.exists():
                        qlog(f"   Arquivo {j} nao encontrado.", "aviso")
                        continue
                    try:
                        ok = _enviar_arquivo(
                            driver, str(arq_path.resolve()), timeout,
                            By, Keys, WebDriverWait, EC,
                            TimeoutException, NoSuchElementException)
                        if ok:
                            qlog(f"   Arquivo {j} ({arq_path.name}) enviado.", "ok")
                            resultado["detalhe"] += f" | arq{j} ok"
                        else:
                            qlog(f"   Arquivo {j} ({arq_path.name}) falhou.", "aviso")
                    except Exception as exc:
                        qlog(f"   Arquivo {j} erro: {exc}", "aviso")

            log_lista.append(resultado)
            Q.put(("resultado_contato", telefone, resultado["status"]))
            Q.put(("progresso", i, total))

            if i < total and self._sending:
                pausa = random.uniform(int_min, int_max)
                qlog(f"   Aguardando {pausa:.1f}s...", "")
                time.sleep(pausa)

        # Salva log
        log_path = OUT_DIR / f"log_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        log_path.write_text(
            json.dumps(log_lista, ensure_ascii=False, indent=2), encoding="utf-8")

        enviados  = sum(1 for r in log_lista if r.get("status") == "enviado")
        erros     = sum(1 for r in log_lista if r.get("status") == "erro")
        ignorados = sum(1 for r in log_lista if r.get("status") == "ignorado")

        qlog("=" * 55, "info")
        qlog(f"Enviados:   {enviados}", "ok")
        if erros:
            qlog(f"Erros:      {erros}", "erro")
        if ignorados:
            qlog(f"Ignorados:  {ignorados}", "aviso")
        qlog(f"Log salvo: {log_path.name}", "info")

        driver.quit()
        Q.put(("fim", f"Concluido — {enviados} enviados, {erros} erros."))


# ══════════════════════════════════════════════════════════════════
#  ENVIO DE ARQUIVO (função standalone)
# ══════════════════════════════════════════════════════════════════
def _enviar_arquivo(driver, file_path: str, timeout: int,
                    By, Keys, WebDriverWait, EC,
                    TimeoutException, NoSuchElementException) -> bool:
    attach_btn = None
    for sel in SEL_ATTACH_BTN:
        try:
            attach_btn = driver.find_element(By.CSS_SELECTOR, sel)
            break
        except NoSuchElementException:
            continue
    if attach_btn is None:
        return False

    attach_btn.click()
    time.sleep(0.9)

    inputs     = driver.find_elements(By.CSS_SELECTOR, 'input[type="file"]')
    file_input = None
    for inp in inputs:
        acc = (inp.get_attribute("accept") or "").strip()
        if acc in ("*", "*/*") or not acc:
            file_input = inp
            break
    if file_input is None and inputs:
        file_input = inputs[0]
    if file_input is None:
        try:
            driver.find_element(By.TAG_NAME, "body").send_keys(Keys.ESCAPE)
        except Exception:
            pass
        return False

    file_input.send_keys(file_path)
    time.sleep(2.5)

    for sel in SEL_SEND_BTN:
        try:
            btn = WebDriverWait(driver, 8).until(
                EC.element_to_be_clickable((By.CSS_SELECTOR, sel)))
            btn.click()
            time.sleep(2.0)
            return True
        except TimeoutException:
            continue

    try:
        driver.switch_to.active_element.send_keys(Keys.ENTER)
        time.sleep(2.0)
        return True
    except Exception:
        return False


# ══════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    app = AppWhatsApp()
    app.mainloop()
