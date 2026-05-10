import SwiftUI
import OSLog

/// File preview, rendered as a tab inside SessionView. Read-only by
/// default with a `pencil` toggle to edit text files inline; save uses
/// `expected_sha256` for optimistic-locking, falling through to a
/// "discard / overwrite" alert on `Conflict (-32004)`.
struct PreviewPane: View {
    @Environment(MotifClient.self) private var motif
    let path: String

    private let log = Logger(subsystem: "io.allsunday.motif", category: "PreviewPane")

    @State private var loading: Bool = true
    @State private var error: String?
    @State private var content: String = ""
    @State private var loadedSha: String?
    @State private var isBinary: Bool = false
    @State private var byteSize: Int = 0
    @State private var truncated: Bool = false
    @State private var mime: String?

    @State private var editing: Bool = false
    @State private var buffer: String = ""
    @State private var saving: Bool = false
    @State private var saveError: String?
    @State private var conflictPrompt: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                Color(.systemBackground)
                content_
            }
        }
        .task { await load() }
        .alert("File changed on the server",
               isPresented: $conflictPrompt) {
            Button("Discard my edits") {
                Task { await load() }
                editing = false
            }
            Button("Overwrite anyway", role: .destructive) {
                Task { await save(force: true) }
            }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Someone else wrote to '\(basename(path))' since you started editing. Overwriting will discard their changes.")
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(basename(path))
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !editing {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.footnote)
                }
                if !isBinary {
                    Button {
                        buffer = content
                        editing = true
                        saveError = nil
                    } label: {
                        Image(systemName: "pencil").font(.footnote)
                    }
                }
            } else {
                Button("Cancel") {
                    editing = false
                    buffer = ""
                    saveError = nil
                }
                .font(.caption)
                Button {
                    Task { await save(force: false) }
                } label: {
                    if saving {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Save").font(.caption.bold())
                    }
                }
                .disabled(saving || buffer == content)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content_: some View {
        if loading && content.isEmpty && !isBinary {
            ProgressView("Loading…")
        } else if let error {
            failureView(error)
        } else if isBinary {
            binaryStub
        } else if editing {
            TextEditor(text: $buffer)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(8)
        } else if !content.isEmpty {
            ScrollView([.vertical, .horizontal]) {
                Text(content)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
            .overlay(alignment: .topTrailing) {
                if truncated {
                    Text("truncated")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.7), in: Capsule())
                        .foregroundStyle(.black)
                        .padding(8)
                }
            }
        } else {
            Text("(empty)")
                .foregroundStyle(.secondary)
        }
    }

    private var binaryStub: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(basename(path))
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 24)
            Text(binarySummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var binarySummary: String {
        var parts: [String] = []
        if let mime, !mime.isEmpty { parts.append(mime) }
        parts.append("\(byteSize) B")
        if truncated { parts.append("(truncated)") }
        return parts.joined(separator: " · ")
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Retry") { Task { await load() } }
        }
    }

    // MARK: - Loading / saving

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let r = try await motif.fsRead(path: path)
            isBinary = r.binary
            truncated = r.truncated
            mime = r.mime
            loadedSha = r.sha256
            if let bytes = Data(base64Encoded: r.content_b64) {
                byteSize = bytes.count
                if !r.binary {
                    content = String(data: bytes, encoding: .utf8) ?? ""
                }
            } else {
                byteSize = 0
                content = ""
            }
            // Reset edit state on a clean load.
            buffer = content
            saveError = nil
        } catch {
            log.error("fs.read(\(path, privacy: .public)): \(String(describing: error), privacy: .public)")
            self.error = "fs.read: \(error)"
        }
    }

    /// Persist `buffer`. Default path uses `expected_sha256 = loadedSha`
    /// so a server-side concurrent change triggers Conflict (-32004) and
    /// we route it to the discard/overwrite alert. `force == true` skips
    /// the lock — used by the alert's "Overwrite anyway" branch.
    private func save(force: Bool) async {
        saving = true
        saveError = nil
        defer { saving = false }
        let data = Data(buffer.utf8)
        let b64  = data.base64EncodedString()
        do {
            let r = try await motif.fsWrite(
                path: path,
                contentB64: b64,
                expectedSha256: force ? nil : loadedSha,
                force: force
            )
            content = buffer
            loadedSha = r.sha256
            byteSize = data.count
            editing = false
        } catch RpcClient.RpcError.server(let code, _) where code == -32004 {
            // Conflict — surface the discard / overwrite alert. We keep
            // `editing` true so the user's text isn't lost.
            conflictPrompt = true
        } catch {
            saveError = "save: \(error)"
        }
    }

    private func basename(_ p: String) -> String {
        if let slash = p.lastIndex(of: "/") {
            return String(p[p.index(after: slash)...])
        }
        return p
    }
}
