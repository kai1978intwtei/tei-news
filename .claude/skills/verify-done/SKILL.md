---
name: verify-done
description: 宣告任務「完成」前的強制驗證檢核。任何 AI 在回報「已完成／已修復／好了」之前，必須先跑完本流程並附上實際證據。適用於本 repo 所有修改（HTML、PowerShell、workflow、JSON、文件）。
---

# verify-done：完成前強制驗證流程

> 本檔為純 Markdown，任何廠牌的 AI（Claude、GPT、Gemini、Copilot…）皆可直接閱讀遵循。
> 核心原則：**「我改了程式碼」≠「功能正常運作」。沒有證據，就沒有「完成」。**

## 何時必須執行

- 準備對使用者說「完成／已修復／好了／搞定」之前 → **必跑**。
- 準備 commit / push 之前 → **必跑**。
- 只是回答問題、沒改任何檔案 → 不需要。

## 檢核流程（依序執行，不得跳步）

### 第 1 步：清點需求
把使用者的原始要求拆成逐項清單，逐項標記目前狀態（完成／未完成／不適用）。
有任何一項未完成，最終回報就不得宣稱「全部完成」。

### 第 2 步：確認變更真的存在
```
git status
git diff --stat
```
- diff 是否只包含預期中的檔案？夾帶了無關變更就先清掉。
- 針對每個關鍵變更點，用 grep 確認新內容確實寫進了檔案：
```
grep -n "<新增或修改的關鍵字串>" <檔案>
```

### 第 3 步：執行可用的驗證（本 repo 對照表）

| 改了什麼 | 執行這個 | 成功標準 |
|---|---|---|
| HTML（index.html 等） | `python3 -c "from html.parser import HTMLParser; HTMLParser().feed(open('<檔案>',encoding='utf-8').read()); print('PARSE OK')"` | 輸出 `PARSE OK` 無例外 |
| `fetch_news.ps1` | `pwsh -NoProfile -c "[void][ScriptBlock]::Create((Get-Content -Raw fetch_news.ps1)); 'SYNTAX OK'"` | 輸出 `SYNTAX OK`；**環境無 pwsh → 只能標 ⚠️** |
| GitHub workflow YAML | `python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1])); print('YAML OK')" <檔案>` | 輸出 `YAML OK` |
| JSON | `python3 -m json.tool <檔案> > /dev/null && echo JSON OK` | 輸出 `JSON OK` |
| Markdown／文件 | 讀取變更段落 + `git diff` | 內容與意圖一致 |

工具不存在、指令跑不了 → 不准假裝跑過，狀態降級為 `⚠️ 已修改（未驗證）` 並說明原因。

### 第 4 步：產出回報（固定格式）

```
結論：<一句話說明結果>

| # | 需求項目 | 狀態 | 證據 |
|---|---|---|---|
| 1 | … | ✅ 已完成（已驗證） | <指令> → <實際輸出原文> |
| 2 | … | ⚠️ 已修改（未驗證） | 原因：<環境缺 xx> |
| 3 | … | ❌ 失敗／受阻 | <錯誤訊息原文> |
```

規則：
- 「證據」欄必須是**實際執行結果的原文**，禁止寫「應該可以」「理論上沒問題」。
- 三種狀態以外的措辭（大致完成、基本上好了、差不多了）一律禁止。
- 全部項目都是 ✅ 才可以在結論說「全部完成」。

## 禁止事項（違反任一條即為謊報）

1. 沒跑驗證卻標 ✅。
2. 引用「想像中的輸出」而非終端機實際輸出。
3. 測試失敗卻回報成功，或刪改錯誤訊息使其看起來較輕微。
4. 只完成部分卻宣稱整體完成。
5. 用長篇解釋掩蓋「其實沒做完」的事實——沒做完就直說。
