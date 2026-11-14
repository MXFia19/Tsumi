import SwiftUI

/// Settings > Extensions (common/routes/settings/tabs/ExtensionTab.svelte): add by manifest URL
/// (Sora module or Stremio addon), default extension zone (drag & drop, or tap to choose), list with
/// star, delete (with confirmation), enable switch and badges (version, stream type, quality, type).
@MainActor
struct ExtensionSettingsView: View {
  @State private var showAddDialog = false
  @State private var sourceURL = ""
  @State private var pendingSource = false
  @State private var failedSource: String? = nil
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
      // Keeps the spinner until the extensions are loaded again.
      await ExtensionManager.shared.refreshAll()
      await ExtensionManager.shared.awaitPendingLoads()
    }
    .sheet(isPresented: $showAddDialog) {
      addDialog
        .presentationDetents([.medium])
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
        ExtensionIconView(url: ext.manifest.iconURL)
        identity(ext)
        Spacer(minLength: 8)
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
        ExtensionIconView(url: ext.manifest.iconURL)
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
      Text(ext.url)
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
    return HStack(spacing: 10) {
      ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
        ExtensionBadge(text: badge)
      }
    }
    .padding(.top, badges.isEmpty ? 0 : 10)
  }

  // MARK: Add dialog

  private var addDialog: some View {
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
      Spacer(minLength: 0)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.black)
  }

  // MARK: Actions

  private func addSource() {
    guard !sourceURL.isEmpty, !pendingSource else { return }
    pendingSource = true
    failedSource = nil
    let url = sourceURL
    Task {
      do {
        try await manager.addExtension(url)
        sourceURL = ""
        showAddDialog = false
      } catch {
        failedSource = error.localizedDescription.isEmpty ? "Failed to add extension" : error.localizedDescription
      }
      pendingSource = false
    }
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
