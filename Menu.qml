import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "MenuModel.js" as MenuModel

Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // Plugin lifecycle hooks. The host calls open(payloadJson) after
  // `omarchy-shell shell summon omarchy.menu ...` and close() when hidden.
  property string pendingInitialMenu: "root"

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    if (payload.fontFamily) root.fontFamily = payload.fontFamily
    // A shell that started mid-update may never have read the shipped menu
    // whole; reading it again here keeps the menu from opening empty.
    if (root.defaultMenuItems.length === 0) defaultMenuFile.reload()

    if (payload.mode === "select" || payload.mode === "input") {
      root.openDmenu(payload)
    } else {
      root.openRoute(payload.initialMenu || payload.menu || "root")
    }
  }

  function close() {
    root.cancel()
  }

  function refresh() {
    defaultMenuFile.reload()
    userMenuFile.reload()
    languageFile.reload()
    menuCatalogFile.reload()
    return "ok"
  }

  function ping() { return "ok" }

  property string fontFamily: Style.font.menuFamily
  // JSONC menu definitions. The shell parses both at startup and merges
  // the user file on top of the defaults, so the keybind → IPC → visible
  // path doesn't have to shell out to bash + jq on every open.
  property string defaultMenuPath: omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
  property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
  // Display language for the shipped rows. The code lives in
  // ~/.config/omarchy/language (omarchy-language owns it); a missing file
  // means English. The catalog at default/i18n/<code>/menu.json is applied
  // to the default items before the user extension merges on top, so a
  // user's own rows and retitles always win.
  property string language: "en"
  property var menuCatalog: ({})
  readonly property string languagePath: Quickshell.env("OMARCHY_LANGUAGE_FILE") || ((Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy/language")
  property var defaultMenuItems: []
  property var userMenuItems: []
  // Whether each file has answered once, loaded or (the user's) missing. At
  // startup both arrive separately, and evaluating guards for the first alone
  // would run the whole batch twice; an open before then evaluates anyway.
  property bool defaultMenuSettled: false
  property bool userMenuSettled: false
  property bool opened: false
  property string mode: "menu"
  readonly property bool dmenuActive: mode === "select" || mode === "input"
  property string dmenuPrompt: ""
  property var dmenuOptions: []
  property bool dmenuMultiple: false
  property var dmenuSelected: []
  // What the last confirmed change applied; a failed change returns the checks here.
  property var dmenuSaved: []
  property string dmenuChangeKey: ""
  property var dmenuOnChange: []
  property string selectionFile: ""
  property string doneFile: ""
  property int dmenuWidth: 300
  property int dmenuMaxHeight: 0
  property bool requestActive: false
  property bool rowsLoaded: false
  property string activeMenu: "root"
  property string filterText: ""
  // Resets of filterText reach the search line; its edits come back through setFilter.
  onFilterTextChanged: if (filterInput.text !== filterText) filterInput.text = filterText
  property int selectedIndex: 0
  property bool cursorActive: false
  property int requestSerial: 0
  property int applySerial: 0
  property var items: ({})
  property var itemOrder: []
  property var navStack: []
  property var providersLoaded: ({})
  property var providerQueue: []
  property int providerRevision: 0

  // Shared application engine (entries, hidden filters, icons, launch,
  // removal), owned by the shell and also used by the standalone launcher.
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null
  property bool deleteConfirmOpen: false
  property var deleteTarget: null
  onOpenedChanged: if (!opened) { deleteConfirmOpen = false; deleteTarget = null }
  // Frosted glass styling: translucent dark glass with hardware blur
  property color background: Util.alpha(Commons.Color.menu.background, 0.62)
  property color foreground: Commons.Color.menu.text
  property color border: Util.alpha(Commons.Color.accent, 0.45)
  property var borderSpec: Border.surfaceSpec("menu", "border", border, 2)
  property color scrim: Util.alpha(Commons.Color.menu.scrim, 0.30)
  property color selectedBackground: Util.alpha(Commons.Color.accent, 0.18)
  property color selectedText: Commons.Color.menu.selectedText
  property color selectedBorder: Util.alpha(Commons.Color.accent, 0.60)
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 1)
  readonly property real rowReservedBorderLeft: Border.left(selectedBorderSpec)
  readonly property real rowReservedBorderRight: Border.right(selectedBorderSpec)
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int baseRowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int detailRowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  // How much of the first hidden row stays visible at the fold — enough to
  // read as a cut-off row rather than a bottom border.
  property int rowPeek: Math.round(baseRowHeight * 0.55)
  property int rowSpacing: Style.spacing.xs
  property int dividerHeight: Style.space(17)
  property bool searchDivider: false
  property int layoutSerial: 0
  property int cardWidth: Math.min(root.dmenuActive ? Style.space(root.dmenuWidth) : ((root.activeMenu === "trigger.capture.screenrecord" || root.activeMenu === "appearance.font" || root.activeMenu === "update.kernel") ? Style.space(520) : Style.space(300)), panel.width - Style.gapsOut * 2)
  property int visibleRowsHeight: root.dmenuActive ? dmenuRowListHeight(layoutSerial, displayModel.count, filterText) : rowListHeight(layoutSerial, displayModel.count, filterText, searchDivider)
  property int cardHeight: root.dmenuActive
    ? Math.min(contentMargin * 2 + headerHeight + (mode === "input" ? 0 : contentSpacing + visibleRowsHeight), panel.height - Style.gapsOut * 2)
    : Math.min(contentMargin * 2 + headerHeight + contentSpacing + visibleRowsHeight, panel.height - Style.gapsOut * 2)

  function finishRequest(selection) {
    if (!root.requestActive || !root.doneFile) {
      root.opened = false
      return
    }

    var activeSelectionFile = root.selectionFile
    var activeDoneFile = root.doneFile
    root.requestActive = false
    root.selectionFile = ""
    root.doneFile = ""

    if (selection === null || selection === undefined) {
      resultProc.command = ["bash", "-c", ": > " + Util.shellQuote(activeDoneFile)]
    } else {
      resultProc.command = ["bash", "-c", "printf '%s\\n' " + Util.shellQuote(selection) + " > " + Util.shellQuote(activeSelectionFile) + "; : > " + Util.shellQuote(activeDoneFile)]
    }
    resultProc.running = true
  }

  function runAction(action) {
    var command = String(action || "")
    if (!command) return

    var summon = MenuModel.summonAction(command)
    if (summon && root.shell && root.shell.summon(summon.id, summon.payload)) return

    Util.execDetached(command)
  }

  // Menu rows only surface their detail while a search is narrowing them;
  // dmenu rows carry caller-supplied subtext that must always be visible.
  function rowHeightForDetail(detail) {
    return (root.filterText || root.dmenuActive) && detail ? root.detailRowHeight : root.baseRowHeight
  }

  // Height the card can devote to rows before running off the screen — or
  // past the frozen top edge once a search has pinned the card in place.
  // Uses panel.cardTop rather than effectiveCardTop: the centered top is
  // derived from the card height, which this value feeds.
  function availableRowsHeight() {
    var top = panel.cardTop >= 0 ? panel.cardTop : Style.gapsOut
    var available = panel.height - top - Style.gapsOut - root.contentMargin * 2 - root.headerHeight - root.contentSpacing
    // The starting menu sets the ceiling along with the offset: drilling into
    // a longer submenu scrolls behind the fold instead of growing the card.
    if (panel.maxRowsHeight >= 0) available = Math.min(available, panel.maxRowsHeight)
    // A card that swallows the whole screen reads as a page, not a menu.
    return Math.min(available, Math.round(panel.height * 0.7))
  }

  // When every row fits, the list gets its full height. When they don't,
  // the card must end mid-row: a clipped row is what tells the eye there is
  // more below the fold, so never come out even on a row boundary.
  function foldedListHeight(totals, available) {
    var count = totals.length
    if (count === 0) return root.baseRowHeight
    if (totals[count - 1] <= available) return totals[count - 1]

    var peek = root.rowPeek
    var full = 0
    while (full < count && totals[full] <= available) full++
    while (full > 1 && totals[full - 1] + root.rowSpacing + peek > available) full--
    if (full < 1) return Math.max(available, root.baseRowHeight)

    return totals[full - 1] + root.rowSpacing + peek
  }

  function rowListHeight(_serial, _count, _filter, _divider) {
    if (displayModel.count === 0) return root.baseRowHeight

    var totals = []
    var total = 0
    var previousSection = ""

    for (var i = 0; i < displayModel.count; i++) {
      var row = displayModel.get(i)
      if (i > 0) total += root.rowSpacing
      if (row.section === "drilldown" && previousSection !== "drilldown") total += root.dividerHeight
      total += root.rowHeightForDetail(row.detail)
      previousSection = row.section
      totals.push(total)
    }

    return foldedListHeight(totals, availableRowsHeight())
  }

  function dmenuRowListHeight(_serial, _count, _filter) {
    if (root.mode === "input") return 0
    if (displayModel.count === 0) return root.baseRowHeight

    var available = availableRowsHeight()
    if (root.dmenuMaxHeight > 0) available = Math.min(available, Style.space(root.dmenuMaxHeight))

    var totals = []
    var total = 0
    for (var i = 0; i < displayModel.count; i++) {
      if (i > 0) total += root.rowSpacing
      total += root.rowHeightForDetail(displayModel.get(i).detail)
      totals.push(total)
    }

    return foldedListHeight(totals, available)
  }

  function item(id) {
    return root.items[id] || null
  }

  // ------------------------------------------------------------------
  // JSONC → normalized item array. Mirrors the bash bin's jq pipeline so
  // the on-disk authoring format stays untouched.
  // ------------------------------------------------------------------

  function stripJsonc(raw) {
    return MenuModel.stripJsonc(raw)
  }

  function normalizeAliases(value) {
    return MenuModel.normalizeAliases(value)
  }

  function normalizeItem(id, raw) {
    return MenuModel.normalizeItem(id, raw)
  }

  function parseMenuJsonc(raw) {
    return MenuModel.parseMenuJsonc(raw)
  }

  function parseCatalog(raw) {
    try {
      var parsed = JSON.parse(raw || "{}")
      return (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : ({})
    } catch (e) {
      return ({})
    }
  }

  function setLanguage(raw) {
    var code = String(raw || "").trim()
    if (!/^[a-z]{2,3}(-[A-Za-z]{2})?$/.test(code)) code = "en"
    if (root.language === code) return
    root.language = code
    menuCatalogFile.reload()
  }

  // Merge defaults + user extension. Later entries override earlier ones
  // on a per-key basis (so the user can tweak label/icon/action without
  // re-declaring the whole row).
  // Catalog-only rebuilds pass skipGuards: retitling rows cannot change any
  // when/checked answer, so re-running the guard batch would be pure waste.
  function rebuildItemsFromSources(skipGuards) {
    var translatedDefaults = MenuModel.applyTranslations(root.defaultMenuItems, root.menuCatalog)
    // The root row is injected by the merge (it has no JSONC entry), so its
    // "Go" label comes from the catalog's root entry; the merge only uses
    // it for the injected row, never over a user-supplied heading.
    var rootCatalog = root.menuCatalog.root
    var mergedMenu = MenuModel.mergeMenuSources(translatedDefaults, root.userMenuItems, rootCatalog && rootCatalog.label)
    root.providerRevision += 1
    root.providersLoaded = ({})
    root.providerQueue = []
    root.items = mergedMenu.items
    root.itemOrder = mergedMenu.itemOrder
    root.rowsLoaded = true
    if (!skipGuards && root.defaultMenuSettled && root.userMenuSettled) root.evaluateGuards()
    if (root.opened) {
      root.rebuildDisplay()
      if (!root.dmenuActive) {
        if (root.filterText.trim()) root.loadProvidersForSearch()
        else root.loadProviderForMenu(root.activeMenu)
      }
    }
  }

  // Each known provider is a tiny bash one-liner that enumerates a list and
  // emits one tab-delimited row per item: `label\tvalue\tcurrent`. The shell
  // turns those into menu items children of `menuId`. A `volatile` provider
  // re-runs every time its submenu is entered, so a font installed since the
  // shell started shows up without restarting it.
  readonly property var providers: ({
    "fonts": {
      script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
      icon: "",
      volatile: true,
      actionFor: function(value) { return "omarchy-font-set " + Util.shellQuote(value) }
    },
    "power-profiles": {
      script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
      icon: "\udb81\udc0b",
      // Profile names are powerprofilesctl ids; only the label is translated,
      // and the id stays searchable through searchTerms.
      labelFor: function(value) {
        if (value === "power-saver") return Commons.I18n.t("menu.powerProfilePowerSaver")
        if (value === "balanced") return Commons.I18n.t("menu.powerProfileBalanced")
        if (value === "performance") return Commons.I18n.t("menu.powerProfilePerformance")
        return value
      },
      actionFor: function(value) { return "omarchy-powerprofiles-set autodetect " + Util.shellQuote(value) }
    },
    // Kernel names are package names, the same in every language.
    "kernels": {
      script: "current=$(omarchy-kernel get 2>/dev/null); omarchy-kernel list 2>/dev/null | while read -r k; do [[ -z $k ]] && continue; printf '%s\\t%s\\t%s\\n' \"$k\" \"$k\" \"$current\"; done",
      icon: "\uf17c",
      volatile: true,
      actionFor: function(value) { return "omarchy-kernel set " + Util.shellQuote(value) }
    },
    // Rows carry a fourth field (the English name) so searching "danish"
    // finds the row labeled with its native name; mergeProviderRows turns
    // it into an alias.
    "languages": {
      script: "current=$(omarchy-language 2>/dev/null); omarchy-language list 2>/dev/null | while IFS=$'\\t' read -r name code english; do [[ -z $code ]] && continue; printf '%s\\t%s\\t%s\\t%s\\n' \"$name\" \"$code\" \"$current\" \"$english\"; done",
      icon: "\uf1ab",
      volatile: true,
      actionFor: function(value) { return "omarchy-language " + Util.shellQuote(value) }
    }
  })

  function slugify(value) {
    return MenuModel.slugify(value)
  }

  // The apps provider is QML-native: rows come from the shared AppLibrary
  // (DesktopEntries) instead of a bash enumeration, so they carry image
  // icons, launch feedback, and uninstall support like the launcher.
  function mergeAppRows() {
    if (!root.appLibrary) return

    var rows = root.appLibrary.sortedEntries("")
    var appRows = []
    for (var j = 0; j < rows.length; j++) {
      var entry = rows[j].entry
      var appId = String(entry.id || "")
      if (!appId) continue
      var subtext = root.appLibrary.entrySubtext(entry)
      var aliases = subtext ? [subtext] : []
      try {
        if (entry.keywords && typeof entry.keywords.join === "function") aliases = aliases.concat(entry.keywords)
      } catch (e) { }
      appRows.push({
        id: "apps." + appId,
        parent: "apps",
        kind: "app",
        icon: "",
        appIcon: String(entry.icon || ""),
        appId: appId,
        label: root.appLibrary.entryName(entry),
        title: "",
        target: "",
        description: subtext,
        action: "",
        provider: "",
        aliases: aliases,
        searchTerms: [],
        when: "",
        checked: "",
        disabled: "",
        order: 0
      })
    }

    var merged = MenuModel.mergeAppRows(root.items, root.itemOrder, appRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) root.rebuildDisplay()
  }

  function startProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return
    if (entry.provider === "apps") {
      root.providersLoaded[id] = true
      root.mergeAppRows()
      return
    }
    var spec = root.providers[entry.provider]
    if (!spec) return

    root.providersLoaded[id] = true
    providerProc.menuId = id
    providerProc.providerKey = entry.provider
    providerProc.revision = root.providerRevision
    providerProc.collected = ""
    providerProc.command = ["bash", "-lc", spec.script]
    providerProc.running = true
  }

  function mergeProviderRows(rows, menuId, providerKey) {
    var spec = root.providers[providerKey]
    if (!spec) return
    var lines = String(rows || "").split("\n")
    var providerRows = []
    var takenIds = ({})
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var rawLabel = parts[0] || ""
      var label = spec.labelFor ? spec.labelFor(rawLabel) : rawLabel
      var value = parts[1] || parts[0] || ""
      var current = parts[2] || ""
      if (!label) continue
      // Distinct values can slugify alike — Fira Code and Fira-Code both give
      // fira-code — and a repeated id is dropped, which would silently lose a
      // row from the list. Nudge it until it is the row's own.
      var rowId = menuId + "." + root.slugify(value)
      while (takenIds[rowId]) rowId += "-"
      takenIds[rowId] = true

      providerRows.push({
        id: rowId,
        parent: menuId,
        kind: "action",
        icon: (value === current) ? "✓" : (spec.icon || ""),
        label: label,
        title: "",
        target: "",
        description: "",
        action: spec.actionFor(value),
        provider: "",
        aliases: [],
        searchTerms: (parts[3] ? [parts[3]] : []).concat(label !== rawLabel ? [rawLabel] : []),
        when: "",
        checked: "",
        disabled: "",
        order: 0
      })
    }
    var merged = MenuModel.swapProviderRows(root.items, root.itemOrder, menuId, providerRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) root.rebuildDisplay()
  }

  function startNextProvider() {
    if (providerProc.running) return

    while (root.providerQueue.length > 0) {
      var id = root.providerQueue.shift()
      var entry = root.item(id)
      if (!entry || !entry.provider || root.providersLoaded[id]) continue

      root.startProviderForMenu(id)
      return
    }
  }

  // Entering a submenu is the one moment a volatile list is worth paying for
  // again: it may have been reshaped by the last pick from it. Search doesn't
  // invalidate, or every keystroke would restart the same enumeration.
  function invalidateVolatileProvider(id) {
    var entry = root.item(id)
    var spec = entry && entry.provider ? root.providers[entry.provider] : null
    if (spec && spec.volatile) root.providersLoaded[id] = false
  }

  function loadProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return

    // Native providers don't touch providerProc, so they never need to queue.
    if (entry.provider === "apps") {
      root.startProviderForMenu(id)
      return
    }

    if (providerProc.running) {
      if (root.providerQueue.indexOf(id) < 0) root.providerQueue = root.providerQueue.concat([id])
      return
    }

    root.startProviderForMenu(id)
  }

  function loadProvidersForSearch() {
    var active = root.item(root.activeMenu) ? root.activeMenu : "root"

    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.item(root.itemOrder[i])
      if (!entry || !entry.provider || root.providersLoaded[entry.id]) continue
      if (active !== "root" && entry.id !== active && !root.isDescendantOf(entry.id, active)) continue

      root.loadProviderForMenu(entry.id)
    }
  }

  function depthFor(id) {
    return MenuModel.depthFor(root.items, id)
  }

  function pathFor(id) {
    return MenuModel.pathFor(root.items, id)
  }

  function parentPathFor(id) {
    return MenuModel.parentPathFor(root.items, id)
  }

  function isDescendantOf(id, ancestorId) {
    return MenuModel.isDescendantOf(root.items, id, ancestorId)
  }

  function childCount(id) {
    return MenuModel.childCount(root.items, root.itemOrder, id)
  }

  // Guarded items are hidden when their `when:` evaluates false. Static
  // submenus are also hidden when none of their descendants are visible;
  // provider-backed menus stay visible because their rows load on demand.
  function isVisible(entry) {
    return MenuModel.isVisible(root.items, root.itemOrder, root.whenResults, entry)
  }

  // Label with the ✓ marker baked in when `checked:` or `disabled:` evaluated
  // truthy.
  function labelFor(entry) {
    return MenuModel.labelFor(entry, root.checkedResults, root.disabledResults)
  }

  function searchableToken(value) {
    return MenuModel.searchableToken(value)
  }

  function leafIdFor(id) {
    return MenuModel.leafIdFor(id)
  }

  function nameSearchText(entry) {
    return MenuModel.nameSearchText(entry)
  }

  function termInSearchWords(term, text) {
    return MenuModel.termInSearchWords(term, text)
  }

  function descriptionTextMatches(query, text) {
    return MenuModel.descriptionTextMatches(query, text)
  }

  // Rows whose `disabled:` evaluated truthy stay listed but dimmed, and the
  // cursor steps over them.
  function isDisabled(entry) {
    return MenuModel.isDisabled(root.disabledResults, entry)
  }

  // A disabled row earns its place in the submenu it belongs to, where the
  // list around it is the point. Search is a list of what you can do, so it
  // leaves them out.
  function matchesQuery(entry, query) {
    return MenuModel.matchesQuery(entry, query, root.isVisible(entry) && !root.isDisabled(entry))
  }

  function searchScore(entry, query) {
    return MenuModel.searchScore(root.items, entry, query)
  }

  function displayRow(entry, detail, score, section) {
    return MenuModel.displayRow(root.items, root.itemOrder, root.checkedResults, root.disabledResults, entry, detail, score, section)
  }

  function rowSelectable(index) {
    if (index < 0 || index >= displayModel.count) return false
    return !displayModel.get(index).disabled
  }

  // First selectable row at or past `from`, continuing in the direction of
  // travel and wrapping. -1 when every row is disabled, which leaves the menu
  // with no cursor at all rather than one parked on a row Enter won't run.
  function nextSelectable(from, direction) {
    var count = displayModel.count
    if (count === 0) return -1

    var step = direction < 0 ? -1 : 1
    var index = ((from % count) + count) % count
    for (var i = 0; i < count; i++) {
      if (root.rowSelectable(index)) return index
      index = (index + step + count) % count
    }

    return -1
  }

  // Park the cursor on a selectable row after the rows underneath it changed.
  // A menu with nothing selectable in it -- every app in it already installed
  // -- shows no cursor at all, and grows one the moment a row can take it.
  function settleCursor() {
    var target = root.nextSelectable(root.selectedIndex, 1)
    root.selectedIndex = target >= 0 ? target : 0
    root.cursorActive = target >= 0
  }

  function rebuildDmenuDisplay() {
    displayModel.clear()
    root.searchDivider = false

    if (root.mode === "input") {
      layoutSerial += 1
      return
    }

    if (root.dmenuMultiple && root.dmenuOnChange.length === 0) {
      displayModel.append({
        itemId: "dmenu.apply", disabled: false, kind: "dmenu", icon: "", iconFont: "",
        appIcon: "", appId: "", label: Commons.I18n.t("common.apply"), target: "",
        detail: Commons.I18n.tn("menu.selectedCount", root.dmenuSelected.length).arg(Commons.I18n.formatNumber(root.dmenuSelected.length)), path: "", childCount: 0,
        action: "", provider: "", score: -1, section: ""
      })
    }
    var query = root.filterText.trim().toLowerCase()
    for (var i = 0; i < root.dmenuOptions.length; i++) {
      // An option is "<label>", "<glyph>\t<label>", or
      // "<glyph>\t<label>\t<subtext>". The glyph never comes back with the
      // selection; the subtext renders under the label, filters alongside it,
      // and returns with the selection as a stable key for same-named rows.
      var parts = String(root.dmenuOptions[i] || "").split("\t")
      var icon = parts.length > 1 ? parts.shift() : ""
      var label = parts.shift() || ""
      var detail = parts.join("\t")
      if (query && label.toLowerCase().indexOf(query) < 0
          && detail.toLowerCase().indexOf(query) < 0) continue
      displayModel.append({
        itemId: "dmenu." + i,
        disabled: false,
        kind: "dmenu",
        icon: root.dmenuMultiple ? (root.dmenuSelected.indexOf(MenuModel.dmenuValue(root.dmenuOptions[i])) !== -1 ? "✓" : "○") : icon,
        iconFont: "",
        appIcon: "",
        appId: "",
        label: label,
        target: "",
        detail: detail,
        path: "",
        childCount: 0,
        action: "",
        provider: "",
        score: i,
        section: ""
      })
    }

    layoutSerial += 1

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) root.revealCursor()
    })
  }

  function updateDmenuChecks() {
    for (var i = 0; i < displayModel.count; i++) {
      var row = displayModel.get(i)
      if (row.itemId === "dmenu.apply") {
        displayModel.setProperty(i, "detail", Commons.I18n.tn("menu.selectedCount", root.dmenuSelected.length).arg(Commons.I18n.formatNumber(root.dmenuSelected.length)))
      } else if (row.kind === "dmenu") {
        var value = MenuModel.dmenuValue(root.dmenuOptions[Number(row.itemId.substring(6))])
        displayModel.setProperty(i, "icon", root.dmenuSelected.indexOf(value) !== -1 ? "✓" : "○")
      }
    }
  }

  function rebuildDisplay() {
    if (root.dmenuActive) {
      root.rebuildDmenuDisplay()
      return
    }

    displayModel.clear()

    if (!root.rowsLoaded) return

    var active = root.item(root.activeMenu) ? root.activeMenu : "root"
    root.activeMenu = active
    var rows = []
    var query = root.filterText.trim()
    root.searchDivider = false

    if (query) {
      var currentRows = []
      var drilldownRows = []

      for (var i = 0; i < root.itemOrder.length; i++) {
        var entry = root.item(root.itemOrder[i])
        if (!entry || entry.id === "root") continue
        if (!root.isDescendantOf(entry.id, active)) continue
        if (!root.matchesQuery(entry, query)) continue

        var detail = root.parentPathFor(entry.id)
        var row = root.displayRow(entry, detail, root.searchScore(entry, query))
        if (entry.parent === active) currentRows.push(row)
        else drilldownRows.push(row)
      }

      var searchSort = function(a, b) {
        if (a.score !== b.score) return a.score - b.score
        return a.path.localeCompare(b.path)
      }

      currentRows.sort(searchSort)
      drilldownRows.sort(searchSort)
      root.searchDivider = currentRows.length > 0 && drilldownRows.length > 0
      if (root.searchDivider) {
        for (var d = 0; d < drilldownRows.length; d++) drilldownRows[d].section = "drilldown"
      }
      rows = currentRows.concat(drilldownRows)
    } else {
      for (var j = 0; j < root.itemOrder.length; j++) {
        var child = root.item(root.itemOrder[j])
        if (!child || child.parent !== active) continue
        if (!root.isVisible(child)) continue
        rows.push(root.displayRow(child, child.description, child.order))
      }

      // DesktopEntries can reorder its values when an application starts.
      // Keep the Apps menu alphabetical independently of provider refreshes.
      if (active === "apps") {
        rows.sort(function(a, b) {
          var aLabel = String(a.label || "").toLowerCase()
          var bLabel = String(b.label || "").toLowerCase()
          if (aLabel < bLabel) return -1
          if (aLabel > bLabel) return 1
          var aId = String(a.itemId || "")
          var bId = String(b.itemId || "")
          if (aId < bId) return -1
          if (aId > bId) return 1
          return 0
        })
      }
    }

    for (var k = 0; k < rows.length; k++) displayModel.append(rows[k])
    layoutSerial += 1

    root.settleCursor()

    Qt.callLater(function() {
      if (displayModel.count > 0) root.revealCursor()
    })
  }

  // Contain alone parks the cursor row flush with the viewport edge, hiding
  // the neighbor entirely and losing the fold affordance. Keep the next
  // hidden row peeking past the cursor in the direction of travel.
  function revealCursor() {
    if (displayModel.count === 0) return
    // In Coverflow mode, root.selectedIndex drives all card translations and 3D rotations directly
  }

  function select(delta) {
    if (displayModel.count === 0) return

    root.disarmPointer()
    var from = cursorActive ? selectedIndex + delta : (delta < 0 ? displayModel.count - 1 : 0)
    var target = root.nextSelectable(from, delta)
    if (target < 0) return

    cursorActive = true
    selectedIndex = target
    revealCursor()
  }

  function setFilter(nextFilter) {
    panel.freezeCardTop()
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = root.mode !== "input"
    root.disarmPointer()
    if (!root.dmenuActive && root.filterText.trim()) root.loadProvidersForSearch()
    root.rebuildDisplay()
  }

  function setActiveMenu(id, pushHistory, fromPointer) {
    panel.freezeCardTop()
    if (!root.item(id)) id = "root"
    if (pushHistory && id !== root.activeMenu) root.navStack = root.navStack.concat([root.activeMenu])
    root.activeMenu = id
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    if (fromPointer) pointerGate.allowInitialSample()
    else root.disarmPointer()
    if (id === "apps" && root.appLibrary) {
      root.providersLoaded[id] = true
      root.mergeAppRows()
    }
    root.rebuildDisplay()
    root.invalidateVolatileProvider(id)
    root.loadProviderForMenu(id)
  }

  function goBack() {
    if (root.activeMenu === "root") return false

    if (root.navStack.length > 0) {
      var previous = root.navStack[root.navStack.length - 1]
      root.navStack = root.navStack.slice(0, root.navStack.length - 1)
      root.setActiveMenu(previous, false)
      return true
    }

    var active = root.item(root.activeMenu)
    root.setActiveMenu((active && active.parent) ? active.parent : "root", false)
    return true
  }

  function activateIndex(index, fromPointer) {
    if (root.deleteConfirmOpen) return
    if (root.dmenuActive) {
      if (root.mode === "input") {
        root.applyDmenuSelection(root.filterText)
        return
      }
      if (index < 0 || index >= displayModel.count) return
      var picked = displayModel.get(index)
      if (root.dmenuMultiple) {
        if (picked.itemId === "dmenu.apply") {
          root.applyDmenuSelection(JSON.stringify(MenuModel.dmenuSelections(root.dmenuOptions, root.dmenuSelected)))
        } else {
          var value = MenuModel.dmenuValue(root.dmenuOptions[Number(picked.itemId.substring(6))])
          var selected = MenuModel.toggleDmenuSelection(selectionProc.requestedSelection(), value)
          if (root.dmenuOnChange.length > 0) {
            selectionProc.enqueue(selected)
          } else {
            root.dmenuSelected = selected
            root.updateDmenuChecks()
          }
        }
      } else {
        root.applyDmenuSelection(picked.detail ? picked.label + "\t" + picked.detail : picked.label)
      }
      return
    }

    if (!root.rowSelectable(index)) return

    var row = displayModel.get(index)
    if (row.kind === "menu" || row.kind === "link" || (row.provider && row.provider.length > 0) || row.itemId === "apps" || row.target === "apps") {
      root.setActiveMenu(row.target || row.itemId, true, fromPointer)
    } else if (row.kind === "app") {
      var appId = row.appId
      var label = row.label
      applySerial = requestSerial
      opened = false
      filterText = ""
      if (root.appLibrary) root.appLibrary.launch(appId, label)
    } else {
      root.applySelected(row.itemId, row.action)
    }
  }

  function requestDeleteSelected() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    if (!row || row.kind !== "app") return
    root.deleteTarget = { appId: row.appId, label: row.label }
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    deleteConfirm.selectedIndex = 1
    root.disarmPointer()
    Qt.callLater(function() { filterInput.forceActiveFocus() })
  }

  function confirmDelete() {
    var target = root.deleteTarget
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    if (!target) return
    root.cancel()
    if (root.appLibrary) root.appLibrary.remove(target.appId, target.label)
  }

  function applyDmenuSelection(value) {
    applySerial = requestSerial
    opened = false
    filterText = ""
    root.finishRequest(value)
  }

  function applySelected(id, action) {
    if (!id) { cancel(); return }

    applySerial = requestSerial
    opened = false
    filterText = ""
    root.runAction(action)
  }

  function cancel() {
    if (root.dmenuActive) root.finishRequest(null)
    opened = false
    filterText = ""
  }

  function openExistingMenu(initialMenu) {
    requestSerial += 1
    mode = "menu"
    requestActive = false
    selectionFile = ""
    doneFile = ""
    activeMenu = root.item(initialMenu) ? initialMenu : "root"
    navStack = []
    filterText = ""
    selectedIndex = 0
    cursorActive = true
    root.disarmPointer()
    root.evaluateGuards()
    opened = true
    if (activeMenu === "apps" && root.appLibrary) {
      root.providersLoaded["apps"] = true
      root.mergeAppRows()
    }
    rebuildDisplay()
    invalidateVolatileProvider(activeMenu)
    loadProviderForMenu(activeMenu)
    // The shell may start before first-install packages have finished placing
    // their icons. Refresh here even when the desktop entry list did not change.
    if (root.appLibrary) root.appLibrary.refreshIcons()

    Qt.callLater(function() { filterInput.forceActiveFocus() })
  }

  function openDmenu(payload) {
    requestSerial += 1
    mode = payload.mode === "input" ? "input" : "select"
    dmenuPrompt = String(payload.prompt || (mode === "input" ? Commons.I18n.t("menu.inputPrompt") : Commons.I18n.t("menu.selectPrompt")))
    dmenuOptions = Array.isArray(payload.options) ? payload.options : []
    dmenuMultiple = mode === "select" && payload.multiple === true
    dmenuOnChange = dmenuMultiple && Array.isArray(payload.onChange)
      && payload.onChange.every(function(arg) { return typeof arg === "string" }) ? payload.onChange : []
    dmenuChangeKey = String(payload.changeKey || JSON.stringify(dmenuOnChange))
    dmenuSelected = MenuModel.dmenuSelections(dmenuOptions, Array.isArray(payload.selected) ? payload.selected : [], dmenuOnChange.length > 0)
    dmenuSaved = dmenuSelected
    if (dmenuOnChange.length > 0)
      dmenuSelected = MenuModel.dmenuSelections(dmenuOptions, selectionProc.requestedSelection(), true)
    selectionFile = String(payload.selectionFile || "")
    doneFile = String(payload.doneFile || "")
    requestActive = !!doneFile
    dmenuWidth = Math.max(1, Number(payload.width || 300))
    dmenuMaxHeight = Math.max(0, Number(payload.maxHeight || 0))
    activeMenu = "root"
    navStack = []
    filterText = ""
    selectedIndex = 0
    cursorActive = mode !== "input"
    root.disarmPointer()
    opened = true
    rebuildDisplay()

    Qt.callLater(function() { filterInput.forceActiveFocus() })
  }
  ListModel { id: displayModel }

  // ----------------------------------------------------------- route surface
  //
  // The menu is opened through the standard plugin lifecycle:
  // `omarchy-shell shell summon omarchy.menu '{"menu":"system"}'`.
  // Callers may pass a real id (`system`, `setup.power`) or an alias declared
  // in JSONC (`power`, `reminder-set`). Unknown strings fall through to the
  // id-as-route behavior so misspellings still attempt to open the literal id.
  function resolveRoute(input) {
    return MenuModel.resolveRoute(root.items, root.itemOrder, input)
  }

  function openRoute(initialMenu) {
    var id = root.resolveRoute(initialMenu)
    var entry = root.items[id]
    // If the resolved id is an action (i.e. the user invoked an alias for
    // a leaf, e.g. `omarchy menu summon screenrecord-stop`), run it directly
    // instead of opening an action with no children.
    if (entry && entry.kind === "action" && entry.action && !entry.provider && entry.id !== "apps") {
      root.cancel()
      root.runAction(entry.action)
      return "ok"
    }
    // If it's a link (a redirect to another menu), follow the link.
    if (entry && entry.kind === "link" && entry.target) id = entry.target
    root.pendingInitialMenu = id
    root.openExistingMenu(id)
    return "ok"
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    if (!root.rowSelectable(index)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  Process {
    id: providerProc
    property string menuId: ""
    property string providerKey: ""
    property string collected: ""
    property int revision: 0
    stdout: SplitParser {
      onRead: function(data) { providerProc.collected += data + "\n" }
    }
    onExited: {
      if (providerProc.revision === root.providerRevision) {
        root.mergeProviderRows(providerProc.collected, providerProc.menuId, providerProc.providerKey)
        if (root.filterText.trim()) root.loadProvidersForSearch()
      }
      root.startNextProvider()
    }
  }

  Process {
    id: selectionProc
    property int serial: 0
    property string changeKey: ""
    property var selected: []
    property var queue: []
    property string collected: ""

    function requestedSelection() {
      for (var i = queue.length - 1; i >= 0; i--) {
        if (queue[i].key === root.dmenuChangeKey) return queue[i].selected
      }
      if (running && changeKey === root.dmenuChangeKey) return selected
      return root.dmenuSelected
    }

    function enqueue(values) {
      var selected = MenuModel.dmenuSelections(root.dmenuOptions, values, true)
      queue = queue.concat([{
        serial: root.requestSerial, key: root.dmenuChangeKey, selected: selected,
        command: root.dmenuOnChange.concat([JSON.stringify(selected)])
      }])
      if (!running) startNext()
    }

    function startNext() {
      if (queue.length === 0) return
      var change = queue[0]
      queue = queue.slice(1)
      serial = change.serial
      changeKey = change.key
      selected = change.selected
      collected = ""
      command = change.command
      running = true
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: selectionProc.collected = text
    }
    onExited: function(exitCode) {
      if (changeKey === root.dmenuChangeKey && root.dmenuActive && root.dmenuOnChange.length > 0) {
        if (exitCode === 0) {
          var applied = selected
          if (collected.trim()) {
            try { applied = JSON.parse(collected) } catch (error) { applied = root.dmenuSelected }
          }
          if (Array.isArray(applied))
            root.dmenuSelected = MenuModel.dmenuSelections(root.dmenuOptions, applied, true)
          root.dmenuSaved = root.dmenuSelected
        } else {
          root.dmenuSelected = root.dmenuSaved
        }
        root.updateDmenuChecks()
      }
      startNext()
    }
  }

  Process {
    id: resultProc
    onExited: {
      if (root.applySerial === root.requestSerial)
        root.opened = false
    }
  }

  PointerMoveGate {
    id: pointerGate
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() {
      if (root.providersLoaded["apps"]) root.mergeAppRows()
    }
  }

  // The JSONC sources are watched so live edits to the default file (or the
  // user extension at ~/.config/omarchy/extensions/omarchy-menu.jsonc) take
  // effect without restarting the shell.
  FileView {
    id: defaultMenuFile
    path: root.defaultMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.defaultMenuItems = MenuModel.keepMenuRows(root.defaultMenuItems, text(), true); root.defaultMenuSettled = true; root.rebuildItemsFromSources() }
    // A user file that loaded first held its evaluation for this one.
    onLoadFailed: { root.defaultMenuSettled = true; if (root.userMenuSettled) root.evaluateGuards() }
    onFileChanged: reload()
  }

  FileView {
    id: userMenuFile
    path: root.userMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.userMenuItems = MenuModel.keepMenuRows(root.userMenuItems, text(), false); root.userMenuSettled = true; root.rebuildItemsFromSources() }
    onLoadFailed: { root.userMenuItems = []; root.userMenuSettled = true; root.rebuildItemsFromSources() }
    onFileChanged: reload()
  }

  // The language choice and its catalog are watched the same way, so
  // picking a language under Setup retitles the menu with no shell restart.
  FileView {
    id: languageFile
    path: root.languagePath
    watchChanges: true
    printErrors: false
    onLoaded: root.setLanguage(text())
    onLoadFailed: root.setLanguage("")
    onFileChanged: reload()
  }

  FileView {
    id: menuCatalogFile
    path: root.omarchyPath + "/default/i18n/" + root.language + "/menu.json"
    watchChanges: true
    printErrors: false
    onLoaded: { root.menuCatalog = root.parseCatalog(text()); root.rebuildItemsFromSources(true) }
    onLoadFailed: { root.menuCatalog = ({}); root.rebuildItemsFromSources(true) }
    onFileChanged: reload()
  }

  // ---------------------------------------------------------------- guards
  //
  // `when:` (visibility) and `checked:` (✓ marker) are bash expressions the
  // shell wasn't allowed to evaluate before the perf rewrite. Now the shell
  // batches them into one bash subprocess per (re)load so the open path
  // never has to wait on them.

  property var whenResults: ({})       // id → true|false (allow visibility)
  property var checkedResults: ({})    // id → true|false (show ✓)
  property var disabledResults: ({})   // id → true|false (dim, skip cursor)
  property bool guardsPending: false

  function evaluateGuards() {
    // Process ignores a command change while it is running, and `collected`
    // belongs to the run in flight, so a second evaluation cannot overwrite
    // the first: it would throw away the lines already read and never start.
    // The surviving tail then lands as the whole answer, and every id lost
    // with it goes back to showing, since a `when:` only hides on an explicit
    // false. Wait for the run in flight and evaluate once it lands instead.
    if (guardProc.running) {
      root.guardsPending = true
      return
    }
    root.guardsPending = false

    var script = MenuModel.guardScript(root.items)
    if (!script) {
      root.whenResults = ({})
      root.checkedResults = ({})
      root.disabledResults = ({})
      return
    }
    guardProc.collected = ""
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
  }

  Process {
    id: guardProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { guardProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      // A batch that was killed rather than finished has only told us about
      // the rows it reached, and a row whose `when:` went unanswered shows.
      // Keep the last complete set rather than let a half-read one through.
      // A signal leaves the exit code at 0, so the status is what tells us.
      if (exitCode !== 0 || exitStatus !== 0) {
        if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
        return
      }

      var nextWhen = ({})
      var nextChecked = ({})
      var nextDisabled = ({})
      var lines = guardProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (!line) continue
        var colon = line.lastIndexOf(":")
        if (colon < 0) continue
        var value = line.substring(colon + 1) === "1"
        var rest = line.substring(0, colon)
        var tagAt = rest.lastIndexOf(":")
        if (tagAt < 0) continue
        var id = rest.substring(0, tagAt)
        var tag = rest.substring(tagAt + 1)
        if (tag === "w") nextWhen[id] = value
        else if (tag === "c") nextChecked[id] = value
        else if (tag === "d") nextDisabled[id] = value
      }
      root.whenResults = nextWhen
      root.checkedResults = nextChecked
      root.disabledResults = nextDisabled
      if (root.opened) root.rebuildDisplay()
      // Run the evaluation that had to stand aside. Deferred by a turn so the
      // process is settled before its command is set again.
      if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
    }
  }
  OverlayWindow {
    id: panel
    shown: root.opened && root.rowsLoaded
    WlrLayershell.namespace: "omarchy-menu"

    // The card opens centered exactly as always. The first search keystroke
    // or submenu move freezes the top line where it currently sits — from
    // then on the card grows and shrinks downward instead of re-centering
    // on every resize, which made the menu jump around. The rows height is
    // frozen at the same moment, so the starting menu also caps how tall the
    // card may grow from there. Closing or changing screens unfreezes both.
    property int cardTop: -1
    property int maxRowsHeight: -1
    readonly property int centeredTop: Math.max(Style.gapsOut, Math.round((height - root.cardHeight) / 2))
    readonly property int effectiveCardTop: cardTop >= 0 ? cardTop : centeredTop
    function freezeCardTop() {
      if (shown && cardTop < 0) {
        cardTop = effectiveCardTop
        maxRowsHeight = root.visibleRowsHeight
      }
    }
    onShownChanged: if (!shown) { cardTop = -1; maxRowsHeight = -1 }
    onTargetScreenChanged: { cardTop = -1; maxRowsHeight = -1 }

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(8/255, 10/255, 14/255, 0.75)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (root.deleteConfirmOpen) {
          deleteConfirm.handleKey(event)
          event.accepted = true
          return
        }

        if (event.key === Qt.Key_Escape) {
          if (root.filterText) root.setFilter("")
          else if (!root.goBack()) root.cancel()
          event.accepted = true
        } else if (event.key === Qt.Key_Backspace && !root.filterText) {
          root.goBack()
          event.accepted = true
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
          root.select(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
          root.select(1)
          event.accepted = true
        } else if (event.key === Qt.Key_PageUp) {
          root.select(-5)
          event.accepted = true
        } else if (event.key === Qt.Key_PageDown) {
          root.select(5)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          if (root.dmenuActive) {
            if (root.mode === "input") root.applyDmenuSelection(root.filterText)
            else if (displayModel.count > 0) root.activateIndex(root.selectedIndex)
          } else if (displayModel.count > 0) {
            root.activateIndex(root.selectedIndex)
          }
          event.accepted = true
        } else if (Util.editsFilter(event, root.filterText)) {
          root.setFilter(Util.editedFilter(event, root.filterText))
          event.accepted = true
        }
      }



      // Top-Right Search Capsule
      Row {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Style.space(48)
        spacing: Style.space(16)

        Rectangle {
          width: Style.space(280)
          height: Style.space(40)
          radius: Style.space(20)
          color: Qt.rgba(24/255, 24/255, 28/255, 0.78)
          border.color: filterInput.text.length > 0 ? "#cda052" : Qt.rgba(255, 255, 255, 0.16)
          border.width: 1.2

          FilterInput {
            id: filterInput
            anchors.fill: parent
            anchors.leftMargin: Style.space(16)
            anchors.rightMargin: Style.space(16)
            verticalAlignment: TextInput.AlignVCenter
            keyHandler: keyCatcher
            readOnly: root.deleteConfirmOpen
            color: "#ffffff"
            font.family: root.fontFamily
            font.pixelSize: Style.space(14)
            onTextChanged: if (text !== root.filterText) root.setFilter(text)
          }

          Text {
            visible: filterInput.text.length === 0
            anchors.fill: filterInput
            verticalAlignment: Text.AlignVCenter
            text: root.dmenuActive ? (root.dmenuPrompt + "…") : "Search protocols…"
            color: Qt.rgba(255, 255, 255, 0.4)
            font.family: root.fontFamily
            font.pixelSize: Style.space(13)
            font.italic: true
            textFormat: Text.PlainText
          }
        }
      }

      // Bottom-Right Navigation Legend
      Row {
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.margins: Style.space(48)
        spacing: Style.space(24)

        Text {
          text: "[ ← / → ] Scroll"
          color: Qt.rgba(255, 255, 255, 0.6)
          font.family: root.fontFamily
          font.pixelSize: Style.space(13)
          textFormat: Text.PlainText
        }
        Text {
          text: "[ Enter ] Select"
          color: "#cda052"
          font.family: root.fontFamily
          font.bold: true
          font.pixelSize: Style.space(13)
          textFormat: Text.PlainText
        }
        Text {
          text: "[ Esc ] Close"
          color: Qt.rgba(255, 255, 255, 0.4)
          font.family: root.fontFamily
          font.pixelSize: Style.space(13)
          textFormat: Text.PlainText
        }
      }

      // Central 3D Holographic Coverflow Glass Carousel
      Item {
        id: coverflowContainer
        anchors.centerIn: parent
        width: parent.width
        height: Style.space(460)

        MouseArea {
          anchors.fill: parent
          onWheel: function(wheel) {
            if (wheel.angleDelta.y > 0 || wheel.angleDelta.x < 0) root.select(-1)
            else if (wheel.angleDelta.y < 0 || wheel.angleDelta.x > 0) root.select(1)
          }
        }

        Repeater {
          model: displayModel

          delegate: Item {
            id: cardItem
            required property int index

            readonly property var row: (index >= 0 && index < displayModel.count) ? displayModel.get(index) : null
            readonly property string itemLabel: row && row.label !== undefined ? String(row.label) : ""
            readonly property string itemDetail: row && row.detail !== undefined ? String(row.detail) : ""
            readonly property string itemIcon: row && row.icon !== undefined ? String(row.icon) : ""
            readonly property bool itemIsApp: row ? (row.kind === "app" || row.isApp === true) : false
            readonly property string itemAppIcon: row && row.appIcon !== undefined ? String(row.appIcon) : ""
            readonly property string itemAppId: row && row.appId !== undefined ? String(row.appId) : ""
            readonly property string itemIconFont: row && row.iconFont !== undefined ? String(row.iconFont) : ""

            readonly property int offset: index - root.selectedIndex
            readonly property bool isCenter: offset === 0

            width: Style.space(260)
            height: Style.space(360)

            readonly property real targetX: {
              if (offset === 0) return coverflowContainer.width / 2
              if (offset === -1) return coverflowContainer.width / 2 - Style.space(250)
              if (offset === 1) return coverflowContainer.width / 2 + Style.space(250)
              if (offset === -2) return coverflowContainer.width / 2 - Style.space(450)
              if (offset === 2) return coverflowContainer.width / 2 + Style.space(450)
              return offset < 0 ? coverflowContainer.width / 2 - Style.space(620) : coverflowContainer.width / 2 + Style.space(620)
            }

            readonly property real targetY: offset === 0 ? (coverflowContainer.height / 2 - Style.space(16)) : (coverflowContainer.height / 2)
            readonly property real targetScale: offset === 0 ? 1.0 : (Math.abs(offset) === 1 ? 0.86 : 0.72)
            readonly property real targetOpacity: offset === 0 ? 1.0 : (Math.abs(offset) === 1 ? 0.74 : 0.38)
            readonly property real targetAngle: offset === 0 ? 0 : (offset === -1 ? 20 : (offset === 1 ? -20 : (offset < 0 ? 32 : -32)))

            x: targetX - width / 2
            y: targetY - height / 2
            scale: targetScale
            opacity: targetOpacity
            z: offset === 0 ? 100 : (Math.abs(offset) === 1 ? 50 : 20)
            visible: Math.abs(offset) <= 3

            transform: Rotation {
              origin.x: cardItem.width / 2
              origin.y: cardItem.height / 2
              axis { x: 0; y: 1; z: 0 }
              angle: cardItem.targetAngle
            }

            Behavior on x { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
            Behavior on y { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }

            // Subtle Outer Rim / Aura for center card
            Rectangle {
              visible: cardItem.isCenter
              anchors.fill: parent
              anchors.margins: -Style.space(3)
              radius: Style.space(23)
              color: "transparent"
              border.color: Qt.rgba(205/255, 160/255, 82/255, 0.25)
              border.width: 1.5
              z: -1
            }

            // Card Glass Surface
            Rectangle {
              anchors.fill: parent
              radius: Style.space(20)
              color: cardItem.isCenter ? Qt.rgba(20/255, 22/255, 28/255, 0.90) : Qt.rgba(14/255, 16/255, 20/255, 0.65)
              border.color: cardItem.isCenter ? "#cda052" : Qt.rgba(255, 255, 255, 0.12)
              border.width: cardItem.isCenter ? 1.8 : 1.0

              // Specular top light sheen inside card (luxury glass reflection)
              Rectangle {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: Style.space(70)
                radius: parent.radius
                gradient: Gradient {
                  GradientStop { position: 0.0; color: cardItem.isCenter ? Qt.rgba(205/255, 160/255, 82/255, 0.16) : Qt.rgba(255, 255, 255, 0.05) }
                  GradientStop { position: 1.0; color: "transparent" }
                }
              }

              // Card click handler
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (cardItem.isCenter) root.activateIndex(cardItem.index)
                  else root.selectedIndex = cardItem.index
                }
              }

              Column {
                anchors.centerIn: parent
                anchors.margins: Style.space(20)
                spacing: Style.space(16)
                width: parent.width - Style.space(40)

                // Large Glowing Icon
                Item {
                  width: Style.space(72)
                  height: Style.space(72)
                  anchors.horizontalCenter: parent.horizontalCenter

                  Text {
                    visible: !cardItem.itemIsApp
                    textFormat: Text.PlainText
                    text: cardItem.itemIcon
                    color: cardItem.isCenter ? "#ffffff" : Qt.rgba(255, 255, 255, 0.60)
                    font.family: cardItem.itemIconFont.length > 0 ? cardItem.itemIconFont : root.fontFamily
                    font.pixelSize: Style.space(56)
                    anchors.centerIn: parent
                  }

                  Image {
                    visible: cardItem.itemIsApp
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectFit
                    source: cardItem.itemIsApp && root.appLibrary ? root.appLibrary.iconSource(cardItem.itemAppIcon) : ""
                  }
                }

                // Title
                Text {
                  textFormat: Text.PlainText
                  text: cardItem.itemLabel
                  color: cardItem.isCenter ? "#ffffff" : Qt.rgba(255, 255, 255, 0.85)
                  font.family: root.fontFamily
                  font.bold: true
                  font.pixelSize: cardItem.isCenter ? Style.space(22) : Style.space(18)
                  horizontalAlignment: Text.AlignHCenter
                  anchors.horizontalCenter: parent.horizontalCenter
                  elide: Text.ElideRight
                  width: parent.width
                }

                // Subtitle / Description
                Text {
                  textFormat: Text.PlainText
                  text: cardItem.itemDetail ? cardItem.itemDetail : (cardItem.itemIsApp ? "Launch application" : "Explore option")
                  color: cardItem.isCenter ? Qt.rgba(255, 255, 255, 0.72) : Qt.rgba(255, 255, 255, 0.40)
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(13)
                  horizontalAlignment: Text.AlignHCenter
                  anchors.horizontalCenter: parent.horizontalCenter
                  elide: Text.ElideRight
                  width: parent.width
                  wrapMode: Text.WordWrap
                  maximumLineCount: 2
                }
              }
            }
          }
        }

        // Empty state
        Column {
          anchors.centerIn: parent
          spacing: Style.space(12)
          visible: displayModel.count === 0 && root.mode !== "input"

          Text {
            text: "󰈉"
            color: Commons.Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.space(48)
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
          }

          Text {
            textFormat: Text.PlainText
            text: root.filterText ? ("No matches for '" + root.filterText + "'") : "No protocols found"
            color: Commons.Color.menu.text
            font.family: root.fontFamily
            font.pixelSize: Style.space(16)
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
          }
        }
      }

      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        opened: root.deleteConfirmOpen
        z: 200
        message: Commons.I18n.t("common.uninstallConfirm").arg((root.deleteTarget && root.deleteTarget.label) || "")
        confirmText: Commons.I18n.t("common.uninstall")
        background: root.background
        foreground: root.foreground
        scrim: root.scrim
        selectedBackground: root.selectedBackground
        selectedText: root.selectedText
        fontFamily: root.fontFamily
        cornerRadius: root.cornerRadius
        onCanceled: root.cancelDelete()
        onConfirmed: root.confirmDelete()
      }
    }
  }
}
