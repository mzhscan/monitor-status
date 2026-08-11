// ===== 星黎监控网页版 =====
// 数据源：relay 的 /web/api/* 端点
// 5s 自动刷新，响应式布局（PC 3列 / 平板 2列 / 手机 1列）
//
// 关键设计：
// - 单页，不依赖任何外部库（不引 jQuery / 不引 chart.js）
// - 折线图用内联 SVG 手写，downsample 到 ~200 点
// - agent 标识用 "id" 字段（push 模式 = push token；proxy 模式 = 用户配置的 name）

(() => {
  "use strict";

  // ===== 全局状态 =====
  const state = {
    agents: [],          // /web/api/agents 返回的列表
    reports: new Map(),  // id -> /web/api/report 响应
    histories: new Map(),// email -> /web/api/traffic_72h 响应
    expandedId: null,    // v2.4.26+: 当前展开的 card id（null = 都没展开）
    selectedEmail: null,
    refreshTimer: null,
    lastRefreshMs: 0,
    refreshError: null,
    sortOrder: loadSortOrder(),  // v2.4.26+: 用户手动排序的 id 列表，存 localStorage
  };

  // v2.4.26+: 排序顺序持久化（localStorage）
  // 用户用 card 头部的上下箭头调整顺序，刷新页面后保留
  const SORT_KEY = "monitor-status-card-order-v1";
  function loadSortOrder() {
    try { return JSON.parse(localStorage.getItem(SORT_KEY) || "[]"); }
    catch (_) { return []; }
  }
  function saveSortOrder() {
    try { localStorage.setItem(SORT_KEY, JSON.stringify(state.sortOrder)); }
    catch (_) { /* localStorage 满了或被禁用，忽略 */ }
  }
  function moveCard(id, dir) {
    const idx = state.sortOrder.indexOf(id);
    if (idx < 0) {
      // 第一次出现这个 id，加到末尾
      state.sortOrder.push(id);
    }
    const newIdx = dir === "up" ? Math.max(0, idx - 1) : Math.min(state.sortOrder.length - 1, idx + 1);
    if (newIdx === idx) return;
    state.sortOrder.splice(idx, 1);
    state.sortOrder.splice(newIdx, 0, id);
    saveSortOrder();
    renderMachines();
  }

  const RELAY_BASE = location.origin;  // 网页本身挂在 relay 上，API 同源
  const REFRESH_INTERVAL_MS = 5000;
  const STALE_THRESHOLD_MS = 120000;  // 2 分钟
  const CHART_MAX_POINTS = 200;

  // ===== 工具 =====
  const $ = (sel) => document.querySelector(sel);
  const $$ = (sel) => document.querySelectorAll(sel);

  const fmtBytes = (b) => {
    if (b == null || isNaN(b)) return "—";
    if (b < 1024) return b + " B";
    if (b < 1024 * 1024) return (b / 1024).toFixed(1) + " KB";
    if (b < 1024 * 1024 * 1024) return (b / 1024 / 1024).toFixed(1) + " MB";
    return (b / 1024 / 1024 / 1024).toFixed(2) + " GB";
  };
  const fmtUptime = (s) => {
    if (!s) return "—";
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    if (d > 0) return `${d}天${h}小时`;
    if (h > 0) return `${h}小时${m}分`;
    return `${m}分钟`;
  };
  const fmtAge = (ms) => {
    if (ms < 0) return "—";
    if (ms < 1000) return "刚刚";
    if (ms < 60000) return Math.floor(ms / 1000) + "秒前";
    if (ms < 3600000) return Math.floor(ms / 60000) + "分钟前";
    if (ms < 86400000) return Math.floor(ms / 3600000) + "小时前";
    return Math.floor(ms / 86400000) + "天前";
  };
  const fmtTime = (ts) => {
    const d = new Date(ts);
    return d.toLocaleTimeString("zh-CN", { hour12: false });
  };
  const escapeHTML = (s) => {
    if (s == null) return "";
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  };
  const classOfPercent = (p) => {
    if (p == null || isNaN(p)) return "low";
    if (p < 60) return "low";
    if (p < 85) return "mid";
    return "high";
  };

  // ===== 数据加载 =====

  async function fetchJSON(url, opts) {
    const r = await fetch(url, { cache: "no-store", ...opts });
    if (!r.ok) {
      let msg = `HTTP ${r.status}`;
      try {
        const j = await r.json();
        if (j.error) msg = j.error;
      } catch (_) { /* 不是 JSON 就算了 */ }
      throw new Error(msg);
    }
    return r.json();
  }

  async function loadAgents() {
    const data = await fetchJSON(`${RELAY_BASE}/web/api/agents`);
    state.agents = data.agents || [];
  }

  async function loadReport(id) {
    return fetchJSON(`${RELAY_BASE}/web/api/report?id=${encodeURIComponent(id)}`);
  }

  async function loadHistory(id, email) {
    return fetchJSON(`${RELAY_BASE}/web/api/traffic_72h?id=${encodeURIComponent(id)}&email=${encodeURIComponent(email)}`);
  }

  // ===== 渲染：概览 =====

  function renderOverview() {
    const total = state.agents.length;
    const online = state.agents.filter((a) => a.online).length;
    const offline = total - online;
    const xuiOnline = state.agents.reduce((s, a) => s + (a.online ? a.online_count || 0 : 0), 0);
    const xuiTotal = state.agents.reduce((s, a) => s + a.total_clients || 0, 0);

    $("#totalCount").textContent = total;
    $("#onlineCount").textContent = online;
    $("#offlineCount").textContent = offline;
    $("#xuiCount").textContent = `${xuiOnline} / ${xuiTotal}`;
  }

  // ===== 渲染：机器卡片 =====

  function renderMachines() {
    const container = $("#machines");
    if (state.agents.length === 0) {
      container.innerHTML = '<p class="loading">还没有机器。检查 relay 的 token 配置。</p>';
      return;
    }
    // v2.4.26+: 排序逻辑
    // 1) 用户手动排的顺序（localStorage 里的 state.sortOrder）优先
    // 2) 新出现的 machine 排到末尾
    // 3) 都不在用户列表时：按 online 排（在线的优先）
    const userOrder = state.sortOrder;
    const sorted = [...state.agents].sort((a, b) => {
      const ia = userOrder.indexOf(a.id);
      const ib = userOrder.indexOf(b.id);
      if (ia >= 0 && ib >= 0) return ia - ib;
      if (ia >= 0) return -1;
      if (ib >= 0) return 1;
      if (a.online !== b.online) return a.online ? -1 : 1;
      return (a.name || "").localeCompare(b.name || "");
    });
    // 把首次出现的 id 同步进 sortOrder（保持顺序持久化）
    sorted.forEach((a) => {
      if (!userOrder.includes(a.id)) userOrder.push(a.id);
    });

    container.innerHTML = sorted.map((a) => renderCard(a, state.expandedId === a.id)).join("");

    // 绑定事件
    container.querySelectorAll(".machine-card").forEach((el) => {
      const id = el.dataset.id;
      // 点击 card 切换展开/收起（除非点的是按钮）
      el.addEventListener("click", (e) => {
        if (e.target.closest("button")) return;  // 忽略按钮点击
        toggleExpand(id);
      });
    });
    container.querySelectorAll(".sort-up").forEach((el) => {
      el.addEventListener("click", (e) => { e.stopPropagation(); moveCard(el.dataset.id, "up"); });
    });
    container.querySelectorAll(".sort-down").forEach((el) => {
      el.addEventListener("click", (e) => { e.stopPropagation(); moveCard(el.dataset.id, "down"); });
    });
  }

  // v2.4.26+: 展开/收起切换
  function toggleExpand(id) {
    if (state.expandedId === id) {
      state.expandedId = null;
    } else {
      state.expandedId = id;
      // 展开时立即拉一次 detail 数据（如果还没有）
      if (!state.reports.has(id)) {
        loadReport(id).then((r) => {
          state.reports.set(id, r);
          renderMachines();
        }).catch(() => { /* 错误会显示在 card 上 */ });
        renderMachines();
        return;
      }
    }
    renderMachines();
  }

  function renderCard(a, expanded) {
    let statusClass = "unknown";
    let statusText = "未知";
    if (a.source === "pushed" || a.source === "proxy") {
      if (a.online) { statusClass = "online"; statusText = "在线"; }
      else if (a.last_received_ms > 0) { statusClass = "stale"; statusText = "卡"; }
      else { statusClass = "offline"; statusText = "离线"; }
    } else {
      statusClass = "unknown";
      statusText = "未配置";
    }
    const cardClass = a.online ? "" : (a.last_received_ms > 0 ? "stale" : "offline");
    const expandedClass = expanded ? " expanded" : "";

    // mini stats 来自 reports 缓存（可能还没拉到）
    const report = state.reports.get(a.id);
    let miniStats = "";
    if (report && report.hardware) {
      const cpu = (report.hardware.cpu || {}).percent;
      const mem = (report.hardware.memory || {}).percent;
      const disk = (report.hardware.disk || {}).percent;
      miniStats = `
        <div class="mini-stat">
          <div class="mini-label">CPU</div>
          <div class="mini-value ${classOfPercent(cpu)}">${cpu != null ? cpu.toFixed(0) + "%" : "—"}</div>
        </div>
        <div class="mini-stat">
          <div class="mini-label">内存</div>
          <div class="mini-value ${classOfPercent(mem)}">${mem != null ? mem.toFixed(0) + "%" : "—"}</div>
        </div>
        <div class="mini-stat">
          <div class="mini-label">磁盘</div>
          <div class="mini-value ${classOfPercent(disk)}">${disk != null ? disk.toFixed(0) + "%" : "—"}</div>
        </div>`;
    } else {
      miniStats = `
        <div class="mini-stat"><div class="mini-label">CPU</div><div class="mini-value">—</div></div>
        <div class="mini-stat"><div class="mini-label">内存</div><div class="mini-value">—</div></div>
        <div class="mini-stat"><div class="mini-label">磁盘</div><div class="mini-value">—</div></div>`;
    }

    const xuiStrip = a.has_xui ? `
      <div class="xui-strip">
        🛰️ 3xui：<b>${a.online_count || 0}</b> 在线 / ${a.total_clients || 0} 总
      </div>` : "";

    const sourceTag = a.source === "pushed"
      ? '<span class="source-tag" title="reverse-agent 推过来">push</span>'
      : a.source === "proxy"
      ? '<span class="source-tag" title="relay 代理拉取">proxy</span>'
      : "";

    // v2.4.26+: 排序按钮（每张卡头部都有）
    const sortBtns = `
      <div class="sort-btns">
        <button class="sort-up" data-id="${escapeHTML(a.id)}" title="上移" aria-label="上移">▲</button>
        <button class="sort-down" data-id="${escapeHTML(a.id)}" title="下移" aria-label="下移">▼</button>
      </div>`;

    // v2.4.26+: 展开时把详情渲染在 card 内部
    const expandArrow = `<span class="expand-arrow ${expanded ? "open" : ""}">▾</span>`;
    const expandContent = expanded ? `<div class="card-detail">${renderDetailBody(a, report)}</div>` : "";

    return `
      <div class="machine-card ${cardClass}${expandedClass}" data-id="${escapeHTML(a.id)}">
        <div class="card-head">
          <div class="card-name">
            <span class="status-dot status-${statusClass}"></span>
            ${escapeHTML(a.name)}
            ${sourceTag}
            ${expandArrow}
          </div>
          <div class="card-head-right">
            <div class="status-text">${statusText}</div>
            ${sortBtns}
          </div>
        </div>
        <div class="card-stats">${miniStats}</div>
        ${xuiStrip}
        <div class="card-footer">${a.last_received_ms ? "更新于 " + fmtTime(a.last_received_ms) + " · " + fmtAge(Date.now() - a.last_received_ms) : "从未上报"}</div>
        ${expandContent}
      </div>`;
  }

  // ===== 渲染：详情（在 card 内部展开，不再用 modal） =====

  // v2.4.26+: 展开时调用这个，返回详情 HTML（不含 head，已在 card 头部显示）
  // report 可能为 null（拉数据失败），这时显示 error
  function renderDetailBody(a, report) {
    if (!report) {
      return `<div class="error-banner">⚠️ 拉数据失败，可能机器不在线或 token 不对</div>`;
    }
    const hw = report.hardware || {};
    const cpu = hw.cpu || {};
    const mem = hw.memory || {};
    const load = hw.load || {};
    const net = hw.network || {};
    const disks = hw.disks || [];
    const xui = report.xui || {};
    const services = report.services || [];

    const barRow = (label, pct, hint) => {
      if (pct == null) return "";
      const cls = classOfPercent(pct);
      return `
        <div class="bar-row">
          <div class="bar-label"><span>${label}</span><span>${pct.toFixed(1)}%</span></div>
          <div class="bar-track"><div class="bar-fill ${cls}" style="width:${Math.min(100, Math.max(0, pct)).toFixed(1)}%"></div></div>
          ${hint ? `<div style="font-size:11px;color:#6b7280;margin-top:2px">${escapeHTML(hint)}</div>` : ""}
        </div>`;
    };

    const netKV = `
      <div class="kv"><div class="kv-label">接收</div><div class="kv-value">${fmtBytes(net.rx_bytes)}</div></div>
      <div class="kv"><div class="kv-label">发送</div><div class="kv-value">${fmtBytes(net.tx_bytes)}</div></div>`;

    const diskKV = disks.length === 0 ? "" : `
      <div class="kv"><div class="kv-label">磁盘 (${escapeHTML(disks[0].mount || "")})</div><div class="kv-value">${disks[0].used_gb?.toFixed(1)} / ${disks[0].total_gb?.toFixed(0)} GB (${disks[0].percent?.toFixed(0)}%)</div></div>`;

    const allDisks = disks.length > 1
      ? `<details style="margin-top:6px"><summary style="cursor:pointer;color:#8b91a0;font-size:12px">所有磁盘 (${disks.length})</summary>
         <div style="margin-top:6px">${disks.map((d) => `${escapeHTML(d.mount)}: ${d.used_gb?.toFixed(1)}/${d.total_gb?.toFixed(0)} GB (${d.percent?.toFixed(0)}%)`).join("<br>")}</div></details>`
      : "";

    const servicesHTML = services.length === 0 ? "" : `
      <div class="detail-section">
        <div class="section-title">系统服务</div>
        <div class="kv-grid">
          ${services.map((s) => `
            <div class="kv">
              <div class="kv-label">${escapeHTML(s.name)}</div>
              <div class="kv-value" style="color:${s.status === "active" ? "#10b981" : "#ef4444"}">${escapeHTML(s.status)}</div>
            </div>`).join("")}
        </div>
      </div>`;

    // 3xui 部分
    let xuiHTML = "";
    if (xui.clients && xui.clients.length > 0) {
      const clients = xui.clients;
      const totalUp = clients.reduce((s, c) => s + (c.up_bytes || 0), 0);
      const totalDn = clients.reduce((s, c) => s + (c.down_bytes || 0), 0);
      const obsAt = xui.observed_at ? fmtTime(xui.observed_at * 1000) : "—";

      xuiHTML = `
        <div class="detail-section">
          <div class="section-title">3xui 客户端（${clients.length}）</div>
          <div class="kv-grid">
            <div class="kv"><div class="kv-label">在线</div><div class="kv-value" style="color:#10b981">${xui.online_count || 0}</div></div>
            <div class="kv"><div class="kv-label">总上行</div><div class="kv-value">${fmtBytes(totalUp)}</div></div>
            <div class="kv"><div class="kv-label">总下行</div><div class="kv-value">${fmtBytes(totalDn)}</div></div>
            <div class="kv"><div class="kv-label">3xui 数据于</div><div class="kv-value">${obsAt}</div></div>
          </div>
          ${xui.inbound_total ? `
            <div class="kv-grid" style="margin-top:10px">
              <div class="kv"><div class="kv-label">主机总上行 (实时)</div><div class="kv-value">${fmtBytes(xui.inbound_total.up_bytes)}</div></div>
              <div class="kv"><div class="kv-label">主机总下行 (实时)</div><div class="kv-value">${fmtBytes(xui.inbound_total.down_bytes)}</div></div>
            </div>
            <div style="font-size:11px;color:#8b91a0;margin-top:4px">inbound 实时流量（per-client 数字断开时才更新，滞后 20+ 分钟）</div>
          ` : ""}
          <table class="client-table" style="margin-top:14px">
            <thead>
              <tr>
                <th>客户端</th><th>状态</th><th>72h ↑</th><th>72h ↓</th>
              </tr>
            </thead>
            <tbody>
              ${clients.map((c) => `
                <tr class="client-row" data-email="${escapeHTML(c.email)}" data-id="${escapeHTML(a.id)}">
                  <td><span class="online-dot ${c.online ? "yes" : "no"}"></span>${escapeHTML(c.email)}</td>
                  <td>${c.enable ? (c.online ? "在线" : "启用") : "停用"}</td>
                  <td>${c.up_72h_bytes != null ? fmtBytes(c.up_72h_bytes) : "—"}</td>
                  <td>${c.down_72h_bytes != null ? fmtBytes(c.down_72h_bytes) : "—"}</td>
                </tr>`).join("")}
            </tbody>
          </table>
          <div class="chart-host" data-id="${escapeHTML(a.id)}"></div>
        </div>`;
    } else if (xui._error) {
      xuiHTML = `
        <div class="detail-section">
          <div class="section-title">3xui</div>
          <div class="error-banner">⚠️ ${escapeHTML(xui._error)}</div>
        </div>`;
    }

    return `
      <div class="detail-section">
        <div class="section-title">资源占用</div>
        ${barRow("CPU", cpu.percent, cpu.model ? cpu.model : null)}
        ${barRow("内存", mem.percent, mem.total_gb ? `${mem.used_gb?.toFixed(1)} / ${mem.total_gb?.toFixed(1)} GB` : null)}
        ${barRow("磁盘", hw.disk?.percent, hw.disk ? `${hw.disk.used_gb?.toFixed(1)} / ${hw.disk.total_gb?.toFixed(0)} GB` : null)}
        <div class="kv-grid" style="margin-top:10px">
          <div class="kv"><div class="kv-label">Load 1m</div><div class="kv-value">${load.load1?.toFixed(2) || "—"}</div></div>
          <div class="kv"><div class="kv-label">Load 5m</div><div class="kv-value">${load.load5?.toFixed(2) || "—"}</div></div>
          <div class="kv"><div class="kv-label">Load 15m</div><div class="kv-value">${load.load15?.toFixed(2) || "—"}</div></div>
          <div class="kv"><div class="kv-label">运行时长</div><div class="kv-value">${fmtUptime(report.uptime_sec || hw.uptime_sec)}</div></div>
          ${netKV}
          ${diskKV}
        </div>
        ${allDisks}
      </div>

      ${servicesHTML}
      ${xuiHTML}
    `;
  }

  // v2.4.26+: 展开时绑定 3xui 客户端行的图表加载
  function bindExpandedCardEvents(id) {
    const card = document.querySelector(`.machine-card.expanded[data-id="${CSS.escape(id)}"]`);
    if (!card) return;
    card.querySelectorAll(".client-row").forEach((row) => {
      row.addEventListener("click", (e) => {
        e.stopPropagation();  // 不让触发 card 的收起
        const email = row.dataset.email;
        const cardId = row.dataset.id;
        openChart(cardId, email);
      });
    });
  }

  async function openChart(id, email) {
    state.selectedEmail = email;
    // 找当前展开 card 里的 chart-host
    const card = document.querySelector(`.machine-card.expanded[data-id="${CSS.escape(id)}"]`);
    if (!card) return;
    const host = card.querySelector(".chart-host");
    if (!host) return;
    host.innerHTML = `<div class="chart-wrap"><div class="chart-title"><span>${escapeHTML(email)} · 加载中…</span></div></div>`;
    try {
      const hist = await loadHistory(id, email);
      host.innerHTML = renderChart(id, email, hist);
    } catch (e) {
      host.innerHTML = `<div class="chart-wrap"><div class="chart-title"><span>${escapeHTML(email)}</span></div><div class="error-banner">加载失败：${escapeHTML(e.message)}</div></div>`;
    }
  }

  // ===== 折线图（纯 SVG） =====

  function downsample(points, maxN) {
    if (points.length <= maxN) return points;
    const bucketSize = points.length / maxN;
    const out = [];
    for (let i = 0; i < maxN; i++) {
      const start = Math.floor(i * bucketSize);
      const end = Math.floor((i + 1) * bucketSize);
      let sumUp = 0, sumDn = 0, sumTs = 0, n = 0;
      for (let j = start; j < end && j < points.length; j++) {
        sumUp += points[j].up || 0;
        sumDn += points[j].dn || 0;
        sumTs += points[j].ts || 0;
        n++;
      }
      if (n > 0) {
        out.push({ ts: sumTs / n, up: sumUp / n, dn: sumDn / n });
      }
    }
    return out;
  }

  function renderChart(id, email, hist) {
    if (!hist || hist.length === 0) {
      return `<div class="chart-wrap"><div class="chart-title"><span>${escapeHTML(email)}</span></div><div class="error-banner">暂无 72h 历史（agent 启动不到 5 分钟或这台机器没 3xui 客户端）</div></div>`;
    }

    const pts = downsample(hist, CHART_MAX_POINTS);
    const W = 600, H = 180, PAD = { l: 50, r: 12, t: 16, b: 26 };
    const innerW = W - PAD.l - PAD.r;
    const innerH = H - PAD.t - PAD.b;

    const ts0 = pts[0].ts, ts1 = pts[pts.length - 1].ts;
    const maxV = Math.max(...pts.map((p) => Math.max(p.up, p.dn)), 1);
    const minV = 0;

    const xFor = (ts) => PAD.l + ((ts - ts0) / (ts1 - ts0 || 1)) * innerW;
    const yFor = (v) => PAD.t + (1 - (v - minV) / (maxV - minV || 1)) * innerH;

    const pathFor = (key) => pts.map((p, i) => `${i === 0 ? "M" : "L"}${xFor(p.ts).toFixed(1)},${yFor(p[key]).toFixed(1)}`).join(" ");

    const upPath = pathFor("up");
    const dnPath = pathFor("dn");

    // y 轴 4 个刻度
    const yTicks = [];
    for (let i = 0; i <= 3; i++) {
      const v = minV + (maxV - minV) * (i / 3);
      yTicks.push({ v, y: PAD.t + (1 - i / 3) * innerH });
    }
    // x 轴刻度（4 个）
    const xTicks = [];
    for (let i = 0; i <= 3; i++) {
      const ts = ts0 + (ts1 - ts0) * (i / 3);
      xTicks.push({ ts, x: PAD.l + (i / 3) * innerW, label: fmtTime(ts) });
    }

    const startLabel = fmtTime(ts0);
    const endLabel = fmtTime(ts1);
    const lastUp = pts[pts.length - 1].up;
    const lastDn = pts[pts.length - 1].dn;
    const totalUp = lastUp;
    const totalDn = lastDn;

    return `
      <div class="chart-wrap">
        <div class="chart-title">
          <span>📈 ${escapeHTML(email)} · 累计流量（72h）</span>
          <span class="chart-legend">
            <span class="legend-item"><span class="legend-swatch" style="background:#4f8ef7"></span>↑ ${fmtBytes(totalUp)}</span>
            <span class="legend-item"><span class="legend-swatch" style="background:#10b981"></span>↓ ${fmtBytes(totalDn)}</span>
          </span>
        </div>
        <svg class="chart-svg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">
          <!-- 网格 -->
          ${yTicks.map((t) => `<line x1="${PAD.l}" y1="${t.y.toFixed(1)}" x2="${W - PAD.r}" y2="${t.y.toFixed(1)}" stroke="rgba(255,255,255,0.05)" stroke-width="1"/>`).join("")}
          <!-- y 轴标签 -->
          ${yTicks.map((t) => `<text x="${PAD.l - 6}" y="${(t.y + 3).toFixed(1)}" text-anchor="end" fill="#6b7280" font-size="10">${fmtBytes(t.v)}</text>`).join("")}
          <!-- x 轴标签 -->
          ${xTicks.map((t) => `<text x="${t.x.toFixed(1)}" y="${(H - 8)}" text-anchor="middle" fill="#6b7280" font-size="10">${t.label}</text>`).join("")}
          <!-- 下行面积（淡） -->
          <path d="${dnPath} L${(W - PAD.r).toFixed(1)},${(H - PAD.b).toFixed(1)} L${PAD.l},${(H - PAD.b).toFixed(1)} Z" fill="rgba(16, 185, 129, 0.08)" />
          <!-- 上行线 -->
          <path d="${upPath}" stroke="#4f8ef7" stroke-width="1.5" fill="none" />
          <!-- 下行线 -->
          <path d="${dnPath}" stroke="#10b981" stroke-width="1.5" fill="none" />
          <!-- 边框 -->
          <line x1="${PAD.l}" y1="${PAD.t}" x2="${PAD.l}" y2="${H - PAD.b}" stroke="rgba(255,255,255,0.1)" stroke-width="1"/>
          <line x1="${PAD.l}" y1="${H - PAD.b}" x2="${W - PAD.r}" y2="${H - PAD.b}" stroke="rgba(255,255,255,0.1)" stroke-width="1"/>
        </svg>
        <div style="font-size:10px;color:#6b7280;margin-top:4px">${startLabel} → ${endLabel} · 共 ${hist.length} 个点（采样到 ${pts.length}）</div>
      </div>`;
  }

  // ===== 主刷新循环 =====

  async function refresh() {
    const btn = $("#refreshBtn");
    btn.classList.add("spinning");
    try {
      await loadAgents();

      // 并行拉所有 agent 的最新 report
      const ids = state.agents.map((a) => a.id);
      await Promise.allSettled(ids.map(async (id) => {
        try {
          const r = await loadReport(id);
          state.reports.set(id, r);
        } catch (_) {
          state.reports.delete(id);
        }
      }));

      // 更新页面
      renderOverview();
      renderMachines();
      // v2.4.26+: 展开中的 card 重新绑定 client-row 事件
      // （renderMachines 整个重渲染了，事件会丢，但 chart-host 里的内容用户已经看过就不重画了）
      if (state.expandedId) {
        bindExpandedCardEvents(state.expandedId);
      }

      state.lastRefreshMs = Date.now();
      state.refreshError = null;
      $("#lastRefresh").textContent = "更新于 " + fmtTime(state.lastRefreshMs);
      const errBanner = document.querySelector("#app > .error-banner");
      if (errBanner) errBanner.remove();
    } catch (e) {
      state.refreshError = e.message;
      $("#lastRefresh").textContent = "刷新失败: " + e.message;
      const container = $("#machines");
      if (state.agents.length === 0) {
        container.innerHTML = `<div class="error-banner">❌ 无法连接 relay：${escapeHTML(e.message)}</div>`;
      }
    } finally {
      btn.classList.remove("spinning");
    }
  }

  // ===== 启动 =====

  function start() {
    // 事件绑定
    $("#refreshBtn").addEventListener("click", refresh);
    // v2.4.26+: ESC 键收起展开的 card（取代了原来的 modal close）
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && state.expandedId) {
        state.expandedId = null;
        renderMachines();
      }
    });

    // 首次加载
    refresh();
    // 定时刷新
    state.refreshTimer = setInterval(refresh, REFRESH_INTERVAL_MS);

    // 页面隐藏时停刷新，回来时立刻刷
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) {
        clearInterval(state.refreshTimer);
      } else {
        refresh();
        state.refreshTimer = setInterval(refresh, REFRESH_INTERVAL_MS);
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
