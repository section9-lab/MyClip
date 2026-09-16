import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import Speech
import UniformTypeIdentifiers

/// Settings for agent availability. Runtime routing is owned by Agent Bridge.
struct SettingsPanelView: View {
    @Bindable var aiService: AIIntegrationService

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PermissionsSection()
                    AIToolsSection(aiService: aiService)
                }
                .padding(16)
            }
        }
    }
}

// MARK: - Permissions Section

private struct PermissionsSection: View {
    @State private var microphoneStatus = PermissionCoordinator.microphoneStatus
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()
    @State private var screenCaptureStatus = PermissionCoordinator.screenCaptureStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerText("Permissions")

            VStack(spacing: 0) {
                SettingsPermissionStatusRow(
                    icon: "mic",
                    title: "Microphone",
                    statusText: microphoneStatusText,
                    tint: microphoneStatus == .granted ? .green : .orange,
                    actionTitle: microphoneStatus == .granted ? nil : "Authorize"
                ) {
                    Task { await requestMicrophoneAccess() }
                }

                Divider()
                    .padding(.leading, 52)

                SettingsPermissionStatusRow(
                    icon: "waveform",
                    title: "Speech Recognition",
                    statusText: speechStatusText,
                    tint: speechStatus == .authorized ? .green : .orange,
                    actionTitle: speechStatus == .authorized ? nil : "Authorize"
                ) {
                    requestSpeechRecognitionAccess()
                }

                Divider()
                    .padding(.leading, 52)

                SettingsPermissionStatusRow(
                    icon: "display",
                    title: "Screen Recording",
                    statusText: screenCaptureStatus == .granted ? "Authorized" : "Not Authorized",
                    tint: screenCaptureStatus == .granted ? .green : .orange,
                    actionTitle: screenCaptureStatus == .granted ? nil : "Authorize"
                ) {
                    requestScreenCaptureAccess()
                }
            }
            .background(settingsCardBackground)
        }
        .onAppear {
            refreshPermissionStatus()
        }
    }

    private var microphoneStatusText: String {
        switch microphoneStatus {
        case .granted:
            return "Authorized"
        case .denied:
            return "Not Authorized"
        case .undetermined:
            return "Not Requested"
        }
    }

    private var speechStatusText: String {
        switch speechStatus {
        case .authorized:
            return "Authorized"
        case .denied, .restricted:
            return "Not Authorized"
        case .notDetermined:
            return "Not Requested"
        @unknown default:
            return "Unknown"
        }
    }

    private func refreshPermissionStatus() {
        microphoneStatus = PermissionCoordinator.microphoneStatus
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        screenCaptureStatus = PermissionCoordinator.screenCaptureStatus
    }

    private func requestMicrophoneAccess() async {
        _ = await PermissionCoordinator.requestMicrophoneAccess()
        refreshPermissionStatus()
    }

    private func requestSpeechRecognitionAccess() {
        SFSpeechRecognizer.requestAuthorization { _ in
            Task { @MainActor in
                refreshPermissionStatus()
            }
        }
    }

    private func requestScreenCaptureAccess() {
        if PermissionCoordinator.requestScreenCaptureAccess() {
            refreshPermissionStatus()
        } else {
            PermissionCoordinator.openScreenCaptureSettings()
            refreshPermissionStatus()
        }
    }
}

private struct SettingsPermissionStatusRow: View {
    let icon: String
    let title: String
    let statusText: String
    let tint: Color
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.06))
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36)

            Text(title)
                .font(.callout.weight(.semibold))

            Spacer()

            Text(statusText)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)

            if let actionTitle {
                Button(actionTitle) {
                    action()
                }
                .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - AI Tools Section

private struct AIToolsSection: View {
    @Bindable var aiService: AIIntegrationService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerText("AI Tools Available to Bridge")

            ForEach(AIToolType.allCases) { tool in
                AIToolToggleRow(
                    tool: tool,
                    sessions: aiService.recentSessionsByTool[tool.baseTool] ?? [],
                    isLoadingSessions: aiService.loadingRecentSessionTools.contains(tool.baseTool),
                    isCurrentRoute: aiService.bridgeService.lastRoute?.target.tool.baseTool == tool.baseTool,
                    isEnabled: Binding(
                        get: { aiService.isToolEnabled(tool) },
                        set: { aiService.setTool(tool, enabled: $0) }
                    )
                )
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 20)

                Text("This page does not choose the current Agent or session. Kara lets Agent Bridge decide from the last successful target, available tools, and request context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.blue.opacity(0.07))
            )

            if aiService.enabledTools.isEmpty {
                Label("Enable at least one installed tool before sending voice requests", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if aiService.enabledTools.allSatisfy({ !$0.canSendMessages }) {
                Label("Enabled tools do not have a detected installation", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let error = aiService.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear {
            aiService.refreshRecentSessions()
        }
    }
}

private struct AIToolToggleRow: View {
    let tool: AIToolType
    let sessions: [AgentRecentSession]
    let isLoadingSessions: Bool
    let isCurrentRoute: Bool
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let icon = tool.brandIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .padding(tool.baseTool == .codexCLI ? 0 : 2)
                } else {
                    Image(systemName: tool.iconSystemName)
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(tool.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(tool.endpointDetail)
                    .font(.caption2)
                    .foregroundStyle(tool.canSendMessages ? Color.secondary : Color.orange)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    statusBadge(installStatusText, color: tool.canSendMessages ? .green : .orange)
                    statusBadge(routeStatusText, color: routeStatusColor)
                    statusBadge(sessionStatusText, color: sessionStatusColor)
                    if isCurrentRoute {
                        statusBadge("Current Route", color: .blue)
                    }
                }
            }

            Spacer()

            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!tool.canSendMessages)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isEnabled && tool.canSendMessages ? 0.48 : 0.26))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.30), lineWidth: 1)
                )
        )
        .opacity(tool.canSendMessages ? 1 : 0.62)
    }

    private var installStatusText: String {
        tool.canSendMessages ? "CLI Installed" : "CLI Not Found"
    }

    private var routeStatusText: String {
        if !tool.canSendMessages {
            return "Not Routable"
        }
        return isEnabled ? "Bridge Routable" : "Disabled"
    }

    private var routeStatusColor: Color {
        if !tool.canSendMessages {
            return .orange
        }
        return isEnabled ? .green : .secondary
    }

    private var sessionStatusText: String {
        if isLoadingSessions {
            return "Loading Sessions"
        }
        if !tool.canSendMessages {
            return "No Sessions"
        }
        if sessions.isEmpty {
            return "No Recent Sessions"
        }
        return "\(sessions.count) Recent"
    }

    private var sessionStatusColor: Color {
        if isLoadingSessions {
            return .blue
        }
        if !tool.canSendMessages || sessions.isEmpty {
            return .secondary
        }
        return .green
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }
}

private struct LegacyAIToolsSection: View {
    @Bindable var aiService: AIIntegrationService
    @State private var testMessage: String = ""
    @State private var screenCaptureStatus = PermissionCoordinator.screenCaptureStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerText("Choose the Target Agent for Voice Transcription")

            screenCapturePermissionPanel

            ForEach(AIToolType.allCases) { tool in
                AIToolRow(
                    tool: tool,
                    canSend: tool.canSendMessages,
                    isSelected: aiService.selectedTool == tool,
                    isExpanded: aiService.selectedTool == tool && tool.canSendMessages,
                    sessions: aiService.recentSessionsByTool[tool] ?? [],
                    isLoadingSessions: aiService.loadingRecentSessionTools.contains(tool),
                    selectedSessionID: aiService.selectedSession.externalID,
                    selectTool: {
                        guard tool.canSendMessages else { return }
                        aiService.selectedTool = (aiService.selectedTool == tool) ? nil : tool
                    },
                    clearSession: {
                        aiService.clearSelectedSession(for: tool)
                    },
                    selectSession: { session in
                        aiService.selectRecentSession(session)
                    }
                )
            }

            if aiService.installedTools.isEmpty {
                emptyAIState
            }

            testMessagePanel

            if let error = aiService.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .onAppear {
            refreshScreenCaptureStatus()
        }
    }

    private var screenCapturePermissionPanel: some View {
        HStack(spacing: 10) {
            Label(screenCaptureStatusTitle, systemImage: screenCaptureStatusIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(screenCaptureStatusColor)

            Spacer()

            Button {
                requestScreenCaptureAccess()
            } label: {
                Label("Authorize Screenshot", systemImage: "rectangle.dashed.badge.record")
            }
            .controlSize(.small)
            .disabled(screenCaptureStatus == .granted)

            Button {
                PermissionCoordinator.openScreenCaptureSettings()
                refreshScreenCaptureStatus()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Open Screen Recording permission settings")
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.30), lineWidth: 1)
                )
        )
    }

    private var screenCaptureStatusTitle: String {
        switch screenCaptureStatus {
        case .granted:
            return "Screenshot Authorized"
        case .denied:
            return "Screenshot Not Authorized"
        }
    }

    private var screenCaptureStatusIcon: String {
        switch screenCaptureStatus {
        case .granted:
            return "checkmark.circle.fill"
        case .denied:
            return "exclamationmark.triangle.fill"
        }
    }

    private var screenCaptureStatusColor: Color {
        switch screenCaptureStatus {
        case .granted:
            return .green
        case .denied:
            return .orange
        }
    }

    private func refreshScreenCaptureStatus() {
        screenCaptureStatus = PermissionCoordinator.screenCaptureStatus
    }

    private func requestScreenCaptureAccess() {
        if PermissionCoordinator.requestScreenCaptureAccess() {
            refreshScreenCaptureStatus()
        } else {
            PermissionCoordinator.openScreenCaptureSettings()
            refreshScreenCaptureStatus()
        }
    }

    private var emptyAIState: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.bubble")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No Installed AI Tools Detected")
                .font(.caption.weight(.medium))
            Text("Supported: Claude, Codex, Hermes CLI")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var testMessagePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test Message")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    TextField("Enter a test message", text: $testMessage, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.callout.weight(.medium))
                        .lineLimit(1...3)
                }

                HStack(spacing: 10) {
                    deliveryStatus
                    Spacer()
                    Button {
                        let message = testMessage
                        Task {
                            await aiService.deliverText(message, notifyOnCompletion: true)
                        }
                    } label: {
                        Label("Send", systemImage: "paperplane")
                    }
                    .controlSize(.small)
                    .disabled(
                        aiService.preferredTool == nil ||
                        !aiService.canSendToSelectedTool ||
                        testMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                if aiService.preferredTool != nil,
                   !aiService.canSendToSelectedTool {
                    Label("The current Agent does not have a detected installation", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if let response = aiService.lastResponse,
                   !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CLI Response")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(response)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 120)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.46))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.34), lineWidth: 1)
                    )
            )
        }
    }

    private var deliveryStatus: some View {
        Label(aiService.statusDetailText, systemImage: statusIconName)
            .font(.caption)
            .foregroundStyle(statusColor)
            .lineLimit(2)
    }

    private var statusIconName: String {
        switch aiService.deliveryState {
        case .idle:
            return "checkmark.circle"
        case .transcribing:
            return "waveform"
        case .sending:
            return "paperplane"
        case .delivered:
            return "checkmark.circle.fill"
        case .running:
            return "bolt.circle"
        case .completed:
            return "checkmark.seal.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch aiService.deliveryState {
        case .failed:
            return .orange
        case .delivered, .completed:
            return .green
        case .sending, .transcribing, .running:
            return .blue
        case .idle:
            return .secondary
        }
    }
}

private struct RecentSessionRow: View {
    let session: AgentRecentSession
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if let icon = session.tool.brandIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .padding(session.tool.baseTool == .codexCLI ? 0 : 2)
                    } else {
                        Image(systemName: session.tool.iconSystemName)
                            .font(.system(size: 14, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text(session.displayTime)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let projectName = session.projectName {
                            Text(projectName)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.66) : Color.white.opacity(0.38))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isSelected ? Color.blue.opacity(0.42) : Color.white.opacity(0.26), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct RecentSessionSkeletonRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 132, height: 9)

                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.055))
                    .frame(width: 84, height: 7)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.30))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
        )
        .redacted(reason: .placeholder)
    }
}

private struct NoSessionRow: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text("No Session")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Send to the current Agent default window")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.66) : Color.white.opacity(0.38))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isSelected ? Color.blue.opacity(0.42) : Color.white.opacity(0.26), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct AIToolRow: View {
    let tool: AIToolType
    let canSend: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let sessions: [AgentRecentSession]
    let isLoadingSessions: Bool
    let selectedSessionID: String?
    let selectTool: () -> Void
    let clearSession: () -> Void
    let selectSession: (AgentRecentSession) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: selectTool) {
                HStack(spacing: 10) {
                    ZStack {
                        if let icon = tool.brandIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .padding(tool.baseTool == .codexCLI ? 0 : 2)
                        } else {
                            Circle()
                                .fill(.white.opacity(isSelected ? 0.78 : 0.55))
                            Image(systemName: tool.iconSystemName)
                                .font(.system(size: 16, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                        }
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.displayName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(canSend ? .primary : .tertiary)
                        HStack(spacing: 6) {
                            Text(tool.endpointDetail)
                                .font(.caption2)
                                .foregroundStyle(canSend ? .secondary : .tertiary)
                                .lineLimit(1)

                            if !canSend {
                                availabilityBadge(tool.unavailableSendReason)
                            }
                        }
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)

            if isExpanded {
                Divider()
                    .padding(.leading, 56)
                    .opacity(0.55)

                VStack(spacing: 4) {
                    NoSessionRow(isSelected: selectedSessionID == nil) {
                        clearSession()
                    }

                    if isLoadingSessions {
                        ForEach(0..<5, id: \.self) { _ in
                            RecentSessionSkeletonRow()
                        }
                    } else {
                        ForEach(sessions) { session in
                            RecentSessionRow(
                                session: session,
                                isSelected: selectedSessionID == session.externalID
                            ) {
                                selectSession(session)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(cardStroke, lineWidth: 1)
                )
        )
        .opacity(canSend ? 1 : 0.58)
    }

    private var cardFill: Color {
        if !canSend {
            return Color.white.opacity(0.24)
        }
        return isSelected ? Color.white.opacity(0.68) : Color.white.opacity(0.42)
    }

    private var cardStroke: Color {
        if !canSend {
            return Color.white.opacity(0.18)
        }
        return isSelected ? Color.blue.opacity(0.42) : Color.white.opacity(0.34)
    }

    private func availabilityBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(canSend ? .secondary : .tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}

// MARK: - IM Channels Section

struct IMChannelsSection: View {
    @Bindable var imService: IMChannelService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerText("Configure IM channels for receiving and forwarding messages")

            VStack(spacing: 10) {
                ForEach(IMPlatformType.visibleIMCases) { platform in
                    IMPlatformCard(platform: platform, imService: imService)
                }
            }

            if let error = imService.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .sheet(
            isPresented: Binding(
                get: { imService.wechatQRCodeURL != nil || imService.wechatStatus == .connecting || imService.wechatStatus == .waitingForScan },
                set: { isPresented in
                    if !isPresented {
                        imService.cancelWeChatLogin()
                    }
                }
            )
        ) {
            WeChatLoginSheet(imService: imService)
        }
    }
}

private struct IMPlatformCard: View {
    let platform: IMPlatformType
    @Bindable var imService: IMChannelService

    var body: some View {
        HStack(spacing: 10) {
            platformIcon

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(platform.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(isAvailable ? .primary : .secondary)

                    if platform == .wechat, imService.isWeChatConnected {
                        Text("Connected")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.green.opacity(0.12))
                            )
                    }

                    if platform == .wechat, imService.isWeChatConnected {
                        Text(imService.wechatAgentState.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(agentStateColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(agentStateColor.opacity(0.12))
                            )
                    }
                }

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                if platform == .wechat {
                    if imService.isWeChatConnected {
                        imService.disconnectWeChat()
                    } else {
                        imService.startWeChatLogin()
                    }
                }
            } label: {
                Text(actionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isAvailable ? .white : .secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isAvailable ? Color.primary.opacity(0.88) : Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isAvailable ? Color.white.opacity(0.42) : Color.white.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(isAvailable ? 0.34 : 0.18), lineWidth: 1)
                )
        )
        .opacity(isAvailable ? 1 : 0.58)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var platformIcon: some View {
        OfficialIMAppIcon(platform: platform)
            .frame(width: 40, height: 40)
    }

    private var isAvailable: Bool {
        platform == .wechat
    }

    private var subtitle: String {
        switch platform {
        case .wechat:
            switch imService.wechatStatus {
            case .connected(let accountID):
                let detail = imService.wechatAgentState.detail
                    .map { " · \($0)" } ?? ""
                return "Receive and reply through the WeChat bot · \(accountID)\(detail)"
            case .connecting:
                return "Generating WeChat login QR code"
            case .waitingForScan:
                return "Scan with WeChat on your phone to connect"
            case .failed(let message):
                return message
            case .disconnected:
                return "Receive and reply through the WeChat bot"
            }
        case .feishu:
            return "Feishu support coming later"
        case .imessage:
            return "iMessage support coming later"
        case .telegram:
            return "Telegram support coming later"
        case .line:
            return "LINE support coming later"
        case .whatsapp:
            return "WhatsApp support coming later"
        default:
            return "\(platform.displayName) support coming later"
        }
    }

    private var actionTitle: String {
        switch platform {
        case .wechat:
            return imService.isWeChatConnected ? "Disconnect" : "Configure"
        case .feishu:
            return "Later"
        case .imessage, .telegram, .line, .whatsapp:
            return "Later"
        default:
            return "Unavailable"
        }
    }

    private var agentStateColor: Color {
        switch imService.wechatAgentState {
        case .idle:
            return .secondary
        case .listening:
            return .blue
        case .reconnecting:
            return .orange
        case .running:
            return .orange
        case .replied:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct OfficialIMAppIcon: View {
    let platform: IMPlatformType

    var body: some View {
        Image(nsImage: IMAppIconProvider.icon(for: platform))
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private enum IMAppIconProvider {
    static func icon(for platform: IMPlatformType) -> NSImage {
        for bundleID in platform.iconBundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }

        for path in platform.iconApplicationPaths where FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }

        if let assetName = platform.fallbackIconAssetName,
           let assetIcon = NSImage(named: NSImage.Name(assetName)) {
            return assetIcon
        }

        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

private extension IMPlatformType {
    var iconBundleIdentifiers: [String] {
        switch self {
        case .wechat:
            return ["com.tencent.xinWeChat", "com.tencent.WeChat"]
        case .feishu:
            return [
                "com.bytedance.macos.feishu",
                "com.larksuite.macos.lark",
                "com.electron.lark",
                "com.larksuite.larkApp"
            ]
        case .imessage:
            return ["com.apple.MobileSMS"]
        case .telegram:
            return ["ru.keepcoder.Telegram", "org.telegram.desktop", "com.tdesktop.Telegram"]
        case .line:
            return ["jp.naver.line.mac"]
        case .whatsapp:
            return ["net.whatsapp.WhatsApp"]
        default:
            return []
        }
    }

    var iconApplicationPaths: [String] {
        switch self {
        case .wechat:
            return ["/Applications/WeChat.app", "/Applications/微信.app"]
        case .feishu:
            return [
                "/Applications/飞书.app",
                "/Applications/Feishu.app",
                "/Applications/Lark.app",
                "/Applications/LarkSuite.app"
            ]
        case .imessage:
            return ["/System/Applications/Messages.app"]
        case .telegram:
            return ["/Applications/Telegram.app", "/Applications/Telegram Lite.app"]
        case .line:
            return ["/Applications/LINE.app"]
        case .whatsapp:
            return ["/Applications/WhatsApp.app"]
        default:
            return []
        }
    }

    var fallbackIconAssetName: String? {
        switch self {
        case .wechat:
            return "IMWechatIcon"
        case .feishu:
            return "IMFeishuIcon"
        case .telegram:
            return "IMTelegramIcon"
        case .line:
            return "IMLineIcon"
        case .whatsapp:
            return "IMWhatsAppIcon"
        default:
            return nil
        }
    }
}

private struct WeChatLoginSheet: View {
    @Bindable var imService: IMChannelService
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.14))
                            .frame(width: 54, height: 54)
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    .offset(y: -10)

                    Text("Scan to Sign In")
                        .font(.title3.weight(.semibold))

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    qrContent
                        .frame(width: 210, height: 210)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 28)

                Button {
                    imService.cancelWeChatLogin()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.82))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(12)
            }

            Divider()

            Button {
                imService.startWeChatLogin()
            } label: {
                Text("Regenerate")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.88))
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 318)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var qrContent: some View {
        if let image = qrImage {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
                )
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var qrImage: NSImage? {
        guard let qrURL = imService.wechatQRCodeURL else {
            return nil
        }
        let data = Data(qrURL.absoluteString.utf8)
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: 210, height: 210))
    }

    private var statusText: String {
        switch imService.wechatStatus {
        case .connecting:
            return "Generating QR code..."
        case .waitingForScan:
            return "Scan the QR code with WeChat to connect"
        case .connected:
            return "WeChat connected"
        case .failed(let message):
            return message
        case .disconnected:
            return "Scan the QR code with WeChat to connect"
        }
    }
}

// MARK: - Scheduled Tasks Section

struct ScheduledTasksSection: View {
    @Bindable var taskService: ScheduledTaskService
    let aiService: AIIntegrationService
    let imService: IMChannelService
    @State private var showingAddSheet = false
    @State private var editingTask: ScheduledTask?
    @State private var viewingRun: ScheduledTaskRun?
    @State private var selectedList: ScheduledTaskList = .tasks
    @State private var sortDescending = true

    private enum ScheduledTaskList: String, CaseIterable, Identifiable {
        case tasks = "My Tasks"
        case runs = "Run History"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader
            wakeNotice
            listHeader

            switch selectedList {
            case .tasks:
                taskList
            case .runs:
                runList
            }
        }
        .padding(16)
        .sheet(isPresented: $showingAddSheet) {
            TaskEditorSheet(taskService: taskService, aiService: aiService, imService: imService)
        }
        .sheet(item: $editingTask) { task in
            TaskEditorSheet(taskService: taskService, aiService: aiService, imService: imService, task: task)
        }
        .sheet(item: $viewingRun, onDismiss: {
            taskService.clearFocusedRun()
        }) { run in
            ScheduledTaskRunDetailSheet(run: run)
        }
        .onAppear(perform: openFocusedRunIfNeeded)
        .onChange(of: taskService.focusedRunID) { _, _ in
            openFocusedRunIfNeeded()
        }
    }

    private func openFocusedRunIfNeeded() {
        guard let focusedRunID = taskService.focusedRunID else { return }
        guard let run = taskService.runs.first(where: { $0.id == focusedRunID }) else {
            taskService.clearFocusedRun()
            return
        }

        selectedList = .runs
        viewingRun = run
        taskService.markRunsSeen()
    }

    private func showRun(_ run: ScheduledTaskRun) {
        viewingRun = run
        taskService.markRunsSeen()
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scheduled Tasks")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Run prompts automatically on a schedule, or trigger them manually.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.92))
                        )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 14) {
                Button {
                    aiService.refreshRecentSessions()
                } label: {
                    Label("Refresh Recent Sessions", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    taskService.sendTestNotification()
                } label: {
                    Label("Test Notification", systemImage: "bell.badge")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var wakeNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)

            Text("Scheduled tasks only run while your Mac is awake")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
                .lineLimit(1)

            Spacer()

            Toggle("Keep Awake", isOn: Binding(
                get: { taskService.keepSystemAwake },
                set: { taskService.setKeepSystemAwake($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.blue)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.88, green: 0.96, blue: 1.0))
        )
    }

    private var listHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            ForEach(ScheduledTaskList.allCases) { item in
                Button {
                    selectedList = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 16, weight: selectedList == item ? .bold : .semibold))
                        .foregroundStyle(selectedList == item ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if selectedList == .tasks {
                Button {
                    sortDescending.toggle()
                } label: {
                    Label(sortDescending ? "Newest First" : "Oldest First", systemImage: "line.3.horizontal.decrease")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .labelStyle(.iconOnly)
                        .frame(width: 32, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sortedTasks: [ScheduledTask] {
        taskService.tasks.sorted {
            sortDescending ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt
        }
    }

    @ViewBuilder
    private var taskList: some View {
        if taskService.tasks.isEmpty {
            VStack(spacing: 7) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("No scheduled tasks yet")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 0)
                ],
                spacing: 10
            ) {
                ForEach(sortedTasks) { task in
                    ScheduledTaskRow(
                        task: task,
                        taskService: taskService,
                        edit: { editingTask = task }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var runList: some View {
        if taskService.runs.isEmpty {
            VStack(spacing: 7) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("No run history yet")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            VStack(spacing: 8) {
                ForEach(taskService.runs) { run in
                    Button {
                        showRun(run)
                    } label: {
                        ScheduledTaskRunRow(run: run)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ScheduledTaskRow: View {
    let task: ScheduledTask
    @Bindable var taskService: ScheduledTaskService
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { task.isEnabled },
                    set: { _ in taskService.toggleTask(id: task.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()

                Spacer()

                Menu {
                    Button {
                        taskService.runNow(id: task.id)
                    } label: {
                        Label("Run Now", systemImage: "play")
                    }

                    Button {
                        edit()
                    } label: {
                        Label("Edit Task", systemImage: "square.and.pencil")
                    }

                    Divider()

                    Button(role: .destructive) {
                        taskService.removeTask(id: task.id)
                    } label: {
                        Label("Delete Task", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(task.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(task.prompt)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle()
                .fill(Color.clear)
                .frame(height: 1)
                .overlay(
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 6]))
                        .foregroundStyle(Color.primary.opacity(0.12))
                )

            HStack(spacing: 8) {
                Label(task.scheduleText, systemImage: "clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.72))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.96, green: 0.94, blue: 0.91))
                    )

                Spacer()

                if let lastRun = task.lastRunAt {
                    Text(lastRun.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(minHeight: 126, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.025), radius: 12, x: 0, y: 6)
    }
}

private struct ScheduledTaskRunRow: View {
    let run: ScheduledTaskRun

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.status == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(run.status == .succeeded ? .green : .orange)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(run.taskName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(run.displayDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if run.responsePreview != nil {
                    Text(run.summaryText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(run.ranAt.formatted(.dateTime.month().day().hour().minute()))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.36))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ScheduledTaskRunDetailSheet: View {
    let run: ScheduledTaskRun
    @Environment(\.dismiss) private var dismiss
    @State private var copiedLabel: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    metaSection
                    ScheduledTaskRunTextBlock(
                        title: "Question",
                        systemImage: "text.quote",
                        text: questionText,
                        emptyText: "No saved prompt snapshot",
                        tint: .blue
                    )
                    ScheduledTaskRunTextBlock(
                        title: "Answer",
                        systemImage: answerIcon,
                        text: answerText,
                        emptyText: "No response",
                        tint: run.status == .succeeded ? .green : .orange
                    )
                }
                .padding(18)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: run.status == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(run.status == .succeeded ? .green : .orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(run.taskName)
                    .font(.headline)
                    .lineLimit(1)
                Text(run.displayDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var metaSection: some View {
        HStack(spacing: 8) {
            Label(run.status.displayName, systemImage: run.status == .succeeded ? "checkmark" : "xmark")
                .foregroundStyle(run.status == .succeeded ? .green : .orange)

            if let targetTool = run.targetTool {
                Label(targetTool.compactDisplayName, systemImage: targetTool.iconSystemName)
                    .foregroundStyle(.secondary)
            }

            if let turnID = run.turnID {
                Label(String(turnID.uuidString.prefix(8)), systemImage: "number")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(run.ranAt.formatted(.dateTime.month().day().hour().minute()))
                .foregroundStyle(.tertiary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let copiedLabel {
                Text("\(copiedLabel) copied")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                copy(answerText, label: "Answer")
            } label: {
                Label("Copy Answer", systemImage: "doc.on.doc")
            }

            Button {
                copy(fullQAText, label: "Q&A")
            } label: {
                Label("Copy Full Q&A", systemImage: "square.on.square")
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var questionText: String {
        let trimmed = run.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed
    }

    private var answerText: String {
        if let response = run.response?.trimmingCharacters(in: .whitespacesAndNewlines),
           !response.isEmpty {
            return response
        }

        return run.displayDetail
    }

    private var answerIcon: String {
        run.status == .succeeded ? "text.bubble" : "exclamationmark.bubble"
    }

    private var fullQAText: String {
        """
        Q:
        \(questionText)

        A:
        \(answerText)
        """
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedLabel = label
    }
}

private struct ScheduledTaskRunTextBlock: View {
    let title: String
    let systemImage: String
    let text: String
    let emptyText: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)

            Text(displayText)
                .font(.system(size: 12.5))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                )
        }
    }

    private var displayText: String {
        text.isEmpty ? emptyText : text
    }
}

private struct TaskEditorSheet: View {
    @Bindable var taskService: ScheduledTaskService
    let aiService: AIIntegrationService
    let imService: IMChannelService
    let task: ScheduledTask?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var prompt = ""
    @State private var cadence: ScheduledTaskCadence = .daily
    @State private var hour = 9
    @State private var minute = 30
    @State private var targetTool: AIToolType?
    @State private var targetChannelID: UUID?

    init(
        taskService: ScheduledTaskService,
        aiService: AIIntegrationService,
        imService: IMChannelService,
        task: ScheduledTask? = nil
    ) {
        self.taskService = taskService
        self.aiService = aiService
        self.imService = imService
        self.task = task
        _name = State(initialValue: task?.name ?? "")
        _prompt = State(initialValue: task?.prompt ?? "")
        _cadence = State(initialValue: task?.cadence ?? .daily)
        _hour = State(initialValue: task?.hour ?? 9)
        _minute = State(initialValue: task?.minute ?? 30)
        _targetTool = State(initialValue: task?.targetTool ?? aiService.preferredTool)
        _targetChannelID = State(initialValue: task?.targetChannelID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeader

            fieldBlock("Task Name") {
                TextField("e.g. Daily Data Report Update", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(inputBackground)
            }

            fieldBlock("Schedule") {
                HStack(spacing: 9) {
                    compactPicker(width: 96) {
                        Picker("", selection: $cadence) {
                            ForEach(ScheduledTaskCadence.allCases) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                    }

                    compactPicker(width: 72) {
                        Picker("", selection: $hour) {
                            ForEach(0..<24, id: \.self) { value in
                                Text(String(format: "%02d", value)).tag(value)
                            }
                        }
                    }

                    Text(":")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.65))

                    compactPicker(width: 72) {
                        Picker("", selection: $minute) {
                            ForEach(stride(from: 0, through: 55, by: 5).map { $0 }, id: \.self) { value in
                                Text(String(format: "%02d", value)).tag(value)
                            }
                        }
                    }
                }
            }

            fieldBlock("Task Prompt") {
                VStack(spacing: 0) {
                    TextEditor(text: $prompt)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .frame(minHeight: 170)

                    HStack(spacing: 8) {
                        if !imService.channels.isEmpty {
                            compactPicker(width: 106) {
                                Picker("", selection: $targetChannelID) {
                                    Text("No Forward").tag(nil as UUID?)
                                    ForEach(imService.channels) { channel in
                                        Text("\(channel.platform.displayName) - \(channel.name)").tag(channel.id as UUID?)
                                    }
                                }
                            }
                        }

                        Spacer()

                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        compactPicker(width: 98) {
                            Picker("", selection: $targetTool) {
                                Text("Auto").tag(nil as AIToolType?)
                                ForEach(AIToolType.allCases) { tool in
                                    Text(tool.compactDisplayName).tag(tool as AIToolType?)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .background(inputBackground)
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.72))
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)

                Button {
                    save()
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.92))
                        )
                }
                .buttonStyle(.plain)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(width: 420)
    }

    private var sheetHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task == nil ? "New Task" : "Edit Task")
                    .font(.system(size: 19, weight: .bold))
                Text("Runs automatically on schedule, or manually on demand.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.78))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.96))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
    }

    private func fieldBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary.opacity(0.82))
            content()
        }
    }

    private func compactPicker<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: width, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.055), lineWidth: 1)
            )
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if var task {
            task.name = trimmedName.isEmpty ? "Scheduled Task" : trimmedName
            task.prompt = trimmedPrompt
            task.cadence = cadence
            task.hour = hour
            task.minute = minute
            task.targetTool = targetTool
            task.targetChannelID = targetChannelID
            taskService.updateTask(task)
        } else {
            taskService.addTask(
                ScheduledTask(
                    name: trimmedName.isEmpty ? "Scheduled Task" : trimmedName,
                    prompt: trimmedPrompt,
                    cadence: cadence,
                    hour: hour,
                    minute: minute,
                    targetTool: targetTool,
                    targetChannelID: targetChannelID
                )
            )
        }
    }
}

// MARK: - Shared helpers

private func headerText(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
}

private var settingsCardBackground: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.white.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.30), lineWidth: 1)
        )
}

private func sectionLabel(_ text: String) -> some View {
    Text(text)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(.top, 4)
}
