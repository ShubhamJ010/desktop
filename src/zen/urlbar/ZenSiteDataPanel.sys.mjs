/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import { AppConstants } from "resource://gre/modules/AppConstants.sys.mjs";

const ADDONS_BUTTONS_HIDDEN = Services.prefs.getBoolPref(
  "zen.theme.hide-unified-extensions-button",
  true
);

const lazy = {};

ChromeUtils.defineESModuleGetters(lazy, {
  FeatureCallout: "resource:///modules/asrouter/FeatureCallout.sys.mjs",
  gZenBoostsManager: "resource:///modules/zen/boosts/ZenBoostsManager.sys.mjs",
});

// --- Workspace Disabled Extensions Architecture (SOLID / DRY) ---

/**
 * Manages per-workspace extension disabled states and lifecycle events.
 *
 * Responsibilities (SRP):
 * - Persists and retrieves disabled extension IDs per workspace in preferences.
 * - Emits observer notifications and callback events for UI and behavioral hooks.
 * - Decouples state storage from presentation logic.
 */
export class ZenSpaceExtensionsManager {
  static PREF_DISABLED_EXTENSIONS = "zen.workspaces.disabled-extensions";
  static TOPIC_CHANGED = "zen-space-extensions-changed";

  static #listeners = new Set();

  /**
   * Get all disabled extension IDs for a given workspace.
   * @param {string} spaceId
   * @returns {string[]}
   */
  static getDisabled(spaceId) {
    if (!spaceId) {
      return [];
    }
    try {
      const raw = Services.prefs.getStringPref(
        this.PREF_DISABLED_EXTENSIONS,
        "{}"
      );
      const map = JSON.parse(raw);
      return Array.isArray(map[spaceId]) ? map[spaceId] : [];
    } catch {
      return [];
    }
  }

  /**
   * Check if an extension is disabled in a given workspace.
   * @param {string} spaceId
   * @param {string} extId
   * @returns {boolean}
   */
  static isDisabled(spaceId, extId) {
    if (!spaceId || !extId) {
      return false;
    }
    return this.getDisabled(spaceId).includes(extId);
  }

  /**
   * Set disabled extension IDs for a workspace.
   * @param {string} spaceId
   * @param {string[]} list
   */
  static setDisabled(spaceId, list) {
    if (!spaceId) {
      return;
    }
    try {
      const raw = Services.prefs.getStringPref(
        this.PREF_DISABLED_EXTENSIONS,
        "{}"
      );
      const map = JSON.parse(raw);
      if (list && list.length > 0) {
        map[spaceId] = Array.from(new Set(list));
      } else {
        delete map[spaceId];
      }
      Services.prefs.setStringPref(
        this.PREF_DISABLED_EXTENSIONS,
        JSON.stringify(map)
      );
      this.#notifyChange(spaceId);
    } catch (e) {
      console.error("ZenSpaceExtensionsManager: failed to save disabled extensions", e);
    }
  }

  static PREF_BROWSER_DISABLED = "zen.workspaces.browser-disabled-extensions";

  /**
   * Get the entire disabled mapping object { [spaceId]: string[] }.
   * @returns {Record<string, string[]>}
   */
  static getAllDisabled() {
    try {
      const raw = Services.prefs.getStringPref(
        this.PREF_DISABLED_EXTENSIONS,
        "{}"
      );
      return JSON.parse(raw);
    } catch {
      return {};
    }
  }

  /**
   * Resolve an extension ID from a DOM element (toolbarbutton, item, etc.).
   * @param {Element} el
   * @returns {string|null}
   */
  static getExtIdFromElement(el) {
    if (!el) return null;
    if (el.getAttribute("data-extensionid")) return el.getAttribute("data-extensionid");
    if (el.getAttribute("extension-id")) return el.getAttribute("extension-id");
    if (el.dataset?.extensionid) return el.dataset.extensionid;
    const id = el.id || "";
    if (id) {
      const policy = globalThis.WebExtensionPolicy?.getByWidgetId?.(id);
      if (policy?.id) {
        return policy.id;
      }
    }
    if (id.endsWith("-browser-action")) {
      const prefix = id.replace(/-browser-action$/, "").toLowerCase();
      const policies = globalThis.WebExtensionPolicy?.getActiveExtensions?.() || [];
      for (const policy of policies) {
        const sanitized = policy.id.toLowerCase().replace(/[^a-z0-9_-]/g, "_");
        if (sanitized === prefix) {
          return policy.id;
        }
      }
      const allDisabled = this.getAllDisabled();
      for (const list of Object.values(allDisabled)) {
        for (const extId of list) {
          const sanitized = extId.toLowerCase().replace(/[^a-z0-9_-]/g, "_");
          if (sanitized === prefix) return extId;
        }
      }
    }
    return null;
  }

  /**
   * Update visibility of toolbar buttons and unified extension items in a window
   * according to the active workspace's disabled extensions list.
   * @param {DOMWindow} win
   */
  static updateToolbarVisibility(win) {
    if (!win || win.closed) return;
    try {
      const activeSpace = win.gZenWorkspaces?.activeWorkspace;
      if (!activeSpace) return;
      const disabled = this.getDisabled(activeSpace);

      const navBar = win.document.getElementById("nav-bar");
      if (navBar) {
        for (const btn of navBar.querySelectorAll("toolbarbutton, toolbaritem")) {
          if (btn.closest("#zen-unified-site-data-panel, #zen-site-data-addons")) {
            continue;
          }
          const extId = this.getExtIdFromElement(btn);
          if (extId) {
            if (disabled.includes(extId)) {
              btn.setAttribute("data-zen-space-hidden", "true");
            } else {
              btn.removeAttribute("data-zen-space-hidden");
            }
          }
        }
      }

      // Ensure no elements inside site data panel carry data-zen-space-hidden
      const siteData = win.document.getElementById("zen-site-data-addons");
      if (siteData) {
        for (const el of siteData.querySelectorAll("[data-zen-space-hidden]")) {
          el.removeAttribute("data-zen-space-hidden");
        }
      }
    } catch (e) {
      console.error("[ZenSpaceExtensionsManager] updateToolbarVisibility error:", e);
    }
  }

  /**
   * Synchronize browser tabs to the `zen.workspaces.browser-disabled-extensions` pref
   * so child/content processes can immediately enforce script/style isolation.
   */
  static syncBrowserSpaces() {
    try {
      const disabledMap = this.getAllDisabled();
      const browserMap = {};

      for (const win of Services.wm.getEnumerator("navigator:browser")) {
        if (!win.gBrowser?.tabs) continue;
        for (const tab of win.gBrowser.tabs) {
          const browser = tab.linkedBrowser;
          if (!browser?.browserId) continue;
          const spaceId =
            tab.getAttribute("zen-workspace-id") ||
            win.gZenWorkspaces?.activeWorkspace;
          if (spaceId && disabledMap[spaceId]) {
            browserMap[browser.browserId] = disabledMap[spaceId];
          }
        }
      }

      Services.prefs.setStringPref(
        this.PREF_BROWSER_DISABLED,
        JSON.stringify(browserMap)
      );
    } catch (e) {
      console.error("[ZenSpaceExtensionsManager] syncBrowserSpaces error:", e);
    }
  }

  /**
   * Update all browser windows and synchronize process state.
   */
  static updateAllWindows() {
    this.syncBrowserSpaces();
    for (const win of Services.wm.getEnumerator("navigator:browser")) {
      this.updateToolbarVisibility(win);
    }
  }

  /**
   * Disable an extension in a workspace.
   * @param {string} spaceId
   * @param {string} extId
   */
  static disable(spaceId, extId) {
    if (!spaceId || !extId) {
      return;
    }
    const current = this.getDisabled(spaceId);
    if (!current.includes(extId)) {
      current.push(extId);
      this.setDisabled(spaceId, current);
    }
  }

  /**
   * Enable an extension in a workspace.
   * @param {string} spaceId
   * @param {string} extId
   */
  static enable(spaceId, extId) {
    if (!spaceId || !extId) {
      return;
    }
    const current = this.getDisabled(spaceId);
    if (current.includes(extId)) {
      const next = current.filter(id => id !== extId);
      this.setDisabled(spaceId, next);
    }
  }

  /**
   * Subscribe to changes in disabled extensions.
   * @param {Function} callback (spaceId: string) => void
   * @returns {Function} unsubscribe function
   */
  static addChangeListener(callback) {
    this.#listeners.add(callback);
    return () => this.#listeners.delete(callback);
  }

  static #notifyChange(spaceId) {
    this.updateAllWindows();
    try {
      Services.obs.notifyObservers(null, this.TOPIC_CHANGED, spaceId);
    } catch {
      // Ignored in test/headless environments
    }
    for (const listener of this.#listeners) {
      try {
        listener(spaceId);
      } catch (err) {
        console.error("ZenSpaceExtensionsManager listener error:", err);
      }
    }
  }
}

/**
 * Presenter for the 3-card stack representation of disabled extensions.
 *
 * Responsibilities (SRP & Open/Closed):
 * - Deterministically calculates visual slot mappings.
 * - Handles placeholder slots when fewer than 3 extensions are disabled.
 * - Updates DOM attributes, images, tooltips, and accessibility attributes.
 */
export class ZenDisabledStackRenderer {
  static PLACEHOLDER_ICON = "chrome://mozapps/skin/extensions/extensionGeneric.svg";

  static SLOTS = [
    { role: "left", mode: "triple-left", selector: ".zen-disabled-stack-card-left" },
    { role: "center", mode: "triple-center", selector: ".zen-disabled-stack-card-center" },
    { role: "right", mode: "triple-right", selector: ".zen-disabled-stack-card-right" },
  ];

  /**
   * Calculate slot configurations for a given array of icon URLs.
   * Guarantees all 3 visual cards are present, using placeholders as needed.
   *
   * @param {string[]} disabledIcons
   * @param {number} totalCount
   * @returns {Array<{ role: string, mode: string, selector: string, icon: string, isPlaceholder: boolean }>}
   */
  static calculateSlots(disabledIcons, totalCount = disabledIcons.length) {
    const count = totalCount;
    if (count === 0) {
      return [];
    }

    if (count === 1) {
      return [
        { ...this.SLOTS[0], icon: this.PLACEHOLDER_ICON, isPlaceholder: true },
        { ...this.SLOTS[1], icon: disabledIcons[0] || this.PLACEHOLDER_ICON, isPlaceholder: false },
        { ...this.SLOTS[2], icon: this.PLACEHOLDER_ICON, isPlaceholder: true },
      ];
    }

    if (count === 2) {
      return [
        { ...this.SLOTS[0], icon: disabledIcons[0] || this.PLACEHOLDER_ICON, isPlaceholder: false },
        { ...this.SLOTS[1], icon: disabledIcons[1] || disabledIcons[0] || this.PLACEHOLDER_ICON, isPlaceholder: false },
        { ...this.SLOTS[2], icon: this.PLACEHOLDER_ICON, isPlaceholder: true },
      ];
    }

    // 3 or more: left card = icon 0, right card = icon 1, center elevated = icon 2
    return [
      { ...this.SLOTS[0], icon: disabledIcons[0] || this.PLACEHOLDER_ICON, isPlaceholder: false },
      { ...this.SLOTS[1], icon: disabledIcons[2] || disabledIcons[0] || this.PLACEHOLDER_ICON, isPlaceholder: false },
      { ...this.SLOTS[2], icon: disabledIcons[1] || disabledIcons[0] || this.PLACEHOLDER_ICON, isPlaceholder: false },
    ];
  }

  /**
   * Render the stack button cards and tooltip.
   *
   * @param {Element} stackBtn
   * @param {string[]} disabledIcons
   * @param {number} totalDisabledCount
   */
  static render(stackBtn, disabledIcons, totalDisabledCount) {
    if (!stackBtn) {
      return;
    }

    const slots = this.calculateSlots(disabledIcons, totalDisabledCount);
    for (const slot of slots) {
      const card = stackBtn.querySelector(slot.selector);
      if (!card) {
        continue;
      }

      card.hidden = false;
      card.setAttribute("stack-mode", slot.mode);

      if (slot.isPlaceholder) {
        card.setAttribute("placeholder", "true");
      } else {
        card.removeAttribute("placeholder");
      }

      const img = card.querySelector(".zen-disabled-stack-icon");
      if (img && slot.icon) {
        img.src = slot.icon;
      }
    }

    stackBtn.setAttribute(
      "tooltiptext",
      `Disabled in this Space (${totalDisabledCount})`
    );
  }
}

export class nsZenSiteDataPanel {
  #iconMap = {
    install: "extension",
    "site-protection": "shield",
  };

  constructor(window) {
    this.window = window;
    this.document = window.document;

    this.unifiedPanel = this.#initUnifiedPanel();
    this.unifiedPanelView = "unified-extensions-view";
    this.extensionsPanelView = "original-unified-extensions-view";

    if (ADDONS_BUTTONS_HIDDEN) {
      this.window.gUnifiedExtensions._panel = this.unifiedPanel;

      // Remove the old permissions dialog
      this.document
        .getElementById("unified-extensions-panel-template")
        ?.remove();
    } else {
      this.extensionsPanel = this.#initExtensionsPanel();
    }

    this.#init();
  }

  #init() {
    // Add a new button to the urlbar popup
    const button = this.window.MozXULElement.parseXULToFragment(`
      <box id="zen-site-data-icon-button" role="button" align="center" class="identity-box-button" delegatesanchor="true">
        <image />
        <box class="zen-site-data-boost-animation"><box class="zen-site-data-boost-strip"/></box>
      </box>
    `);
    this.anchor = button.querySelector("#zen-site-data-icon-button");
    this.document.getElementById("identity-icon-box").before(button);

    this.extensionsPanelButton = this.document.getElementById(
      "unified-extensions-button"
    );
    this.window.gUnifiedExtensions._button = ADDONS_BUTTONS_HIDDEN
      ? this.anchor
      : this.extensionsPanelButton;

    this.document
      .getElementById("nav-bar")
      .setAttribute("addon-webext-overflowbutton", "zen-site-data-icon-button");

    this.#initCopyUrlButton();
    this.#initEventListeners();
    this.#initBrowserListeners();
    this.#initUnifiedExtensionsManageHook();
    this.#initSpaceDisabledExtensions();
    this.#maybeShowFeatureCallout();

    this.window.ZenSpaceExtensionsManager = ZenSpaceExtensionsManager;
    ZenSpaceExtensionsManager.updateToolbarVisibility(this.window);
    ZenSpaceExtensionsManager.syncBrowserSpaces();
  }

  #initEventListeners() {
    this.unifiedPanel.addEventListener("popupshowing", this);
    this.document
      .getElementById("zen-site-data-manage-addons")
      .addEventListener("click", this);
    this.document
      .getElementById("zen-site-data-settings-more")
      .addEventListener("click", this);
    this.anchor.addEventListener("click", this);
    const kCommandIDs = [
      "zen-site-data-header-share",
      "zen-site-data-header-boost",
      "zen-site-data-header-bookmark",
      "zen-site-data-security-info",
      "zen-site-data-actions",
      "zen-site-data-new-addon-button",
    ];

    for (let id of kCommandIDs) {
      this.document.getElementById(id).addEventListener("command", this);
    }

    this.#initContextMenuEventListener();
  }

  #initBrowserListeners() {
    Services.obs.addObserver(this, "zen-boosts-update");
    this.window.gBrowser.addProgressListener({
      onLocationChange: aWebProgress => {
        if (aWebProgress.isTopLevel) {
          this.checkIfTabIsBoosted();
        }
      },
    });
    const onWorkspacesUpdate = () => {
      if (this.#isFolderOpen()) {
        this.#toggleDisabledFolder(false);
      }
      this.#updateSpaceDisabledExtensions();
      ZenSpaceExtensionsManager.updateToolbarVisibility(this.window);
      ZenSpaceExtensionsManager.syncBrowserSpaces();
    };
    const onTabSelect = () => {
      ZenSpaceExtensionsManager.updateToolbarVisibility(this.window);
    };

    this.window.addEventListener("ZenWorkspacesUIUpdate", onWorkspacesUpdate);
    this.window.gBrowser.tabContainer?.addEventListener("TabSelect", onTabSelect);

    this.window.addEventListener(
      "unload",
      () => {
        this.window.removeEventListener("ZenWorkspacesUIUpdate", onWorkspacesUpdate);
        this.window.gBrowser.tabContainer?.removeEventListener("TabSelect", onTabSelect);
        this._unsubscribeExtensions?.();
        Services.obs.removeObserver(this, "zen-boosts-update");
      },
      { once: true }
    );
  }

  observe(subject, topic) {
    switch (topic) {
      case "zen-boosts-update":
        this.checkIfTabIsBoosted();
        break;
    }
  }

  #getCurrentDomain() {
    try {
      return this.window.gBrowser.currentURI.host;
    } catch {
      return "";
    }
  }

  checkIfTabIsBoosted() {
    const domain = this.#getCurrentDomain();
    const isBoosted = lazy.gZenBoostsManager.registeredBoostForDomain(domain);
    if (isBoosted) {
      this.anchor.setAttribute("boosting", "true");
    } else {
      this.anchor.removeAttribute("boosting");
    }
    // Force a reflow to ensure the attribute change is applied before any potential animation.
    if (this.unifiedPanel.state === "open") {
      this.anchor.getBoundingClientRect();
    }
  }

  #initCopyUrlButton() {
    // This function is a bit out of place, but it's related enough to the panel
    // that it's easier to do it here than in a separate module.
    const container = this.document.getElementById("page-action-buttons");
    const fragment = this.window.MozXULElement.parseXULToFragment(`
      <hbox id="zen-copy-url-button"
            class="urlbar-page-action"
            role="button"
            data-l10n-id="zen-urlbar-copy-url-button"
            disabled="true">
        <image class="urlbar-icon"/>
      </hbox>
    `);
    container.after(fragment);

    const aElement = this.document.getElementById("zen-copy-url-button");
    aElement.addEventListener("click", () => {
      if (aElement.hasAttribute("disabled")) {
        return;
      }
      this.document.getElementById("cmd_zenCopyCurrentURL").doCommand();
    });

    this.window.gBrowser.addProgressListener({
      onLocationChange: (aWebProgress, aRequest, aLocation) => {
        if (aWebProgress.isTopLevel) {
          const disabled = !this.#canCopyUrl(aLocation);
          if (disabled) {
            aElement.setAttribute("disabled", true);
          } else {
            aElement.removeAttribute("disabled");
          }
        }
      },
    });
  }

  #initContextMenuEventListener() {
    const kCommands = {
      context_zenClearSiteData: event => {
        this.window.gIdentityHandler.clearSiteData(event);
      },
      context_zenOpenGetAddons: () => {
        this.#openGetAddons();
      },
      context_zenOpenSiteSettings: () => {
        const { BrowserCommands } = this.window;
        BrowserCommands.pageInfo(null, "permTab");
      },
    };

    for (let [id, handler] of Object.entries(kCommands)) {
      this.document.getElementById(id).addEventListener("command", handler);
    }

    const menu = this.document.getElementById("unified-extensions-context-menu");
    if (menu) {
      menu.addEventListener("popupshowing", event => {
        if (event.target === menu) {
          this.#onUnifiedContextMenuShowing(menu);
        }
      });
    }
  }

  #initUnifiedExtensionsManageHook() {
    const manageExtensionItem = this.document.getElementById(
      "unified-extensions-context-menu-manage-extension"
    );

    manageExtensionItem.addEventListener("command", () => {
      this.unifiedPanel.hidePopup();
    });
  }

  #initExtensionsPanel() {
    const panel = this.window.gUnifiedExtensions.panel;

    const extensionsView = panel?.querySelector("#unified-extensions-view");
    extensionsView.setAttribute("id", this.extensionsPanelView);

    const panelMultiView = panel?.querySelector("panelmultiview");
    panelMultiView.setAttribute("mainViewId", this.extensionsPanelView);

    return panel;
  }

  #initUnifiedPanel() {
    const panel = this.document.getElementById("zen-unified-site-data-panel");
    this.window.gUnifiedExtensions.initializePanel(panel);
    return panel;
  }

  #preparePanel() {
    this.#toggleDisabledFolder(false);
    this.#resetSiteOptionsList();
    this.#setSiteBoost();
    this.#setSitePermissions();
    this.#setSiteSecurityInfo();
    this.#setSiteHeader();
    this.#updateSpaceDisabledExtensions();
    this.#setAddonsOverflow();
  }

  #setSiteBoost() {
    const domain = this.#getCurrentDomain();
    const uri = this.window.gBrowser.currentURI;
    const canBoostSite = lazy.gZenBoostsManager.canBoostSite(uri);

    const list = this.document.getElementById("zen-site-data-boost-list");
    const section = list.closest(".zen-site-data-section");
    section.hidden = true;

    if (!canBoostSite) {
      return;
    }

    /* Boosts panel */

    const boosts = lazy.gZenBoostsManager.loadBoostsFromStore(domain);
    let validBoostCount = 0;

    if (boosts) {
      const activeBoostId = lazy.gZenBoostsManager.getActiveBoostId(domain);
      boosts.forEach(boost => {
        const boostData = boost.boostEntry.boostData;
        if (!boostData.changeWasMade) {
          return;
        }
        validBoostCount++;

        const enabled = boost.id === activeBoostId;
        list.appendChild(
          this.#createBoostPanelItem(
            "boost-brush",
            boostData.boostName,
            "zen-site-data-toggle-boost",
            boost,
            enabled
          )
        );
      });
    }
    section.hidden = validBoostCount === 0;
  }

  #updateSiteBoost() {
    const boostList = this.document.getElementById("zen-site-data-boost-list");
    boostList.innerHTML = "";

    this.#setSiteBoost();
  }

  #createBoostPanelItem(
    iconClass,
    title,
    actionId,
    boost = null,
    enabled = false
  ) {
    const container = this.document.createXULElement("hbox");
    container.classList.add("permission-popup-boost-item");

    container.setAttribute("align", "center");
    container.setAttribute("role", "group");
    container.setAttribute("data-action-id", actionId);
    container.setAttribute("state", "enabled");

    if (boost) {
      container.setAttribute("data-boost-id", boost.id);
      container.setAttribute("state", enabled ? "enabled" : "disabled");
    }

    const img = this.document.createXULElement("toolbarbutton");
    img.classList.add(
      "permission-popup-boost-icon",
      "zen-site-data-boost-icon"
    );
    img.setAttribute("closemenu", "none");
    img.classList.add(iconClass);

    const labelContainer = this.document.createXULElement("vbox");
    labelContainer.setAttribute("flex", "1");
    labelContainer.setAttribute("align", "start");
    labelContainer.classList.add("permission-popup-boost-label-container");

    const nameLabel = this.document.createXULElement("label");
    nameLabel.setAttribute("flex", "1");
    nameLabel.setAttribute("class", "permission-popup-boost-label");
    nameLabel.textContent = title || "";
    labelContainer.appendChild(nameLabel);

    const stateLabel = this.document.createXULElement("label");
    stateLabel.setAttribute("class", "zen-permission-popup-boost-state-label");
    const stateLabelId = enabled
      ? "zen-site-data-protections-enabled"
      : "zen-site-data-protections-disabled";
    this.document.l10n.formatMessages([stateLabelId]).then(([labelContent]) => {
      stateLabel.textContent = labelContent.value;
    });
    labelContainer.appendChild(stateLabel);

    container.appendChild(img);
    container.appendChild(labelContainer);

    if (boost) {
      const editorButton = this.document.createXULElement("toolbarbutton");
      editorButton.setAttribute("data-action-id", "zen-site-data-edit-boost");
      editorButton.setAttribute("data-boost-id", boost.id);
      editorButton.classList.add("zen-permission-popup-boost-editor-button");
      container.appendChild(editorButton);

      editorButton.addEventListener("click", event => {
        event.stopPropagation(); // Prevents the container event
        this.#onBoostClick(event);
      });
    }

    container.addEventListener("click", this.#onBoostClick.bind(this));

    return container;
  }

  #setAddonsOverflow() {
    const addons = this.document.getElementById("zen-site-data-addons");
    if (addons.getBoundingClientRect().height > 420) {
      addons.setAttribute("overflowing", "true");
    } else {
      addons.removeAttribute("overflowing");
    }
  }

  get #currentPageIsBookmarked() {
    // A hacky way to check if the current page is bookmarked, but
    // it works for our purposes.
    return this.window.BookmarkingUI.star?.hasAttribute("starred");
  }

  #setSiteHeader() {
    {
      const button = this.document.getElementById("zen-site-data-reader-mode");
      const urlbarButton =
        this.window.document.getElementById("reader-mode-button");
      const isActive = urlbarButton?.hasAttribute("readeractive");
      const isVisible = !urlbarButton?.hidden || isActive;

      button.disabled = !isVisible;
      button.classList.toggle("active", Boolean(isActive));
      this.document.l10n.setAttributes(
        button,
        urlbarButton?.getAttribute("data-l10n-id") ||
          "zen-site-data-header-reader-mode"
      );
    }
    {
      const button = this.document.getElementById("zen-site-data-header-boost");
      const canBoost = lazy.gZenBoostsManager.canBoostSite(
        this.window.gBrowser.currentURI
      );
      if (canBoost) {
        button.removeAttribute("disabled");
      } else {
        button.setAttribute("disabled", "true");
      }
    }
    {
      const button = this.document.getElementById(
        "zen-site-data-header-bookmark"
      );
      const isPageBookmarked = this.#currentPageIsBookmarked;

      if (isPageBookmarked) {
        button.classList.add("active");
      } else {
        button.classList.remove("active");
      }
    }
    {
      const button = this.document.getElementById("zen-site-data-header-share");
      if (this.#canCopyUrl(this.window.gBrowser.currentURI)) {
        button.removeAttribute("disabled");
      } else {
        button.setAttribute("disabled", "true");
      }
    }
  }

  /**
   * Determines whether the copy URL button should be hidden for the given URI.
   *
   * @param {nsIURI} uri - The URI to check.
   * @returns {boolean} True if the button should be hidden, false otherwise.
   */
  #canCopyUrl(uri) {
    if (!uri) {
      return false;
    }

    return uri.scheme.startsWith("http");
  }

  #resetSiteOptionsList() {
    const settingsList = this.document.getElementById(
      "zen-site-data-settings-list"
    );
    settingsList.innerHTML = "";
    const boostList = this.document.getElementById("zen-site-data-boost-list");
    boostList.innerHTML = "";
  }

  #setSiteSecurityInfo() {
    const { gIdentityHandler } = this.window;
    const button = this.document.getElementById("zen-site-data-security-info");

    if (gIdentityHandler._isSecureInternalUI) {
      button.parentNode.hidden = true;
      return;
    }

    let identity;
    if (gIdentityHandler._pageExtensionPolicy) {
      this.document.l10n.setAttributes(
        button,
        "zen-site-data-security-info-extension"
      );
      identity = "extension";
    } else if (
      gIdentityHandler._uriHasHost &&
      gIdentityHandler._isSecureConnection &&
      !gIdentityHandler._isCertUserOverridden &&
      !gIdentityHandler._isCertErrorPage &&
      !gIdentityHandler._isAboutHttpsOnlyErrorPage
    ) {
      this.document.l10n.setAttributes(
        button,
        "zen-site-data-security-info-secure"
      );
      identity = "secure";
    } else {
      this.document.l10n.setAttributes(
        button,
        "zen-site-data-security-info-not-secure"
      );
      identity = "not-secure";
    }

    button.parentNode.hidden = false;
    button.setAttribute("identity", identity);
  }

  #setSitePermissions() {
    const { gBrowser, SitePermissions } = this.window;
    const list = this.document.getElementById("zen-site-data-settings-list");
    const section = list.closest(".zen-site-data-section");

    // show permission icons
    let permissions = SitePermissions.getAllPermissionDetailsForBrowser(
      gBrowser.selectedBrowser
    );

    // Don't display origin-keyed 3rdPartyStorage permissions that are covered by
    // site-keyed 3rdPartyFrameStorage permissions.
    let thirdPartyStorageSites = new Set(
      permissions
        .map(function (permission) {
          let [id, key] = permission.id.split(
            SitePermissions.PERM_KEY_DELIMITER
          );
          if (id == "3rdPartyFrameStorage" || id == "3rdPartyStorage") {
            return key;
          }
          return null;
        })
        .filter(function (key) {
          return key != null;
        })
    );
    permissions = permissions.filter(function (permission) {
      let [id, key] = permission.id.split(SitePermissions.PERM_KEY_DELIMITER);
      if (id != "3rdPartyStorage") {
        return true;
      }
      try {
        let origin = Services.io.newURI(key);
        let site = Services.eTLD.getSite(origin);
        return !thirdPartyStorageSites.has(site);
      } catch {
        return false;
      }
    });

    this._sharingState = gBrowser.selectedTab._sharingState;

    if (this._sharingState?.geo) {
      let geoPermission = permissions.find(perm => perm.id === "geo");
      if (!geoPermission) {
        permissions.push({
          id: "geo",
          state: SitePermissions.ALLOW,
          scope: SitePermissions.SCOPE_REQUEST,
          sharingState: true,
        });
      }
    }

    if (this._sharingState?.xr) {
      let xrPermission = permissions.find(perm => perm.id === "xr");
      if (!xrPermission) {
        permissions.push({
          id: "xr",
          state: SitePermissions.ALLOW,
          scope: SitePermissions.SCOPE_REQUEST,
          sharingState: true,
        });
      }
    }

    if (this._sharingState?.webRTC) {
      let webrtcState = this._sharingState.webRTC;
      // If WebRTC device or screen are in use, we need to find
      // the associated ALLOW permission item to set the sharingState field.
      for (let id of ["camera", "microphone", "screen"]) {
        if (webrtcState[id]) {
          let found = false;
          for (let permission of permissions) {
            let [permId] = permission.id.split(
              SitePermissions.PERM_KEY_DELIMITER
            );
            if (permId != id || permission.state != SitePermissions.ALLOW) {
              continue;
            }
            found = true;
          }
          if (!found) {
            // If the ALLOW permission item we were looking for doesn't exist,
            // the user has temporarily allowed sharing and we need to add
            // an item in the permissions array to reflect this.
            permissions.push({
              id,
              state: SitePermissions.ALLOW,
              scope: SitePermissions.SCOPE_REQUEST,
              sharingState: webrtcState[id],
            });
          }
        }
      }
    }

    // Add site protection permissions if needed.
    const { gProtectionsHandler } = this.window;
    if (
      gBrowser.currentURI.schemeIs("http") ||
      gBrowser.currentURI.schemeIs("https") ||
      gBrowser.currentURI.schemeIs("ftp")
    ) {
      permissions.push({
        id: "site-protection",
        state: gProtectionsHandler.hasException
          ? SitePermissions.BLOCK
          : SitePermissions.ALLOW,
        scope: SitePermissions.SCOPE_PERSISTENT,
      });
    }

    for (let permission of permissions) {
      let [id] = permission.id.split(SitePermissions.PERM_KEY_DELIMITER);

      if (id == "storage-access" || id == "3rdPartyStorage") {
        // Storage access and cross-site cookie permissions are per embedding
        // site and belong to the Content Blocking UI, not to this list.
        continue;
      }

      if (permission.state == SitePermissions.PROMPT) {
        // We don't display "ask" permissions in the site data panel.
        continue;
      }

      list.appendChild(this.#createPermissionItem(id, permission));
    }

    section.hidden = !list.childElementCount;
  }

  #getPermissionStateLabelId(permission) {
    const { SitePermissions } = this.window;
    switch (permission.state) {
      // There should only be these types being displayed in the panel.
      case SitePermissions.ALLOW:
        if (permission.id === "site-protection") {
          return "zen-site-data-protections-enabled";
        }
        return "zen-site-data-setting-allow";
      case SitePermissions.BLOCK:
      case SitePermissions.AUTOPLAY_BLOCKED_ALL:
        if (permission.id === "site-protection") {
          return "zen-site-data-protections-disabled";
        }
        return "zen-site-data-setting-block";
      default:
        return null;
    }
  }

  #createPermissionItem(id, permission) {
    const { SitePermissions } = this.window;

    // Create a permission item for the site data panel.
    let container = this.document.createXULElement("hbox");
    const idNoSuffix = permission.id;
    container.classList.add(
      "permission-popup-permission-item",
      `permission-popup-permission-item-${idNoSuffix}`
    );
    container.setAttribute("align", "center");
    container.setAttribute("role", "group");

    container.setAttribute(
      "state",
      permission.state == SitePermissions.ALLOW ? "allow" : "block"
    );

    let img = this.document.createXULElement("toolbarbutton");
    img.classList.add(
      "permission-popup-permission-icon",
      "zen-site-data-permission-icon"
    );
    img.setAttribute("closemenu", "none");
    if (this.#iconMap[id]) {
      img.classList.add(`zen-permission-${this.#iconMap[id]}-icon`);
    }

    let labelContainer = this.document.createXULElement("vbox");
    labelContainer.setAttribute("flex", "1");
    labelContainer.setAttribute("align", "start");
    labelContainer.classList.add("permission-popup-permission-label-container");
    labelContainer._permission = permission;

    let nameLabel = this.document.createXULElement("label");
    nameLabel.setAttribute("flex", "1");
    nameLabel.setAttribute("class", "permission-popup-permission-label");
    let label = SitePermissions.getPermissionLabel(permission.id);
    if (label) {
      nameLabel.textContent = label;
    } else {
      this.document.l10n.setAttributes(
        nameLabel,
        "zen-site-data-setting-" + idNoSuffix
      );
    }
    labelContainer.appendChild(nameLabel);

    let stateLabel = this.document.createXULElement("label");
    stateLabel.setAttribute(
      "class",
      "zen-permission-popup-permission-state-label"
    );
    stateLabel.setAttribute(
      "data-l10n-id",
      this.#getPermissionStateLabelId(permission)
    );
    labelContainer.appendChild(stateLabel);

    container.appendChild(img);
    container.appendChild(labelContainer);

    container.addEventListener("click", this);
    return container;
  }

  #openGetAddons() {
    const { switchToTabHavingURI } = this.window;
    let amoUrl = Services.urlFormatter.formatURLPref(
      "extensions.getAddons.link.url"
    );
    switchToTabHavingURI(amoUrl, true);
  }

  #onCommandEvent(event) {
    if (this._justClosedFolder) {
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    const target =
      event.target.closest?.("#zen-site-data-new-addon-button, [id]") ||
      event.target;
    const id = target.id;
    switch (id) {
      case "zen-site-data-new-addon-button": {
        if (this.#isFolderOpen()) {
          event.preventDefault();
          event.stopPropagation();
          this.#toggleDisabledFolder(false);
        } else {
          this.#openGetAddons();
        }
        break;
      }
      case "zen-site-data-security-info": {
        this.window.gIdentityHandler._openPopup(event);
        break;
      }
      case "zen-site-data-header-boost": {
        const domain = this.#getCurrentDomain();
        const uri = this.window.gBrowser.currentURI;
        const boost = lazy.gZenBoostsManager.createNewBoost(domain);
        lazy.gZenBoostsManager.openBoostWindow(this.window, boost, uri);
        break;
      }
      case "zen-site-data-actions": {
        const button = this.document.getElementById("zen-site-data-actions");
        const popup = this.document.getElementById("zenSiteDataActions");
        popup.openPopup(
          button,
          "after_start",
          0,
          0,
          /* context menu */ true,
          false,
          this.window.event
        );
        break;
      }
      case "zen-site-data-header-bookmark": {
        this.window.BookmarkingUI.onStarCommand(event);
        break;
      }
      case "zen-site-data-header-share": {
        /* eslint-disable mozilla/valid-services */
        if (Services.zen.canShare()) {
          const buttonRect = event.target.getBoundingClientRect();
          const currentUrl = this.window.gBrowser.currentURI;
          /* eslint-disable mozilla/valid-services */
          Services.zen.share(
            currentUrl,
            "",
            "",
            buttonRect.left,
            this.window.innerHeight - buttonRect.bottom,
            buttonRect.width,
            buttonRect.height
          );
        } else {
          this.window.gZenCommonActions.copyCurrentURLToClipboard();
        }
        if (AppConstants.platform !== "macosx") {
          this.unifiedPanel.hidePopup();
        }
      }
    }
  }

  #onPermissionClick(label) {
    const { SitePermissions, gBrowser } = this.window;
    const permission = label._permission;

    let newState;
    switch (permission.state) {
      case SitePermissions.ALLOW:
        newState = SitePermissions.BLOCK;
        break;
      case SitePermissions.BLOCK:
      case SitePermissions.AUTOPLAY_BLOCKED_ALL:
        newState = SitePermissions.ALLOW;
        break;
      default:
        return;
    }

    if (permission.id === "site-protection") {
      const { gProtectionsHandler } = this.window;
      if (newState === SitePermissions.BLOCK) {
        gProtectionsHandler.disableForCurrentPage();
      } else {
        gProtectionsHandler.enableForCurrentPage();
      }
    } else {
      SitePermissions.setForPrincipal(
        gBrowser.contentPrincipal,
        permission.id,
        newState
      );
    }

    const isCrossSiteCookie = permission.id.startsWith("3rdPartyStorage");
    label.parentNode.setAttribute(
      "state",
      newState == SitePermissions.ALLOW ? "allow" : "block"
    );
    label._permission.state = newState;
    if (!isCrossSiteCookie) {
      label
        .querySelector(".zen-permission-popup-permission-state-label")
        .setAttribute(
          "data-l10n-id",
          this.#getPermissionStateLabelId(label._permission)
        );
    }
  }

  #onBoostClick(event) {
    const target = event.target.closest("[data-action-id]");
    if (!target) {
      return;
    }

    const actionId = target.getAttribute("data-action-id");
    const domain = this.#getCurrentDomain();

    switch (actionId) {
      case "zen-site-data-toggle-boost": {
        const boostId = target.getAttribute("data-boost-id");

        lazy.gZenBoostsManager.toggleBoostActiveForDomain(domain, boostId);
        this.#updateSiteBoost();
        break;
      }
      case "zen-site-data-edit-boost": {
        const boostId = target.getAttribute("data-boost-id");
        const uri = this.window.gBrowser.currentURI;
        const boost = lazy.gZenBoostsManager.loadBoostFromStore(
          domain,
          boostId
        );
        lazy.gZenBoostsManager.openBoostWindow(this.window, boost, uri);
        this.unifiedPanel.hidePopup();
        break;
      }
    }
  }

  #onClickEvent(event) {
    const id = event.target.id;
    switch (id) {
      case "zen-site-data-manage-addons": {
        const { BrowserAddonUI } = this.window;
        BrowserAddonUI.openAddonsMgr("addons://list/extension");
        this.unifiedPanel.hidePopup();
        break;
      }
      case "zen-site-data-settings-more": {
        const { BrowserCommands } = this.window;
        BrowserCommands.pageInfo(null, "permTab");
        break;
      }
      case "zen-site-data-icon-button": {
        this.window.gUnifiedExtensions.togglePanel(
          event,
          null,
          this.unifiedPanel,
          this.unifiedPanelView,
          this.anchor
        );
        break;
      }
      default: {
        const item = event.target.closest(".permission-popup-permission-item");
        if (!item) {
          break;
        }
        const label = item.querySelector(
          ".permission-popup-permission-label-container"
        );
        if (label?._permission) {
          this.#onPermissionClick(label);
        }
        break;
      }
    }
  }

  handleEvent(event) {
    const type = event.type;
    switch (type) {
      case "click":
        this.#onClickEvent(event);
        break;
      case "command":
        this.#onCommandEvent(event);
        break;
      case "popupshowing":
        this.#preparePanel();
        break;
    }
  }

  async #maybeShowFeatureCallout() {
    const kPref = "zen.site-data-panel.show-callout";
    if (!Services.prefs.getBoolPref(kPref, false)) {
      return;
    }
    Services.prefs.setBoolPref(kPref, false);
    const { gBrowser, gZenWorkspaces } = this.window;
    await gZenWorkspaces.promiseInitialized;
    await new Promise(resolve => {
      const checkEmptyTab = () => {
        if (!gBrowser.selectedTab.hasAttribute("zen-empty-tab")) {
          resolve();
          return;
        }
        this.window.addEventListener("TabSelect", checkEmptyTab, {
          once: true,
        });
      };
      checkEmptyTab();
    });
    const callout = new lazy.FeatureCallout({
      win: this.window,
      location: "chrome",
      context: "chrome",
      browser: gBrowser.selectedBrowser,
      theme: { preset: "chrome" },
    });
    this.window.setTimeout(() => {
      callout.showFeatureCallout({
        id: "ZEN_EXTENSIONS_PANEL_MOVE_CALLOUT",
        template: "feature_callout",
        groups: ["cfr"],
        content: {
          id: "ZEN_EXTENSIONS_PANEL_MOVE_CALLOUT",
          template: "multistage",
          backdrop: "transparent",
          transitions: true,
          screens: [
            {
              id: "ZEN_EXTENSIONS_PANEL_MOVE_CALLOUT",
              anchors: [
                {
                  selector: "#zen-site-data-icon-button",
                  panel_position: {
                    anchor_attachment: "bottomcenter",
                    callout_attachment: "topleft",
                  },
                },
              ],
              content: {
                position: "callout",
                width: "355px",
                title: {
                  string_id: "zen-site-data-panel-feature-callout-title",
                },
                subtitle: {
                  string_id: "zen-site-data-panel-feature-callout-subtitle",
                },
                dismiss_button: {
                  action: {
                    dismiss: true,
                  },
                  background: true,
                  size: "small",
                },
              },
            },
          ],
        },
      });
    }, 1000);
  }

  // --- Workspace Disabled Extensions UI Methods ---

  #initSpaceDisabledExtensions() {
    this.#ensureDisabledExtensionsDOMElements();
    this._unsubscribeExtensions = ZenSpaceExtensionsManager.addChangeListener(
      () => {
        this.#updateSpaceDisabledExtensions();
      }
    );
  }

  #disableExtensionInActiveSpace(extId) {
    const spaceId = this.window.gZenWorkspaces?.activeWorkspace;
    if (spaceId && extId) {
      ZenSpaceExtensionsManager.disable(spaceId, extId);
    }
  }

  #enableExtensionInActiveSpace(extId) {
    const spaceId = this.window.gZenWorkspaces?.activeWorkspace;
    if (!spaceId || !extId) {
      return;
    }
    ZenSpaceExtensionsManager.enable(spaceId, extId);
    if (ZenSpaceExtensionsManager.getDisabled(spaceId).length === 0) {
      this.#toggleDisabledFolder(false);
    }
  }

  #isFolderOpen() {
    const section = this.document.getElementById("zen-site-data-section-addons");
    return section?.getAttribute("disabled-folder") === "true";
  }

  #toggleDisabledFolder(open) {
    const section = this.document.getElementById("zen-site-data-section-addons");
    if (!section) {
      return;
    }

    const spaceId = this.window.gZenWorkspaces?.activeWorkspace;
    const disabledList = ZenSpaceExtensionsManager.getDisabled(spaceId);

    const titleNormal = this.document.getElementById(
      "zen-site-data-addons-title-normal"
    );
    const titleDisabled = this.document.getElementById(
      "zen-site-data-addons-title-disabled"
    );
    const newAddonBtn = this.document.getElementById(
      "zen-site-data-new-addon-button"
    );

    if (open) {
      if (disabledList.length === 0) {
        return;
      }
      section.setAttribute("disabled-folder", "true");
      if (titleNormal) {
        titleNormal.hidden = true;
      }
      if (titleDisabled) {
        titleDisabled.hidden = false;
      }
      if (newAddonBtn) {
        newAddonBtn.setAttribute("closemenu", "none");
        if (!newAddonBtn._origTooltip) {
          newAddonBtn._origTooltip =
            newAddonBtn.getAttribute("tooltiptext") || "";
        }
        newAddonBtn.setAttribute("tooltiptext", "Close disabled group");
      }
      this.#updateDisabledHeaderSpaceIcon();
    } else {
      section.removeAttribute("disabled-folder");
      if (titleNormal) {
        titleNormal.hidden = false;
      }
      if (titleDisabled) {
        titleDisabled.hidden = true;
      }
      if (newAddonBtn) {
        newAddonBtn.setAttribute("closemenu", "none");
        if (newAddonBtn._origTooltip !== undefined) {
          newAddonBtn.setAttribute("tooltiptext", newAddonBtn._origTooltip);
        }
      }
    }
    this.#updateSpaceDisabledExtensions();
  }

  #updateDisabledHeaderSpaceIcon() {
    const space = this.window.gZenWorkspaces?.getActiveWorkspace?.();
    const iconImg = this.document.getElementById(
      "zen-site-data-disabled-space-icon-img"
    );
    const iconText = this.document.getElementById(
      "zen-site-data-disabled-space-icon-text"
    );
    if (!iconImg || !iconText) {
      return;
    }

    const icon = this.window.gZenWorkspaces?.getWorkspaceIcon?.(space);
    if (icon) {
      if (
        icon.endsWith(".svg") ||
        icon.startsWith("chrome:") ||
        icon.startsWith("resource:") ||
        icon.startsWith("http")
      ) {
        iconImg.src = icon;
        iconImg.hidden = false;
        iconText.hidden = true;
      } else {
        iconText.textContent = icon;
        iconText.hidden = false;
        iconImg.hidden = true;
      }
    } else {
      iconImg.hidden = true;
      iconText.textContent = "●";
      iconText.hidden = false;
    }
  }

  #ensureDisabledExtensionsDOMElements() {
    // 1. Header elements
    const section = this.document.getElementById("zen-site-data-section-addons");
    if (section) {
      let headerTitleBox = this.document.getElementById(
        "zen-site-data-addons-header-title-box"
      );
      if (!headerTitleBox) {
        const header = section.querySelector(".zen-site-data-section-header");
        if (header) {
          let titleNormal = header.querySelector(
            '[data-l10n-id="unified-extensions-header-title"]'
          );
          if (titleNormal) {
            titleNormal.id = "zen-site-data-addons-title-normal";
          }
          const titleFrag = this.window.MozXULElement.parseXULToFragment(`
            <hbox id="zen-site-data-addons-header-title-box" flex="1" align="center">
              <hbox id="zen-site-data-addons-title-disabled" align="center" hidden="true">
                <box id="zen-site-data-disabled-space-icon-wrapper" class="zen-site-data-space-icon-wrapper">
                  <image id="zen-site-data-disabled-space-icon-img" class="zen-site-data-space-icon" hidden="true" />
                  <label id="zen-site-data-disabled-space-icon-text" class="zen-site-data-space-icon-text" hidden="true" />
                </box>
                <label id="zen-site-data-disabled-title-label" value="Disabled" />
              </hbox>
            </hbox>
          `);
          const box = titleFrag.querySelector(
            "#zen-site-data-addons-header-title-box"
          );
          if (titleNormal) {
            header.insertBefore(box, titleNormal);
            box.insertBefore(titleNormal, box.firstChild);
          } else {
            header.insertBefore(box, header.firstChild);
          }
        }
      }
    }

    // 2. Stack container in grid
    let stackContainer = this.document.getElementById(
      "zen-site-data-disabled-stack-container"
    );
    if (!stackContainer) {
      const stackFrag = this.window.MozXULElement.parseXULToFragment(`
        <vbox id="zen-site-data-disabled-stack-container" hidden="true">
          <toolbarbutton id="zen-site-data-disabled-stack-button"
                         class="subviewbutton toolbarbutton-1"
                         tooltiptext="Disabled Extensions"
                         closemenu="none"
                         hidden="true">
            <box class="zen-disabled-stack-wrapper">
              <box class="zen-disabled-stack-card zen-disabled-stack-card-left" hidden="true">
                <image class="zen-disabled-stack-icon" />
              </box>
              <box class="zen-disabled-stack-card zen-disabled-stack-card-right" hidden="true">
                <image class="zen-disabled-stack-icon" />
              </box>
              <box class="zen-disabled-stack-card zen-disabled-stack-card-center" hidden="true">
                <image class="zen-disabled-stack-icon" />
              </box>
            </box>
          </toolbarbutton>
        </vbox>
      `);
      const newAddonBtnContainer = this.document.getElementById(
        "zen-site-data-new-addon-button-container"
      );
      if (newAddonBtnContainer) {
        newAddonBtnContainer.before(stackFrag);
      } else {
        this.document.getElementById("zen-site-data-addons")?.appendChild(stackFrag);
      }
    }

    const stackBtn = this.document.getElementById(
      "zen-site-data-disabled-stack-button"
    );
    if (stackBtn && !stackBtn._zenClickHandlerAttached) {
      stackBtn._zenClickHandlerAttached = true;
      const handleStackActivate = e => {
        e.preventDefault();
        e.stopPropagation();
        this.#toggleDisabledFolder(true);
      };
      stackBtn.addEventListener("click", handleStackActivate);
      stackBtn.addEventListener("command", handleStackActivate);
    }

    const newAddonBtn = this.document.getElementById(
      "zen-site-data-new-addon-button"
    );
    if (newAddonBtn) {
      newAddonBtn.setAttribute("closemenu", "none");
      if (!newAddonBtn._zenFolderCloseAttached) {
        newAddonBtn._zenFolderCloseAttached = true;
        const handleFolderClose = e => {
          if (this.#isFolderOpen()) {
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();
            this._justClosedFolder = true;
            this.#toggleDisabledFolder(false);
            this.window.setTimeout(() => {
              this._justClosedFolder = false;
            }, 300);
            return;
          }
          if (this._justClosedFolder) {
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();
          }
        };
        newAddonBtn.addEventListener("click", handleFolderClose, true);
        newAddonBtn.addEventListener("command", handleFolderClose, true);
      }
    }

    // Quick-toggle to re-enable when clicking any disabled extension tile in folder
    const addonsContainer = this.document.getElementById("zen-site-data-addons");
    if (addonsContainer && !addonsContainer._zenQuickToggleAttached) {
      addonsContainer._zenQuickToggleAttached = true;
      const handleFolderItemAction = e => {
        if (!this.#isFolderOpen()) {
          return;
        }
        const target = e.target;
        const newAddonBtn = this.document.getElementById("zen-site-data-new-addon-button");
        if (target === newAddonBtn || newAddonBtn?.contains(target)) {
          return; // Allow the red close button to close the folder
        }
        const item = target.closest(
          "unified-extensions-item, .unified-extensions-item, toolbaritem, toolbarbutton"
        );
        if (!item || item.id === "zen-site-data-disabled-stack-button" || item.closest("#zen-site-data-disabled-stack-container")) {
          return;
        }

        const extId = this.#getItemExtensionId(item);
        if (extId) {
          e.preventDefault();
          e.stopPropagation();
          e.stopImmediatePropagation();
          this.#enableExtensionInActiveSpace(extId);
        }
      };

      addonsContainer.addEventListener("click", handleFolderItemAction, true);
      addonsContainer.addEventListener("command", handleFolderItemAction, true);
    }

    // 3. Context Menu Items (only "Disable on this Space" in active grid)
    const menu = this.document.getElementById("unified-extensions-context-menu");
    const existingEnable = this.document.getElementById("zen-context-enable-in-space");
    if (existingEnable) {
      existingEnable.remove();
    }
    if (menu && !this.document.getElementById("zen-context-disable-in-space")) {
      const menuFrag = this.window.MozXULElement.parseXULToFragment(`
        <menuitem id="zen-context-disable-in-space"
                  label="Disable on this Space"
                  class="zen-context-disable-in-space"
                  hidden="true" />
      `);
      const pinItem = menu.querySelector(
        ".unified-extensions-context-menu-pin-to-toolbar"
      );
      if (pinItem) {
        pinItem.after(menuFrag);
      } else {
        menu.prepend(menuFrag);
      }

      this.document
        .getElementById("zen-context-disable-in-space")
        ?.addEventListener("command", e => {
          e.stopPropagation();
          if (menu._zenCurrentExtensionId) {
            this.#disableExtensionInActiveSpace(menu._zenCurrentExtensionId);
          }
        });
    }
  }

  #getItemExtensionId(item) {
    if (!item) {
      return null;
    }
    if (item.extension?.id) {
      return item.extension.id;
    }
    let id =
      item.dataset?.extensionid ||
      item.getAttribute?.("data-extensionid") ||
      item.querySelector?.("[data-extensionid]")?.dataset?.extensionid ||
      item.querySelector?.("[data-extensionid]")?.getAttribute("data-extensionid");
    if (!id && item.id) {
      const policy = globalThis.WebExtensionPolicy?.getByWidgetId?.(item.id);
      if (policy) {
        id = policy.id;
      }
    }
    if (!id && item.id && item.id.endsWith("-browser-action")) {
      id = item.id.slice(0, -"-browser-action".length);
    }
    return id;
  }

  #getExtensionIcon(item, extId) {
    if (item) {
      const img =
        item.querySelector(".unified-extensions-item-icon") ||
        item.querySelector(".toolbarbutton-icon") ||
        item.querySelector("image");
      if (img) {
        const src = img.getAttribute("src") || img.src;
        if (src) {
          return src;
        }
      }
      const btn = item.querySelector("toolbarbutton") || item;
      const btnImg = btn.getAttribute?.("image");
      if (btnImg) {
        return btnImg;
      }
      if (img) {
        const computed = this.window.getComputedStyle(img).listStyleImage;
        if (computed && computed !== "none") {
          const match = computed.match(/url\(["']?([^"']+)["']?\)/);
          if (match) {
            return match[1];
          }
        }
      }
    }

    if (extId) {
      const policy = globalThis.WebExtensionPolicy?.getByID?.(extId);
      if (policy?.extension?.iconURL) {
        return policy.extension.iconURL;
      }
      const icons = policy?.extension?.manifest?.icons;
      if (icons) {
        const best =
          icons["64"] ||
          icons["48"] ||
          icons["32"] ||
          icons["16"] ||
          Object.values(icons)[0];
        if (best) {
          return policy.extension.baseURI?.resolve(best) || best;
        }
      }
    }

    return ZenDisabledStackRenderer.PLACEHOLDER_ICON;
  }

  #onUnifiedContextMenuShowing(menu) {
    const pinItem = menu.querySelector(
      ".unified-extensions-context-menu-pin-to-toolbar"
    );
    const existingEnable = this.document.getElementById("zen-context-enable-in-space");
    if (existingEnable) {
      existingEnable.remove();
    }
    const disableItem = this.document.getElementById("zen-context-disable-in-space");
    if (!disableItem) {
      return;
    }

    let extId = this.window.gUnifiedExtensions?._getExtensionId?.(menu);
    if (!extId) {
      const trigger = menu.triggerNode?.closest?.("[data-extensionid]");
      extId =
        trigger?.dataset?.extensionid || trigger?.getAttribute("data-extensionid");
    }
    if (!extId) {
      const widget = menu.triggerNode?.closest?.(
        "toolbaritem, toolbarbutton, unified-extensions-item, .unified-extensions-item"
      );
      extId = this.#getItemExtensionId(widget);
    }
    menu._zenCurrentExtensionId = extId;

    const isFolder = this.#isFolderOpen();
    const inSiteDataGrid = Boolean(
      menu.triggerNode?.closest("#zen-site-data-addons")
    );

    if (isFolder) {
      if (pinItem) {
        pinItem.hidden = true;
      }
      disableItem.hidden = true;
    } else {
      disableItem.hidden = !inSiteDataGrid || !extId;
    }
  }

  #updateSpaceDisabledExtensions() {
    this.#ensureDisabledExtensionsDOMElements();

    const spaceId = this.window.gZenWorkspaces?.activeWorkspace;
    const disabledList = ZenSpaceExtensionsManager.getDisabled(spaceId);

    const addonsContainer = this.document.getElementById("zen-site-data-addons");
    const stackContainer = this.document.getElementById(
      "zen-site-data-disabled-stack-container"
    );
    const stackBtn = this.document.getElementById(
      "zen-site-data-disabled-stack-button"
    );
    const section = this.document.getElementById("zen-site-data-section-addons");
    const isFolder = section?.getAttribute("disabled-folder") === "true";

    // When no extensions are disabled on this space:
    if (disabledList.length === 0) {
      if (stackContainer) {
        stackContainer.hidden = true;
        stackContainer.style.display = "none";
      }
      if (stackBtn) {
        stackBtn.hidden = true;
        stackBtn.style.display = "none";
      }
      if (isFolder) {
        this.#toggleDisabledFolder(false);
      }
      if (addonsContainer) {
        const items = addonsContainer.querySelectorAll(
          "#unified-extensions-area > *, #overflowed-extensions-list > *, .unified-extensions-list > *"
        );
        for (const item of items) {
          item.setAttribute("data-zen-space-disabled", "false");
          item.hidden = false;
          item.style.display = "";
        }
      }
      this.#setAddonsOverflow();
      return;
    }

    // Extensions are disabled on this space:
    if (addonsContainer) {
      const items = addonsContainer.querySelectorAll(
        "#unified-extensions-area > *, #overflowed-extensions-list > *, .unified-extensions-list > *"
      );

      const disabledIcons = [];

      for (const item of items) {
        item.removeAttribute("data-zen-space-hidden");
        const actionBtn = item.querySelector?.(".unified-extensions-item-action-button");
        if (actionBtn) {
          actionBtn.removeAttribute("data-zen-space-hidden");
        }

        const extId = this.#getItemExtensionId(item);
        const isDisabled = Boolean(extId && disabledList.includes(extId));
        item.setAttribute("data-zen-space-disabled", isDisabled ? "true" : "false");

        const shouldHide = isFolder ? !isDisabled : isDisabled;
        item.hidden = shouldHide;
        item.style.display = shouldHide ? "none" : "";

        if (isFolder && isDisabled) {
          item.setAttribute("tooltiptext", "Click to enable in this Space");
          const actionBtn = item.querySelector?.(".unified-extensions-item-action-button");
          if (actionBtn) {
            actionBtn.setAttribute("tooltiptext", "Click to enable in this Space");
          }
        } else {
          item.removeAttribute("tooltiptext");
        }

        if (isDisabled) {
          const iconUrl = this.#getExtensionIcon(item, extId);
          if (iconUrl) {
            disabledIcons.push(iconUrl);
          }
        }
      }

      // Add icons for any disabled extensions not present in the DOM
      for (const extId of disabledList) {
        if (disabledIcons.length < 3 && disabledIcons.length < disabledList.length) {
          const fallback = this.#getExtensionIcon(null, extId);
          if (fallback && !disabledIcons.includes(fallback)) {
            disabledIcons.push(fallback);
          }
        }
      }

      if (stackContainer && stackBtn) {
        stackContainer.hidden = isFolder;
        stackBtn.hidden = isFolder;
        stackContainer.style.display = isFolder ? "none" : "";
        stackBtn.style.display = isFolder ? "none" : "";

        if (!isFolder) {
          ZenDisabledStackRenderer.render(
            stackBtn,
            disabledIcons,
            disabledList.length
          );
        }
      }
    }

    if (isFolder) {
      this.#updateDisabledHeaderSpaceIcon();
    }

    this.#setAddonsOverflow();
  }
}

