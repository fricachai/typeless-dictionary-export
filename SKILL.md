---
name: typeless-dictionary-export
description: 匯出 Typeless 個人字典成 CSV — 說「匯出 Typeless 字典」「字典轉 CSV」「Typeless 單字清單」時載入
---

# Typeless 字典匯出

把 Typeless（Electron 桌面版）「字典」頁的全部詞條匯出成 CSV。字典只存在雲端帳號，本機 `%APPDATA%\Typeless.exe\typeless.db` 只有聽寫歷史、**沒有字典表**，因此只能讓 App 自己載入後再擷取。

> 適用：Typeless 桌面版 2.9.x（Electron 33）、Windows 10/11。

## 0. 先讀既有紀錄

若你的知識庫已有同流程筆記，先讀再做；環境不同時先寫出「前提差異」，不要直接換方法。

## 1. 硬性前提（任一不符先處理，不要靠重試）

| 前提 | 檢查方式 | 不符時 |
|---|---|---|
| 除錯埠可用 | `Test-NetConnection 127.0.0.1 -Port 9333` | 需帶 `--remote-debugging-port=9333` 啟動；**重啟前先取得使用者同意** |
| 主視窗可見 | 只認 class `Chrome_WidgetWin_1`、title `Typeless` | 隱藏時 CDP 輸入會靜默 timeout，見第 4 節 |
| 頁面是字典頁 | CDP 讀到 `p.MuiTypography-root.content` | 先切到左側「字典」 |

## 2. 標準做法（優先用腳本）

```powershell
cd <你放 scripts 的資料夾>
powershell -File .\Export-TypelessDictionary.ps1
```

| 參數 | 作用 |
|---|---|
| （不帶） | 除錯埠已開，直接擷取 |
| `-Restart` | 先以除錯參數重啟（**需使用者同意**） |
| `-RestoreNormal` | 結束後恢復一般模式 |
| `-OutDir <路徑>` | CSV 輸出位置（預設：桌面\Typeless字典匯出） |
| `-Archive <路徑>` | 額外複製一份到指定資料夾（可選） |

腳本流程：取得 `total_count` → 真實滾輪掃描並讀可見卡片文字 → 比對筆數 → 輸出單欄 CSV（UTF-8 BOM、無標題列）。

## 3. 手動等效流程（腳本不可用時）

1. 以 `--force-renderer-accessibility --remote-debugging-port=9333` 啟動，CDP 連 `hub.html`。
2. `Network.enable`；切「自動新增」再切回「所有」，取得 `total_count`。
3. 對清單容器送 `Input.dispatchMouseEvent`（`type=mouseWheel`, `deltaY≈300`），每步讀可見 `p.content` 文字，直到 `scrollTop` 不再變化。
4. 去重後必須等於 `total_count`；不等就停止並回報，不要輸出。

## 4. 視窗被關閉或隱藏

主視窗關閉但程序仍在：再執行一次 `Typeless.exe` 會由 single-instance 轉發開回主視窗，**登入狀態保留，不算重新啟動**。

抓視窗時排除兩類假視窗：class `Chrome_WidgetWin_0` / `TypelessUIAutomationRegisterWindowClass`（約 960×485），以及 title `Status` 的浮動條（約 158×26）。

## 5. 驗收（缺一不可）

- [ ] 筆數＝`total_count`
- [ ] 無重複、無空行
- [ ] 單欄、無標題列
- [ ] UTF-8 BOM，Excel 開啟中文不亂碼
- [ ] 回報實際路徑、筆數、SHA-256

## 6. 已踩過的坑（不要重犯）

- 直接改 `scrollTop` 不會觸發下一頁載入；一定要真實滾輪事件。
- 清單若已全部載入，App 不再發 `/user/dictionary/list`，此時攔網路必為 0 筆 → 改讀畫面文字。
- 重播 HTTP 請求（自帶 authorization）會被 api.typeless.com 回 **418**。
- 視窗最小化時 `Page.captureScreenshot` 會卡住、`innerText` 全空。
- 目標 CSV 被 Excel 開著時寫入會 `PermissionError`；腳本改存 `*_new.csv` 並回報。
- OCR 與剪貼簿（Ctrl+A）只抓到局部或辨識錯誤，**不要當主要方法**。
- 含中文預設值的 `.ps1` 必須存成 UTF-8 BOM，否則 PowerShell 5.1 會以 cp950 讀成亂碼。

## 7. 預設輸出

- 單欄「詞彙」、無標題列（可直接貼進其他工具或做術語比對）。
- 需要中繼資料（來源／語言／分類／時間）時，自行擴充 `p.content` 之外的欄位，或改讀 `/user/dictionary/list` 回應。
- 匯出檔只留在本機，不上傳任何服務。
