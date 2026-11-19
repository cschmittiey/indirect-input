import AppKit
import SwiftUI
import MX2Native

struct ContentView: View {
    @ObservedObject var model: BridgeModel
    @State private var showConnection = false

    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.67, green: 0.70, blue: 0.64)
            : Color(red: 0.34, green: 0.40, blue: 0.31)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            signalPath
            routing
            feedbackHelp
            activity
            footer
        }
        .padding(24)
        .frame(width: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .textFieldStyle(.roundedBorder)
        .tint(accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 48, height: 48).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Indirect Input")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("TRAKTOR MX2  /  NATIVE + RGB")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("A little protocol DI box: Traktor MX2 in, clean OSC out.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var signalPath: some View {
        HStack(spacing: 16) {
            statusLamp("HID connection", model.hidIndicator)
            Divider()
            statusLamp("OSC feedback", model.feedbackIndicator)
            Divider()
            statusLamp("RGB transport", model.rgbIndicator)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)))
    }

    private func statusLamp(_ title: String, _ state: String) -> some View {
        let color: Color = switch state {
        case "Connected", "Received", "Accepted": .green
        case "Error": .orange
        default: .secondary
        }
        return HStack(spacing: 9) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.medium))
                Text(state).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var routing: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("DECK PAIR")
                Picker("Deck pair", selection: Binding(
                    get: { model.deckPair }, set: { model.setDeckPair($0) })) {
                    Text("1 + 2").tag(1)
                    Text("3 + 4").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .frame(width: 178)
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("SET BOTH PAD BANKS")
                Picker("Pad bank for both sides", selection: Binding(
                    get: { model.padBank }, set: { model.setPadBank($0) })) {
                    Text("Cues").tag(MX2PadBank.hotcues)
                    Text("Loops").tag(MX2PadBank.loops)
                    Text("Stems · unmapped").tag(MX2PadBank.stems)
                    Text("Sampler").tag(MX2PadBank.pattern)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 2)
    }

    private var feedbackHelp: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 17))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("No subscriptions, no lights.").font(.system(size: 13, weight: .semibold))
                Text("In Syndicate → OSC FEEDBACK, tick subscriptions (Playing, Cues, Loop, Meter) and send to 127.0.0.1:9096. Then resend state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Resend feedback") { model.requestFeedback() }
                    Button("Syndicate settings…") { model.openSyndicateSettings() }
                }
                .padding(.top, 3)
                if !model.settingsNotice.isEmpty {
                    Text(model.settingsNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionLabel("LAST SIGNAL")
                Spacer()
                Circle().fill(model.flash ? accent : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text("\(model.eventCount) OSC events  ·  \(model.feedbackRenders) renders")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            signalLine("IN", text: model.nativeInput)
            signalLine("OUT", text: model.nativeOutput)
            Text("RGB acceptance is not proof that the LEDs lit.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func signalLine(_ direction: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(direction).foregroundStyle(.tertiary).frame(width: 28, alignment: .leading)
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    sectionLabel("OSC DESTINATION")
                    Text("\(model.osc.host):\(String(model.osc.port))")
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                Spacer()
                Button(showConnection ? "Hide editor" : "Edit address…") { showConnection.toggle() }
            }
            if showConnection {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        TextField("Host", text: $model.host).accessibilityLabel("OSC host")
                        TextField("Port", text: $model.port).frame(width: 75)
                            .accessibilityLabel("OSC port")
                        Button("Apply") { model.apply() }
                    }
                    Text("Match the host and port to Syndicate’s OSC INPUT. Feedback always listens locally on 9096.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.connectionNotice.isEmpty {
                        Text(model.connectionNotice).font(.caption).textSelection(.enabled)
                    }
                }
                .padding(.top, 8)
            }
            HStack {
                Spacer()
                Button("Reveal diagnostic log") { model.revealLog() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}
