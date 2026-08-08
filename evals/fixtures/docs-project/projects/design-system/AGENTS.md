# design-system — 作業差分

Project固有の作業差分と条件付きDocs Routeだけを持つ。契約は`PROJECT.md`、状態は`STATE.md`が所有する。

## Project Docs Route

条件に一致した正本だけを読む。Domain Canonを無条件に全件読まない。

| 条件 | 読む正本 |
|---|---|
| モジュール、依存、データフロー、境界を変更する | `ARCHITECTURE.md` |
| 構造決定やコンポーネント定義を変更する | `docs/DESIGN.md` |
| 定性的な製品判断・レビュー基準を扱う | `docs/PRODUCT_SENSE.md` |
| 未確定の問いを調査・実験で確かめる | `docs/RESEARCH.md` |

## 実行

- 検証は`bash scripts/verify-catalog.sh`で行い、他のコマンドで代替しない。
- 生成物は`outputs/`だけへ書き、`inputs/`を書き換えない。

## 承認ゲート

- カタログの外部公開は、利用者の明示指示があるまで行わない。

## Project Notes

- 兄弟instance文書への参照はProject root内で解決する。
