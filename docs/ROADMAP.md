# Roadmap

這份 roadmap 用來整理 `0.1.0 Beta` 後的優先工作。正式 issue 可依照下列項目建立。

## P0: 數字鍵盤修正在注音組字狀態下的穩定性

目前已知：在注音尚未按 Enter 完成組字時，部分 App 可能遇到數字輸入順序問題。

目標：

- 降低注音組字狀態下按右側數字鍵的吃字風險
- 評估「保守模式」或 App 相容性策略
- 維持快速模式的手感

測試 App：LINE、Notes、Word、Chrome/Edge 表單、Finder 重新命名欄位。

## P0: Apple Developer ID 簽章與 notarization

目前 `.pkg` 尚未 Developer ID 簽署與 notarize。若要給更多人安裝，需要降低 Gatekeeper 警告。

目標：

- 建立 Developer ID Application / Installer 簽章流程
- 將 build script 支援簽章參數
- 完成 notarization 與 stapler

## P1: README 截圖與安裝流程圖片

讓第一次看到專案的人能快速理解使用方式。

需要截圖：

- 主設定視窗
- 權限設定引導
- Menu Bar 狀態選單
- 數字鍵盤修正區塊

## P1: Homebrew Cask 支援

讓使用者能用 Homebrew 安裝與更新。

目標：

- 建立 release asset 命名規則
- 計算 SHA256
- 撰寫 Homebrew Cask

## P2: 設定匯出 / 匯入

方便 beta 使用者備份與搬移設定。

目標：

- 匯出目前 App 規則與全域預設
- 匯入設定時提供預覽與覆蓋確認

## P2: 多語系介面

目前以繁體中文與台灣注音使用情境為主。後續可加入英文介面，方便更多使用者理解權限需求。
