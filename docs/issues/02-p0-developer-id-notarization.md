# P0: 建立 Apple Developer ID 簽章與 notarization 流程

## 背景

目前 `.pkg` 尚未 Developer ID 簽署與 notarize。若要給更多人安裝，需要降低 Gatekeeper 警告與安裝阻力。

## 目標

- 建立 Developer ID Application 簽章流程
- 建立 Developer ID Installer 簽章流程
- 將 build script 支援簽章參數
- 完成 notarization 與 stapler

## 驗收方向

- 產出的 `.app` 與 `.pkg` 可通過 `spctl` 檢查
- `.pkg` 可正常安裝到 `/Applications/Input Method Agent.app`
- 安裝後第一次開啟仍能正常進入權限引導

Priority: P0
