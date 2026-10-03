<div align="center">

<img src=".github/assets/banner.svg" alt="PSM" width="820">

# Dayv PSM · Proxy Stack Manager

**Свой прокси-сервер на VPS одной командой: VLESS REALITY, Hysteria2, TUIC, AnyTLS**<br>
Xray / sing-box / mihomo · общий порт 443 · учётные записи · лимиты трафика · перенос сервера

<p>
  <a href="https://psm-docs.pages.dev/en/"><b>📖 Документация исходного проекта (English)</b></a> ·
  <a href="README_EN.md">English</a> ·
  <a href="README.md">简体中文</a>
</p>

</div>

Форк [jinqians/proxy-stack](https://github.com/jinqians/proxy-stack), сопровождаемый **bigyvc (Dayv)**, под AGPL-3.0. Внешняя документация относится к исходному проекту. [Руководство](FORK_GUIDE.md) · [Аудит](AUDIT.md).

## Установка

На VPS от root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bigyvc/proxy-stack/main/bootstrap.sh)
```

Затем запустите `psm`, откроется меню. Интерфейс есть на русском (пункт «Language» в меню).

## Возможности

- VLESS REALITY / Vision / XHTTP, Hysteria2 (перескок портов), TUIC v5, AnyTLS, Snell, Shadowsocks 2022, Trojan, VMess, WireGuard
- Три ядра — Xray, sing-box и mihomo — можно запускать одновременно
- Несколько узлов на одном порту 443
- Ссылки, QR-коды, подписки
- Учётные записи с датой окончания и месячным лимитом трафика
- Перенос сервера: `psm migrate push root@новый-сервер`
- Диагностика и автоисправление: `psm doctor --fix`

Системы: Debian, Ubuntu, Alpine, RHEL / Rocky Linux / AlmaLinux (x86_64, arm64).

Подробности — в [документации на английском](https://psm-docs.pages.dev/en/).

## Лицензия

[AGPL-3.0](LICENSE). Используйте в рамках законов вашей страны.
