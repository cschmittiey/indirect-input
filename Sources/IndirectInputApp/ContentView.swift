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
                PatchMark().frame(width: 48, height: 48).accessibilityHidden(true)
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
        VStack(alignment: .leading, spacing: 0) {
            statusRow("HID connection", symbol: "cable.connector",
                      detail: model.nativeStatus,
                      color: model.nativeConnected ? accent : .orange)
            Divider().padding(.leading, 40)
            statusRow("OSC feedback", symbol: "arrow.down.left",
                      detail: model.feedbackStatus, color: .secondary)
            Divider().padding(.leading, 40)
            statusRow("RGB transport", symbol: "lightbulb",
                      detail: model.rgbStatus, color: .secondary)
        }
        .padding(.horizontal, 14)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)))
    }

    private func statusRow(_ title: String, symbol: String,
                           detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 22, height: 20)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 12, weight: .medium)).frame(width: 106, alignment: .leading)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 12)
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
            DisclosureGroup("OSC destination", isExpanded: $showConnection) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        TextField("Host", text: $model.host).accessibilityLabel("OSC host")
                        TextField("Port", text: $model.port).frame(width: 75)
                            .accessibilityLabel("OSC port")
                        Button("Apply") { model.apply() }
                    }
                    Text("Enable Syndicate OSC INPUT on port 9090. Feedback always listens locally on 9096.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.connectionNotice.isEmpty {
                        Text(model.connectionNotice).font(.caption).textSelection(.enabled)
                    }
                }
                .padding(.top, 8)
            }
            .font(.caption)
            HStack {
                Text("OSC → \(model.osc.host):\(String(model.osc.port))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
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

/// A tiny patch cable; the same geometry is used by Resources/AppIcon.svg.
private struct PatchMark: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Color(red: 0.16, green: 0.18, blue: 0.18))
                Path { path in
                    path.move(to: CGPoint(x: size * 0.25, y: size * 0.32))
                    path.addLine(to: CGPoint(x: size * 0.39, y: size * 0.32))
                    path.addCurve(to: CGPoint(x: size * 0.61, y: size * 0.68),
                                  control1: CGPoint(x: size * 0.65, y: size * 0.32),
                                  control2: CGPoint(x: size * 0.35, y: size * 0.68))
                    path.addLine(to: CGPoint(x: size * 0.75, y: size * 0.68))
                }
                .stroke(Color(red: 0.85, green: 0.83, blue: 0.78),
                        style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round))
                ForEach(0..<2) { index in
                    Circle()
                        .fill(Color(red: 0.16, green: 0.18, blue: 0.18))
                        .overlay(Circle().strokeBorder(Color(red: 0.85, green: 0.83, blue: 0.78),
                                                      lineWidth: size * 0.045))
                        .frame(width: size * 0.19, height: size * 0.19)
                        .position(x: size * (index == 0 ? 0.25 : 0.75),
                                  y: size * (index == 0 ? 0.32 : 0.68))
                }
            }
        }
    }
}
