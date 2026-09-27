import SwiftUI
#if canImport(SafeSpaceCore)
import SafeSpaceCore
#endif

enum AppLanguage: String, CaseIterable, Identifiable { case english = "English", vietnamese = "Tiếng Việt"; var id: String { rawValue } }

struct ContentView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appLanguage") private var language = AppLanguage.english.rawValue
    @State private var section: String? = "cache"
    @State private var pending: [DiskEntry] = []
    @State private var showCleanSheet = false
    @State private var showAccessGuide = false
    @State private var acknowledged = false
    @State private var reviewPhrase = ""
    @State private var pendingDocker: DockerAction?
    @State private var dockerAcknowledged = false
    @State private var volumePhrase = ""
    @State private var filter = ""
    private var vi: Bool { language == AppLanguage.vietnamese.rawValue }
    private func t(_ en: String, _ vn: String) -> String { vi ? vn : en }
    private var group: DiskGroup { DiskGroup.all.first { $0.id == section } ?? DiskGroup.all[0] }
    private var currentResult: GroupResult? { model.openedResult ?? model.results[group.id] }
    private var entries: [DiskEntry] { (currentResult?.entries ?? []).filter { filter.isEmpty || $0.url.lastPathComponent.localizedCaseInsensitiveContains(filter) } }

    var body: some View {
        NavigationSplitView { sidebar } detail: {
            VStack(spacing: 0) {
                summary.padding(24); Divider()
                if section == "docker" { dockerPanel } else { storagePanel }
                Divider(); HStack(spacing: 10) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2); Spacer()
                    if model.isScanning { Button(t("Stop scan", "Dừng quét")) { model.cancel() } }
                    Button(t("Activity", "Nhật ký")) { model.showActivity = true }
                }.padding(12)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.blue).preferredColorScheme(.light)
        .toolbar {
            ToolbarItemGroup {
                Button { model.scan() } label: { Label(t("Scan", "Quét"), systemImage: "magnifyingglass") }.disabled(model.busy)
                Button { section == "docker" ? model.refreshDocker() : model.scan() } label: { Label(t("Refresh", "Làm mới"), systemImage: "arrow.clockwise") }.disabled(model.busy)
                Button { model.reveal(section == "docker" ? model.home.appendingPathComponent("Library/Containers/com.docker.docker") : model.home.appendingPathComponent(group.relativePath)) } label: { Label(t("Open in Finder", "Mở Finder"), systemImage: "folder") }
                Menu {
                    Picker(t("Display language", "Ngôn ngữ hiển thị"), selection: $language) { ForEach(AppLanguage.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    Divider()
                    Button(t("Deep scan & access guide", "Hướng dẫn quét sâu và quyền truy cập")) { showAccessGuide = true }
                } label: { Label(t("Settings", "Cài đặt"), systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $showCleanSheet) { cleanConfirmation }
        .sheet(isPresented: $showAccessGuide) { accessGuide }
        .sheet(item: $pendingDocker) { dockerConfirmation($0) }
        .sheet(isPresented: $model.showActivity) { activitySheet }
        .onChange(of: section) { _ in model.closeFolder() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Fuk Mac Storage", systemImage: "internaldrive.fill").font(.title2.bold()).foregroundStyle(.blue).padding(.horizontal, 16).padding(.top, 18)
            Text(t("STORAGE, UNDER CONTROL", "QUẢN LÝ DUNG LƯỢNG")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16)
            List(selection: $section) {
                Section(t("Storage categories", "Nhóm dung lượng")) { ForEach(DiskGroup.all) { sidebarRow($0) } }
                if model.docker != nil { Section("Docker") { Label("Docker", systemImage: "shippingbox.fill").tag("docker") } }
            }.listStyle(.sidebar)
            Label(t("Nothing is selected automatically", "Không tự chọn để xoá"), systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary).padding(16)
        }.navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 310)
    }
    private func sidebarRow(_ group: DiskGroup) -> some View {
        HStack { Label(group.title, systemImage: group.icon); Spacer(); if let result = model.results[group.id] { Text(formattedBytes(result.bytes)).font(.caption).foregroundStyle(.secondary) } }.tag(group.id)
    }
    private var summary: some View {
        HStack(spacing: 22) {
            metric(t("Available storage", "Dung lượng trống"), formattedBytes(model.freeBytes), t("Reported by macOS", "macOS báo cáo"), "internaldrive")
            Divider().frame(height: 56)
            metric(t("Scanned storage", "Đã quét"), formattedBytes(model.cacheBytes), t("Selected categories", "Các nhóm có thể chọn"), "externaldrive")
            Divider().frame(height: 56)
            metric(t("Ready to clean", "Sẵn sàng dọn"), formattedBytes(model.selectedBytes), t("Moves to Trash first", "Chuyển vào Thùng rác trước"), "trash")
        }
    }
    private func metric(_ title: String, _ value: String, _ detail: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).foregroundStyle(.primary).monospacedDigit(); Text(detail).font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var storagePanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let folder = model.openedFolder {
                        Button { model.closeFolder() } label: { Label(t("Back to category", "Quay lại nhóm"), systemImage: "chevron.left") }.buttonStyle(.borderless)
                        Text(folder.lastPathComponent).font(.title.bold()).foregroundStyle(.primary)
                    } else { Text(group.title).font(.title.bold()).foregroundStyle(.primary) }
                    Text(model.openedFolder == nil ? group.note : t("Select a folder to scan one level deeper.", "Chọn thư mục để quét sâu thêm một cấp.")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(); Label(t("Review before cleaning", "Xem trước khi dọn"), systemImage: "checkmark.shield").font(.caption.weight(.medium)).padding(8).background(Color.blue.opacity(0.10), in: Capsule()).foregroundStyle(.blue)
            }
            if let result = currentResult {
                if !result.issues.isEmpty { Label(t("Some items could not be fully scanned. Their size is partial; cleaning needs an extra confirmation.", "Một số mục chưa quét đủ. Dung lượng là một phần; dọn cần xác nhận thêm."), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                HStack { TextField(t("Search items…", "Tìm mục…"), text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 330); Spacer(); Text("\(entries.count) " + t("items", "mục")).font(.caption).foregroundStyle(.secondary) }
                ScrollView { LazyVStack(spacing: 0) { ForEach(entries) { entry in entryRow(entry); Divider() } } }
            } else { Spacer(); VStack(spacing: 12) { Image(systemName: "internaldrive.badge.magnifyingglass").font(.system(size: 46)).foregroundStyle(.blue); Text(model.busy ? t("Scanning…", "Đang quét…") : t("Scan your Mac to begin", "Quét máy Mac để bắt đầu")).font(.title3.weight(.semibold)); Text(t("We only read storage information until you choose an item.", "App chỉ đọc dung lượng cho đến khi bạn chọn mục.")).foregroundStyle(.secondary); if !model.busy { Button(t("Scan storage", "Quét dung lượng")) { model.scan() }.buttonStyle(.borderedProminent) } }.frame(maxWidth: .infinity); Spacer() }
            HStack {
                Button(t("Select all scanned", "Chọn tất cả đã quét")) { entries.filter(\.eligible).forEach { model.selected.insert($0.id) } }.disabled(entries.filter(\.eligible).isEmpty || model.busy)
                Button(t("Clear selection", "Bỏ chọn")) { model.selected.removeAll() }.disabled(model.selected.isEmpty || model.busy)
                Spacer()
                Text("\(model.chosen.count) " + t("items", "mục") + " • " + formattedBytes(model.selectedBytes)).font(.callout)
                Button(t("Clean selected…", "Dọn mục đã chọn…")) { pending = model.chosen.sorted { $0.url.path < $1.url.path }; acknowledged = false; reviewPhrase = ""; showCleanSheet = true }.buttonStyle(.borderedProminent).disabled(model.selected.isEmpty || model.busy)
            }
            Text(t("Size is an estimate. APFS snapshots, clones and hard links can make the actual recovered space different.", "Dung lượng là ước tính; APFS snapshots, clones và hard links có thể làm dung lượng thực khác.")).font(.caption2).foregroundStyle(.secondary)
        }.padding(24)
    }
    private func entryRow(_ entry: DiskEntry) -> some View {
        HStack(spacing: 12) {
            if entry.eligible { Toggle("", isOn: Binding(get: { model.selected.contains(entry.id) }, set: { value in
                if value { model.selected.insert(entry.id) } else { model.selected.remove(entry.id) }
            })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy) } else { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).frame(width: 16) }
            VStack(alignment: .leading, spacing: 3) {
                if entry.isDirectory { Button(entry.url.lastPathComponent) { model.openFolder(entry, group: group) }.buttonStyle(.plain).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1) }
                else { Text(entry.url.lastPathComponent).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1) }
                if entry.isDirectory { Text(t("Click name to open", "Bấm tên để mở")).font(.caption2).foregroundStyle(.blue) }
                if entry.needsExtraConfirmation { Text(t("Needs an extra confirmation", "Cần xác nhận thêm")).font(.caption2).foregroundStyle(.orange) }; if entry.isLink { Text(t("Symbolic link — not followed", "Symbolic link — không đi theo")).font(.caption2).foregroundStyle(.secondary) }; if entry.issueCount > 0 { Text(t("Partial scan — still available with review", "Quét một phần — vẫn có thể dọn sau khi xác nhận")).font(.caption2).foregroundStyle(.orange) }
            }
            Spacer(); Text(formattedBytes(entry.bytes)).monospacedDigit().foregroundStyle(.secondary)
            if entry.isDirectory { Button { model.openFolder(entry, group: group) } label: { Image(systemName: "chevron.right") }.help(t("Open folder", "Mở thư mục")).buttonStyle(.borderless) }
            Button { model.reveal(entry.url) } label: { Image(systemName: "folder") }.help(t("Open in Finder", "Mở Finder")).buttonStyle(.borderless)
        }.padding(.vertical, 11).padding(.horizontal, 4)
    }
    private var cleanConfirmation: some View {
        let requiresReview = pending.contains(where: \.needsExtraConfirmation)
        return VStack(alignment: .leading, spacing: 16) { Label(t("Move selected items to Trash?", "Chuyển mục đã chọn vào Thùng rác?"), systemImage: "trash").font(.title2.bold()).foregroundStyle(.blue); Text("\(pending.count) " + t("items", "mục") + " • " + formattedBytes(pending.reduce(0) { $0 + $1.bytes })); Text(t("The selected folders and their current contents will move to Trash. Storage becomes available only after you empty Trash yourself.", "Các thư mục đã chọn và nội dung hiện có sẽ được chuyển vào Thùng rác. Dung lượng chỉ trống sau khi bạn tự làm trống Thùng rác.")).foregroundStyle(.secondary); ScrollView { VStack(alignment: .leading, spacing: 7) { ForEach(pending) { Text($0.url.lastPathComponent).font(.system(.caption, design: .monospaced)) } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 150); Toggle(t("I closed related apps and stopped active builds.", "Tôi đã đóng app liên quan và dừng build."), isOn: $acknowledged); if requiresReview { TextField(t("Type REMOVE to confirm app/developer data", "Gõ REMOVE để xác nhận dữ liệu app/dev"), text: $reviewPhrase).textFieldStyle(.roundedBorder) }; HStack { Button(t("Cancel", "Huỷ")) { showCleanSheet = false }.keyboardShortcut(.cancelAction); Spacer(); Button(t("Move to Trash", "Chuyển vào Thùng rác"), role: .destructive) { showCleanSheet = false; model.clean(pending) }.disabled(!acknowledged || (requiresReview && reviewPhrase != "REMOVE")) } }.padding(26).frame(width: 650)
    }
    private var dockerPanel: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) { HStack { Text("Docker").font(.title.bold()); Spacer(); Button(t("Refresh Docker", "Làm mới Docker")) { model.refreshDocker() }.disabled(model.busy) }; Text(t("Docker cleanup deletes directly and never uses Trash. Each level has its own confirmation.", "Dọn Docker xoá trực tiếp, không dùng Thùng rác. Mỗi mức cần xác nhận riêng.")).foregroundStyle(.secondary); if let report = model.docker { Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) { GridRow { Text(t("Type", "Loại")); Text(t("Size", "Dung lượng")); Text("Reclaimable") }.font(.caption.bold()); ForEach(report.usage) { row in GridRow { Text(row.type); Text(row.size); Text(row.reclaimable) } } }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)); ForEach(DockerAction.allCases) { action in VStack(alignment: .leading, spacing: 8) { HStack { Text(action.title).font(.headline); Spacer(); Button(t("Review…", "Xem trước…")) { dockerAcknowledged = false; volumePhrase = ""; pendingDocker = action } }; Text(action.warning).font(.caption).foregroundStyle(.secondary); Text("docker " + action.arguments.joined(separator: " ")).font(.system(.caption, design: .monospaced)) }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)) } } }.padding(24) }
    }
    private func dockerConfirmation(_ action: DockerAction) -> some View {
        VStack(alignment: .leading, spacing: 16) { Label(action.title, systemImage: "exclamationmark.triangle.fill").font(.title2.bold()).foregroundStyle(.orange); Text(action.warning); if let report = model.docker { Text(t("Estimated reclaimable: ", "Ước tính reclaimable: ") + report.estimate(for: action)).font(.callout); Toggle(t("I understand this deletes directly and I have checked my data.", "Tôi hiểu thao tác xoá trực tiếp và đã kiểm tra dữ liệu."), isOn: $dockerAcknowledged); if action == .volumes { TextField(t("Type DELETE VOLUMES", "Gõ DELETE VOLUMES"), text: $volumePhrase).textFieldStyle(.roundedBorder) }; HStack { Button(t("Cancel", "Huỷ")) { pendingDocker = nil }; Spacer(); Button(t("Run prune", "Chạy prune"), role: .destructive) { pendingDocker = nil; model.prune(action, report: report) }.disabled(!dockerAcknowledged || (action == .volumes && volumePhrase != "DELETE VOLUMES")) } } }.padding(26).frame(width: 650)
    }
    private var activitySheet: some View {
        let lines = model.activity.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: model.activityTitle.contains("complete") ? "checkmark.circle.fill" : "clock.arrow.circlepath").font(.system(size: 30)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.activityTitle).font(.title3.bold()).foregroundStyle(.white)
                    Text(model.activityDate.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.white.opacity(0.82))
                }
                Spacer()
            }.padding(22).background(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 14) {
                Label(t("Operation details", "Chi tiết thao tác"), systemImage: "list.bullet.rectangle").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: line.hasPrefix("Moved") ? "checkmark.circle.fill" : "info.circle.fill").foregroundStyle(line.hasPrefix("Moved") ? .blue : .secondary)
                                Text(line).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(11).background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                Text(t("The list was updated without a full scan. Use Refresh when you want a new storage measurement.", "Danh sách đã được cập nhật mà không quét lại toàn bộ. Dùng Làm mới khi bạn muốn đo lại dung lượng.")).font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button(t("Done", "Xong")) { model.showActivity = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            }.padding(22)
        }.frame(width: 720, height: 470).background(Color(nsColor: .windowBackgroundColor))
    }

    private var accessGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(t("Deep scan & access", "Quét sâu và quyền truy cập"), systemImage: "lock.shield").font(.title2.bold()).foregroundStyle(.blue)
            Text(t("Fuk Mac Storage scans inside each selected storage category. If macOS protects some files, the app reports a partial size and requires an extra confirmation before moving the parent item to Trash.", "Fuk Mac Storage quét bên trong từng nhóm dữ liệu. Nếu macOS bảo vệ một số file, app ghi dung lượng một phần và yêu cầu xác nhận thêm trước khi chuyển mục cha vào Thùng rác."))
            Divider()
            Text(t("How to clean all app cache", "Cách dọn toàn bộ app cache")).font(.headline)
            Text(t("Scan → App caches → Select all scanned → Clean selected. This moves the contents of your Caches folder to Trash; it does not delete the Caches folder itself.", "Quét → App caches → Chọn tất cả đã quét → Dọn mục đã chọn. App chuyển nội dung của Caches vào Thùng rác, không xoá thư mục Caches."))
            Divider()
            Text(t("Full Disk Access", "Full Disk Access")).font(.headline)
            Text(t("If Terminal can remove an item but this app cannot, Terminal may have Full Disk Access. You can grant the same permission in System Settings → Privacy & Security → Full Disk Access, then quit and reopen Fuk Mac Storage and scan again.", "Nếu Terminal xoá được mà app không được, Terminal có thể đã có Full Disk Access. Bạn có thể cấp quyền đó tại System Settings → Privacy & Security → Full Disk Access, sau đó tắt/mở Fuk Mac Storage và quét lại."))
            Text(t("Risk: Full Disk Access lets this app inspect and move much more of your personal data. Only enable it when necessary, use the signed copy you trust, and turn it off again when you are done. It does not bypass macOS protections for every system-owned file.", "Rủi ro: Full Disk Access cho phép app xem và chuyển nhiều dữ liệu cá nhân hơn. Chỉ bật khi cần, chỉ dùng bản app bạn tin cậy và tắt lại sau khi xong. Quyền này không vượt qua mọi bảo vệ của macOS đối với file hệ thống."))
                .foregroundStyle(.orange)
            HStack { Spacer(); Button(t("Close", "Đóng")) { showAccessGuide = false }.keyboardShortcut(.cancelAction) }
        }.padding(26).frame(width: 690)
    }
}
