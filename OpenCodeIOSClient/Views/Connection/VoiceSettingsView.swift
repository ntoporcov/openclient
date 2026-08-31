import SwiftUI

struct VoiceSettingsView: View {
    @ObservedObject var store: SpeechVoiceStore

    var body: some View {
        Form {
            Section {
                Picker("Input Mode", selection: Binding(
                    get: { store.isHoldToTalkEnabled },
                    set: { store.setHoldToTalkEnabled($0) }
                )) {
                    Text("Automatic").tag(false)
                    Text("Hold to Talk").tag(true)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Talk")
            } footer: {
                Text("Automatic sends after silence. Hold to Talk sends when you release the sphere.")
            }

            Text("Download more voices in Settings > Accessibility > Read & Speak (or Spoken Content) > Voices. OpenClient updates this list automatically after a voice downloads.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)

            Section {
                personalVoiceContent
            } header: {
                Text("Personal Voice")
            } footer: {
                Text("Create a Personal Voice in Settings > Accessibility > Personal Voice, then allow OpenClient to use it here.")
            }

            Section {
                voiceRow(
                    title: String(localized: "Best Available"),
                    subtitle: String(localized: "Automatically prefers Premium, then Enhanced, then Standard."),
                    identifier: nil
                )

                if store.compatibleVoiceOptions.isEmpty {
                    Text("No installed voices are available for this language.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.compatibleVoiceOptions) { voice in
                        voiceRow(
                            title: voice.name,
                            subtitle: voiceSubtitle(voice),
                            identifier: voice.identifier
                        )
                    }
                }
            } header: {
                Text("Installed Voices")
            } footer: {
                Text("Best Available automatically uses the highest-quality installed voice for your language.")
            }

        }
        .navigationTitle("Voice")
        .opencodeInlineNavigationTitle()
        .onAppear {
            store.refreshVoices()
        }
        .onDisappear {
            store.stopPreview()
        }
    }

    private func voiceRow(title: String, subtitle: String, identifier: String?) -> some View {
        let isPreviewing = store.isPreviewingVoice(identifier: identifier)

        return HStack(spacing: 12) {
            Button {
                if isPreviewing {
                    store.stopPreview()
                } else {
                    store.previewVoice(identifier: identifier)
                }
            } label: {
                Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                    .foregroundStyle(isPreviewing ? Color.accentColor : Color.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPreviewing ? Text("Stop Preview") : Text("Preview"))
            .accessibilityValue(title)

            Button {
                store.selectVoice(identifier: identifier)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if store.selectedVoiceIdentifier == identifier {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var personalVoiceContent: some View {
        switch store.personalVoiceAccess {
        case .notDetermined:
            Button {
                store.requestPersonalVoiceAccess()
            } label: {
                if store.isRequestingPersonalVoiceAccess {
                    ProgressView()
                } else {
                    Label("Allow Personal Voice", systemImage: "person.wave.2")
                }
            }
            .disabled(store.isRequestingPersonalVoiceAccess)
        case .authorized:
            Label("Personal Voice access is allowed.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Label("Personal Voice access was denied. You can change this in Settings.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        case .unsupported:
            Label("Personal Voice is not available on this device.", systemImage: "person.crop.circle.badge.xmark")
                .foregroundStyle(.secondary)
        }
    }

    private func voiceSubtitle(_ voice: SpeechVoiceOption) -> String {
        let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        return "\(language) - \(String(localized: voice.quality.title))"
    }
}
