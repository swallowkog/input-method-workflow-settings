# Input Method Agent

macOS 常駐輸入法工作流工具，用來防止中文輸入法破壞快捷鍵與數字輸入。它會監聽目前前景 App，依照設定自動切換到指定輸入法。

App 啟動後會常駐在 macOS 上方選單列，用一個鍵盤加漢堡選單的小圖示；點圖示可以打開產品化設定視窗，依照「① 選擇 App　② 指定輸入法　③ 儲存並啟用」三步驟完成設定。


## 下載 Beta

目前公開測試版本為 `0.1.0 Beta`。請到 [GitHub Releases](https://github.com/swallowkog/input-method-workflow-settings/releases) 下載 `Input Method Agent Installer.pkg`。

Beta 測試重點與已知限制請見 [0.1.0 Beta 測試指南](docs/BETA_TESTING.md)。

## 建置

```bash
swift build -c release
```

## 開啟圖形介面

```bash
.build/release/input-method-agent --gui
```

圖形介面功能：

- 設定「全域預設輸入法」，未指定的 App 會跟隨此設定
- 直接列出系統中掃描到的所有應用程式，預設隱藏 Bundle ID
- 搜尋 App 名稱，並用「全部 / 已設定 / 跟隨全域 / ABC / 注音」快速篩選
- 替每個 App 指定「開啟時使用」的輸入法，未指定時會顯示「全域預設（ABC）」這類明確文案
- 次要操作收在「更多⋯」選單，右鍵 App 列也可複製 Bundle ID，供進階排查使用
- 套用創作者常用建議規則，快速設定剪輯、影像、開發與溝通 App
- 勾選「登入後自動啟動」，讓選單列工具在登入 macOS 後自動啟動
- 在「數字鍵盤修正」區塊開啟右側數字鍵盤半形輸入，並可切換快速或穩定速度、使用測試欄確認輸出
- 以待辦清單查看輔助使用、輸入監控與數字鍵盤修正狀態，必要時可直接開啟權限設定並重新檢查
- 儲存到 `~/.config/input-method-agent/config.json`

## 打包成 App

```bash
./scripts/build-app.sh
```

完成後會產生：

```text
dist/Input Method Agent.app
```

可以直接開啟這個 App，它會出現在 macOS 選單列。

啟動後不會自動彈出設定視窗；需要修改規則時，點選單列的鍵盤圖示，再選「輸入法設定...」。

## 打包成安裝包

```bash
./scripts/build-installer.sh
```

完成後會產生：

```text
dist/Input Method Agent Installer.pkg
dist/Input Method Agent.app.zip
```

`.pkg` 會安裝到：

```text
/Applications/Input Method Agent.app
```

目前產生的是未使用 Apple Developer ID 簽署與 notarize 的安裝包。自己使用或小範圍測試可以安裝；若要公開發佈給一般使用者，建議用 Apple Developer ID 正式簽署並 notarize。

## 查看可用輸入法 ID

```bash
.build/release/input-method-agent --list
```

輸出會長得像這樣：

```text
com.apple.keylayout.ABC  |  ABC
com.apple.inputmethod.TCIM.Zhuyin  |  注音
```

## 建立設定檔

```bash
.build/release/input-method-agent --init-config
```

預設設定檔位置：

```text
~/.config/input-method-agent/config.json
```

設定範例：

```json
{
  "defaultInputSourceID": "com.apple.keylayout.ABC",
  "logSwitches": false,
  "appInputSources": {
    "com.apple.TextEdit": "com.apple.inputmethod.TCIM.Zhuyin",
    "com.apple.Terminal": "com.apple.keylayout.ABC",
    "com.microsoft.VSCode": "com.apple.keylayout.ABC"
  }
}
```

`appInputSources` 的 key 是 App Bundle ID，value 是輸入法 ID。

## 執行

```bash
.build/release/input-method-agent
```

或指定設定檔：

```bash
.build/release/input-method-agent --config ./config.json
```

## 登入後常駐

在設定視窗底部勾選「登入後自動啟動」即可。App 會自動建立或移除：

```text
~/Library/LaunchAgents/local.input-method-agent.plist
```

這份設定會指向目前安裝或執行的 App，不需要手動修改 launchd plist。

## 數字鍵盤修正

在設定視窗的「數字鍵盤修正」區塊勾選「在中文輸入法下，數字鍵盤仍輸入半形數字」後，右側數字鍵盤的 `0` 到 `9` 和小數點會強制輸出半形字元，不會受目前中文輸入法影響。

這個功能會在按下右側數字鍵盤時，短暫切到 ABC 輸入法讓數字自然輸出半形，接著自動切回原本輸入法。速度可選「快速」或「穩定」；快速優先輸入手感，穩定則保留較長等待時間以降低特殊 App 漏字機率。

第一次開啟時，macOS 可能會要求以下權限，允許後功能才會生效：

- 「輔助使用」：讓 App 可以偵測目前 App、切換輸入法，並在數字鍵盤修正時送出修正後的右側數字鍵。
- 「輸入監控」：判斷按下的是不是右側數字鍵盤的數字或小數點。

這個功能只有在開啟「數字鍵盤修正」時才會啟動輸入監控。程式只處理右側數字鍵盤的 `0` 到 `9` 與小數點；不記錄按鍵內容，也不會把資料傳到網路。


## 隱私與權限

本 App 所有設定皆儲存在本機，不記錄、不儲存、不上傳任何輸入內容。

- 輔助使用權限僅用於偵測目前正在使用的 App、執行輸入法切換，並在數字鍵盤修正時送出右側數字鍵。
- 輸入監控權限僅用於判斷右側數字鍵盤的 `0` 到 `9` 與小數點輸入。
- App 不會讀取一般文字輸入內容，也不會把任何按鍵內容傳到網路。

## 開源授權

本專案以 [MIT License](LICENSE) 開源。你可以自由使用、修改與發佈此專案；若重新散佈，請保留授權文字。
