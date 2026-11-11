# Typeless 字典匯出 Skill

把 **Typeless**（Windows 桌面版語音輸入工具）「字典」頁的全部詞條，一鍵匯出成 CSV。
適合需要備份自訂詞彙、做術語一致性檢查、或把字典帶到其他工具的人。

- 不用 OCR、不用手動複製
- 筆數會與 App 顯示的 `total_count` 對帳，不一致就不輸出
- 輸出單欄 CSV（UTF-8 BOM，Excel 直接開不亂碼）

> 已在 Windows 11 + Typeless 2.9.x（Electron 33）實測：988 → 989 → 990 筆皆與 App 總數一致。

---

## 為什麼需要它

Typeless 的字典只存在雲端帳號，**App 沒有匯出功能**；本機資料庫 `%APPDATA%\Typeless.exe\typeless.db` 只有聽寫歷史，沒有字典表。
所以只能讓 App 自己把清單載入畫面，再從畫面／網路回應把詞條取出來。

這個 Skill 把「怎麼取」固定下來，包含三個容易踩的坑：

1. App 的除錯通道（CDP）預設是關的，要用 `--remote-debugging-port` 啟動。
2. 視窗被隱藏時，CDP 送輸入會**無聲卡住**（不是報錯），必須先確認視窗可見。
3. 一旦清單全部載入，App 就不再發 API 請求，這時攔網路會拿到 0 筆 → 要改讀畫面文字。

---

## 需求

| 項目 | 版本／說明 |
|---|---|
| 作業系統 | Windows 10 / 11（僅 Windows 已驗證） |
| Typeless | 桌面版 2.9.x（Electron） |
| Python | 3.10 以上，需 `websockets` 套件 |
| PowerShell | 5.1 以上 |

安裝 Python 依賴：

```powershell
python -m pip install websockets
```

---

## 安裝到你的 AI Agent

這個 Skill 採用常見的 `SKILL.md` 格式（YAML frontmatter：`name`、`description`），
只要你的 Agent 支援這種 skill 目錄，把整個資料夾放進去即可。

### OpenCode

```powershell
$dst = "$env:USERPROFILE\.config\opencode\skills\typeless-dictionary-export"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item .\SKILL.md $dst -Force
Copy-Item .\scripts $dst -Recurse -Force
```

### Codex

```powershell
$dst = "$env:USERPROFILE\.codex\skills\typeless-dictionary-export"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item .\SKILL.md $dst -Force
Copy-Item .\scripts $dst -Recurse -Force
```

> 兩個工具都裝時，想避免日後同步兩份內容，可以只留一份實體、另一邊用目錄連結：
> `cmd /c mklink /J "%USERPROFILE%\.codex\skills\typeless-dictionary-export" "%USERPROFILE%\.config\opencode\skills\typeless-dictionary-export"`

### 其他 Agent

- 找到它的 skills 目錄（關鍵字：`skills`、`SKILL.md`、`Agent Skills`），把資料夾放進去。
- 若你的 Agent 不支援 skill 目錄：把 `SKILL.md` 的內容貼進系統提示、`AGENTS.md` 或專案規則，並保留 `scripts/` 在固定位置即可。

安裝後**開新的工作階段**才會載入。

---

## 使用

### 最簡單的用法

對 Agent 說：

```
匯出 Typeless 字典
```

Agent 會載入這個 Skill，依序檢查前提、必要時詢問是否重啟、掃描、輸出 CSV。

### 直接跑腳本

```powershell
cd <本資料夾>\scripts
powershell -File .\Export-TypelessDictionary.ps1
```

| 參數 | 作用 |
|---|---|
| （不帶） | 除錯埠已開時直接擷取 |
| `-Restart` | 先以除錯參數重啟 Typeless（**請先取得使用者同意**） |
| `-RestoreNormal` | 結束後恢復一般模式（關閉除錯埠） |
| `-OutDir <路徑>` | CSV 輸出位置（預設：`桌面\Typeless字典匯出`） |
| `-Archive <路徑>` | 額外複製一份到指定資料夾（可選） |
| `-Port <埠>` | 除錯埠，預設 9333 |

範例（含重啟與收尾）：

```powershell
powershell -File .\Export-TypelessDictionary.ps1 -Restart -RestoreNormal
```

### 輸出

```
桌面\Typeless字典匯出\Typeless_字典_詞彙_YYYYMMDD.csv
```

- 單欄「詞彙」、無標題列
- UTF-8 BOM
- 終端機會印出筆數、`total_count`、SHA-256

---

## 驗證方式

腳本成功的條件是：

```
collected unique == total_count
```

終端機輸出範例：

```
total_count = 990
precondition ok: wheel scroll verified
collected unique = 990 | total_count = 990
FILE   : ...\Typeless_字典_詞彙_20261111.csv
ROWS   : 990
```

若出現 `PRECONDITION_FAILED`，代表視窗不可見或滾輪沒生效——請先把 Typeless 主視窗叫到最上層，再重跑。

---

## 疑難排解

| 症狀 | 原因 | 處理 |
|---|---|---|
| `port 9333 is closed` | App 是一般模式啟動 | 加 `-Restart`（需使用者同意），或自行帶 `--remote-debugging-port=9333` 啟動 |
| `PRECONDITION_FAILED: 滾輪事件無回應` | 主視窗被隱藏／最小化／被其他視窗完全遮住 | 叫出 Typeless 主視窗後重跑 |
| `collected unique` 少於 `total_count` | 掃描中斷或視窗在過程中失去焦點 | 重跑一次；仍失敗請確認沒有其他程式搶焦點 |
| 攔網路一直是 0 筆 | 清單已全部載入，App 不再請求 | 正常現象，改讀畫面文字（腳本已自動採此模式） |
| `PermissionError` 且出現 `*_new.csv` | 目標 CSV 正被 Excel 開啟 | 關閉 Excel 後重跑，或直接使用 `_new.csv` |
| `NO_HUB_WINDOW` | 主視窗被關閉，只剩浮動條 | 腳本會再呼叫一次 `Typeless.exe` 讓它開回主視窗（不算重啟） |
| PowerShell 中文變亂碼 | `.ps1` 未存成 UTF-8 BOM | 以 UTF-8 BOM 重新存檔 |

---

## 隱私與安全

- 匯出檔**只留在本機**，不上傳任何服務。
- 除錯埠只綁 `127.0.0.1`，但仍建議完成後關閉（`-RestoreNormal`）。
- 字典內容可能包含人名或內部術語，分享 CSV 前請自行檢查。
- 這個 Skill 不會修改 Typeless 的詞條，只讀取。

---

## 檔案結構

```
typeless-dictionary-export/
├─ SKILL.md                          # Agent 讀的 skill 定義
├─ README.md                         # 本文件
└─ scripts/
   ├─ Export-TypelessDictionary.ps1  # 入口：檢查／喚起視窗 + 呼叫 Python
   └─ export_typeless_dictionary.py  # CDP 掃描、比對、輸出 CSV
```

---

## 已知限制

- 只在 **Windows** 驗證；macOS 版 Typeless 的視窗 class 與行為不同，需自行調整。
- Typeless 改版可能改變頁面結構（`p.MuiTypography-root.content`）或 API 路徑，屆時需更新腳本。
- 需要暫時重啟 Typeless 才能開啟除錯通道，過程約 1 分鐘無法語音輸入。
- 詞條順序依 App 當下載入順序，不保證與畫面完全一致。

---

## 授權

本專案採用 **MIT License**，詳見 [LICENSE](LICENSE)。

可自由使用、修改、再散布與商業使用，只需保留著作權聲明與授權條文。若要改成其他授權（例如 CC BY 4.0），替換 `LICENSE` 內容並同步修改本節即可。
