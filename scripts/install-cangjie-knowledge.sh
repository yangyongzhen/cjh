#!/usr/bin/env bash
# 安装"仓颉知识层"到 cjh 数据目录。核心形态：**入口与全文分离**。
#
#   ~/.cjh/skills/<name>.md                        ← 短入口（常驻 system prompt：描述 + 一行指针）
#   ~/.cjh/cangjie-ref/skills/<name>/SKILL.md      ← 全文（不常驻；模型按需 read_file / grep）
#
# 为什么分离：cjh 的 loadSkills（src/skills.cj:222）把技能正文**全文拼接注入** system prompt，
#   正文越厚，每轮请求的常驻 token 越多。入口只承担"何时用 + 全文在哪"，
#   细节留在磁盘上按需读取——离线、零新代码、常驻成本从数十 KB 降到 KB 级。
#
# 收录来源：
#   1) 本仓 skills/*.md 六篇自研技能（零依赖，纯 Markdown；仓内仍是全文，安装时投影成"入口+全文"）
#   2) （可选 --with-cangjie-skills）CangjieSkills 的三个外部技能，按依赖分级：
#      - cangjie-code-review / cangjie-build-diagnose：纯 Markdown references，零依赖
#      - cangjie-coding：需要 Python 3.11+（scripts/search_docs.py + references/knowledge.sqlite3）
#
# 去重策略：只收录 **Skill 发布件** `.agents/skills/*`（三个技能合计约 8.9 MB）；仓库根的
#   开发态语料 `references/`（39 MB）与发布件内容重复，默认不收。
#
# 用法：
#   scripts/install-cangjie-knowledge.sh                       # 只装本仓六篇
#   scripts/install-cangjie-knowledge.sh --with-cangjie-skills # 额外收录 CangjieSkills
#   scripts/install-cangjie-knowledge.sh --force               # 覆盖同名技能（含用户自建）
#   scripts/install-cangjie-knowledge.sh --dry-run             # 只打印将要做什么
#
# 环境变量：
#   CJH_HOME                 数据目录（默认 $HOME/.cjh）
#   CANGJIE_SKILLS_REPO      CangjieSkills 仓库地址（默认 AtomGit）
#   CANGJIE_SKILLS_BRANCH    指定分支（默认克隆默认分支）
#
# 幂等与升级：
#   - 入口带标记 `cjh-knowledge-entry v1`：重跑即幂等刷新（无需 --force）；
#   - 旧版安装产物（整篇正文直接写进 ~/.cjh/skills/）：自动迁移为短入口——先把旧文件
#     备份到 ~/.cjh/skills/.backup/<name>.md.<时间戳>，再改写，绝不丢内容；
#   - 其他同名但非本工具生成的文件：跳过（保护用户自建技能），--force 才覆盖。
#     判定"本工具生成"：含标记；或 frontmatter 的 name 与本技能名一致；或含 CangjieSkills 来源备注。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CJH_HOME="${CJH_HOME:-$HOME/.cjh}"
SKILLS_DIR="$CJH_HOME/skills"
REF_DIR="$CJH_HOME/cangjie-ref"
FULLTEXT_DIR="$REF_DIR/skills"

CANGJIE_SKILLS_REPO="${CANGJIE_SKILLS_REPO:-https://atomgit.com/Cangjie-SIG/CangjieSkills.git}"
CANGJIE_SKILLS_BRANCH="${CANGJIE_SKILLS_BRANCH:-}"

ZERO_DEP_SKILLS="cangjie-code-review cangjie-build-diagnose"
PY_SKILL="cangjie-coding"
MIN_PY_MINOR=11

ENTRY_MARKER="cjh-knowledge-entry v1"
WITH_EXTERNAL=0
FORCE=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --with-cangjie-skills) WITH_EXTERNAL=1 ;;
        --force) FORCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
            exit 0
            ;;
        *) echo "[install] 未知参数：$arg（--help 查看用法）" >&2; exit 2 ;;
    esac
done

log() { echo "[install] $*"; }
warn() { echo "[install][warn] $*" >&2; }
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] $*"
    else
        "$@"
    fi
}

entry_bytes=0
fulltext_bytes=0
count_entries=0
count_fulltext=0

# 取 frontmatter 中某个键的值（保留引号等原始形态；文件须以 --- 开头）
fm_value() { # $1=文件 $2=键名
    awk -v key="$2" '
        NR == 1 && $0 == "---" { inf = 1; next }
        inf && $0 == "---" { exit }
        inf {
            if (index($0, key ":") == 1) {
                line = $0
                sub(/^[^:]*:[ \t]*/, "", line)
                print line
                exit
            }
        }
    ' "$1"
}

# 旧版整篇入口迁移：先备份旧文件（绝不丢内容），日志说清去向
migrate_legacy_entry() { # $1=入口路径 $2=name
    local target="$1" name="$2"
    local backup_dir="$SKILLS_DIR/.backup"
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    run mkdir -p "$backup_dir"
    run cp "$target" "$backup_dir/$name.md.$stamp"
    log "旧版整篇入口 → 已备份 $backup_dir/$name.md.$stamp，改写为短入口"
}

# 是否应写入入口：本工具产物 → 幂等刷新；旧版产物 → 备份后迁移；其余 → 保护用户文件
should_write_entry() { # $1=入口路径 $2=name
    local target="$1" name="$2"
    if [ ! -e "$target" ]; then
        return 0
    fi
    if grep -qF "$ENTRY_MARKER" "$target" 2>/dev/null; then
        return 0
    fi
    local fm_name
    fm_name="$(fm_value "$target" name)"
    if [ "$fm_name" = "$name" ] || grep -qF "atomgit.com/Cangjie-SIG/CangjieSkills" "$target" 2>/dev/null; then
        migrate_legacy_entry "$target" "$name"
        return 0
    fi
    if [ "$FORCE" -eq 1 ]; then
        log "覆盖（--force）：$target"
        return 0
    fi
    log "跳过（已存在且非本工具生成，--force 可覆盖）：$target"
    return 1
}

# 生成短入口：frontmatter（触发用）+ 一行指针 + 标记
write_entry() { # $1=name $2=description $3=全文绝对路径 $4=来源说明
    local name="$1" desc="$2" full="$3" origin="$4"
    local target="$SKILLS_DIR/$name.md"
    if ! should_write_entry "$target" "$name"; then
        return 0
    fi
    if [ -z "$desc" ]; then
        warn "$name 的 frontmatter 缺少 description（触发信息会变弱）"
    fi
    run mkdir -p "$SKILLS_DIR"
    local tmp
    tmp="$(mktemp)"
    {
        printf -- '---\n'
        printf 'name: %s\n' "$name"
        printf 'description: %s\n' "$desc"
        printf -- '---\n\n'
        printf '完整文档（命令 / 示例 / 清单）在磁盘上，不在本提示词内：`%s`\n' "$full"
        printf '需要时用 `read_file` 读它；内容长时先 `grep` 定位小节标题，再只读命中那一段。\n'
        printf '\n<!-- %s：正文已外置（常驻提示词只保留本入口）。\n' "$ENTRY_MARKER"
        printf '     来源：%s；重跑 scripts/install-cangjie-knowledge.sh 可刷新本入口。 -->\n' "$origin"
    } > "$tmp"
    run cp "$tmp" "$target"
    rm -f "$tmp"
    if [ "$DRY_RUN" -eq 0 ]; then
        entry_bytes=$((entry_bytes + $(wc -c < "$target")))
    fi
    count_entries=$((count_entries + 1))
}

# 全文（按需读取）落盘：内容一致则不动，保持 mtime 稳定
put_fulltext() { # $1=源文件 $2=目标路径
    if [ -e "$2" ] && cmp -s "$1" "$2"; then
        return 0
    fi
    run mkdir -p "$(dirname "$2")"
    run cp "$1" "$2"
    if [ "$DRY_RUN" -eq 0 ]; then
        fulltext_bytes=$((fulltext_bytes + $(wc -c < "$2")))
    fi
    count_fulltext=$((count_fulltext + 1))
}

# ---------- 1) 本仓六篇自研技能：仓内是全文，安装时投影成"入口 + 全文" ----------
install_own_skills() {
    local src_dir="$REPO_ROOT/skills"
    if [ ! -d "$src_dir" ]; then
        warn "未找到 $src_dir，跳过自研技能"
        return 0
    fi
    local f name desc full
    for f in "$src_dir"/*.md; do
        [ -e "$f" ] || continue
        name="$(basename "$f" .md)"
        desc="$(fm_value "$f" description)"
        full="$FULLTEXT_DIR/$name/SKILL.md"
        put_fulltext "$f" "$full"
        write_entry "$name" "$desc" "$full" "本仓 skills/$name.md"
    done
    log "自研技能投影完成：入口 → $SKILLS_DIR，全文 → $FULLTEXT_DIR"
}

# ---------- 2) 外部技能：整目录收录（全文）+ 短入口 ----------
# CangjieSkills 是 <name>/{SKILL.md,scripts,references} 目录式，保留渐进披露结构；
# SKILL.md 正文里的相对路径就地改写为绝对路径，入口只指向改好的那份。
rewrite_skill_md() { # $1=SKILL.md 绝对路径 $2=技能根目录 $3=name
    local md="$1" root="$2" name="$3"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] 改写相对路径为绝对路径：$md"
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    {
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line//.\/references\//$root/references/}"
            line="${line//<skill-root>/$root}"
            line="${line//scripts\//$root/scripts/}"
            printf '%s\n' "$line"
        done < "$md"
        if ! grep -qF "来源：$CANGJIE_SKILLS_REPO" "$md" 2>/dev/null; then
            printf '\n<!-- 本文件由 scripts/install-cangjie-knowledge.sh 从 CangjieSkills 收录生成；\n     来源：%s（.agents/skills/%s）。升级上游请重跑脚本（--force 覆盖）。 -->\n' \
                "$CANGJIE_SKILLS_REPO" "$name"
        fi
    } > "$tmp"
    mv "$tmp" "$md"
}

install_external_skill() { # $1=克隆根 $2=name
    local repo_dir="$1" name="$2"
    local src="$repo_dir/.agents/skills/$name"
    local corpus_dest="$FULLTEXT_DIR/$name"
    local entry_dest="$SKILLS_DIR/$name.md"

    if [ ! -f "$src/SKILL.md" ]; then
        warn "未找到 $src/SKILL.md，跳过 $name"
        return 0
    fi
    local need_corpus=1
    if [ -e "$corpus_dest" ] && [ "$FORCE" -eq 0 ]; then
        need_corpus=0
    fi
    if [ "$need_corpus" -eq 1 ]; then
        run mkdir -p "$FULLTEXT_DIR"
        if [ -d "$corpus_dest" ] && [ "$FORCE" -eq 1 ]; then
            run rm -rf "$corpus_dest"
        fi
        run cp -R "$src" "$corpus_dest"
        if [ "$DRY_RUN" -eq 0 ]; then
            fulltext_bytes=$((fulltext_bytes + $(du -sb "$corpus_dest" | cut -f1)))
            count_fulltext=$((count_fulltext + 1))
        fi
        rewrite_skill_md "$corpus_dest/SKILL.md" "$corpus_dest" "$name"
    else
        log "全文已存在，跳过语料复制：$corpus_dest"
    fi

    local desc
    desc="$(fm_value "$corpus_dest/SKILL.md" description)"
    write_entry "$name" "$desc" "$corpus_dest/SKILL.md" \
        "$CANGJIE_SKILLS_REPO（.agents/skills/$name）"
    log "已收录外部技能 $name → 入口 $entry_dest，全文 $corpus_dest/SKILL.md"
}

python_ok() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$MIN_PY_MINOR" <<'PY'
import sys
need = int(sys.argv[1])
sys.exit(0 if sys.version_info >= (3, need) else 1)
PY
}

install_external_skills() {
    local tmp
    tmp="$(mktemp -d)"
    log "克隆 CangjieSkills（depth 1）→ $tmp"
    local clone_args=(--depth 1 -q)
    [ -n "$CANGJIE_SKILLS_BRANCH" ] && clone_args+=(--branch "$CANGJIE_SKILLS_BRANCH")
    if ! run git clone "${clone_args[@]}" "$CANGJIE_SKILLS_REPO" "$tmp/CangjieSkills"; then
        warn "克隆失败（网络或地址问题）：$CANGJIE_SKILLS_REPO"
        rm -rf "$tmp"
        return 1
    fi
    local repo_dir="$tmp/CangjieSkills"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] 将收录：$ZERO_DEP_SKILLS $PY_SKILL"
        rm -rf "$tmp"
        return 0
    fi

    local s
    for s in $ZERO_DEP_SKILLS; do
        install_external_skill "$repo_dir" "$s"
    done

    if python_ok; then
        log "检测到 $(python3 -V 2>&1)，满足 Python 3.${MIN_PY_MINOR}+，收录 $PY_SKILL"
        install_external_skill "$repo_dir" "$PY_SKILL"
    else
        warn "未检测到 Python 3.${MIN_PY_MINOR}+：跳过 $PY_SKILL（该技能的检索后端 scripts/search_docs.py 依赖 Python）"
        warn "  如需安装：装好 Python 3.${MIN_PY_MINOR}+ 后重跑，或手工复制 .agents/skills/$PY_SKILL"
    fi
    rm -rf "$tmp"
}

# ---------- 执行 ----------
log "数据目录：$CJH_HOME"
install_own_skills
if [ "$WITH_EXTERNAL" -eq 1 ]; then
    install_external_skills || warn "外部技能收录未完成（本仓技能已装好）"
else
    log "未指定 --with-cangjie-skills：仅安装本仓六篇（如需收录 CangjieSkills 请加该参数）"
fi

log "本次写入：入口 $count_entries 篇（常驻提示词字节：$entry_bytes）、全文 $count_fulltext 份（按需读取字节：$fulltext_bytes）"
log "入口目录 $SKILLS_DIR："
ls -1 "$SKILLS_DIR" 2>/dev/null | sed 's/^/  - /' || true
log "完成。入口（含描述）进 system prompt；全文留在磁盘，模型按需 read_file / grep，离线可用。"
