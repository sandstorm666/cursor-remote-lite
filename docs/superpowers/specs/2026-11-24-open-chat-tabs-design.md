# Open chat tabs + fix history

Date: 2026-11-24  
Branch: feat/multi-computer

## Problem

- One Cursor window can have multiple Chat Editors tabs open; the phone only mirrors the active panel and has no way to list or switch those open tabs.
- The phone **历史** control opens Cursor’s history menu via DOM selectors that no longer match the current UI, so the menu arrives empty.

## Goals

1. List **open chat editor tabs in the current window** on the phone and switch with one tap.
2. Repair **全部历史…** (former 历史) so it either shows items or a clear failure message — never a silent empty success.
3. Keep **＋ 新建** and the window switcher unchanged. Do not close tabs from the phone; do not list tabs across windows.

## Interaction

- Toolbar label **历史** → **对话**.
- Sheet:
  1. Section **打开中**: rows for each visible Chat Editors tab; current tab marked; tap → switch.
  2. Footer **全部历史…** → existing history menu flow with updated selectors.
- Empty open-tab list: show hint「当前窗口没有打开的聊天标签」; still show **全部历史…**.

## Data flow

```
Phone --listChats--> Relay --chatTabs()--> Cursor DOM
Relay --{t:chats,items}--> Phone

Phone --switchChat(label)--> Relay --tabTarget+click--> Cursor
Relay --pollChat--> Phone

Phone --openMenu(history)--> Relay --history control+menuItems--> Cursor
Relay --{t:menu,kind:history,items,error?}--> Phone
```

## Failure handling

- Missing tab on switch: status error; refresh open-tab list.
- History button or rows not found: explicit copy that this Cursor version may not expose history; suggest open tabs or Screen mode.

## Acceptance

- Two+ Chat Editors tabs → listed; tap non-active → content switches.
- Zero open chat tabs → empty hint + **全部历史…** present.
- **全部历史…** → non-empty menu or explicit error (not silent empty).
- **＋ 新建** and window switcher unchanged.
