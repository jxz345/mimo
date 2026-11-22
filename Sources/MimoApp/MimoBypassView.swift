import SwiftUI

struct MimoBypassView: View {
    @ObservedObject var monitor: PublicIPMonitor
    @Binding var draft: MimoBypassDraft
    @State private var bulk = ""
    @State private var match: MimoBypassDomain.Match = .suffix
    @State private var error: String?
    @State private var deleting: UUID?
    private var index: Int? { draft.blocks.firstIndex { $0.id == draft.selected } }
    private var conflict: Bool { draft.conflicts(with: monitor.daemonState) }
    private var busy: Bool { !monitor.canChangeSharedSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Rule only", systemImage: "arrow.triangle.branch").font(.callout.weight(.medium))
                Text(monitor.routingState.configuration.mode == .rule
                     ? "Enabled blocks bypass your selected proxy." : "Saved for Rule. Direct and Global do not use these blocks.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Domain blocks").font(.headline)
                        Spacer()
                        Button(action: addBlock) { Image(systemName: "plus") }.accessibilityLabel("Add bypass block")
                    }.padding(.bottom, 8)
                    ForEach(draft.blocks) { block in
                        Button {
                            draft.selected = block.id; bulk = ""; error = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(block.name.isEmpty ? "Untitled block" : block.name).font(.callout.weight(.medium))
                                HStack {
                                    Text("\(block.domains.count) domains"); Spacer(); Text(block.enabled ? "On" : "Off")
                                }.font(.caption).foregroundStyle(.secondary)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(draft.selected == block.id ? Color.primary.opacity(0.08) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                }.padding(14).frame(width: 210)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    if let index { editor(index) }
                    else {
                        Text("Your bypass list is empty").font(.headline)
                        Text("Add a named block, then enter the domains it should match.").foregroundStyle(.secondary)
                        Button("Add block", action: addBlock)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
                .disabled(busy)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if conflict {
                Text("Shared settings changed in another window or account. Reload before applying; your draft is still here.")
                    .font(.callout).foregroundStyle(.orange)
                Button("Discard draft and reload") { draft.receive(monitor.daemonState, discard: true); error = nil }
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(monitor.isChangingSettings ? "Applying changes…" : draft.isDirty ? "Unsaved changes" : "All changes saved").font(.headline)
                    Text(monitor.routingState.configuration.mode == .rule ? "Apply once to update the Rule profile." : "Changes take effect when you select Rule.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { draft.receive(monitor.daemonState, discard: true); bulk = ""; error = nil }
                    .disabled(!draft.isDirty || busy)
                Button("Apply changes") { apply() }.disabled(!draft.isDirty || busy || conflict || draft.revision == nil)
            }
            Label("MagicDNS, native Tailscale transport and local-network rules are managed by Mimo. These blocks change website routing only.", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { draft.receive(monitor.daemonState) }
        .onChange(of: monitor.daemonState?.revision) { _, _ in draft.receive(monitor.daemonState) }
        .confirmationDialog("Delete this bypass block and its domains?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete block", role: .destructive) {
                draft.blocks.removeAll { $0.id == deleting }; draft.selected = draft.blocks.first?.id; deleting = nil
            }
        } message: { Text("Your active rules change only when you apply.") }
    }

    private func editor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Block name", text: $draft.blocks[index].name)
                Toggle("Enabled", isOn: $draft.blocks[index].enabled).toggleStyle(.switch).fixedSize()
                Button { deleting = draft.blocks[index].id } label: { Image(systemName: "trash") }.accessibilityLabel("Delete block")
            }
            Text(draft.blocks[index].enabled ? "These domains connect directly in Rule mode." : "This block is off. Its domains are kept for later.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(draft.blocks[index].domains.indices, id: \.self) { row in
                HStack(spacing: 8) {
                    TextField("example.com", text: $draft.blocks[index].domains[row].domain)
                        .autocorrectionDisabled().accessibilityLabel("Domain \(row + 1)")
                    matchPicker($draft.blocks[index].domains[row].match)
                    Button { draft.blocks[index].domains.remove(at: row) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Remove domain \(row + 1)")
                }
            }
            Divider()
            Text("Add domains · one per line").font(.callout)
            TextEditor(text: $bulk).font(.system(.body, design: .monospaced)).frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator)).accessibilityLabel("New domains, one per line")
            HStack { matchPicker($match); Spacer(); Button("Add domains") { addDomains(index) }.disabled(bulk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.textFieldStyle(.roundedBorder)
    }
    private func matchPicker(_ selection: Binding<MimoBypassDomain.Match>) -> some View {
        Picker("Match", selection: selection) {
            Text("Domain + subdomains").tag(MimoBypassDomain.Match.suffix)
            Text("Exact domain").tag(MimoBypassDomain.Match.exact)
        }.labelsHidden().frame(width: 170)
    }
    private func addBlock() {
        let block = MimoBypassBlock(); draft.blocks.append(block); draft.selected = block.id; bulk = ""; error = nil
    }
    private func addDomains(_ index: Int) {
        do {
            let entries = try bulk.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { try MimoBypassDomain(String($0), match: match).validated() }
            for entry in entries where !draft.blocks[index].domains.contains(entry) { draft.blocks[index].domains.append(entry) }
            bulk = ""; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func apply() {
        do {
            let blocks = try MimoBypassBlock.validated(draft.blocks)
            guard let revision = draft.revision else { return }
            Task {
                if await monitor.saveBypass(blocks, expectedRevision: revision) { draft.receive(monitor.daemonState, discard: true); error = nil }
            }
        } catch { self.error = error.localizedDescription }
    }
}
