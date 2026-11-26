# LiveCopilot

<img src="assets/brand/LiveCopilot-preview.png" width="88" alt="LiveCopilot">

[English](README.md) · **繁體中文** · [简体中文](README.zh-Hans.md)

**跟上對話，找到依據，用自己的話回答。**

面向面試、會議和學術答辯的原生 macOS 助手。LiveCopilot 即時轉錄語音，檢索個人文件中的相關資料，並在懸浮窗中串流呈現回答建議。也可以不開麥，直接輸入問題。

[下載 2.12](https://github.com/carey-bk/LiveCopilot/releases/tag/v2.12) · [產品介紹](https://carey-bk.github.io/LiveCopilot/zh-Hant/) · [版本說明](docs/releases/2.12.md)

## 下載與使用要求

**2.12 · 安裝檔 538 MB · macOS 通用版本 · Developer ID 簽名與 Apple 公證**

[從 GitHub 下載安裝檔](https://github.com/carey-bk/LiveCopilot/releases/download/v2.12/LiveCopilot-2.12-macOS-universal.dmg) · [GitHub 發佈頁與驗證值](https://github.com/carey-bk/LiveCopilot/releases/tag/v2.12) · 網盤備用下載見[產品介紹頁](https://carey-bk.github.io/LiveCopilot/zh-Hant/#download)。

| 功能 | 使用要求 |
|---|---|
| 應用本體 | macOS 14 或更高版本；Apple Silicon 或 Intel |
| 本地 Laya 自動觸發 | 需要 Apple Silicon，模型已內建 |
| Apple 本地語音識別 | macOS 26 或更高版本，以及受支援的設備與語言 |
| AI 回答 | 自備受支援分析服務的 API Key |

安裝檔**已內建 Arctic 檢索模型和 Laya 自動觸發模型**，檢索資料和自動觸發都無需另外下載模型。本地語音識別模型可在首次引導或「設定 → 服務」中按需下載：Zipformer 約 **200 MB**、Paraformer 約 **238 MB**；macOS 26 上的 Apple 本機語音識別無需透過 LiveCopilot 下載。無需另外安裝 Python、Ollama 或 Docker。本地模型會佔用磁碟空間以及本機記憶體和計算資源。

打開 DMG，將 LiveCopilot 拖入「應用程式」後啟動。已有使用者可以從應用程式選單選擇「LiveCopilot → 檢查更新…」：2.11 只需下載 2.1 MB、2.10.0 只需下載 3.7 MB 的增量更新，更早的版本下載完整安裝檔。從 2.12 起，連不上 GitHub 時更新會自動改用香港鏡像。正常升級保留設定、API Key、文件和歷史；以舊 BGE-M3 模型建立的資料索引，在原檔案仍在時會自動以 Arctic 重建。

## 2.12 更新了什麼？

- 修復：回答較多時懸浮視窗可能卡死幾分鐘（2.10 和 2.11 都受影響）。
- 懸浮視窗的使用提示改為區域高亮：提示指向的位置保持明亮，其餘區域變暗。
- 「回報問題」會把執行日誌、卡頓記錄和系統報告打包成可預覽的 ZIP，並開啟一封已附上 ZIP 的郵件寄給作者；軟體卡住超過 3 秒時會自動記錄卡在哪裡。
- 應用程式內更新優先連線 GitHub，連不上時自動改用香港鏡像；更新失敗時的連結改為官網下載區。
- 新手引導的回答服務頁不再超出視窗；內建的 Arctic 模型不再顯示下載說明。

完整說明：[docs/releases/2.12.md](docs/releases/2.12.md)。

## 開始第一次對話

1. **安裝並打開引導。** 六步驟引導會帶你選擇輸入方式、準備語音識別並測試回答服務。日後可在設定的「概覽」中重新開啟。
2. **準備語音識別。** macOS 26 上預設使用 Apple 本機語音識別；中英雙語也可以下載本地 Zipformer。文件檢索用的 Arctic 和 Apple Silicon 上自動觸發用的 Laya 均已內建。
3. **連接分析服務。** 選擇 OpenAI、DeepSeek、Qwen、GLM、Kimi 或相容串流 Chat Completions 的服務，保存自己的 API Key。
4. **按需添加資料。** 知識庫支援 PDF、Markdown、TXT、DOCX。掃描版 PDF 請先 OCR；更換向量模型後重建文件索引。
5. **開始監聽或直接輸入。** 現場模式使用麥克風；遠端會議模式採集系統音訊並可選用麥克風。按提示授予 macOS 權限，也可保持監聽關閉、手動提問。
6. **回看完整會話。** 在懸浮窗閱讀回答和來源，結束後到歷史記錄查看問題、回答及引用。

`⌥H` 顯示或隱藏懸浮窗；生成回答、總結、追問快捷鍵可自訂。重要事實和引用請自行核對。

## 哪些處理在本機完成？

| 環節 | 可選服務 | 什麼內容會離開本機？ |
|---|---|---|
| 語音識別 | 本地 Zipformer、Paraformer、Apple；OpenAI Live | 本地識別在設備上完成；OpenAI Live 會向 OpenAI 發送音訊。 |
| 文件索引與檢索 | 本地 Arctic（已內建）；OpenAI Embeddings | Arctic 本地處理；OpenAI Embeddings 接收索引或查詢文字，檢索資料仍保存在本機。 |
| 自動觸發回答 | 本地語音搭配 Laya；OpenAI Live 的語義委派 | Laya 的判斷在本地完成；雲端語音遵循其服務供應商的資料處理方式。 |
| 生成回答與自動命名 | 使用者選擇的分析 API | 相關問題、對話文字及選中證據；自動命名會使用會話問答上下文。 |

例如選擇 **Zipformer + Arctic + DeepSeek**，語音識別和索引在本地完成，DeepSeek 負責回答，無需 OpenAI Key。本地處理無 API 呼叫費用；雲服務可能按帳戶用量收費。

## 隱私與使用邊界

- API Key 保存在本機 macOS 鑰匙串；文件、索引和歷史保存在本地。無需 LiveCopilot 帳戶，也不經過開發者運營的中轉伺服器。
- 本地語音不等於完全離線回答：所選分析服務會收到相關文字，並適用其留存與計費政策。刪除本地歷史無法撤回已發出的 API 請求。
- 會議分享與錄製隱藏可選，預設關閉。請在實際會議軟體中驗證效果；設定頁和歷史頁仍可被擷取。
- 不內建 OCR，不保證說話人分離，不提供 AI 語音播放或雲端備份。Laya 可能漏判或誤觸發；應用支援 Intel 不代表 Laya 支援 Intel。

[隱私說明](docs/PRIVACY.md) · [服務選擇指南](docs/SERVICE_GUIDE.md) · [本地模型](docs/LOCAL_MODELS.md)

## 開發與文件

基於 Swift/SwiftUI。原始碼建置需要完整 Xcode 和 XcodeGen：

```bash
./StealthApp/scripts/test-core.sh
./StealthApp/scripts/build.sh
xcodebuild -project StealthApp/LiveCopilot.xcodeproj -scheme LiveCopilot \
  -configuration Debug -derivedDataPath StealthApp/build CODE_SIGNING_ALLOWED=NO test
```

模型權重不放在 Git 中：正式打包時從本機資源目錄放入內建的 Arctic 和 Laya 模型，並在簽名前驗證。原生執行階段依賴固定驗證值。Debug 使用獨立應用標識，模擬測試無需 API Key 或付費請求。正式簽名、公證是獨立步驟，打包前請閱讀發佈指南。

| 文件 | 用途 |
|---|---|
| [架構說明](docs/ARCHITECTURE.md) | 元件與資料流 |
| [驗證說明](docs/VERIFICATION.md) | 測試方式與證據邊界 |
| [模型分發](docs/MODEL_RELEASE_READINESS.md) | 模型版本固定與發佈要求 |
| [發佈指南](docs/RELEASING.md) | 簽名、公證、打包與更新 |
| [回報問題](https://github.com/carey-bk/LiveCopilot/issues) | 請附應用版本、macOS 版本和模型診斷，勿附金鑰或私人對話 |

技術文件保持英文。三份 README 介紹同一版本；應用介面支援英文、簡體中文和繁體中文。

## 致謝與許可

基於 [vortechron/stealth](https://github.com/vortechron/stealth)，保留上游 Git 歷史和 [MIT 許可](LICENSE)。各執行階段依賴保留自己的許可聲明。[作者：carey-bk](https://github.com/carey-bk)。

---

[English](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)
