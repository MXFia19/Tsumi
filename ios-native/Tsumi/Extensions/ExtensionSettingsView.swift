import SwiftUI

/// Settings > Extensions (common/routes/settings/tabs/ExtensionTab.svelte): add by manifest URL
/// (Sora module or Stremio addon, shown before it is installed: name, the hosts it says it uses, "updated in place"
/// when it is already installed, plain http script warning, Install / Update), default extension zone (drag & drop,
/// or tap to choose), list with star, delete (with confirmation), enable switch (also on the default card),
/// badges (version, stream type, quality, type, plain http) and, on Sora modules, the "Link results to AniList /
/// TMDB" switch of their Search page results. Each card shows the load state: loading, error with
/// Retry (failed loads are also retried when the device gets back online), update waiting for approval, update
/// applied. Only the host of a manifest URL is shown (the URL can carry a private token).
@MainActor
struct ExtensionSettingsView: View {
  @State private var showAddDialog = false
  @State private var sourceURL = ""
  @State private var pendingSource = false
  @State private var failedSource: String? = nil
  /// Extension loaded by "Add" and shown before it is installed.
  @State private var preview: ExtensionInstallPreview? = nil
  @State private var dragOverDefault = false
  @State private var confirmingDelete: String? = nil
  /// Extension whose "Delete Extension" context-menu item asks for confirmation.
  @State private var menuDeleteKey: String? = nil

  private var manager: ExtensionManager { ExtensionManager.shared }

  private var defaultExtension: InstalledExtension? {
    guard let key = manager.defaultKey else { return nil }
    return manager.installed.first { $0.key == key }
  }

  /// Every extension but the default one, starred first.
  private var otherExtensions: [InstalledExtension] {
    let defaultKey = manager.defaultKey
    let starred = manager.starredKey
    let others = manager.installed.filter { $0.key != defaultKey }
    return others.filter { $0.key == starred } + others.filter { $0.key != starred }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("Extensions")
            .font(.title2.bold())
            .foregroundStyle(.white)
          Spacer()
          Button {
            showAddDialog.toggle()
            failedSource = nil
            preview = nil
          } label: {
            Label("Add Extension", systemImage: "plus")
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 14)
              .padding(.vertical, 9)
              .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
              .foregroundStyle(.white)
          }
          .buttonStyle(.plain)
        }
        .padding(.bottom, 20)

        if manager.installed.isEmpty {
          emptyCard
        } else {
          defaultSection
          Text("Extensions")
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.bottom, 10)
          VStack(spacing: 10) {
            ForEach(otherExtensions) { ext in
              extensionCard(ext)
            }
          }
        }
      }
      .padding(20)
    }
    .background(Color.black)
    .refreshable {
      // Keeps the spinner until the extensions are loaded again (each load is bounded by the request timeouts).
      await ExtensionManager.shared.refreshAll()
      await ExtensionManager.shared.awaitPendingLoads(timeout: nil)
    }
    .sheet(isPresented: $showAddDialog) {
      addDialog
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    .confirmationDialog(
      menuDeleteTitle,
      isPresented: Binding(
        get: { menuDeleteKey != nil },
        set: { if !$0 { menuDeleteKey = nil } }
      ),
      titleVisibility: .visible,
      presenting: menuDeleteKey
    ) { key in
      Button("Delete", role: .destructive) {
        menuDeleteKey = nil
        removeSource(key)
      }
      Button("Cancel", role: .cancel) {
        menuDeleteKey = nil
      }
    } message: { _ in
      Text("The extension is removed from this device. You can add it again from its URL.")
    }
  }

  /// Title of the context-menu delete confirmation (ConfirmButton of ExtensionTab.svelte).
  private var menuDeleteTitle: String {
    guard let key = menuDeleteKey, let ext = manager.installedExtension(key) else { return "Delete Extension?" }
    return "Delete \(ext.displayName)?"
  }

  // MARK: Empty state

  private var emptyCard: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 36))
        .foregroundStyle(.white)
      VStack(alignment: .leading, spacing: 4) {
        Text("No Extensions Found")
          .font(.headline)
          .foregroundStyle(.white)
        Text("Click the \(Text("Add Extension").underline()) button above to get started.")
          .font(.subheadline)
          .foregroundStyle(ExtensionPalette.muted)
      }
      Spacer(minLength: 0)
    }
    .padding(15)
    .background(ExtensionPalette.danger.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ExtensionPalette.danger, lineWidth: 1))
  }

  // MARK: Default extension

  private var defaultSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 5) {
        Image(systemName: "crown.fill")
          .foregroundStyle(Color.accentColor)
        Text("Default Extension")
          .font(.headline)
          .foregroundStyle(.white)
      }
      .padding(.bottom, 5)
      Text("Drag an extension here to set it as default. The default extension is used automatically — Tsumi will pick the best match and start playing without manual selection.")
        .font(.footnote)
        .foregroundStyle(ExtensionPalette.muted)
        .padding(.bottom, 10)

      Group {
        if let ext = defaultExtension {
          defaultCard(ext)
        } else {
          dropZone
        }
      }
      .dropDestination(for: String.self) { keys, _ in
        guard let key = keys.first, manager.installedExtension(key) != nil else { return false }
        manager.setDefault(key)
        return true
      } isTargeted: { targeted in
        dragOverDefault = targeted
      }
      .padding(.bottom, 20)
    }
  }

  private var dropZone: some View {
    Menu {
      ForEach(manager.installed) { ext in
        Button(ext.displayName) { manager.setDefault(ext.key) }
      }
    } label: {
      Text("Drag an extension here to set it as default")
        .font(.subheadline)
        .foregroundStyle(ExtensionPalette.muted)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding(10)
        .background(dragOverDefault ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(dragOverDefault ? Color.accentColor : ExtensionPalette.dimmed, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        )
    }
  }

  private func defaultCard(_ ext: InstalledExtension) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 10) {
        ExtensionIconView(url: ext.manifest.iconURL, allowsLocalNetwork: ExtensionImageLoader.allowsLocalNetwork(extensionKey: ext.key))
        identity(ext)
        Spacer(minLength: 8)
        // The default card replaces the list entry: its switch is here, so a disabled default can be enabled again.
        Toggle("", isOn: Binding(
          get: { ext.enabled },
          set: { manager.toggleExtension(ext.key, enabled: $0) }
        ))
        .labelsHidden()
        .accessibilityLabel("Enabled")
        Button {
          manager.unsetDefault()
        } label: {
          Image(systemName: "xmark")
            .font(.title3)
            .foregroundStyle(ExtensionPalette.dimmed)
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove as Default")
      }
      badgeRow(versionAndStreamOnly: true, ext)
      linkResultsRow(ext)
      statusRow(ext)
    }
    .padding(15)
    .background(ExtensionPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.accentColor, lineWidth: 1))
    .opacity(ext.enabled ? 1 : 0.4)
  }

  // MARK: Extension cards

  private func extensionCard(_ ext: InstalledExtension) -> some View {
    let isStarred = manager.starredKey == ext.key
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(ExtensionPalette.dimmed)
          .accessibilityLabel("Drag to set as default")
        ExtensionIconView(url: ext.manifest.iconURL, allowsLocalNetwork: ExtensionImageLoader.allowsLocalNetwork(extensionKey: ext.key))
        identity(ext)
        Spacer(minLength: 8)
        HStack(spacing: 10) {
          Button {
            toggleStar(ext.key)
          } label: {
            Image(systemName: isStarred ? "star.fill" : "star")
              .font(.title3)
              .foregroundStyle(isStarred ? ExtensionPalette.warning : ExtensionPalette.dimmed)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(isStarred ? "Unstar" : "Star — always show at the top of search results")
          deleteControl(ext)
          Toggle("", isOn: Binding(
            get: { ext.enabled },
            set: { manager.toggleExtension(ext.key, enabled: $0) }
          ))
          .labelsHidden()
        }
      }
      badgeRow(versionAndStreamOnly: false, ext)
      linkResultsRow(ext)
      statusRow(ext)
    }
    .padding(15)
    .background(ExtensionPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isStarred ? ExtensionPalette.warning : ExtensionPalette.cardBorder, lineWidth: 1))
    .opacity(ext.enabled ? 1 : 0.4)
    .draggable(ext.key)
    .contextMenu {
      Button {
        manager.setDefault(ext.key)
      } label: {
        Label("Set as Default", systemImage: "crown")
      }
      Button {
        toggleStar(ext.key)
      } label: {
        Label(isStarred ? "Unstar" : "Star", systemImage: isStarred ? "star.slash" : "star")
      }
      Button(role: .destructive) {
        menuDeleteKey = ext.key
      } label: {
        Label("Delete Extension", systemImage: "trash")
      }
    }
  }

  private func identity(_ ext: InstalledExtension) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(ext.displayName)
        .font(.headline)
        .foregroundStyle(.white)
        .lineLimit(1)
      if let language = ext.manifest.language, !language.isEmpty {
        Text(language)
          .font(.subheadline)
          .foregroundStyle(ExtensionPalette.muted)
      }
      // Host only: the rest of a manifest URL can be a private token.
      Text(ExtensionURLMask.host(ext.url))
        .font(.caption)
        .foregroundStyle(ExtensionPalette.muted)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  @ViewBuilder
  private func deleteControl(_ ext: InstalledExtension) -> some View {
    if confirmingDelete == ext.key {
      HStack(spacing: 10) {
        Button {
          confirmingDelete = nil
          removeSource(ext.key)
        } label: {
          Image(systemName: "checkmark")
            .font(.title3.weight(.semibold))
            .foregroundStyle(ExtensionPalette.success)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Confirm")
        Button {
          confirmingDelete = nil
        } label: {
          Image(systemName: "xmark")
            .font(.title3)
            .foregroundStyle(ExtensionPalette.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel")
      }
    } else {
      Button {
        confirmingDelete = ext.key
      } label: {
        Image(systemName: "trash")
          .font(.title3)
          .foregroundStyle(ExtensionPalette.danger)
      }
      .buttonStyle(.plain)
      .disabled(pendingSource)
      .accessibilityLabel("Delete Extension")
    }
  }

  private func badgeRow(versionAndStreamOnly: Bool, _ ext: InstalledExtension) -> some View {
    var badges: [String] = []
    if let version = ext.manifest.version, !version.isEmpty { badges.append(version) }
    if let streamType = ext.manifest.streamType, !streamType.isEmpty { badges.append(streamType) }
    if !versionAndStreamOnly {
      if let quality = ext.manifest.quality, !quality.isEmpty { badges.append(quality) }
      if let type = ext.manifest.type, !type.isEmpty, type != "stremio" { badges.append(type) }
    }
    if isInsecure(ext) { badges.append("http (not secure)") }
    return HStack(spacing: 10) {
      ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
        ExtensionBadge(text: badge)
      }
    }
    .padding(.top, badges.isEmpty ? 0 : 10)
  }

  /// "Link results to AniList / TMDB" of a Sora module (Stremio addons have none: their results are not opened from
  /// the Search page). Off: a result tapped on the Search page opens its module page (SoraResultView) instead of
  /// the matching title.
  @ViewBuilder
  private func linkResultsRow(_ ext: InstalledExtension) -> some View {
    if ext.kind == .sora {
      Toggle(isOn: Binding(
        get: { ext.linkResults },
        set: { manager.setLinkResults(ext.key, $0) }
      )) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Link results to AniList / TMDB")
            .font(.subheadline)
            .foregroundStyle(.white)
          Text("Off: results of this module open as they are, with its own episodes and no list tracking. For modules that are not anime, shows or movies.")
            .font(.caption)
            .foregroundStyle(ExtensionPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.top, 10)
    }
  }

  /// Manifest or script loaded over plain http.
  private func isInsecure(_ ext: InstalledExtension) -> Bool {
    if let loaded = manager.loadedExtension(ext.key) { return !loaded.isSecure }
    return ext.url.lowercased().hasPrefix("http:")
  }

  // MARK: Load state

  private func hasStatus(_ key: String) -> Bool {
    manager.loadingKeys.contains(key) || manager.loadErrors[key] != nil || manager.pendingUpdates[key] != nil || manager.updateNotes[key] != nil
  }

  /// Loading, last error (with Retry), update waiting for approval (with Update), update applied.
  @ViewBuilder
  private func statusRow(_ ext: InstalledExtension) -> some View {
    let key = ext.key
    if hasStatus(key) {
      VStack(alignment: .leading, spacing: 8) {
        if manager.loadingKeys.contains(key) {
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.mini)
              .tint(ExtensionPalette.muted)
            Text("Loading…")
              .font(.caption)
              .foregroundStyle(ExtensionPalette.muted)
          }
        } else if let error = manager.loadErrors[key] {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(ExtensionPalette.danger)
            VStack(alignment: .leading, spacing: 2) {
              Text(error)
                .font(.caption)
                .foregroundStyle(ExtensionPalette.danger)
                .lineLimit(3)
              Text(fallbackText(key))
                .font(.caption2)
                .foregroundStyle(ExtensionPalette.muted)
            }
            Spacer(minLength: 4)
            Button("Retry") { manager.retry(key) }
              .font(.caption.weight(.semibold))
              .buttonStyle(.borderless)
          }
        }
        if let pending = manager.pendingUpdates[key] {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
              .font(.caption)
              .foregroundStyle(ExtensionPalette.warning)
            Text("Update available (\(pending.summary)). Its code came over plain http, so it is not used until you update.")
              .font(.caption)
              .foregroundStyle(ExtensionPalette.warning)
              .lineLimit(3)
            Spacer(minLength: 4)
            Button("Update") { manager.applyUpdate(key) }
              .font(.caption.weight(.semibold))
              .buttonStyle(.borderless)
          }
        } else if let note = manager.updateNotes[key] {
          Label(note, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(ExtensionPalette.success)
        }
      }
      .padding(.top, 10)
    }
  }

  private func fallbackText(_ key: String) -> String {
    if manager.loadedExtension(key) == nil { return "Not available until it loads." }
    if manager.offlineKeys.contains(key) { return "Using the copy saved on this device." }
    return "Using the copy loaded earlier."
  }

  // MARK: Add dialog

  private var addDialog: some View {
    ScrollView {
      addDialogContent
    }
    .background(Color.black)
  }

  private var addDialogContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Add Extension")
          .font(.title3.bold())
          .foregroundStyle(.white)
        Spacer()
        Button {
          showAddDialog = false
        } label: {
          Image(systemName: "xmark.circle")
            .font(.title2)
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
      }
      ExtensionNoticeBanner(
        systemImage: "exclamationmark.triangle",
        tint: ExtensionPalette.warning,
        title: nil,
        messageText: Text("Extensions are sandboxed and should be safe, but avoid adding \(Text("unknown").underline()) or \(Text("untrusted").underline()) sources."),
        messageColor: ExtensionPalette.warning
      )
      if let failedSource {
        ExtensionNoticeBanner(systemImage: "xmark.circle", tint: ExtensionPalette.danger, title: nil, message: failedSource)
      }
      HStack(spacing: 10) {
        TextField("Sora module or Stremio addon manifest URL", text: $sourceURL)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.done)
          .onSubmit { addSource() }
          .onChange(of: sourceURL) { _, _ in preview = nil }
          .disabled(pendingSource)
          .padding(.horizontal, 12)
          .frame(height: 40)
          .background(ExtensionPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ExtensionPalette.cardBorder, lineWidth: 1))
        Button {
          addSource()
        } label: {
          HStack(spacing: 5) {
            if pendingSource {
              ProgressView().tint(.white)
            } else {
              Image(systemName: "plus.square")
            }
            Text("Add")
          }
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 90, height: 40)
          .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(pendingSource || sourceURL.isEmpty)
        .opacity(pendingSource || sourceURL.isEmpty ? 0.6 : 1)
      }
      if let shown = preview {
        previewCard(shown)
      }
      Spacer(minLength: 0)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  /// The loaded extension before it is installed (preview card of ExtensionTab.svelte).
  private func previewCard(_ item: ExtensionInstallPreview) -> some View {
    let manifest = item.result.manifest
    var kindLine = item.isStremio ? "Stremio addon" : "Sora module"
    if let version = manifest.version, !version.isEmpty { kindLine += " · \(version)" }
    if let language = manifest.language, !language.isEmpty { kindLine += " · \(language)" }
    let installTitle = item.existingKey != nil ? "Update" : "Install"
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        ExtensionIconView(url: manifest.iconURL, allowsLocalNetwork: item.result.allowsLocalNetwork)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.name)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(2)
          Text(kindLine)
            .font(.subheadline)
            .foregroundStyle(ExtensionPalette.muted)
            .lineLimit(1)
        }
      }
      if item.existingKey != nil {
        Label {
          Text(item.installedVersion.map { "Already installed (\($0)): it will be updated in place." } ?? "Already installed: it will be updated in place.")
        } icon: {
          Image(systemName: "arrow.up.circle")
        }
        .font(.footnote)
        .foregroundStyle(ExtensionPalette.muted)
      }
      VStack(alignment: .leading, spacing: 5) {
        Label(item.isStremio ? "Addon server" : "Sites this module mentions", systemImage: "globe")
          .font(.footnote.weight(.bold))
          .foregroundStyle(.white)
        if item.domains.isEmpty {
          Text("Not known in advance.")
            .font(.footnote)
            .foregroundStyle(ExtensionPalette.muted)
        } else {
          Text(item.domains.joined(separator: ", "))
            .font(.footnote)
            .foregroundStyle(ExtensionPalette.muted)
            .textSelection(.enabled)
          if !item.isStremio {
            Text("Taken from its manifest and script: a module can still build other addresses while it runs.")
              .font(.caption)
              .foregroundStyle(ExtensionPalette.muted)
          }
        }
      }
      if item.insecureScript {
        Label("The script is downloaded without encryption (http), so it could be altered on the way.", systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(ExtensionPalette.warning)
      }
      HStack(spacing: 10) {
        Spacer()
        Button("Cancel") {
          preview = nil
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .frame(height: 36)
        .background(ExtensionPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .buttonStyle(.plain)
        Button(installTitle) {
          installPreview()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .frame(height: 36)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .buttonStyle(.plain)
      }
    }
    .padding(15)
    .background(ExtensionPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ExtensionPalette.cardBorder, lineWidth: 1))
  }

  // MARK: Actions

  /// "Add": loads the extension and shows it (checkSource of ExtensionTab.svelte); "Install" / "Update" then adds it.
  private func addSource() {
    guard !sourceURL.isEmpty, !pendingSource else { return }
    pendingSource = true
    failedSource = nil
    preview = nil
    let url = sourceURL
    Task {
      do {
        let loaded = try await manager.previewExtension(url)
        // The address was edited meanwhile: this preview is for another one.
        if sourceURL == url { preview = loaded }
      } catch {
        failedSource = error.localizedDescription.isEmpty ? "Failed to load extension" : error.localizedDescription
      }
      pendingSource = false
    }
  }

  private func installPreview() {
    guard let shown = preview else { return }
    manager.installExtension(shown)
    sourceURL = ""
    preview = nil
    showAddDialog = false
  }

  private func removeSource(_ key: String) {
    guard !pendingSource else { return }
    pendingSource = true
    if manager.defaultKey == key { manager.unsetDefault() }
    if manager.starredKey == key { manager.unsetStar() }
    manager.removeExtension(key)
    pendingSource = false
  }

  private func toggleStar(_ key: String) {
    if manager.starredKey == key {
      manager.unsetStar()
    } else {
      manager.setStar(key)
    }
  }
}
