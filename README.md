<div align="center">

# 📸 PhotographersPocketKnife

**O canivete suíço do fotógrafo — seleção, edição e envio de fotos, tudo numa app nativa para macOS.**

![macOS](https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-0D96F6?style=for-the-badge&logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-FFD700?style=for-the-badge)

</div>

---

## About

**PhotographersPocketKnife** é uma aplicação nativa para macOS pensada para o fluxo de trabalho completo de um fotógrafo profissional, sem sair de uma só app:

- 🗂️ **Organizar** — importar, comparar e selecionar as melhores fotos de uma sessão (rating, flags, cores, metadados)
- 🎨 **Editar** — ajustes não-destrutivos de exposição, cor, crop e muito mais
- 📤 **Enviar** — transferir as fotos finais para servidores de clientes via FTP/SFTP

Tudo com uma interface cuidada, animada, com suporte a **Dark/Light/System mode** e disponível em **Português (PT-PT)** e **Inglês**.

---

## ✨ Funcionalidades

| Módulo | O que faz |
|---|---|
| **Culling** | Importação de cartões/pastas (com cópia por data), grid de thumbnails com cache, lupa, comparação de 2–4 fotos, rating, flags, cores, filtros e ordenação, renomeação em lote com templates, IPTC em lote (sidecar XMP para RAW), deteção de duplicados, atalhos configuráveis |
| **Edição** | Non-destructive (Core Image + Metal): exposição, contraste, realces/sombras, brancos/pretos, temperatura/tinta, vibrância/saturação, nitidez, ruído, vinheta, curvas RGB e por canal, HSL, crop com terços/espiral dourada, endireitar, perspetiva, correção de lente RAW, histórico com undo/redo, presets, copiar/colar definições, antes/depois, exportação JPEG/TIFF/PNG/HEIC com presets |
| **Envio** | Perfis FTP, FTPS, SFTP e S3 com passwords no Keychain, teste de ligação, pastas remotas por data/evento, fila com progresso, pausa/retoma, retry automático, notificações e histórico, "exportar + enviar" |

---

## 🛠️ Tech Stack

![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-0D96F6?style=for-the-badge&logo=swift&logoColor=white)
![Xcode](https://img.shields.io/badge/Xcode-147EFB?style=for-the-badge&logo=xcode&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white)

---

## 🚀 Getting Started

```bash
git clone https://github.com/VidiPT89/PhotographersPocketKnife.git
cd PhotographersPocketKnife
xcodegen generate   # brew install xcodegen
open PhotographersPocketKnife.xcodeproj
```

Testes: `xcodebuild test -scheme PhotographersPocketKnife -destination 'platform=macOS'`

Escolhe o scheme `PhotographersPocketKnife` e corre (⌘R). Requer macOS 14+, Xcode 15+ e [XcodeGen](https://github.com/yonaskolb/XcodeGen).

---

## 🌍 Idiomas & Temas

- 🇵🇹 Português (PT-PT) / 🇬🇧 English — alternável a qualquer momento nas definições
- 🌗 Dark, Light e System mode

---

## 📄 License

Distributed under the MIT License. See `LICENSE` for details.

---

<div align="center">

Contributions, issues and feature requests are welcome.

**Developed by [David Arsénio Martins](https://ividi.dev/)** · [GitHub](https://github.com/VidiPT89/)

</div>
