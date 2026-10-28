/* cjh 官网 i18n：英文是默认语言，也是 HTML 里唯一的原文。
 *
 * 这里只维护中文字典，切回英文时从每个元素首次加载时缓存的 innerHTML 还原。
 * 好处是少一份英文副本 —— 不会出现「中英两版文案各改各的」这种同步债；
 * 代价是英文只能改在 HTML 上，改中文只能改这份字典，边界很清楚。
 */
(() => {
  const STORAGE_KEY = 'cjh-lang';

  const ZH = {
    brandTag: '仓颉 · Coding Agent',

    'nav.features': '特性',
    'nav.shots': '界面',
    'nav.start': '上手',
    'nav.download': '下载',
    'nav.ecosystem': '生态',
    'nav.docs': '文档',
    'nav.cta': '下载 v1.6.1',

    'hero.title': '用仓颉语言<br><span class="grad">从零实现的终端编码代理</span>',
    'hero.lede':
      '说一句话，Agent 自己规划、调工具、读结果、迭代到完成；全过程在 TUI 里实时可见，也能用内置 Web 界面远程驱动。<strong>单二进制零依赖</strong> —— 一个文件就是一个 agent。',
    'hero.download': '下载 v1.6.1',
    'hero.start': '30 秒上手',
    'hero.repo': 'AtomGit 仓库 →',

    'fact.size': '静态单文件',
    'fact.tests': '单测全绿',
    'fact.deps': '运行时依赖',
    'fact.libs': '可发布库',

    'term.nokey': '# 无需 API Key：Mock 模式跑通全链路',
    'term.realmodel': '# 接真模型（任选一个 Provider 的 Key）',

    'strip.lang': '语言',
    'strip.form': '形态',
    'strip.form.v': 'TUI + Web + 无头 JSON',
    'strip.channel': '渠道',

    'features.h': '为什么用它',
    'features.p':
      '不堆功能。只盯两条硬指标 —— <strong>省 token</strong>、<strong>跑得快</strong> —— 再把它装进一个不用安装的二进制里。',

    'c1.h': '一个文件 = 一个 agent',
    'c1.p':
      '仓颉 <code>cjnative</code> 静态编译：Linux 17.1 MB、Windows exe 14.2 MB，没有 Node / Python 运行时依赖。下载、<code>chmod</code>、运行，三步到位。',
    'c2.h': '省 token：截断 + 落盘回溯',
    'c2.p':
      '超阈值工具结果保留头尾、中间完整落盘 <code>~/.cjh/spill/</code>，省略标记带路径，模型需要时用 <code>read_file</code> 读回 —— 既省 token 又不丢信息。',
    'c3.h': '高执行效率：DAG 并发',
    'c3.p':
      '从工具调用提取资源访问 <code>(path, isWrite)</code> 构建依赖图，拓扑分组，同组 <code>spawn</code> 并发、组间串行；<code>parallelSavedMs</code> 实时量化省下的时间。',
    'c4.h': 'TUI 差分渲染',
    'c4.p':
      '自实现 termios + ANSI 差分刷新（纯 libc FFI，不依赖第三方库）：Markdown 渲染、<code>/</code> 命令补全、10 套主题、Tasks / Agents 双面板左右分栏、危险操作审批队列化。',
    'c5.h': 'Web 远程驱动',
    'c5.p':
      '内置 HTTP Server + WebSocket 流式对话 + REST API + 前端 SPA，浏览器里远程驱动同一个 Agent，token 鉴权与启动安全审计默认开启。',
    'c6.h': '插件信任链',
    'c6.p':
      '技能即 Markdown，插件可携带工具；SHA256 校验和 + SM2 国密签名（仓颉 <code>stdx.crypto</code> 原生），从语言层到供应链层双保险。',

    'c7.h': '并行子代理，可控可观测',
    'c7.p':
      '<code>task</code> 工具并发派发 <code>explore</code>/<code>worker</code> 子代理，右下 Agents 面板实时呈现轮次 / token / 当前工具；并发数、token 预算、超时四键管控，错峰起跑 + 限流退避重试 —— 5 路并发实测扛得住真实服务商限流。',

    'shots.h': '界面',
    'shots.p': '终端里的全屏 TUI，和浏览器里的实时流。',
    shot1:
      '<strong>会话实录</strong>：Mock 模式下的真实 CLI 输出 —— 规划、调工具、看结果、给出答复',
    shot2:
      '<strong>TUI</strong>：彩色 logo + 对话 / 帮助视图 + 可滚动输出区（Markdown、流式增量、工具调用提示）+ 状态栏 + 输入框',
    shot3:
      '<strong>Web</strong>：内置 HTTP Server + WebSocket 流式对话，浏览器远程驱动同一个 Agent',

    'start.h': '30 秒上手',
    'start.p': '先不花钱跑起来：Mock 模式不联网、不用 API Key，全链路照样走一遍。',
    'p1.h': '① 零 Key 试跑（Mock）',
    'p2.h': '② 接真模型',
    'p3.h': '③ Windows',
    copy: '复制',
    'start.note':
      '想从源码构建？看 <a href="https://atomgit.com/qq8864/cjh/blob/main/README.md" target="_blank" rel="noopener">README</a>：仓颉 SDK 1.0.5+，<code>cjpm build</code> 出静态单文件，<code>./scripts/test.sh</code> 跑全量单测。',

    'dl.h': '下载 v1.6.1',
    'dl.p':
      'Linux 与 Windows 预编译包，直接取用。<a href="https://atomgit.com/qq8864/cjh/releases" target="_blank" rel="noopener">全部发布记录 →</a>',
    'dl1.desc': '静态单文件，<code>chmod +x</code> 即可运行。需 glibc ≥ 2.34。',
    'dl2.os': 'Windows x64 · 推荐',
    'dl2.desc': 'exe + 4 个运行时 DLL，解压即用。',
    'dl3.os': 'Windows x64 · 仅 exe',
    'dl3.desc': '只要可执行文件，运行时 DLL 自备。',
    'dl.note':
      '需要 tar 包或完整校验和？见仓库 <a href="https://atomgit.com/qq8864/cjh/blob/main/dist/SHA256SUMS" target="_blank" rel="noopener">dist/SHA256SUMS</a>。',

    'eco.h': '沉到上游的痕迹',
    'eco.p':
      '不只是「用仓颉写了个 agent」：开发中踩的坑写成了文档，确认的缺陷反馈给了官方 —— 每条都带最小复现，不是「感觉有问题」。',
    'e1.h': '56 条开发踩坑',
    'e1.p':
      '1000+ 行记录，覆盖 FFI / 条件编译 / 静态链接 / 并发与锁 / TLS / 终端编码 / 产物核对。每条都写了现象、排查铁证与可复用配方。<a href="https://atomgit.com/qq8864/cjh/blob/main/docs/开发文档与踩坑记录.md" target="_blank" rel="noopener">读记录 →</a>',
    'e2.h': '6 个可独立发布的库',
    'e2.p':
      '<code>cjterm</code> / <code>cjlog</code> / <code>cjconfig</code> / <code>cjcfg</code> / <code>cjutil</code> / <code>cjllm</code>：零依赖或仅官方 stdx，各带独立 README、示例与 MIT 许可，可单独贡献给生态。',
    'e3.h': '12 条上游缺陷报告',
    'e3.p':
      '提交给 <code>Cangjie/UsersForum</code> 的 #3473–#3484（缺陷 + 提案），全部已被官方分派并回复。<a href="https://atomgit.com/Cangjie/UsersForum/issues/3473" target="_blank" rel="noopener">看 issue →</a>',
    'e4.h': '静态链接下 cjpm test 崩溃',
    'e4.p':
      '编译能过，跑测试包时 SIGSEGV / double free 退出；同一工程切动态链接 <strong>441/441 全绿</strong>，定位到静态链接 + 测试宏的组合。<a href="https://atomgit.com/Cangjie/UsersForum/issues/3473" target="_blank" rel="noopener">#3473 →</a>',
    'e5.h': 'Windows 出不了纯 exe',
    'e5.p':
      '同样的 <code>--static*</code>：Linux 能出零依赖单文件，Windows 上既不报错也不生效（产物大小与 PE 导入表同动态版一致），SDK 也没提供静态 runtime。<a href="https://atomgit.com/Cangjie/UsersForum/issues/3484" target="_blank" rel="noopener">#3484 →</a>',
    'e6.h': '连自己的结论也推翻',
    'e6.p':
      '复核社区反馈时纠正了自身 3 条旧判断：<code>connect(timeout:)</code> 其实生效、<code>spawn</code> 默认栈其实完整、<code>Directory.removeIfExists</code> 其实是顶级函数。实测优先于印象。',

    'docs.h': '文档',
    'docs.p': '源码与文档同仓，关键设计都写清了「为什么」。',
    'd1.t': '功能清单',
    'd1.d': 'Agent 主循环 / 工具 / 主题 / 插件 / MCP / 平台',
    'd2.t': '更新日志',
    'd2.d': '按版本记录新增、修复与测试',
    'd3.t': '开发文档与踩坑记录',
    'd3.d': '56 条真实踩坑与定位手法',
    'd4.t': '跨平台终端层方案',
    'd4.d': 'POSIX / Win32 条件编译与 VT 统一',
    'd5.t': '进度记录',
    'd5.d': '阶段目标与实测数据',
    'd6.d': '英文主版；中文版见 README.zh-CN.md',

    'cta.h': '一个文件就是一个 agent',
    'cta.p': '下载 17 MB，跳过所有运行时安装。有问题、有想法，直接开 issue。',
    'cta.issue': '开 issue',

    'footer.tag': '仓颉语言实现的 Coding Agent Harness',
    'footer.note':
      'v1.6.1 · 本站为纯静态页面（无外部依赖），源码见仓库 <code>site/</code> · QQ 技术交流群 <strong>92381027</strong> · 开源许可 <a href="https://atomgit.com/qq8864/cjh/blob/main/LICENSE" target="_blank" rel="noopener">MIT</a>',
  };

  const nodes = Array.from(document.querySelectorAll('[data-i18n]'));

  // 首次加载时把英文原文（含标签）缓存到数据集上，作为切回英文的唯一来源
  nodes.forEach((el) => {
    if (el.dataset.i18nHtml === undefined) el.dataset.i18nHtml = el.innerHTML;
  });

  // 语言优先级：URL 的 ?lang= > localStorage > 默认英文。
  // URL 参数既方便把中文版链接直接发给别人，也让无头渲染能定格某一语言。
  const langFromUrl = () => {
    try {
      const q = new URLSearchParams(location.search).get('lang');
      return q === 'zh' || q === 'en' ? q : null;
    } catch (e) {
      return null;
    }
  };

  const readLang = () => {
    try {
      return localStorage.getItem(STORAGE_KEY) === 'zh' ? 'zh' : 'en';
    } catch (e) {
      // 隐私模式 / file:// 下 localStorage 可能不可用，退回默认英文
      return 'en';
    }
  };

  const writeLang = (lang) => {
    try {
      localStorage.setItem(STORAGE_KEY, lang);
    } catch (e) {
      /* 存不住就只在本次会话内生效 */
    }
  };

  const apply = (lang) => {
    const zh = lang === 'zh';
    nodes.forEach((el) => {
      const key = el.dataset.i18n;
      el.innerHTML = zh && ZH[key] !== undefined ? ZH[key] : el.dataset.i18nHtml;
    });
    document.documentElement.lang = zh ? 'zh-CN' : 'en';
    const btn = document.getElementById('lang-switch');
    if (btn) {
      btn.textContent = zh ? 'EN' : '中文';
      // 按钮写的是「目标语言」，标签也照此说，读屏用户不会误解
      btn.setAttribute('aria-label', zh ? 'Switch to English' : '切换到中文');
    }
  };

  document.addEventListener('DOMContentLoaded', () => {
    const fromUrl = langFromUrl();
    // 从 ?lang= 进来就记住它，之后不带参数刷新仍是同一语言
    if (fromUrl) writeLang(fromUrl);
    apply(fromUrl || readLang());
    const btn = document.getElementById('lang-switch');
    if (btn) {
      btn.addEventListener('click', () => {
        const next = readLang() === 'zh' ? 'en' : 'zh';
        writeLang(next);
        apply(next);
      });
    }
  });

  // main.js 的复制反馈要跟着当前语言走：t(英文, 中文)
  window.cjhI18n = {
    lang: readLang,
    t: (en, zh) => (readLang() === 'zh' ? zh : en),
  };
})();
