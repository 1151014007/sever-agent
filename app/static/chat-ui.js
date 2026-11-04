/* Appearance preferences stay separate from user and conversation identifiers. */
(() => {
  const THEME_KEY = "mewhelp_appearance";
  const THEMES = ["cloud", "linen", "graphite"];
  let theme = "cloud";
  try {
    const saved = localStorage.getItem(THEME_KEY);
    if (THEMES.includes(saved)) theme = saved;
  } catch (_) { /* A blocked preference store should not prevent chatting. */ }
  document.documentElement.dataset.theme = theme;

  document.addEventListener("DOMContentLoaded", () => {
    const settings = document.getElementById("appearance-settings");
    const settingsButton = document.getElementById("settings-button");
    const themeInputs = [...document.querySelectorAll('input[name="appearance"]')];
    themeInputs.forEach((input) => {
      input.checked = input.value === theme;
      input.addEventListener("change", () => {
        if (!input.checked || !THEMES.includes(input.value)) return;
        theme = input.value;
        document.documentElement.dataset.theme = theme;
        try {
          localStorage.setItem(THEME_KEY, theme);
          document.getElementById("settings-note").textContent = "已保存，下次打开时继续使用此配色。";
        } catch (_) {
          document.getElementById("settings-note").textContent = "已应用；当前浏览器无法保存外观设置。";
        }
      });
    });

    function positionSettings() {
      const trigger = settingsButton.getBoundingClientRect();
      settings.style.left = Math.max(12, Math.min(trigger.right - settings.offsetWidth, innerWidth - settings.offsetWidth - 12)) + "px";
      settings.style.top = Math.max(12, Math.min(trigger.top - settings.offsetHeight - 12, innerHeight - settings.offsetHeight - 12)) + "px";
    }
    settingsButton.addEventListener("click", () => {
      if (settings.open) return;
      settings.showModal();
      settingsButton.setAttribute("aria-expanded", "true");
      positionSettings();
      themeInputs.find((input) => input.checked)?.focus();
    });
    document.getElementById("settings-close").addEventListener("click", () => settings.close());
    settings.addEventListener("click", (event) => {
      if (event.target !== settings) return;
      const rect = settings.getBoundingClientRect();
      if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) settings.close();
    });
    settings.addEventListener("close", () => {
      settingsButton.setAttribute("aria-expanded", "false");
      settingsButton.focus();
    });
    window.addEventListener("resize", () => { if (settings.open) positionSettings(); });

    // The same sidebar remains available on small screens, including its settings entry.
    const sidebar = document.getElementById("sidebar");
    const sidebarToggle = document.getElementById("sidebar-toggle");
    const scrim = document.getElementById("sidebar-scrim");
    const mobile = matchMedia("(max-width: 760px)");
    function setSidebar(open, restoreFocus = false) {
      const expanded = open && mobile.matches;
      document.body.classList.toggle("sidebar-open", expanded);
      sidebarToggle.setAttribute("aria-expanded", String(expanded));
      sidebar.inert = mobile.matches && !expanded;
      scrim.hidden = !expanded;
      if (expanded) document.getElementById("sidebar-close").focus();
      else if (restoreFocus) sidebarToggle.focus();
    }
    sidebarToggle.addEventListener("click", () => setSidebar(true));
    document.getElementById("sidebar-close").addEventListener("click", () => setSidebar(false, true));
    scrim.addEventListener("click", () => setSidebar(false, true));
    sidebar.addEventListener("click", (event) => {
      const button = event.target.closest(".conv-item, #new-chat");
      if (button && !button.disabled && mobile.matches) setSidebar(false);
    });
    document.addEventListener("keydown", (event) => {
      if (!mobile.matches || !document.body.classList.contains("sidebar-open") || settings.open) return;
      if (event.key === "Escape") setSidebar(false, true);
      if (event.key === "Tab") {
        const buttons = [...sidebar.querySelectorAll("button:not(:disabled)")].filter((button) => button.getClientRects().length);
        const first = buttons[0], last = buttons[buttons.length - 1];
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
      }
    });
    mobile.addEventListener("change", () => {
      if (settings.open) settings.close();
      setSidebar(false);
    });
    setSidebar(false);
  });
})();
