# LiveCopilot

<img src="assets/brand/LiveCopilot-preview.png" width="88" alt="LiveCopilot">

[English](README.md) · **繁體中文** · [简体中文](README.zh-Hans.md)

**跟上對話，找到依據，用自己的話回答。**

面向面試、會議和學術答辯的原生 macOS 助手。LiveCopilot 即時轉錄語音，檢索個人文件中的相關資料，並在懸浮窗中串流呈現回答建議。也可以不開麥，直接輸入問題。

[下載 2.9.2](https://github.com/carey-bk/LiveCopilot/releases/tag/v2.9.2) · [產品介紹](https://carey-bk.github.io/LiveCopilot/zh-Hant/) · [版本說明](docs/releases/2.9.2.md)

## 下載與使用要求

**2.9.2 · 安裝檔 39.38 MB · macOS 通用版本 · Developer ID 簽名與 Apple 公證**

[下載安裝檔 — 香港鏡像站](https://livecopilot-downloads-hk.oss-cn-hongkong.aliyuncs.com/releases/v2.9.2/LiveCopilot-2.9.2-macOS-universal.dmg) · [GitHub 下載與驗證值](https://github.com/carey-bk/LiveCopilot/releases/tag/v2.9.2)

| 功能 | 使用要求 |
|---|---|
| 應用本體 | macOS 14 或更高版本；Apple Silicon 或 Intel |
| 本地 Laya 自動觸發 | 需要 Apple Silicon，模型另行下載 |
| Apple 本地語音識別 | macOS 26 或更高版本，以及受支援的設備與語言 |
| AI 回答 | 自備受支援分析服務的 API Key |

小安裝檔**不包含 Laya 權重**。在首次引導或「設定 → 服務」中下載所需模型，無需另外安裝 Python、Ollama 或 Docker。下載大小約為：Zipformer + VAD **200 MB**、BGE-M3 **635 MB**、Laya 與執行環境 **767 MB**。安裝後還需額外磁碟空間，執行會佔用本機記憶體和計算資源。

打開 DMG，將 LiveCopilot 拖入「應用程式」後啟動。已有使用者可以從應用程式選單選擇「LiveCopilot → 檢查更新…」。正常升級保留設定、API Key、文件和歷史；Laya 模型更新獨立於應用程式更新。

## 2.9.2 更新了什麼？

- 改善對話紀錄儲存。磁碟寫入失敗後可重試，保留後續追問與回答。連續重設同一場對話只會產生一筆紀錄。
- 改善麥克風切換、系統音訊擷取逾時與雲端連線中斷後的處理。
- 減少長時間監聽時的逐字稿更新和音訊回呼等待。Intel Mac 的懸浮視窗使用較輕量的背景。
- 改善文件編碼辨識、大型文件分段、本機向量模型備援與翻譯服務錯誤處理。

## 開始第一次對話

1. **安裝並打開引導。** 六步驟引導會帶你選擇輸入方式、準備模型並測試回答服務。日後可從一般設定重新開啟。
2. **準備語音與本地模型。** 中英雙語優先選擇 Zipformer；文件檢索建議使用本機 BGE-M3，無需 OpenAI 金鑰，Apple Silicon 使用者可下載 Laya 開啟自動觸發。按需下載即可。
3. **連接分析服務。** 選擇 OpenAI、DeepSeek、Qwen、GLM、Kimi 或相容串流 Chat Completions 的服務，保存自己的 API Key。
4. **按需添加資料。** 知識庫支援 PDF、Markdown、TXT、DOCX。掃描版 PDF 請先 OCR；更換向量模型後重建文件索引。
5. **開始監聽或直接輸入。** 現場模式使用麥克風；遠端會議模式採集系統音訊並可選用麥克風。按提示授予 macOS 權限，也可保持監聽關閉、手動提問。
6. **回看完整會話。** 在懸浮窗閱讀回答和來源，結束後到歷史記錄查看問題、回答及引用。

`⌥H` 顯示或隱藏懸浮窗；生成回答、總結、追問快捷鍵可自訂。重要事實和引用請自行核對。

## 哪些處理在本機完成？

| 環節 | 可選服務 | 什麼內容會離開本機？ |
|---|---|---|
| 語音識別 | 本地 Zipformer、Paraformer、Apple；OpenAI Live | 本地識別在設備上完成；OpenAI Live 會向 OpenAI 發送音訊。 |
| 文件索引與檢索 | 本地 BGE-M3；OpenAI Embeddings | BGE-M3 本地處理；OpenAI Embeddings 接收索引或查詢文字，檢索資料仍保存在本機。 |
| 自動觸發回答 | 本地語音搭配 Laya；OpenAI Live 的語義委派 | Laya 的判斷在本地完成；雲端語音遵循其服務供應商的資料處理方式。 |
| 生成回答與自動命名 | 使用者選擇的分析 API | 相關問題、對話文字及選中證據；自動命名會使用會話問答上下文。 |

例如選擇 **Zipformer + BGE-M3 + DeepSeek**，語音識別和索引在本地完成，DeepSeek 負責回答，無需 OpenAI Key。本地處理無 API 呼叫費用；雲服務可能按帳戶用量收費。

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

乾淨儲存庫無需下載 Laya 權重即可建置小體積應用；原生執行階段依賴固定驗證值。Debug 使用獨立應用標識，模擬測試無需 API Key 或付費請求。正式簽名、公證是獨立步驟，打包前請閱讀發佈指南。

| 文件 | 用途 |
|---|---|
| [架構說明](docs/ARCHITECTURE.md) | 元件與資料流 |
| [驗證說明](docs/VERIFICATION.md) | 測試方式與證據邊界 |
| [模型分發](docs/MODEL_RELEASE_READINESS.md) | 模型版本固定與發佈要求 |
| [發佈指南](docs/RELEASING.md) | 簽名、公證、打包與更新 |
| [回報問題](https://github.com/carey-bk/LiveCopilot/issues) | 請附應用版本、macOS 版本和模型診斷，勿附金鑰或私人對話 |

技術文件保持英文。三份 README 介紹同一版本；應用介面目前支援簡體中文和英文。

## 致謝與許可

基於 [vortechron/stealth](https://github.com/vortechron/stealth)，保留上游 Git 歷史和 [MIT 許可](LICENSE)。各執行階段依賴保留自己的許可聲明。[作者：carey-bk](https://github.com/carey-bk)。

---

[English](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)
