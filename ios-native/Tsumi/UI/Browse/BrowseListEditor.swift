import SwiftUI

// components/Scoring.svelte: the list editor (status, episode progress, score with its names, rewatches,
// delete / save with the toasts and profile syncing of MediaListService).

/// Bookmark / pencil button that opens the list editor (Scoring.svelte trigger).
@MainActor
struct BrowseListEditorButton: View {
  let media: Media
  var size: CGFloat = 44
  @State private var showEditor = false

  var body: some View {
    let entry = BrowseMediaInfo.entry(media)
    Button {
      showEditor = true
    } label: {
      Image(systemName: entry == nil ? "bookmark" : "square.and.pencil")
        .font(.system(size: size * 0.4, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(BrowsePalette.cardStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .accessibilityLabel("List Editor")
    .disabled(!ProfilesService.shared.isAuthorized)
    .sheet(isPresented: $showEditor) {
      BrowseListEditor(media: media)
    }
  }
}

@MainActor
struct BrowseListEditor: View {
  let media: Media
  @Environment(\.dismiss) private var dismiss
  @State private var status: ListStatus?
  @State private var progress: Int
  @State private var score: Double
  @State private var repeatCount: Int
  @State private var isWorking = false
  private let hasEntry: Bool
  private let maxEpisode: Int
  /// Progress of the entry when the editor opened (kept as is when the user does not edit it).
  private let initialProgress: Int

  static let statusOrder: [ListStatus] = [.current, .planning, .completed, .paused, .dropped, .repeating]

  init(media: Media) {
    self.media = media
    let entry = MediaListService.shared.entry(for: media)
    hasEntry = entry != nil
    maxEpisode = AnimeHelpers.maxEpisode(media)
    _status = State(initialValue: entry?.status)
    initialProgress = entry?.progress ?? 0
    _progress = State(initialValue: entry?.progress ?? 0)
    _score = State(initialValue: (entry?.score ?? 0).rounded())
    _repeatCount = State(initialValue: entry?.repeatCount ?? 0)
  }

  /// handleEpisodes: the progress is capped to the episode count (12 for releasing titles without one).
  private var progressLimit: Int {
    if maxEpisode > 0 { return maxEpisode }
    return media.status == .releasing ? 12 : 0
  }

  private var totalText: String {
    maxEpisode > 0 ? String(maxEpisode) : "?"
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(BrowseMediaInfo.title(media))
            .font(.headline)
        }
        statusSection
        episodeSection
        scoreSection
        rewatchSection
        actionsSection
      }
      .navigationTitle("List Editor")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          // Esc closes the editor only: without its own shortcut, the Esc of the details under it (found further
          // up the responder chain) closed the details as well (DetailsModal checkClose, PC audit).
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(isWorking)
        }
      }
    }
    .presentationDetents([.medium, .large])
    .preferredColorScheme(.dark)
  }

  private var statusSection: some View {
    Section("Status") {
      Picker("Status", selection: $status) {
        if status == nil {
          Text("Not on List").tag(ListStatus?.none)
        }
        ForEach(Self.statusOrder, id: \.self) { value in
          Text(value.label).tag(ListStatus?.some(value))
        }
      }
      .pickerStyle(.menu)
    }
  }

  private var episodeSection: some View {
    Section("Episode") {
      HStack {
        TextField("Episode", value: $progress, format: .number)
          .keyboardType(.numberPad)
          .onChange(of: progress) { _, newValue in
            clamp(newValue)
          }
        Text("/ \(totalText)")
          .foregroundStyle(BrowsePalette.muted)
        Stepper("Episode", value: $progress, in: 0...max(progressLimit, 0))
          .labelsHidden()
      }
    }
  }

  private var scoreSection: some View {
    Section("Your Score") {
      Slider(value: $score, in: 0...10, step: 1)
      HStack(spacing: 6) {
        Spacer()
        if Int(score) != 0 {
          Text(String(Int(score)))
            .fontWeight(.bold)
            .underline()
          Text("/ 10")
        }
        Text(Self.scoreName(Int(score)))
          .foregroundStyle(BrowsePalette.muted)
        Spacer()
      }
    }
  }

  private var rewatchSection: some View {
    Section("Rewatches") {
      Stepper(value: $repeatCount, in: 0...999) {
        Text(String(repeatCount))
      }
    }
  }

  @ViewBuilder
  private var actionsSection: some View {
    if status != nil && hasEntry {
      Section {
        Button(role: .destructive) {
          remove()
        } label: {
          Text("Delete")
            .frame(maxWidth: .infinity)
        }
        .disabled(isWorking)
      }
    }
  }

  static func scoreName(_ score: Int) -> String {
    switch score {
    case 10: return "(Masterpiece)"
    case 9: return "(Great)"
    case 8: return "(Very Good)"
    case 7: return "(Good)"
    case 6: return "(Fine)"
    case 5: return "(Average)"
    case 4: return "(Bad)"
    case 3: return "(Very bad)"
    case 2: return "(Horrible)"
    case 1: return "(Appalling)"
    default: return "Not Rated"
    }
  }

  private func clamp(_ value: Int) {
    if value < 0 {
      progress = 0
    } else if value > progressLimit {
      progress = progressLimit
    }
  }

  /// saveEntry: "Not on List" deletes the entry.
  private func save() {
    guard let status else {
      remove()
      return
    }
    isWorking = true
    let target = media
    // Like handleEpisodes, only an edited progress is capped: an untouched one is saved as it is (a finished
    // title without an episode count has a limit of 0, which turned progress 40 into 0 on a score change).
    let savedProgress = progress == initialProgress ? progress : min(max(progress, 0), max(progressLimit, 0))
    let values = (progress: savedProgress, score: score, repeatCount: repeatCount)
    // Like the PC editor (Scoring.svelte toggleModal): the sheet closes at once and the change is saved meanwhile,
    // with a toast when AniList / MyAnimeList answered. It stayed open until the other profiles were synced too.
    Task { @MainActor in
      await MediaListService.shared.save(target, status: status, progress: values.progress, score: values.score, repeatCount: values.repeatCount)
    }
    dismiss()
  }

  private func remove() {
    guard hasEntry else {
      dismiss()
      return
    }
    isWorking = true
    let target = media
    Task { @MainActor in
      await MediaListService.shared.delete(target)
    }
    dismiss()
  }
}
