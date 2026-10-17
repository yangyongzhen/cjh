/* cjh 官网交互：复制命令 / 滚动进场 / 导航高亮（零依赖） */
(() => {
  /* 1) 一键复制命令 */
  document.querySelectorAll('.copy').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const target = document.querySelector(btn.dataset.copy);
      if (!target) return;
      const text = target.innerText.trim();
      let ok = false;
      try {
        await navigator.clipboard.writeText(text);
        ok = true;
      } catch (err) {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.top = '-1000px';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        try {
          ok = document.execCommand('copy');
        } catch (e) {
          ok = false;
        }
        document.body.removeChild(ta);
      }
      const label = btn.textContent;
      btn.textContent = ok ? '已复制' : '复制失败';
      btn.classList.toggle('done', ok);
      setTimeout(() => {
        btn.textContent = label;
        btn.classList.remove('done');
      }, 1500);
    });
  });

  /* 2) 滚动进场（尊重 prefers-reduced-motion，由 CSS 兜底） */
  const items = Array.from(
    document.querySelectorAll('.section-head, .card, .shot, .panel, .dl, .doc, .cta-inner')
  );
  if (items.length && 'IntersectionObserver' in window) {
    items.forEach((el) => el.classList.add('reveal'));
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add('in');
            io.unobserve(entry.target);
          }
        });
      },
      { rootMargin: '0px 0px -8% 0px', threshold: 0.08 }
    );
    items.forEach((el) => io.observe(el));
  }

  /* 3) 导航：滚动描边 + 当前区块高亮 */
  const nav = document.getElementById('nav');
  const links = Array.from(document.querySelectorAll('.nav-links a'));
  const sections = links
    .map((a) => document.querySelector(a.getAttribute('href')))
    .filter((el) => !!el);
  const onScroll = () => {
    if (nav) {
      nav.style.borderBottomColor = window.scrollY > 8 ? 'rgba(15, 191, 174, 0.35)' : '';
    }
    let active = null;
    sections.forEach((sec) => {
      if (sec.getBoundingClientRect().top <= 120) active = sec;
    });
    links.forEach((a) => {
      const on = active && a.getAttribute('href') === '#' + active.id;
      a.style.color = on ? 'var(--text)' : '';
    });
  };
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();
})();
