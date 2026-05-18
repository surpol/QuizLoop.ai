import SwiftUI

struct AppHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.largeTitle.weight(.semibold))

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LocalStatusCard: View {
    let readiness: ModelReadiness
    let sourceCount: Int
    let modelName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: readiness.systemImage)
                    .font(.title3)
                    .foregroundStyle(readiness.color)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(readiness.isReady ? "Offline assistant ready" : readiness.title)
                        .font(.headline)

                    Text("\(modelName) / \(sourceCount) saved notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Text("QuizLoop.ai answers from your notes first, then uses Gemma to explain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct EmptyInlineState: View {
    let title: String
    let detail: String
    let systemImage: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        title: String,
        detail: String,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.teal)

            Text(title)
                .font(.headline)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(2)

            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct QuizBuildProgressView: View {
    let progress: QuizBuildProgress
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 14)

                Text(progress.stage.title)
                    .font((compact ? Font.caption : Font.subheadline).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(progress.percentText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                    .monospacedDigit()
            }

            ProgressView(value: progress.clampedProgress)
                .tint(.teal)

            if compact == false {
                Text(progress.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(progress.stage.title), \(progress.percentText). \(progress.detail)")
    }
}

struct MasteryRing: View {
    let snapshot: MasterySnapshot
    var size: CGFloat = 92
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.secondarySystemBackground), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(0, min(snapshot.weightedMastery, 1)))
                .stroke(Color.teal, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                Image(systemName: snapshot.weightedMastery >= 0.995 ? "checkmark" : "arrow.up")
                    .font(size > 70 ? .title3.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(snapshot.weightedMastery >= 0.995 ? .green : .teal)

                Text(snapshot.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(snapshot.title) learning progress")
    }
}

struct CoveragePill: View {
    let tested: Int
    let total: Int

    var body: some View {
        Text("\(tested)/\(total) tested")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TopicCoverageRow: View {
    let title: String
    let summary: String
    let snapshot: MasterySnapshot
    var isSelected = false
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                MasteryRing(snapshot: snapshot, size: 54, lineWidth: 7)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.teal)
                        }
                    }

                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    CoveragePill(tested: snapshot.testedCount, total: snapshot.totalCount)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.teal.opacity(0.45) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

struct SubtopicCoverageGrid: View {
    let subtopics: [SubtopicMastery]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(subtopics) { subtopic in
                VStack(alignment: .leading, spacing: 10) {
                    MasteryRing(snapshot: subtopic.snapshot, size: 58, lineWidth: 7)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(subtopic.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        CoveragePill(tested: subtopic.snapshot.testedCount, total: subtopic.snapshot.totalCount)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

extension ModelReadiness {
    var title: String {
        switch self {
        case .checking:
            "Checking"
        case .ready:
            "Ready"
        case .serverUnavailable:
            "Server unavailable"
        case .modelMissing:
            "Model missing"
        case .unsupportedModelFormat:
            "Unsupported model"
        case .deviceNotEligible:
            "Device not eligible"
        case .appleIntelligenceNotEnabled:
            "LiteRT-LM not linked"
        case .appleModelNotReady:
            "Gemma preparing"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "QuizLoop.ai is checking the selected model runtime."
        case .ready:
            "This is the model QuizLoop.ai is currently using."
        case .serverUnavailable:
            "QuizLoop.ai cannot reach the configured Gemma endpoint."
        case .modelMissing(let model):
            "\(model) is not installed yet."
        case .unsupportedModelFormat(let model):
            "\(model) is downloaded, but this build cannot run that model format."
        case .deviceNotEligible:
            "This device cannot run the selected on-device model runtime."
        case .appleIntelligenceNotEnabled:
            "Gemma is downloaded, but this build does not include the LiteRT-LM Swift runtime needed to run it."
        case .appleModelNotReady:
            "The on-device Gemma runtime is still preparing."
        }
    }

    var systemImage: String {
        switch self {
        case .checking:
            "hourglass"
        case .ready:
            "checkmark.circle.fill"
        case .serverUnavailable:
            "wifi.exclamationmark"
        case .modelMissing:
            "square.and.arrow.down"
        case .unsupportedModelFormat:
            "exclamationmark.triangle.fill"
        case .deviceNotEligible:
            "iphone.slash"
        case .appleIntelligenceNotEnabled:
            "exclamationmark.triangle"
        case .appleModelNotReady:
            "clock"
        }
    }

    var color: Color {
        switch self {
        case .ready:
            .teal
        case .checking, .appleModelNotReady:
            .secondary
        default:
            .orange
        }
    }
}
